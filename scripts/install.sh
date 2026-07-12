#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_DIR="${SIRI_TTS_INSTALL_DIR:-/Applications}"
APP_NAME="Siri TTS Server.app"
SOURCE_APP="${ROOT}/dist/${APP_NAME}"
DESTINATION="${INSTALL_DIR}/${APP_NAME}"
CLI_DIR="${HOME}/.local/bin"
INSTALLED_EXECUTABLE="${DESTINATION}/Contents/MacOS/siri-tts-server"
STAGED="${INSTALL_DIR}/.${APP_NAME}.installing"
BACKUP="${INSTALL_DIR}/.${APP_NAME}.backup"
CLI_LINK="${CLI_DIR}/siri-tts-server"

"${ROOT}/scripts/build-app.sh" >/dev/null
mkdir -p "${INSTALL_DIR}" "${CLI_DIR}"

# Recover a previous interrupted swap before beginning a new one.
if [[ -d "${BACKUP}" && ! -d "${DESTINATION}" ]]; then
    mv "${BACKUP}" "${DESTINATION}"
elif [[ -d "${BACKUP}" && -d "${DESTINATION}" ]]; then
    rm -rf "${BACKUP}"
fi

rm -rf "${STAGED}"
ditto "${SOURCE_APP}" "${STAGED}"
codesign --verify --deep --strict "${STAGED}"

process_ids() {
    [[ -f "${INSTALLED_EXECUTABLE}" ]] || return 0
    lsof -t -- "${INSTALLED_EXECUTABLE}" 2>/dev/null | sort -u || true
}

is_audiobook_job() {
    local pid="$1" command
    command="$(ps -p "${pid}" -o command= 2>/dev/null || true)"
    [[ "${command}" == *" audiobook create"* ]]
}

for pid in $(process_ids); do
    if is_audiobook_job "${pid}"; then
        printf 'error: audiobook creation is active (PID %s); finish or cancel it before updating\n' "${pid}" >&2
        rm -rf "${STAGED}"
        exit 1
    fi
done

was_running=0
[[ -n "$(process_ids)" ]] && was_running=1
swap_started=0
committed=0
cleanup() {
    local status=$?
    trap - EXIT INT TERM
    if [[ "${committed}" != "1" && "${swap_started}" == "1" && -d "${BACKUP}" ]]; then
        rm -rf "${DESTINATION}"
        mv "${BACKUP}" "${DESTINATION}" || true
        if [[ "${was_running}" == "1" ]]; then open "${DESTINATION}" >/dev/null 2>&1 || true; fi
    fi
    rm -rf "${STAGED}"
    exit "${status}"
}
trap cleanup EXIT INT TERM

if [[ -d "${DESTINATION}" ]]; then
    osascript -e 'tell application id "com.xrishox.macos-tts-server" to quit' \
        >/dev/null 2>&1 || true
    for _ in {1..50}; do
        [[ -z "$(process_ids)" ]] && break
        sleep 0.1
    done
    remaining="$(process_ids)"
    if [[ -n "${remaining}" ]]; then
        kill -TERM ${remaining} 2>/dev/null || true
        for _ in {1..50}; do
            [[ -z "$(process_ids)" ]] && break
            sleep 0.1
        done
    fi
    if [[ -n "$(process_ids)" ]]; then
        printf 'error: installed app did not stop; refusing to replace a running executable\n' >&2
        exit 1
    fi
fi

rm -rf "${BACKUP}"
if [[ -d "${DESTINATION}" ]]; then mv "${DESTINATION}" "${BACKUP}"; fi
swap_started=1
if [[ "${SIRI_TTS_INSTALL_TEST_FAIL_AFTER_BACKUP:-0}" == "1" ]]; then
    [[ "${INSTALL_DIR}" == /tmp/* ]] || {
        printf 'error: install test failpoint is restricted to /tmp\n' >&2
        exit 1
    }
    printf 'error: injected install failure after backup\n' >&2
    exit 99
fi
mv "${STAGED}" "${DESTINATION}"
codesign --verify --deep --strict "${DESTINATION}"

temporary_link="${CLI_DIR}/.siri-tts-server.$$.tmp"
rm -f "${temporary_link}"
ln -s "${INSTALLED_EXECUTABLE}" "${temporary_link}"
mv -f "${temporary_link}" "${CLI_LINK}"

rm -rf "${BACKUP}"
committed=1
if [[ "${SIRI_TTS_NO_OPEN:-0}" != "1" ]]; then
    open "${DESTINATION}" || printf 'warning: installed successfully but could not launch the app\n' >&2
fi

printf 'Installed %s\n' "${DESTINATION}"
printf 'CLI: %s serve\n' "${CLI_LINK}"
if [[ ":${PATH}:" != *":${CLI_DIR}:"* ]]; then
    printf 'Note: %s is not on PATH; use the full CLI path shown above.\n' "${CLI_DIR}"
fi
printf 'Grant Full Disk Access if requested, then quit and reopen the app before testing.\n'
