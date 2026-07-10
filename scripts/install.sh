#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_DIR="${SIRI_TTS_INSTALL_DIR:-/Applications}"
APP_NAME="Siri TTS Server.app"
SOURCE_APP="${ROOT}/dist/${APP_NAME}"
DESTINATION="${INSTALL_DIR}/${APP_NAME}"
CLI_DIR="${HOME}/.local/bin"
INSTALLED_EXECUTABLE="${DESTINATION}/Contents/MacOS/siri-tts-server"
INSTALLED_PROCESS_PATTERN="^${INSTALLED_EXECUTABLE//./\\.}([[:space:]]|$)"

"${ROOT}/scripts/build-app.sh" >/dev/null
mkdir -p "${INSTALL_DIR}" "${CLI_DIR}"

if [[ -d "${DESTINATION}" ]]; then
    osascript -e 'tell application id "com.xrishox.macos-tts-server" to quit' \
        >/dev/null 2>&1 || true
    for _ in {1..50}; do
        if ! pgrep -f "${INSTALLED_PROCESS_PATTERN}" >/dev/null; then
            break
        fi
        sleep 0.1
    done
    if pgrep -f "${INSTALLED_PROCESS_PATTERN}" >/dev/null; then
        pkill -TERM -f "${INSTALLED_PROCESS_PATTERN}" || true
        for _ in {1..50}; do
            if ! pgrep -f "${INSTALLED_PROCESS_PATTERN}" >/dev/null; then
                break
            fi
            sleep 0.1
        done
    fi
    if pgrep -f "${INSTALLED_PROCESS_PATTERN}" >/dev/null; then
        printf 'error: installed app did not stop; refusing to replace a running executable\n' >&2
        exit 1
    fi
fi

staged="${INSTALL_DIR}/.${APP_NAME}.installing"
rm -rf "${staged}"
ditto "${SOURCE_APP}" "${staged}"
rm -rf "${DESTINATION}"
mv "${staged}" "${DESTINATION}"
ln -sfn "${DESTINATION}/Contents/MacOS/siri-tts-server" "${CLI_DIR}/siri-tts-server"

codesign --verify --deep --strict "${DESTINATION}"
if [[ "${SIRI_TTS_NO_OPEN:-0}" != "1" ]]; then
    open "${DESTINATION}"
fi

printf 'Installed %s\n' "${DESTINATION}"
printf 'CLI: %s serve\n' "${CLI_DIR}/siri-tts-server"
if [[ ":${PATH}:" != *":${CLI_DIR}:"* ]]; then
    printf 'Note: %s is not on PATH; use the full CLI path shown above.\n' "${CLI_DIR}"
fi
printf 'Grant Full Disk Access from the menu if requested, then run the connection test.\n'
