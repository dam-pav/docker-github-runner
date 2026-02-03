#!/bin/bash
set -euo pipefail

cd /actions-runner

VERSION_FILE=".release-hash"

log() { echo "[entrypoint] $*"; }

# ---------- Root-only: ensure runner can use host docker socket ----------
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

# ---------- Read GITHUB_TOKEN from secret file (if present) ----------
SECRETS_FILE="/run/secrets/credentials"
if [ -e "${SECRETS_FILE}" ]; then
  if [ -f "${SECRETS_FILE}" ] && [ -r "${SECRETS_FILE}" ] && [ -s "${SECRETS_FILE}" ]; then
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
      log "Using GITHUB_TOKEN from ${SECRETS_FILE} (masked: ${GITHUB_TOKEN:0:4}****)"
    else
      log "Credentials file ${SECRETS_FILE} present but contains no GITHUB_TOKEN entries"
    fi
  else
    log "Credentials file ${SECRETS_FILE} not usable (not regular/readable/non-empty)"
  fi
else
  log "No credentials file at ${SECRETS_FILE}; will use env var if provided"
fi

if [ -z "${GITHUB_TOKEN:-}" ]; then
  echo "ERROR: GITHUB_TOKEN must be provided (via env or /run/secrets/credentials)" >&2
  exit 1
fi

if [ -z "${REPO_URL:-}" ]; then
  echo "ERROR: REPO_URL must be set (example: https://github.com/owner/repo or https://github.com/orgs/org)" >&2
  exit 1
fi

if [[ "${REPO_URL}" != https://github.com/* ]]; then
  echo "ERROR: REPO_URL must start with 'https://github.com/'" >&2
  exit 1
fi

if [ -z "${RUNNER_NAME:-}" ]; then
  echo "ERROR: RUNNER_NAME must be set and unique (no default)" >&2
  exit 1
fi

# Normalize path
url_path="${REPO_URL#https://github.com/}"
url_path="${url_path%/}"
if [ -z "${url_path}" ]; then
  echo "ERROR: REPO_URL must include an org or owner/repo path" >&2
  exit 1
fi

# Determine API URLs
IFS='/' read -r part1 part2 _ <<< "$url_path"
if [ -n "${part2:-}" ]; then
  API_REG_URL="https://api.github.com/repos/${part1}/${part2}/actions/runners/registration-token"
  API_LIST_URL="https://api.github.com/repos/${part1}/${part2}/actions/runners"
  API_DELETE_URL_PREFIX="https://api.github.com/repos/${part1}/${part2}/actions/runners"
else
  if [[ "$url_path" == orgs/* ]]; then
    org_name="${url_path#orgs/}"
  else
    org_name="$url_path"
  fi
  API_REG_URL="https://api.github.com/orgs/${org_name}/actions/runners/registration-token"
  API_LIST_URL="https://api.github.com/orgs/${org_name}/actions/runners"
  API_DELETE_URL_PREFIX="https://api.github.com/orgs/${org_name}/actions/runners"
fi

mask_token() {
  local t="${1:-}"
  [ -z "$t" ] && echo "" || echo "${t:0:4}****"
}

http_post_json() {
  local url="$1"
  curl -fsS -X POST \
    -H "Authorization: token ${GITHUB_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    "$url"
}

http_get_json() {
  local url="$1"
  curl -fsS \
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

  local i resp=""
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

# ---------- Determine latest runner release asset + bootstrap if needed ----------
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

# ---------- Health check docker socket as runner (non-fatal) ----------
if [ -x /usr/local/bin/docker-socket-check.sh ]; then
  set +e
  runuser -u runner -- /usr/local/bin/docker-socket-check.sh
  set -e
fi

# ---------- Obtain registration token ----------
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

# ---------- Best-effort delete stale runner(s) by name (before config) ----------
set +e
list_resp=$(http_get_json "$API_LIST_URL" 2>/dev/null)
set -e
stale_ids=$(echo "${list_resp:-}" | jq -r ".runners[]? | select(.name==\"${RUNNER_NAME}\") | .id" 2>/dev/null || true)
for id in $stale_ids; do
  http_delete "${API_DELETE_URL_PREFIX}/${id}" || true
done

# ---------- Hand off to non-root for config + run + cleanup ----------
log "Handing off to user 'runner' for config + run (must not run as root)"
export _ENTRY_REPO_URL="${REPO_URL}"
export _ENTRY_TOKEN="${TOKEN_TO_USE}"
export _ENTRY_NAME="${RUNNER_NAME}"
export _ENTRY_WORK="${RUNNER_WORKDIR:-_work}"
export _ENTRY_LABELS="${COMBINED_LABELS}"
export _ENTRY_API_LIST_URL="${API_LIST_URL}"
export _ENTRY_API_DELETE_PREFIX="${API_DELETE_URL_PREFIX}"
export _ENTRY_OWNER_NAME="${RUNNER_NAME}" # for clarity

exec runuser -u runner -- bash -lc '
  set -euo pipefail
  cd /actions-runner

  log() { echo "[runner] $*"; }

  http_get_json() {
    local url="$1"
    curl -fsS -H "Authorization: token ${GITHUB_TOKEN}" -H "Accept: application/vnd.github+json" "$url"
  }

  http_delete() {
    local url="$1"
    curl -fsS -X DELETE -H "Authorization: token ${GITHUB_TOKEN}" -H "Accept: application/vnd.github+json" "$url" >/dev/null
  }

  cleanup() {
    trap - SIGINT SIGTERM EXIT
    log "Cleanup: attempting to unregister runner \"${_ENTRY_NAME}\""

    # Give the runner a moment to terminate its session cleanly
    sleep 2

    # Find runner id(s) by name; retry a few times (eventual consistency)
    local ids=""
    for i in 1 2 3 4 5 6; do
      set +e
      local lr
      lr=$(http_get_json "${_ENTRY_API_LIST_URL}" 2>/dev/null)
      set -e
      ids=$(echo "${lr:-}" | jq -r ".runners[]? | select(.name==\"${_ENTRY_NAME}\") | .id" 2>/dev/null || true)
      [ -n "${ids:-}" ] && break
      sleep 2
    done

    if [ -z "${ids:-}" ]; then
      log "Cleanup: runner not found via API; nothing to delete"
      return 0
    fi

    for id in $ids; do
      if http_delete "${_ENTRY_API_DELETE_PREFIX}/${id}"; then
        log "Cleanup: unregistered runner id ${id}"
      else
        log "Cleanup: failed to unregister runner id ${id}"
      fi
    done
  }

  trap cleanup SIGINT SIGTERM EXIT

  log "Configuring runner for ${_ENTRY_REPO_URL} as ${_ENTRY_NAME}"
  ./config.sh --unattended \
    --url "${_ENTRY_REPO_URL}" \
    --token "${_ENTRY_TOKEN}" \
    --name "${_ENTRY_NAME}" \
    --work "${_ENTRY_WORK}" \
    --labels "${_ENTRY_LABELS}" \
    --replace

  log "Starting runner"
  exec ./run.sh
'
