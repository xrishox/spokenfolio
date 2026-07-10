#!/usr/bin/env bash
set -euo pipefail

FORK_URL="https://github.com/xrishox/readest.git"
BRANCH="custom-openai-tts-implementation"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLONE_DIR="${READEST_CHECKOUT:-${SCRIPT_DIR}/readest}"

command -v pnpm >/dev/null || { echo 'pnpm is required' >&2; exit 1; }
command -v cargo >/dev/null || { echo 'Rust/cargo is required' >&2; exit 1; }

if [[ ! -d "${CLONE_DIR}/.git" ]]; then
    git clone --branch "${BRANCH}" --single-branch "${FORK_URL}" "${CLONE_DIR}"
fi

cd "${CLONE_DIR}"
git fetch origin "${BRANCH}"
git checkout "${BRANCH}"
git pull --ff-only origin "${BRANCH}"
git submodule update --init --recursive
pnpm install --frozen-lockfile
pnpm --filter @readest/readest-app setup-vendors
pnpm --filter @readest/readest-app tauri build --bundles appimage

bundle_dir="apps/readest-app/src-tauri/target/release/bundle/appimage"
ls "${bundle_dir}"/*.AppImage
