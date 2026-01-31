#!/bin/bash
set -euo pipefail

cd /actions-runner

VERSION_FILE=".runner-version"
CONFIGURED_FILE=".runner-configured"

# Determine the runner download asset URL from GitHub Releases (no RUNNER_VERSION required)
log "Determining runner asset (linux x64) from GitHub Releases API"
if [ -n "${GITHUB_TOKEN:-}" ]; then
  release_resp=$(curl -s -H "Authorization: token ${GITHUB_TOKEN}" "https://api.github.com/repos/actions/runner/releases/latest")
else
  release_resp=$(curl -s "https://api.github.com/repos/actions/runner/releases/latest")
fi
RUNNER_URL_DL=$(echo "$release_resp" | jq -r '.assets[] | select(.name|test("linux-x64")) | .browser_download_url' | head -n1)
RUNNER_TAR=$(echo "$release_resp" | jq -r '.assets[] | select(.name|test("linux-x64")) | .name' | head -n1)
if [ -z "$RUNNER_URL_DL" ] || [ "$RUNNER_URL_DL" = "null" ]; then
  echo "ERROR: failed to determine runner download URL from Releases API. Set a GITHUB_TOKEN or check network/rate limits." >&2
  exit 1
fi

bootstrap_runner() {
  echo "Bootstrapping GitHub runner version ${RUNNER_VERSION}"

  rm -rf bin externals *.sh || true

  curl -L -o "${RUNNER_TAR}" "${RUNNER_URL_DL}"
  tar xzf "${RUNNER_TAR}"
  rm "${RUNNER_TAR}"

  echo "${RUNNER_VERSION}" > "${VERSION_FILE}"
}

# Install / upgrade runner if needed
if [ ! -f "${VERSION_FILE}" ] || [ "$(cat ${VERSION_FILE})" != "${RUNNER_VERSION}" ]; then
  bootstrap_runner
fi

# Always configure runner on start (obtain registration token via GitHub API if needed)
if [ -z "${REPO_URL:-}" ]; then
  echo "ERROR: REPO_URL must be set"
  exit 1
fi

# Require RUNNER_NAME (no default)
if [ -z "${RUNNER_NAME:-}" ]; then
  echo "ERROR: RUNNER_NAME must be set and unique for each runner (no default)."
  exit 1
fi
SELECTED_NAME="${RUNNER_NAME}"

# verbosity helper (always verbose)
log() {
  echo "[entrypoint] $*"
}

mask_token() {
  token="$1"
  if [ -z "$token" ]; then
    echo ""
  else
    echo "${token:0:4}****"
  fi
}

# Obtain a registration token: prefer explicit RUNNER_TOKEN, otherwise use GITHUB_TOKEN to request one
if [ -n "${RUNNER_TOKEN:-}" ]; then
  TOKEN_TO_USE="${RUNNER_TOKEN}"
else
  if [ -z "${GITHUB_TOKEN:-}" ]; then
    echo "ERROR: either RUNNER_TOKEN or GITHUB_TOKEN (GitHub PAT) must be provided"
    exit 1
  fi

  log "Requesting registration token from GitHub API"

  # parse REPO_URL to determine repo vs org
  url_path="${REPO_URL#https://github.com/}"
  # strip possible leading 'orgs/'
  url_path="${url_path#/}"
  IFS='/' read -r part1 part2 _ <<< "$url_path"

  if [ -n "$part2" ]; then
    # repo: owner/repo
    API_URL="https://api.github.com/repos/${part1}/${part2}/actions/runners/registration-token"
    API_LIST_URL="https://api.github.com/repos/${part1}/${part2}/actions/runners"
    API_DELETE_REPO=true
  else
    # org: either /orgs/<org> or plain /<org>
    # support URLs like https://github.com/orgs/<org> and https://github.com/<org>
    if [[ "$url_path" == orgs/* ]]; then
      org_name="${url_path#orgs/}"
    else
      org_name="$url_path"
    fi
    API_URL="https://api.github.com/orgs/${org_name}/actions/runners/registration-token"
    API_LIST_URL="https://api.github.com/orgs/${org_name}/actions/runners"
    API_DELETE_REPO=false
  fi
    # helper: POST with retries (exponential backoff)
    http_post_with_retries() {
      local url="$1"; shift
      local auth_header="$1"; shift
      local attempts=${GH_API_RETRIES:-6}
      local delay=${GH_API_INITIAL_DELAY:-1}
      local backoff=${GH_API_BACKOFF_MULT:-2}
      for i in $(seq 1 "$attempts"); do
        resp=$(curl -s -X POST -H "$auth_header" -H "Accept: application/vnd.github+json" "$url" 2>/dev/null) || resp=""
        if echo "$resp" | jq -e . >/dev/null 2>&1; then
          echo "$resp"
          return 0
        fi
        if [ "$i" -lt "$attempts" ]; then
          sleep $delay
          delay=$((delay * backoff))
        fi
      done
      return 1
    }

    # GET with retries
    http_get_with_retries() {
      local url="$1"; shift
      local auth_header="$1"; shift
      local attempts=${GH_API_RETRIES:-6}
      local delay=${GH_API_INITIAL_DELAY:-1}
      local backoff=${GH_API_BACKOFF_MULT:-2}
      for i in $(seq 1 "$attempts"); do
        resp=$(curl -s -H "$auth_header" -H "Accept: application/vnd.github+json" "$url" 2>/dev/null) || resp=""
        if echo "$resp" | jq -e . >/dev/null 2>&1; then
          echo "$resp"
          return 0
        fi
        if [ "$i" -lt "$attempts" ]; then
          sleep $delay
          delay=$((delay * backoff))
        fi
      done
      return 1
    }

    # DELETE with retries
    http_delete_with_retries() {
      local url="$1"; shift
      local auth_header="$1"; shift
      local attempts=${GH_API_RETRIES:-6}
      local delay=${GH_API_INITIAL_DELAY:-1}
      local backoff=${GH_API_BACKOFF_MULT:-2}
      for i in $(seq 1 "$attempts"); do
        status=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE -H "$auth_header" -H "Accept: application/vnd.github+json" "$url" 2>/dev/null) || status=0
        if [ "$status" -ge 200 ] && [ "$status" -lt 300 ]; then
          return 0
        fi
        if [ "$i" -lt "$attempts" ]; then
          sleep $delay
          delay=$((delay * backoff))
        fi
      done
      return 1
    }

    # request registration token with retries
    api_auth_header="Authorization: token ${GITHUB_TOKEN}"
    resp=$(http_post_with_retries "$API_URL" "$api_auth_header") || resp=""
    TOKEN_TO_USE=$(echo "$resp" | jq -r .token 2>/dev/null || true)
    if [ -z "$TOKEN_TO_USE" ] || [ "$TOKEN_TO_USE" = "null" ]; then
      echo "Failed to obtain registration token from GitHub API after retries:" >&2
      echo "$resp" >&2
      exit 1
    fi
    log "Obtained registration token (masked): $(mask_token "$TOKEN_TO_USE")"
    expires_at=$(echo "$resp" | jq -r .expires_at 2>/dev/null || true)
    if [ -n "$expires_at" ] && [ "$expires_at" != "null" ]; then
      log "Token expires at: $expires_at"
    fi
fi

  log "Configuring runner for ${REPO_URL} as ${SELECTED_NAME}"
  HARD_LABELS="self-hosted,x64,linux"
  if [ -n "${RUNNER_LABELS:-}" ]; then
    COMBINED_LABELS="${HARD_LABELS},${RUNNER_LABELS}"
  else
    COMBINED_LABELS="${HARD_LABELS}"
  fi

  ./config.sh --unattended \
    --url "${REPO_URL}" \
    --token "${TOKEN_TO_USE}" \
    --name "${SELECTED_NAME}" \
    --work "${RUNNER_WORKDIR:-_work}" \
    --labels "${COMBINED_LABELS}" \
    --replace

# Run the runner and ensure we deregister on container stop
child_pid=0
cleanup() {
  echo "Shutting down runner"
  if [ "$child_pid" -ne 0 ]; then
    kill -TERM "$child_pid" 2>/dev/null || true
    wait "$child_pid" || true
  fi

  if [ -n "${GITHUB_TOKEN:-}" ]; then
    log "Removing runner registration via GitHub API"
    # find runner id by name
    list_resp=$(http_get_with_retries "$API_LIST_URL" "Authorization: token ${GITHUB_TOKEN}") || list_resp=""
    runner_ids=$(echo "$list_resp" | jq -r ".runners[] | select(.name==\"${SELECTED_NAME}\") | .id" 2>/dev/null || true)
    count=$(echo "$runner_ids" | wc -w | tr -d ' ')
    log "Found $count matching runner(s) for ${SELECTED_NAME}"
    if [ -n "$runner_ids" ]; then
      for id in $runner_ids; do
        if [ "$API_DELETE_REPO" = true ]; then
          del_url="https://api.github.com/repos/${part1}/${part2}/actions/runners/${id}"
        else
          del_url="https://api.github.com/orgs/${org_name}/actions/runners/${id}"
        fi
        if http_delete_with_retries "$del_url" "Authorization: token ${GITHUB_TOKEN}"; then
          echo "Removed runner id ${id}"
        else
          echo "Failed to remove runner id ${id} after retries" >&2
        fi
      done
    else
      log "No matching runner entries found for ${SELECTED_NAME}"
    fi
  else
    # no GITHUB_TOKEN: try local remove
    ./config.sh remove --unattended || true
  fi

  exit 0
}

trap 'cleanup' SIGINT SIGTERM EXIT

./run.sh &
child_pid=$!
wait "$child_pid"
