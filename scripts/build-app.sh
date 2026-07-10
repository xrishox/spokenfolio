#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Siri TTS Server.app"
DIST="${ROOT}/dist"
APP="${DIST}/${APP_NAME}"
CONTENTS="${APP}/Contents"
MACOS="${CONTENTS}/MacOS"

cd "${ROOT}"
swift build --configuration release

rm -rf "${APP}"
mkdir -p "${MACOS}"
install -m 755 ".build/release/siri-tts-server" "${MACOS}/siri-tts-server"
install -m 644 "Resources/Info.plist" "${CONTENTS}/Info.plist"

identity="${CODE_SIGN_IDENTITY:-}"
explicit_identity=0
[[ -n "${identity}" ]] && explicit_identity=1
if [[ -z "${identity}" ]]; then
    identity="$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -nE 's/^[[:space:]]*[0-9]+\) [[:xdigit:]]+ "([^"]+)"$/\1/p' \
        | grep -E '^(Apple Development|Developer ID Application):' \
        | head -n 1 || true)"
fi
if [[ -z "${identity}" ]]; then
    identity="-"
    printf 'warning: no Apple code-signing identity found; using ad-hoc signing\n' >&2
    printf 'warning: Full Disk Access may need to be granted again after rebuilding\n' >&2
fi

if ! codesign --force --options runtime --sign "${identity}" "${APP}"; then
    if [[ "${explicit_identity}" == "1" || "${identity}" == "-" ]]; then
        exit 1
    fi
    printf 'warning: the discovered signing identity is unavailable to codesign\n' >&2
    printf 'warning: falling back to ad-hoc signing for this local build\n' >&2
    codesign --force --options runtime --sign - "${APP}"
fi
codesign --verify --deep --strict --verbose=2 "${APP}"
printf '%s\n' "${APP}"
