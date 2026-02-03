#!/bin/bash
set -euo pipefail

cd /actions-runner

VERSION_FILE=".release-hash"

log() { echo "[entrypoint] $*"; }

# -----------------------------
# Docker socket access (root)
# -----------------------------
# Ensure the `runner` user can access /var/run/docker.sock when it is mounted in.
# This runs as root and then continues (PID 1 remains this script).
if [ "$(id -u)" = "0" ]; then
  if [ -S /var/run/docker.sock ]; then
    sock_gid=$(stat -c '%g' /var/run/docker.sock)

    # Find a group that already has this GID (on the container)
    existing_group_by_gid=$(getent group | awk -F: -v gid="$sock_gid" '$3==gid {print $1; exit}' || true)

    if [ -n "${existing_group_by_gid:-}" ]; then
      group_name="$existing_group_by_gid"
    else
      # Prefer the group name "docker" (create/adjust as needed)
      if getent group docker >/dev/null 2>&1; then
        old_gid=$(getent group docker | awk -F: '{print $3}')
        if [ "$old_gid" != "$sock_gid" ]; then
          log "Updating group 'docker' GID from ${old_gid} to ${sock_gid} to match docker socket"
          groupmod -g "$sock_gid" docker
        fi
        group_name="docker"
      else
        log "Creating group 'docker' with GID ${sock_gid}"
        groupadd -g "$sock_gid" docker
        group_name="docker"
      fi
    fi

    log "Adding user 'runner' to group '${group_name}' (gid: ${sock_gid})"
    usermod -aG "$group_name" runner || true
  else
    log "No docker socket at /var/run/docker.sock visible in container"
  fi

  # Optional: quick health check as runner (does not abort startup)
  if /usr/local/bin/docker-socket-check.sh >/dev/null 2>&1; then
    log "Docker socket health-check: OK"
  else
    log "Docker socket health-check: FAILED — runner may not be able to use docker. Mount /var/run/docker.sock into the container."
  fi
fi

# -----------------------------
# Credentials (PAT) from secret
# -----------------------------
SECRETS_FILE="/run/secrets/credentials"
if [ -e "$SECRETS_FILE" ]; then
  if [ -f "$SECRETS_FILE" ]; then
    if [ ! -r "$SECRETS_FILE" ]; then
      log "Credentials file ${SECRETS_FILE} exists but is not readable; will use env var if provided"
    elif [ ! -s "$SECRETS_FILE" ]; then
      log "Credentials file ${SECRETS_FILE} exists but is empty; will use env var if provided"
    else
      token_from_file=$(
        grep -E '^[[:space:]]*GITHUB_TOKEN[[:space:]]*[:=]' "$SECRETS_FILE" 2>/dev/null \
          | sed -E 's/^[[:space:]]*GITHUB_TOKEN[[:space:]]*[:=][[:space:]]*//' \
          | tr -d '\r' \
          | tail -n1 \
        || true
      )
      if [ -n "${token_from_file:-}" ]; then
        token_from_file=$(echo "$token_from_file" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')
        export GITHUB_TOKEN="$token_from_file"
        log "Using GITHUB_TOKEN from ${SECRETS_FILE} (masked: ${GITHUB_TOKEN:0:4}****)"
      else
        log "Credentials file ${SECRETS_FILE} present but contains no GITHUB_TOKEN entry; will use env var if provided"
      fi
    fi
  else
    log "Credentials path ${SECRETS_FILE} exists but is not a regular file; will use env var if provided"
  fi
else
  log "No credentials file at ${SECRETS_FILE}; will use env var if provided"
fi

if [ -z "${GITHUB_TOKEN:-}" ]; then
  echo "ERROR: GITHUB_TOKEN must be provided (env var or /run/secrets/credentials)" >&2
  exit 1
fi

# -----------------------------
# Determine latest runner asset
# -----------------------------
log "Determining runner asset (linux x64) from GitHub Releases API"
release_resp=$(curl -s -H "Authorization: token ${GITHUB_TOKEN}" "https://api.github.com/repos/actions/runner/releases/latest")

RUNNER_URL_DL=$(echo "$release_resp" | jq -r '.assets[] | select(.name|test("linux-x64")) | .browser_download_url' | head -n1)
RUNNER_TAR=$(echo "$release_resp" | jq -r '.assets[] | select(.name|test("linux-x64")) | .name' | head -n1)

RELEASE_RECORD=$(echo "$release_resp" | jq -c '{tag: .tag_name, name: .name, assets: [.assets[] | {name: .name, url: .browser_download_url}]}' 2>/dev/null || true)
RELEASE_HASH=$(printf "%s" "$RELEASE_RECORD" | sha1sum | awk '{print $1}')

if [ -z "${RUNNER_URL_DL:-}" ] || [ "$RUNNER_URL_DL" = "null" ]; then
  echo "ERROR: failed to determine runner download URL from Releases API." >&2
  exit 1
fi

bootstrap_runner() {
  log "Bootstrapping GitHub runner (release hash: ${RELEASE_HASH})"

  # Avoid nuking all *.sh if extraction fails; remove only what the runner tar provides.
  rm -rf bin externals || true
  rm -f run.sh config.sh env.sh || true

  curl -L -o "${RUNNER_TAR}" "${RUNNER_URL_DL}"
  tar xzf "${RUNNER_TAR}"
  rm -f "${RUNNER_TAR}"

  printf "%s" "${RELEASE_HASH}" > "${VERSION_FILE}"
}

if [ ! -f "${VERSION_FILE}" ] || [ "$(cat "${VERSION_FILE}")" != "${RELEASE_HASH}" ]; then
  bootstrap_runner
fi

# -----------------------------
# Validate required env
# -----------------------------
if [ -z "${REPO_URL:-}" ]; then
  echo "ERROR: REPO_URL must be set" >&2
  exit 1
fi

if [[ "${REPO_URL}" != https://github.com/* ]]; then
  echo "ERROR: REPO_URL must start with 'https://github.com/'" >&2
  exit 1
fi

if [ -z "${RUNNER_NAME:-}" ]; then
  echo "ERROR: RUNNER_NAME must be set and unique for each runner (no default)." >&2
  exit 1
fi
SELECTED_NAME="${RUNNER_NAME}"

mask_token() {
  local t="$1"
  [ -n "$t" ] && echo "${t:0:4}****" || echo ""
}

# -----------------------------
# GitHub API helpers
# -----------------------------
# parse REPO_URL to determine repo vs org
url_path="${REPO_URL#https://github.com/}"
url_path="${url_path%/}"
url_path="${url_path#/}"
IFS='/' read -r part1 part2 _ <<< "$url_path"

if [ -n "${part2:-}" ]; then
  # repo: owner/repo
  API_REG_TOKEN_URL="https://api.github.com/repos/${part1}/${part2}/actions/runners/registration-token"
  API_LIST_URL="https://api.github.com/repos/${part1}/${part2}/actions/runners"
  API_DELETE_REPO=true
else
  # org: https://github.com/orgs/<org> OR https://github.com/<org>
  if [[ "$url_path" == orgs/* ]]; then
    org_name="${url_path#orgs/}"
  else
    org_name="$url_path"
  fi
  API_REG_TOKEN_URL="https://api.github.com/orgs/${org_name}/actions/runners/registration-token"
  API_LIST_URL="https://api.github.com/orgs/${org_name}/actions/runners"
  API_DELETE_REPO=false
fi

http_post_with_retries() {
  local url="$1"
  local auth_header="$2"
  local attempts=${GH_API_RETRIES:-6}
  local delay=${GH_API_INITIAL_DELAY:-1}
  local backoff=${GH_API_BACKOFF_MULT:-2}
  local resp=""

  for i in $(seq 1 "$attempts"); do
    resp=$(curl -s -X POST -H "$auth_header" -H "Accept: application/vnd.github+json" "$url" 2>/dev/null) || resp=""
    if echo "$resp" | jq -e . >/dev/null 2>&1; then
      echo "$resp"
      return 0
    fi
    [ "$i" -lt "$attempts" ] && sleep "$delay" && delay=$((delay * backoff))
  done
  echo "$resp"
  return 1
}

http_get_with_retries() {
  local url="$1"
  local auth_header="$2"
  local attempts=${GH_API_RETRIES:-6}
  local delay=${GH_API_INITIAL_DELAY:-1}
  local backoff=${GH_API_BACKOFF_MULT:-2}
  local resp=""

  for i in $(seq 1 "$attempts"); do
    resp=$(curl -s -H "$auth_header" -H "Accept: application/vnd.github+json" "$url" 2>/dev/null) || resp=""
    if echo "$resp" | jq -e . >/dev/null 2>&1; then
      echo "$resp"
      return 0
    fi
    [ "$i" -lt "$attempts" ] && sleep "$delay" && delay=$((delay * backoff))
  done
  echo "$resp"
  return 1
}

http_delete_with_retries() {
  local url="$1"
  local auth_header="$2"
  local attempts=${GH_API_RETRIES:-6}
  local delay=${GH_API_INITIAL_DELAY:-1}
  local backoff=${GH_API_BACKOFF_MULT:-2}
  local status=0

  for i in $(seq 1 "$attempts"); do
    status=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE -H "$auth_header" -H "Accept: application/vnd.github+json" "$url" 2>/dev/null) || status=0
    if [ "$status" -ge 200 ] && [ "$status" -lt 300 ]; then
      return 0
    fi
    [ "$i" -lt "$attempts" ] && sleep "$delay" && delay=$((delay * backoff))
  done
  return 1
}

api_auth_header="Authorization: token ${GITHUB_TOKEN}"

# -----------------------------
# Obtain registration token
# -----------------------------
log "Requesting registration token from GitHub API"
resp=$(http_post_with_retries "$API_REG_TOKEN_URL" "$api_auth_header") || true
TOKEN_TO_USE=$(echo "$resp" | jq -r .token 2>/dev/null || true)

if [ -z "${TOKEN_TO_USE:-}" ] || [ "$TOKEN_TO_USE" = "null" ]; then
  echo "Failed to obtain registration token from GitHub API:" >&2
  echo "$resp" >&2
  exit 1
fi

log "Obtained registration token (masked): $(mask_token "$TOKEN_TO_USE")"
expires_at=$(echo "$resp" | jq -r .expires_at 2>/dev/null || true)
[ -n "${expires_at:-}" ] && [ "$expires_at" != "null" ] && log "Token expires at: $expires_at"

# -----------------------------
# Configure runner
# -----------------------------
log "Configuring runner for ${REPO_URL} as ${SELECTED_NAME}"

HARD_LABELS="self-hosted,x64,linux"
COMBINED_LABELS="${HARD_LABELS}"
[ -n "${RUNNER_LABELS:-}" ] && COMBINED_LABELS="${HARD_LABELS},${RUNNER_LABELS}"

# Best-effort: delete any existing runner with same name before re-registering
list_resp=$(http_get_with_retries "$API_LIST_URL" "$api_auth_header") || list_resp=""
stale_ids=$(echo "$list_resp" | jq -r ".runners[] | select(.name==\"${SELECTED_NAME}\") | .id" 2>/dev/null || true)
for id in $stale_ids; do
  if [ "$API_DELETE_REPO" = true ]; then
    del_url="https://api.github.com/repos/${part1}/${part2}/actions/runners/${id}"
  else
    del_url="https://api.github.com/orgs/${org_name}/actions/runners/${id}"
  fi
  http_delete_with_retries "$del_url" "$api_auth_header" || true
done

./config.sh --unattended \
  --url "${REPO_URL}" \
  --token "${TOKEN_TO_USE}" \
  --name "${SELECTED_NAME}" \
  --work "${RUNNER_WORKDIR:-_work}" \
  --labels "${COMBINED_LABELS}" \
  --replace

RUNNER_REGISTERED=1
child_pid=0

# -----------------------------
# Cleanup on stop (PID 1)
# -----------------------------
cleanup() {
  trap - SIGINT SIGTERM

  [ "${RUNNER_REGISTERED:-}" != "1" ] && exit 0

  log "Stopping runner process"
  if [ "$child_pid" -ne 0 ]; then
    kill -TERM "$child_pid" 2>/dev/null || true
    set +e
    wait "$child_pid" || true
    set -e
  fi

  sleep 2

  log "Attempting runner unregister"
  runner_ids=""
  for _ in {1..6}; do
    list_resp=$(http_get_with_retries "$API_LIST_URL" "$api_auth_header") || list_resp=""
    runner_ids=$(echo "$list_resp" | jq -r ".runners[] | select(.name==\"${SELECTED_NAME}\") | .id" 2>/dev/null || true)
    [ -n "$runner_ids" ] && break
    sleep 2
  done

  if [ -z "${runner_ids:-}" ]; then
    log "Runner not found in API, skipping unregister"
    exit 0
  fi

  for id in $runner_ids; do
    if [ "$API_DELETE_REPO" = true ]; then
      del_url="https://api.github.com/repos/${part1}/${part2}/actions/runners/${id}"
    else
      del_url="https://api.github.com/orgs/${org_name}/actions/runners/${id}"
    fi

    if http_delete_with_retries "$del_url" "$api_auth_header"; then
      log "Unregistered runner id $id"
    else
      log "Failed to unregister runner id $id"
    fi
  done

  exit 0
}

trap 'cleanup' SIGINT SIGTERM

# -----------------------------
# Start runner as user `runner`
# -----------------------------
if [ ! -x /actions-runner/run.sh ]; then
  echo "ERROR: /actions-runner/run.sh not found or not executable. Runner bootstrap likely failed." >&2
  exit 1
fi

log "Starting runner process as user 'runner'"
runuser -u runner -- /actions-runner/run.sh &
child_pid=$!

set +e
wait "$child_pid"
rc=$?
set -e
exit "$rc"
