#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="SpokenFolio.app"
DIST="${ROOT}/dist"
APP="${DIST}/${APP_NAME}"
CONTENTS="${APP}/Contents"
MACOS="${CONTENTS}/MacOS"
FRAMEWORKS="${CONTENTS}/Frameworks"
RESOURCES="${CONTENTS}/Resources"

cd "${ROOT}"
if [[ -d webui ]]; then
  if command -v npm >/dev/null 2>&1; then
    (cd webui && npm ci --no-audit --no-fund && npm run build)
  else
    echo "warning: npm not found; packaging the committed WebUI shell only" >&2
  fi
fi
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
mkdir -p "${MACOS}" "${FRAMEWORKS}" "${RESOURCES}"
install -m 755 ".build/release/spokenfolio" "${MACOS}/spokenfolio"
# The WebUI ships inside the SwiftPM resource bundle; Bundle.module falls
# back to Bundle.main.resourceURL, so the bundle must land in Resources
# before signing seals the app.
if [[ ! -d ".build/release/spokenfolio_SpokenFolioApp.bundle" ]]; then
  echo "error: SwiftPM resource bundle missing from the release build" >&2
  exit 1
fi
cp -R ".build/release/spokenfolio_SpokenFolioApp.bundle" "${RESOURCES}/"
install -m 644 "Resources/Info.plist" "${CONTENTS}/Info.plist"

iconset="${DIST}/SpokenFolio.iconset"
rm -rf "${iconset}"
mkdir -p "${iconset}"
for spec in "16:icon_16x16.png" "32:icon_16x16@2x.png" "32:icon_32x32.png" \
    "64:icon_32x32@2x.png" "128:icon_128x128.png" "256:icon_128x128@2x.png" \
    "256:icon_256x256.png" "512:icon_256x256@2x.png" "512:icon_512x512.png" \
    "1024:icon_512x512@2x.png"; do
    size="${spec%%:*}"
    name="${spec#*:}"
    sips -z "${size}" "${size}" "Resources/SpokenFolioIcon.png" \
        --out "${iconset}/${name}" >/dev/null
done
iconutil -c icns "${iconset}" -o "${RESOURCES}/SpokenFolio.icns"
rm -rf "${iconset}"
app_version="${APP_VERSION:-$(tr -d '[:space:]' < VERSION)}"
build_number="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || printf '1')}"
plutil -replace CFBundleShortVersionString -string "${app_version}" "${CONTENTS}/Info.plist"
plutil -replace CFBundleVersion -string "${build_number}" "${CONTENTS}/Info.plist"

stdlib_tool="$(xcrun --find swift-stdlib-tool 2>/dev/null || true)"
if [[ -z "${stdlib_tool}" ]]; then
    printf 'error: swift-stdlib-tool is required to make the app self-contained\n' >&2
    exit 1
fi
# SwiftPM release binaries can retain a developer-toolchain rpath. Loading
# from it makes a bundle appear healthy only on the machine that built it.
while IFS= read -r rpath; do
    [[ "${rpath}" == *'.xctoolchain/usr/lib/swift'* ]] || continue
    install_name_tool -delete_rpath "${rpath}" "${MACOS}/spokenfolio"
done < <(otool -l "${MACOS}/spokenfolio" | awk '/cmd LC_RPATH/{found=1; next} found && /path /{print $2; found=0}')
install_name_tool -add_rpath '@executable_path/../Frameworks' "${MACOS}/spokenfolio"
if ! "${stdlib_tool}" --copy \
    --scan-executable "${MACOS}/spokenfolio" \
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
done < <("${stdlib_tool}" --print --scan-executable "${MACOS}/spokenfolio" --platform macosx)

rpaths="$(otool -l "${MACOS}/spokenfolio" | awk '/cmd LC_RPATH/{found=1; next} found && /path /{print $2; found=0}')"
grep -Fx '@executable_path/../Frameworks' <<<"${rpaths}" >/dev/null || {
    printf 'error: packaged executable cannot locate its embedded compatibility libraries\n' >&2
    exit 1
}
if grep -E '/Applications/|\.xctoolchain/' <<<"${rpaths}" >/dev/null; then
    printf 'error: packaged executable retains a developer-machine runtime path\n' >&2
    exit 1
fi

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
