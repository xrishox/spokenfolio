#!/usr/bin/env bash
# Install the macOS TTS server (patched macos-speech-server) as a LaunchAgent.
#
# - Clones upstream at a pinned commit into server/macos-speech-server (if missing)
# - Applies our patches from server/patches/ (voices endpoints, stt:none)
# - Builds a release binary and installs it via upstream's deploy/install-agent.sh
# - Uses server/speech-server.yaml as the config (kept if one is already installed)
set -euo pipefail

UPSTREAM_URL="https://github.com/dokterbob/macos-speech-server.git"
UPSTREAM_COMMIT="ad16a6a"   # last verified-good upstream commit
BRANCH="voices-endpoint"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLONE_DIR="${SCRIPT_DIR}/macos-speech-server"
CONFIG_SRC="${SCRIPT_DIR}/speech-server.yaml"

info() { printf '[install] %s\n' "$1"; }
die()  { printf '[install] ERROR: %s\n' "$1" >&2; exit 1; }

[[ -f "${CONFIG_SRC}" ]] || die "missing ${CONFIG_SRC}"

if [[ ! -d "${CLONE_DIR}/.git" ]]; then
    info "Cloning upstream macos-speech-server"
    git clone "${UPSTREAM_URL}" "${CLONE_DIR}"
fi

cd "${CLONE_DIR}"

if ! git rev-parse --verify --quiet "${BRANCH}" >/dev/null; then
    info "Creating ${BRANCH} at ${UPSTREAM_COMMIT} and applying patches"
    git checkout -q -b "${BRANCH}" "${UPSTREAM_COMMIT}"
    git am "${SCRIPT_DIR}"/patches/*.patch
else
    git checkout -q "${BRANCH}"
fi

# Upstream installer reads its source config from the repo root (gitignored there).
install -m 644 "${CONFIG_SRC}" "${CLONE_DIR}/speech-server.yaml"

info "Running upstream LaunchAgent installer (builds release binary)"
./deploy/install-agent.sh

info "Done. Smoke test with: scripts/smoke-test.sh http://localhost:8787"
