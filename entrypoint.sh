#!/bin/bash
set -euo pipefail

cd /actions-runner

VERSION_FILE=".release-hash"

log() { echo "[entrypoint] $*"; }

mask_token() {
  local t="${1:-}"
  [ -z "$t" ] && echo "" || echo "${t:0:4}****"
}

# -------------------------
# GitHub API helpers
# -------------------------
http_get_json() {
  local url="$1"
  curl -fsS \
    -H "Authorization: token ${GITHUB_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    "$url"
}

http_post_json() {
  local url="$1"
  curl -fsS -X POST \
    -H "Authorization: token ${GITHUB_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    "$url"
}

http_delete() {
  local url="$1"
  curl -fsS -X DELETE \
    -H "Authorization: token ${GITHUB_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    "$url" >/dev/null
}

with_retries_json() {
  local method="$1"; shift
  local url="$1"; shift
  local attempts="${GH_API_RETRIES:-6}"
  local delay="${GH_API_INITIAL_DELAY:-1}"
  local backoff="${GH_API_BACKOFF_MULT:-2}"

  local i resp="" rc=0
  for i in $(seq 1 "$attempts"); do
    set +e
    if [ "$method" = "GET" ]; then
      resp=$(http_get_json "$url" 2>/dev/null)
    else
      resp=$(http_post_json "$url" 2>/dev/null)
    fi
    rc=$?
    set -e

    if [ "$rc" -eq 0 ] && echo "$resp" | jq -e . >/dev/null 2>&1; then
      echo "$resp"
      return 0
    fi

    if [ "$i" -lt "$attempts" ]; then
      sleep "$delay"
      delay=$((delay * backoff))
    fi
  done

  echo "$resp"
  return 1
}

# -------------------------
# Root-only: docker.sock group mapping
# -------------------------
if [ "$(id -u)" = "0" ]; then
  if [ -S /var/run/docker.sock ]; then
    sock_gid=$(stat -c '%g' /var/run/docker.sock)

    existing_group_by_gid=$(getent group | awk -F: -v gid="$sock_gid" '$3==gid {print $1; exit}')
    if [ -n "${existing_group_by_gid:-}" ]; then
      group_name="$existing_group_by_gid"
    else
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
fi

# -------------------------
# Read GITHUB_TOKEN from secret file (if present)
# -------------------------
SECRETS_FILE="/run/secrets/credentials"
if [ -e "${SECRETS_FILE}" ] && [ -f "${SECRETS_FILE}" ] && [ -r "${SECRETS_FILE}" ] && [ -s "${SECRETS_FILE}" ]; then
  token_from_file=$(
    grep -E '^[[:space:]]*GITHUB_TOKEN[[:space:]]*[:=]' "${SECRETS_FILE}" 2>/dev/null \
      | sed -E 's/^[[:space:]]*GITHUB_TOKEN[[:space:]]*[:=][[:space:]]*//' \
      | tr -d '\r' \
      | tail -n1 \
      || true
  )
  if [ -n "${token_from_file:-}" ]; then
    token_from_file=$(echo "${token_from_file}" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')
    export GITHUB_TOKEN="${token_from_file}"
    log "Using GITHUB_TOKEN from ${SECRETS_FILE} (masked: $(mask_token "$GITHUB_TOKEN"))"
  fi
else
  log "No usable credentials file at ${SECRETS_FILE}; will use env var if provided"
fi

if [ -z "${GITHUB_TOKEN:-}" ]; then
  echo "ERROR: GITHUB_TOKEN must be provided (via env or /run/secrets/credentials)" >&2
  exit 1
fi

if [ -z "${REPO_URL:-}" ]; then
  echo "ERROR: REPO_URL must be set (example: https://github.com/owner/repo or https://github.com/orgs/org)" >&2
  exit 1
fi

if [ -z "${RUNNER_NAME:-}" ]; then
  echo "ERROR: RUNNER_NAME must be set and unique (no default)" >&2
  exit 1
fi

# -------------------------
# Determine repo/org API endpoints
# -------------------------
url_path="${REPO_URL#https://github.com/}"
url_path="${url_path%/}"
IFS='/' read -r part1 part2 _ <<< "$url_path"

if [ -n "${part2:-}" ]; then
  API_REG_URL="https://api.github.com/repos/${part1}/${part2}/actions/runners/registration-token"
  API_LIST_URL="https://api.github.com/repos/${part1}/${part2}/actions/runners"
  API_DELETE_PREFIX="https://api.github.com/repos/${part1}/${part2}/actions/runners"
else
  if [[ "$url_path" == orgs/* ]]; then
    org_name="${url_path#orgs/}"
  else
    org_name="$url_path"
  fi
  API_REG_URL="https://api.github.com/orgs/${org_name}/actions/runners/registration-token"
  API_LIST_URL="https://api.github.com/orgs/${org_name}/actions/runners"
  API_DELETE_PREFIX="https://api.github.com/orgs/${org_name}/actions/runners"
fi

# -------------------------
# Download/refresh runner if needed
# -------------------------
log "Determining runner asset (linux x64) from GitHub Releases API"
release_resp=$(curl -fsS -H "Authorization: token ${GITHUB_TOKEN}" "https://api.github.com/repos/actions/runner/releases/latest")
RUNNER_URL_DL=$(echo "$release_resp" | jq -r '.assets[] | select(.name|test("linux-x64")) | .browser_download_url' | head -n1)
RUNNER_TAR=$(echo "$release_resp" | jq -r '.assets[] | select(.name|test("linux-x64")) | .name' | head -n1)

RELEASE_RECORD=$(echo "$release_resp" | jq -c '{tag: .tag_name, assets: [.assets[] | {name: .name, url: .browser_download_url}] }')
RELEASE_HASH=$(printf "%s" "$RELEASE_RECORD" | sha1sum | awk '{print $1}')

if [ -z "${RUNNER_URL_DL:-}" ] || [ "${RUNNER_URL_DL}" = "null" ]; then
  echo "ERROR: failed to determine runner download URL from Releases API" >&2
  exit 1
fi

bootstrap_runner() {
  log "Bootstrapping GitHub runner (release hash: ${RELEASE_HASH})"
  rm -rf bin externals *.sh || true
  curl -fsSL -o "${RUNNER_TAR}" "${RUNNER_URL_DL}"
  tar xzf "${RUNNER_TAR}"
  rm -f "${RUNNER_TAR}"
  echo "${RELEASE_HASH}" > "${VERSION_FILE}"
  chown -R runner:runner /actions-runner || true
}

if [ ! -f "${VERSION_FILE}" ] || [ "$(cat "${VERSION_FILE}")" != "${RELEASE_HASH}" ]; then
  bootstrap_runner
fi

# Optional: docker socket health check (non-fatal)
if [ -x /usr/local/bin/docker-socket-check.sh ]; then
  set +e
  runuser -u runner -- /usr/local/bin/docker-socket-check.sh
  set -e
fi

# -------------------------
# Register token
# -------------------------
log "Requesting registration token from GitHub API (${API_REG_URL})"
resp=$(with_retries_json POST "$API_REG_URL") || true
TOKEN_TO_USE=$(echo "${resp:-}" | jq -r '.token' 2>/dev/null || true)
expires_at=$(echo "${resp:-}" | jq -r '.expires_at' 2>/dev/null || true)

if [ -z "${TOKEN_TO_USE:-}" ] || [ "${TOKEN_TO_USE}" = "null" ]; then
  echo "ERROR: Failed to obtain registration token. Response:" >&2
  echo "${resp:-<empty>}" >&2
  exit 1
fi

log "Obtained registration token (masked): $(mask_token "$TOKEN_TO_USE")"
[ -n "${expires_at:-}" ] && [ "${expires_at}" != "null" ] && log "Token expires at: ${expires_at}"

HARD_LABELS="self-hosted,linux,x64"
if [ -n "${RUNNER_LABELS:-}" ]; then
  COMBINED_LABELS="${HARD_LABELS},${RUNNER_LABELS}"
else
  COMBINED_LABELS="${HARD_LABELS}"
fi

# Best-effort delete stale runners by name (before re-register)
set +e
list_resp=$(http_get_json "$API_LIST_URL" 2>/dev/null)
set -e
stale_ids=$(echo "${list_resp:-}" | jq -r ".runners[]? | select(.name==\"${RUNNER_NAME}\") | .id" 2>/dev/null || true)
for id in $stale_ids; do
  http_delete "${API_DELETE_PREFIX}/${id}" || true
done

# -------------------------
# Global state for cleanup
# -------------------------
RUNNER_CHILD_PID=0
RUNNER_REGISTERED=0
CLEANUP_RAN=0

cleanup() {
  # Always run once
  if [ "${CLEANUP_RAN}" = "1" ]; then
    return 0
  fi
  CLEANUP_RAN=1

  # Stop runner process if running
  if [ "$RUNNER_CHILD_PID" -ne 0 ]; then
    log "Stopping runner process (pid=${RUNNER_CHILD_PID})"
    kill -TERM "$RUNNER_CHILD_PID" 2>/dev/null || true
    set +e
    wait "$RUNNER_CHILD_PID"
    set -e
  fi

  # Unregister via API if we got as far as registering
  if [ "${RUNNER_REGISTERED}" = "1" ]; then
    log "Attempting runner unregister via API (name=${RUNNER_NAME})"

    local ids=""
    local i
    for i in 1 2 3 4 5 6; do
      set +e
      local lr
      lr=$(http_get_json "$API_LIST_URL" 2>/dev/null)
      set -e
      ids=$(echo "${lr:-}" | jq -r ".runners[]? | select(.name==\"${RUNNER_NAME}\") | .id" 2>/dev/null || true)
      [ -n "${ids:-}" ] && break
      sleep 2
    done

    if [ -z "${ids:-}" ]; then
      log "Runner not found via API; nothing to delete"
      return 0
    fi

    for id in $ids; do
      if http_delete "${API_DELETE_PREFIX}/${id}"; then
        log "Unregistered runner id ${id}"
      else
        log "Failed to unregister runner id ${id}"
      fi
    done
  fi
}

# Ensure cleanup runs on stop and on normal exit
trap cleanup SIGINT SIGTERM EXIT

# -------------------------
# Configure runner (MUST be as runner user)
# -------------------------
if [ -f .runner ]; then
  log "Local runner config detected; removing before reconfiguration"
  runuser -u runner -- ./config.sh remove --unattended --token "${TOKEN_TO_USE}" || true
fi

log "Configuring runner for ${REPO_URL} as ${RUNNER_NAME} (running config.sh as user 'runner')"
runuser -u runner -- ./config.sh --unattended \
  --url "${REPO_URL}" \
  --token "${TOKEN_TO_USE}" \
  --name "${RUNNER_NAME}" \
  --work "${RUNNER_WORKDIR:-_work}" \
  --labels "${COMBINED_LABELS}" \
  --replace

RUNNER_REGISTERED=1

# -------------------------
# Start runner (as runner user) and supervise
# -------------------------
log "Starting runner (run.sh) as user 'runner'"
runuser -u runner -- ./run.sh &
RUNNER_CHILD_PID=$!

set +e
wait "$RUNNER_CHILD_PID"
rc=$?
set -e

# Let EXIT trap do unregister; preserve run.sh exit code
exit "$rc"
