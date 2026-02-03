#!/bin/bash
set -euo pipefail

cd /actions-runner

VERSION_FILE=".release-hash"
CONFIGURED_FILE=".runner-configured"

# verbosity helper (always verbose) — define early so initial logs work
log() {
  echo "[entrypoint] $*"
}

# When running as the non-root `runner` user (re-exec path), perform a quick
# health check to verify that the `runner` user can access the Docker socket
# and that the docker CLI can reach the daemon. This logs a helpful message
# if access fails but does not abort container startup.
if [ -n "${ENTRYPOINT_AS_RUNNER:-}" ]; then
  if /usr/local/bin/docker-socket-check.sh; then
    log "Docker socket health-check: OK"
  else
    log "Docker socket health-check: FAILED — runner may not be able to use docker. See README for troubleshooting and mount /var/run/docker.sock into the container."
  fi
fi

# If started as root, attempt to map the host docker socket's GID to
# a group inside the container and add the `runner` user to that group.
# This allows non-root `runner` to access `/var/run/docker.sock` when
# the socket is mounted into the container.
if [ "$(id -u)" = "0" ] && [ -z "${ENTRYPOINT_AS_RUNNER:-}" ]; then
  if [ -S /var/run/docker.sock ]; then
    sock_gid=$(stat -c '%g' /var/run/docker.sock)
    existing_group=$(getent group | awk -F: -v gid="${sock_gid}" '$3==gid {print $1; exit}')
    if [ -z "${existing_group}" ]; then
      groupadd -g "${sock_gid}" docker 2>/dev/null || true
      group_name=docker
    else
      group_name="${existing_group}"
    fi
    log "Adding user 'runner' to group '${group_name}' (gid: ${sock_gid}) to allow docker socket access"
    usermod -aG "${group_name}" runner 2>/dev/null || true
  else
    log "No docker socket at /var/run/docker.sock visible in container"
  fi
  log "Re-execing entrypoint as 'runner'"
  exec su -p runner -c 'ENTRYPOINT_AS_RUNNER=1 /entrypoint.sh'
fi

SECRETS_FILE="/run/secrets/credentials"
token_from_file=""
# Detailed diagnostics for credentials file state:
# - missing file
# - exists but not regular file
# - exists but not readable
# - exists but empty
# - exists but contains no GITHUB_TOKEN entries
if [ -e "${SECRETS_FILE}" ]; then
  if [ -f "${SECRETS_FILE}" ]; then
    if [ ! -r "${SECRETS_FILE}" ]; then
      log "Credentials file ${SECRETS_FILE} exists but is not readable by the container (check host permissions); will use environment variable if provided"
    elif [ ! -s "${SECRETS_FILE}" ]; then
      log "Credentials file ${SECRETS_FILE} exists but is empty; will use environment variable if provided"
    else
      token_from_file=$(grep -E '^[[:space:]]*GITHUB_TOKEN[[:space:]]*[:=]' "${SECRETS_FILE}" 2>/dev/null | sed -E 's/^[[:space:]]*GITHUB_TOKEN[[:space:]]*[:=][[:space:]]*//' | tr -d '\r' | tail -n1 || true)
      if [ -n "${token_from_file}" ]; then
        token_from_file=$(echo "${token_from_file}" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g' | tr -d '\r')
        export GITHUB_TOKEN="${token_from_file}"
        masked="${GITHUB_TOKEN:0:4}****"
        log "Using GITHUB_TOKEN from ${SECRETS_FILE} (masked: ${masked})"
      else
        log "Credentials file ${SECRETS_FILE} present but contains no GITHUB_TOKEN entries; will use environment variable if provided"
      fi
    fi
  else
    log "Credentials path ${SECRETS_FILE} exists but is not a regular file; will use environment variable if provided"
  fi
else
  log "No credentials file at ${SECRETS_FILE}; will use environment variable if provided"
fi

# Determine the runner download asset URL from GitHub Releases
log "Determining runner asset (linux x64) from GitHub Releases API"
if [ -n "${GITHUB_TOKEN:-}" ]; then
  release_resp=$(curl -s -H "Authorization: token ${GITHUB_TOKEN}" "https://api.github.com/repos/actions/runner/releases/latest")
else
  release_resp=$(curl -s "https://api.github.com/repos/actions/runner/releases/latest")
fi
RUNNER_URL_DL=$(echo "$release_resp" | jq -r '.assets[] | select(.name|test("linux-x64")) | .browser_download_url' | head -n1)
RUNNER_TAR=$(echo "$release_resp" | jq -r '.assets[] | select(.name|test("linux-x64")) | .name' | head -n1)

# Build a compact release record and compute its hash. We use the hash
# to detect changes between runs and decide whether to re-download.
RELEASE_RECORD=$(echo "$release_resp" | jq -c '{tag: .tag_name, name: .name, assets: [.assets[] | {name: .name, url: .browser_download_url}]}' 2>/dev/null || true)
RELEASE_HASH=$(printf "%s" "$RELEASE_RECORD" | sha1sum | awk '{print $1}')
if [ -z "$RUNNER_URL_DL" ] || [ "$RUNNER_URL_DL" = "null" ]; then
  echo "ERROR: failed to determine runner download URL from Releases API. Set a GITHUB_TOKEN or check network/rate limits." >&2
  exit 1
fi

bootstrap_runner() {
  echo "Bootstrapping GitHub runner (release hash: ${RELEASE_HASH})"

  rm -rf bin externals *.sh || true

  curl -L -o "${RUNNER_TAR}" "${RUNNER_URL_DL}"
  tar xzf "${RUNNER_TAR}"
  rm "${RUNNER_TAR}"

  echo "${RELEASE_HASH}" > "${VERSION_FILE}"
}

# Install / upgrade runner if needed
if [ ! -f "${VERSION_FILE}" ] || [ "$(cat ${VERSION_FILE})" != "${RELEASE_HASH}" ]; then
  bootstrap_runner
fi

# Always configure runner on start (obtain registration token via GitHub API if needed)
if [ -z "${REPO_URL:-}" ]; then
  echo "ERROR: REPO_URL must be set"
  exit 1
fi

# Basic validation: must start with https://github.com/ and include a path
if [[ "${REPO_URL}" != https://github.com/* ]]; then
  echo "ERROR: REPO_URL must start with 'https://github.com/' (example: https://github.com/owner/repo or https://github.com/orgs/orgname)"
  exit 1
fi

# normalize and extract path (strip prefix and trailing slash)
url_path="${REPO_URL#https://github.com/}"
url_path="${url_path%/}"
if [ -z "${url_path}" ]; then
  echo "ERROR: REPO_URL must include an organization or owner/repo path"
  exit 1
fi

# Require RUNNER_NAME (no default)
if [ -z "${RUNNER_NAME:-}" ]; then
  echo "ERROR: RUNNER_NAME must be set and unique for each runner (no default)."
  exit 1
fi
SELECTED_NAME="${RUNNER_NAME}"


mask_token() {
  token="$1"
  if [ -z "$token" ]; then
    echo ""
  else
    echo "${token:0:4}****"
  fi
}

# Obtain a registration token via `GITHUB_TOKEN` (RUNNER_TOKEN support removed)
if [ -z "${GITHUB_TOKEN:-}" ]; then
  echo "ERROR: GITHUB_TOKEN must be provided (RUNNER_TOKEN support removed)"
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

  exit 0
}

trap 'cleanup' SIGINT SIGTERM EXIT

./run.sh &
child_pid=$!
wait "$child_pid"
