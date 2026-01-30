#!/bin/bash
set -euo pipefail

cd /actions-runner

if [ -z "${RUNNER_VERSION:-}" ]; then
  echo "ERROR: RUNNER_VERSION must be set"
  exit 1
fi

RUNNER_TAR="actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz"
RUNNER_URL_DL="https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/${RUNNER_TAR}"
VERSION_FILE=".runner-version"
CONFIGURED_FILE=".runner-configured"

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

# Configure runner once
if [ ! -f "${CONFIGURED_FILE}" ]; then
  if [ -z "${RUNNER_URL:-}" ] || [ -z "${RUNNER_TOKEN:-}" ]; then
    echo "ERROR: RUNNER_URL and RUNNER_TOKEN must be set"
    exit 1
  fi

  echo "Configuring runner for ${RUNNER_URL}"

  # Prefer RUNNER_NAME (set in env or .env), then hostname
  SELECTED_NAME="${RUNNER_NAME:-$(hostname)}"

  ./config.sh --unattended \
    --url "${RUNNER_URL}" \
    --token "${RUNNER_TOKEN}" \
    --name "${SELECTED_NAME}" \
    --work "${RUNNER_WORKDIR:-_work}" \
    ${RUNNER_LABELS:+--labels "${RUNNER_LABELS}"} \
    --replace

  touch "${CONFIGURED_FILE}"
fi

exec ./run.sh
