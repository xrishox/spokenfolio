#!/usr/bin/env bash
# Build the patched Readest AppImage. RUN THIS ON THE LINUX BOX
# (Tauri only produces AppImages on Linux).
#
# - Clones upstream readest (if missing) next to this script
# - Applies our patches from readest/patches/ on a dedicated local branch
# - Builds the AppImage with pnpm + tauri
#
# Build deps (Arch: base-devel webkit2gtk-4.1 gtk3 libappindicator-gtk3 librsvg;
# Debian/Ubuntu: build-essential libwebkit2gtk-4.1-dev libgtk-3-dev
# libayatana-appindicator3-dev librsvg2-dev) plus rust (rustup), node >= 22, pnpm.
set -euo pipefail

UPSTREAM_URL="https://github.com/readest/readest.git"
BRANCH="custom-openai-tts-codecs"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLONE_DIR="${SCRIPT_DIR}/readest"

info() { printf '[build] %s\n' "$1"; }
die()  { printf '[build] ERROR: %s\n' "$1" >&2; exit 1; }

command -v pnpm >/dev/null || die "pnpm not found"
command -v cargo >/dev/null || die "rust/cargo not found (install via rustup)"

if [[ ! -d "${CLONE_DIR}/.git" ]]; then
    info "Cloning upstream readest"
    git clone --depth 50 "${UPSTREAM_URL}" "${CLONE_DIR}"
fi

cd "${CLONE_DIR}"

if ! git rev-parse --verify --quiet "${BRANCH}" >/dev/null; then
    BASE_COMMIT="$(cat "${SCRIPT_DIR}/patches/BASE_COMMIT" 2>/dev/null || echo origin/main)"
    info "Creating ${BRANCH} at ${BASE_COMMIT} and applying patches"
    git checkout -q -b "${BRANCH}" "${BASE_COMMIT}" \
        || { git fetch --depth 200 origin && git checkout -q -b "${BRANCH}" "${BASE_COMMIT}"; }
    git am "${SCRIPT_DIR}"/patches/*.patch
else
    git checkout -q "${BRANCH}"
fi

info "Initializing Readest submodules"
git submodule update --init --recursive

info "Installing JS dependencies"
pnpm install

info "Preparing PDF, SimpleCC, and Jieba web assets"
pnpm --filter @readest/readest-app setup-vendors

info "Building AppImage (this takes a while on first run)"
pnpm --filter @readest/readest-app tauri build --bundles appimage

BUNDLE_DIR="apps/readest-app/src-tauri/target/release/bundle/appimage"
ls "${BUNDLE_DIR}"/*.AppImage 2>/dev/null || die "no AppImage produced (check output above)"
info "AppImage ready in ${CLONE_DIR}/${BUNDLE_DIR}/"
