#!/bin/bash
set -euo pipefail

log() { echo "[docker-check] $*"; }

# Exit codes:
# 0 - OK
# 2 - socket missing
# 3 - docker CLI cannot reach daemon for current user
# 4 - docker CLI not installed

SOCKET="/var/run/docker.sock"

if [ ! -S "${SOCKET}" ]; then
  log "No docker socket at ${SOCKET} (socket missing or not a socket).\n  To enable docker in workflows mount the host socket: -v /var/run/docker.sock:/var/run/docker.sock"
  exit 2
fi

if ! command -v docker >/dev/null 2>&1; then
  log "docker CLI not found in container; cannot verify daemon connectivity. Ensure docker is installed in the image."
  exit 4
fi

# Try contacting the daemon with a short timeout to avoid hangs
if command -v timeout >/dev/null 2>&1; then
  if timeout 5 docker version >/dev/null 2>&1; then
    log "Docker CLI can reach daemon (socket accessible)."
    exit 0
  else
    owner_info=$(stat -c '%U:%G %u:%g' "${SOCKET}" 2>/dev/null || true)
    log "Docker CLI cannot reach daemon while running as $(id -un) or permissions prevent access. Socket owner/info: ${owner_info}
      Common fixes:
      - Ensure the container user is a member of the socket's group (the image attempts to map the socket gid at startup).
      - Start the container with the socket mounted: -v /var/run/docker.sock:/var/run/docker.sock
      - Optionally use Docker Compose \`group_add\` with the host docker gid, or run with --privileged as a last resort.
      - Check host permissions: run 'ls -l /var/run/docker.sock' on the host to inspect uid:gid."
    exit 3
  fi
else
  # No timeout available; attempt a quick check but limit runtime by running in background briefly
  docker version >/dev/null 2>&1 &
  pid=$!
  sleep 5
  if kill -0 "$pid" 2>/dev/null; then
    # still running => assume failure/hang
    kill "$pid" 2>/dev/null || true
    owner_info=$(stat -c '%U:%G %u:%g' "${SOCKET}" 2>/dev/null || true)
    log "Docker CLI check timed out or failed. Socket owner/info: ${owner_info}\n  See README for troubleshooting."
    exit 3
  else
    wait "$pid" || true
    log "Docker CLI can reach daemon (socket accessible)."
    exit 0
  fi
fi
