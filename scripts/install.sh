#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_DIR="${SPOKENFOLIO_INSTALL_DIR:-/Applications}"
APP_NAME="SpokenFolio.app"
LEGACY_APP_NAME="Siri TTS Server.app"
SOURCE_APP="${ROOT}/dist/${APP_NAME}"
DESTINATION="${INSTALL_DIR}/${APP_NAME}"
LEGACY_DESTINATION="${INSTALL_DIR}/${LEGACY_APP_NAME}"
STAGED="${INSTALL_DIR}/.${APP_NAME}.installing"
BACKUP="${INSTALL_DIR}/.${APP_NAME}.backup"
LEGACY_BACKUP="${INSTALL_DIR}/.${LEGACY_APP_NAME}.backup"
CLI_DIR="${HOME}/.local/bin"
CLI_LINK="${CLI_DIR}/spokenfolio"
LEGACY_CLI_LINK="${CLI_DIR}/siri-tts-server"
CLI_BACKUP="${CLI_DIR}/.spokenfolio.install-backup"
LEGACY_CLI_BACKUP="${CLI_DIR}/.siri-tts-server.install-backup"
INSTALLED_EXECUTABLE="${DESTINATION}/Contents/MacOS/spokenfolio"
LEGACY_EXECUTABLE="${LEGACY_DESTINATION}/Contents/MacOS/siri-tts-server"
LEGACY_SUPPORT="${HOME}/Library/Application Support/com.xrishox.macos-tts-server"
CURRENT_SUPPORT="${HOME}/Library/Application Support/com.xrishox.spokenfolio"
MIGRATION_JOURNAL="${HOME}/Library/Application Support/.com.xrishox.spokenfolio.migration.json"

"${ROOT}/scripts/build-app.sh" >/dev/null
mkdir -p "${INSTALL_DIR}" "${CLI_DIR}"
rm -rf "${STAGED}"
ditto "${SOURCE_APP}" "${STAGED}"
codesign --verify --deep --strict "${STAGED}"

process_ids() {
    local executable
    for executable in "${INSTALLED_EXECUTABLE}" "${LEGACY_EXECUTABLE}"; do
        [[ -f "${executable}" ]] || continue
        lsof -t -- "${executable}" 2>/dev/null || true
    done | sort -u
}

is_heavy_work() {
    local pid="$1" command
    command="$(ps -p "${pid}" -o command= 2>/dev/null || true)"
    [[ "${command}" == *" jobs run "* \
        || "${command}" == *" audiobook create"* \
        || "${command}" == *" readaloud create"* \
        || "${command}" == *" readaloud tools install"* \
        || "${command}" == *" stalign "* ]]
}

active_execution_ids() {
    local root lock
    for root in "${CURRENT_SUPPORT}" "${LEGACY_SUPPORT}"; do
        lock="${root}/studio-execution.lock"
        [[ -f "${lock}" ]] && lsof -t -- "${lock}" 2>/dev/null || true
    done | sort -u
}

for pid in $(process_ids; active_execution_ids); do
    if is_heavy_work "${pid}" || [[ -n "$(active_execution_ids | grep -x "${pid}" || true)" ]]; then
        printf 'error: book production or ReadAloud work is active (PID %s); pause or finish it before updating\n' "${pid}" >&2
        rm -rf "${STAGED}"
        exit 1
    fi
done

is_managed_link() {
    local link="$1"
    [[ -L "${link}" ]] || return 1
    local target
    target="$(readlink "${link}")"
    [[ "${target}" == *"/Siri TTS Server.app/Contents/MacOS/siri-tts-server" \
        || "${target}" == *"/SpokenFolio.app/Contents/MacOS/spokenfolio" \
        || "${target}" == "${LEGACY_EXECUTABLE}" \
        || "${target}" == "${INSTALLED_EXECUTABLE}" ]]
}

for link in "${CLI_LINK}" "${LEGACY_CLI_LINK}"; do
    if [[ -e "${link}" || -L "${link}" ]]; then
        if ! is_managed_link "${link}"; then
            printf 'error: refusing to replace user-managed path %s\n' "${link}" >&2
            rm -rf "${STAGED}"
            exit 1
        fi
    fi
done

was_running=0
[[ -n "$(process_ids)" ]] && was_running=1
for bundle_id in com.xrishox.spokenfolio com.xrishox.macos-tts-server; do
    osascript -e "tell application id \"${bundle_id}\" to quit" >/dev/null 2>&1 || true
done
for _ in {1..100}; do
    [[ -z "$(process_ids)" ]] && break
    sleep 0.1
done
if [[ -n "$(process_ids)" ]]; then
    printf 'error: installed application did not stop; refusing to replace a running executable\n' >&2
    rm -rf "${STAGED}"
    exit 1
fi
if [[ -n "$(active_execution_ids)" ]]; then
    printf 'error: production execution lock remains held; refusing identity migration\n' >&2
    rm -rf "${STAGED}"
    exit 1
fi

swap_started=0
committed=0
cleanup() {
    local status=$?
    trap - EXIT INT TERM
    if [[ "${committed}" != "1" && "${swap_started}" == "1" ]]; then
        rm -rf "${DESTINATION}" "${LEGACY_DESTINATION}"
        [[ -d "${BACKUP}" ]] && mv "${BACKUP}" "${DESTINATION}"
        [[ -d "${LEGACY_BACKUP}" ]] && mv "${LEGACY_BACKUP}" "${LEGACY_DESTINATION}"
        rm -f "${CLI_LINK}" "${LEGACY_CLI_LINK}"
        [[ -e "${CLI_BACKUP}" || -L "${CLI_BACKUP}" ]] && mv "${CLI_BACKUP}" "${CLI_LINK}"
        [[ -e "${LEGACY_CLI_BACKUP}" || -L "${LEGACY_CLI_BACKUP}" ]] \
            && mv "${LEGACY_CLI_BACKUP}" "${LEGACY_CLI_LINK}"
        if [[ "${was_running}" == "1" ]]; then
            if [[ -d "${LEGACY_DESTINATION}" ]]; then open "${LEGACY_DESTINATION}" >/dev/null 2>&1 || true
            elif [[ -d "${DESTINATION}" ]]; then open "${DESTINATION}" >/dev/null 2>&1 || true
            fi
        fi
    fi
    rm -rf "${STAGED}"
    exit "${status}"
}
trap cleanup EXIT INT TERM

rm -rf "${BACKUP}" "${LEGACY_BACKUP}"
rm -f "${CLI_BACKUP}" "${LEGACY_CLI_BACKUP}"
[[ -d "${DESTINATION}" ]] && mv "${DESTINATION}" "${BACKUP}"
[[ -d "${LEGACY_DESTINATION}" ]] && mv "${LEGACY_DESTINATION}" "${LEGACY_BACKUP}"
[[ -e "${CLI_LINK}" || -L "${CLI_LINK}" ]] && mv "${CLI_LINK}" "${CLI_BACKUP}"
[[ -e "${LEGACY_CLI_LINK}" || -L "${LEGACY_CLI_LINK}" ]] \
    && mv "${LEGACY_CLI_LINK}" "${LEGACY_CLI_BACKUP}"
swap_started=1

if [[ "${SPOKENFOLIO_INSTALL_TEST_FAIL_AFTER_BACKUP:-0}" == "1" ]]; then
    [[ "${INSTALL_DIR}" == /tmp/* ]] || {
        printf 'error: install test failpoint is restricted to /tmp\n' >&2
        exit 1
    }
    printf 'error: injected install failure after backup\n' >&2
    exit 99
fi

mv "${STAGED}" "${DESTINATION}"
codesign --verify --deep --strict "${DESTINATION}"

temporary_link="${CLI_DIR}/.spokenfolio.$$.tmp"
rm -f "${temporary_link}"
ln -s "${INSTALLED_EXECUTABLE}" "${temporary_link}"
mv -f "${temporary_link}" "${CLI_LINK}"

# LaunchServices gives the foreground migration process permission to show the
# normal Keychain access prompt. Direct non-interactive execution cannot do so.
open -W -n "${DESTINATION}" --args _migrate-legacy-identity
if [[ -d "${LEGACY_SUPPORT}" || ! -d "${CURRENT_SUPPORT}" || -e "${MIGRATION_JOURNAL}" ]]; then
    printf 'error: identity migration did not commit; restoring the previous installation\n' >&2
    exit 1
fi

committed=1
rm -rf "${BACKUP}" "${LEGACY_BACKUP}" || true
rm -f "${CLI_BACKUP}" "${LEGACY_CLI_BACKUP}" "${LEGACY_CLI_LINK}" || true

if [[ "${SPOKENFOLIO_NO_OPEN:-0}" != "1" ]]; then
    open "${DESTINATION}" || printf 'warning: installed successfully but could not launch the app\n' >&2
fi

printf 'Installed %s\n' "${DESTINATION}"
printf 'CLI: %s serve\n' "${CLI_LINK}"
if [[ ":${PATH}:" != *":${CLI_DIR}:"* ]]; then
    printf 'Note: %s is not on PATH; use the full CLI path shown above.\n' "${CLI_DIR}"
fi
printf 'Grant Full Disk Access to SpokenFolio, then quit and reopen it before testing Siri synthesis.\n'
printf 'The renamed app has a new Launch at Login identity; re-enable it in SpokenFolio Settings if desired.\n'
