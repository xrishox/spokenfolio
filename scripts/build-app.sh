#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Siri TTS Server.app"
DIST="${ROOT}/dist"
APP="${DIST}/${APP_NAME}"
CONTENTS="${APP}/Contents"
MACOS="${CONTENTS}/MacOS"
FRAMEWORKS="${CONTENTS}/Frameworks"

cd "${ROOT}"
swift build --configuration release

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

rm -rf "${APP}"
mkdir -p "${MACOS}" "${FRAMEWORKS}"
install -m 755 ".build/release/siri-tts-server" "${MACOS}/siri-tts-server"
install -m 644 "Resources/Info.plist" "${CONTENTS}/Info.plist"

stdlib_tool="$(xcrun --find swift-stdlib-tool 2>/dev/null || true)"
if [[ -z "${stdlib_tool}" ]]; then
    printf 'error: swift-stdlib-tool is required to make the app self-contained\n' >&2
    exit 1
fi
install_name_tool -add_rpath '@executable_path/../Frameworks' "${MACOS}/siri-tts-server"
if ! "${stdlib_tool}" --copy \
    --scan-executable "${MACOS}/siri-tts-server" \
    --platform macosx --destination "${FRAMEWORKS}" --sign "${identity}"; then
    printf 'error: could not embed/sign required Swift compatibility libraries\n' >&2
    exit 1
fi
find "${FRAMEWORKS}" -type f -name '*.original' -delete

while IFS= read -r required; do
    [[ -z "${required}" ]] && continue
    if [[ ! -f "${FRAMEWORKS}/$(basename "${required}")" ]]; then
        printf 'error: required Swift library was not bundled: %s\n' "${required}" >&2
        exit 1
    fi
done < <("${stdlib_tool}" --print --scan-executable "${MACOS}/siri-tts-server" --platform macosx)

if ! codesign --force --options runtime --sign "${identity}" "${APP}"; then
    if [[ "${explicit_identity}" == "1" || "${identity}" == "-" ]]; then
        exit 1
    fi
    printf 'error: the discovered signing identity is unavailable to codesign\n' >&2
    printf 'error: unlock its private key or set CODE_SIGN_IDENTITY=- explicitly\n' >&2
    printf 'error: refusing an ad-hoc fallback that would reset Full Disk Access\n' >&2
    exit 1
fi
codesign --verify --deep --strict --verbose=2 "${APP}"
printf '%s\n' "${APP}"
