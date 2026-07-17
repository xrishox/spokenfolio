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

mkdir -p "${INSTALL_DIR}" "${CLI_DIR}"

recover_interrupted_backup() {
    local backup="$1" destination="$2"
    [[ -e "${backup}" || -L "${backup}" ]] || return 0
    if [[ -e "${destination}" || -L "${destination}" ]]; then
        printf 'error: both %s and interrupted-install backup %s exist; refusing to delete either\n' \
            "${destination}" "${backup}" >&2
        exit 1
    fi
    mv "${backup}" "${destination}"
}

recover_interrupted_backup "${BACKUP}" "${DESTINATION}"
recover_interrupted_backup "${LEGACY_BACKUP}" "${LEGACY_DESTINATION}"
recover_interrupted_backup "${CLI_BACKUP}" "${CLI_LINK}"
recover_interrupted_backup "${LEGACY_CLI_BACKUP}" "${LEGACY_CLI_LINK}"
"${ROOT}/scripts/build-app.sh" >/dev/null
rm -rf "${STAGED}"
ditto "${SOURCE_APP}" "${STAGED}"
codesign --verify --deep --strict "${STAGED}"

is_managed_bundle() {
    local bundle="$1" expected_id="$2" executable="$3"
    [[ -d "${bundle}" && -f "${bundle}/Contents/Info.plist" && -f "${executable}" ]] || return 1
    [[ "$(plutil -extract CFBundleIdentifier raw "${bundle}/Contents/Info.plist" 2>/dev/null || true)" == "${expected_id}" ]]
}

if [[ -e "${DESTINATION}" || -L "${DESTINATION}" ]]; then
    is_managed_bundle "${DESTINATION}" com.xrishox.spokenfolio "${INSTALLED_EXECUTABLE}" || {
        printf 'error: refusing to replace unrecognized path %s\n' "${DESTINATION}" >&2
        exit 1
    }
fi
if [[ -e "${LEGACY_DESTINATION}" || -L "${LEGACY_DESTINATION}" ]]; then
    is_managed_bundle "${LEGACY_DESTINATION}" com.xrishox.macos-tts-server "${LEGACY_EXECUTABLE}" || {
        printf 'error: refusing to replace unrecognized path %s\n' "${LEGACY_DESTINATION}" >&2
        exit 1
    }
fi

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
request_quit() {
    local bundle_id="$1" pid
    osascript -e "tell application id \"${bundle_id}\" to quit" >/dev/null 2>&1 &
    pid=$!
    for _ in {1..20}; do
        kill -0 "${pid}" 2>/dev/null || break
        sleep 0.1
    done
    if kill -0 "${pid}" 2>/dev/null; then
        kill "${pid}" 2>/dev/null || true
    fi
    wait "${pid}" 2>/dev/null || true
}
for bundle_id in com.xrishox.spokenfolio com.xrishox.macos-tts-server; do
    request_quit "${bundle_id}"
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
destination_backed=0
legacy_backed=0
cli_backed=0
legacy_cli_backed=0
new_destination=0
new_cli=0
cleanup() {
    local status=$?
    trap - EXIT INT TERM
    if [[ "${committed}" != "1" && "${swap_started}" == "1" ]]; then
        [[ "${new_destination}" == "1" ]] && rm -rf "${DESTINATION}"
        [[ "${destination_backed}" == "1" ]] && mv "${BACKUP}" "${DESTINATION}"
        [[ "${legacy_backed}" == "1" ]] && mv "${LEGACY_BACKUP}" "${LEGACY_DESTINATION}"
        [[ "${new_cli}" == "1" ]] && rm -f "${CLI_LINK}"
        [[ "${cli_backed}" == "1" ]] && mv "${CLI_BACKUP}" "${CLI_LINK}"
        [[ "${legacy_cli_backed}" == "1" ]] \
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

[[ ! -e "${BACKUP}" && ! -L "${BACKUP}" \
    && ! -e "${LEGACY_BACKUP}" && ! -L "${LEGACY_BACKUP}" \
    && ! -e "${CLI_BACKUP}" && ! -L "${CLI_BACKUP}" \
    && ! -e "${LEGACY_CLI_BACKUP}" && ! -L "${LEGACY_CLI_BACKUP}" ]]
swap_started=1
if [[ -d "${DESTINATION}" ]]; then mv "${DESTINATION}" "${BACKUP}"; destination_backed=1; fi
if [[ -d "${LEGACY_DESTINATION}" ]]; then
    mv "${LEGACY_DESTINATION}" "${LEGACY_BACKUP}"; legacy_backed=1
fi
if [[ -e "${CLI_LINK}" || -L "${CLI_LINK}" ]]; then
    mv "${CLI_LINK}" "${CLI_BACKUP}"; cli_backed=1
fi
if [[ -e "${LEGACY_CLI_LINK}" || -L "${LEGACY_CLI_LINK}" ]]; then
    mv "${LEGACY_CLI_LINK}" "${LEGACY_CLI_BACKUP}"; legacy_cli_backed=1
fi

if [[ "${SPOKENFOLIO_INSTALL_TEST_FAIL_AFTER_BACKUP:-0}" == "1" ]]; then
    [[ "${INSTALL_DIR}" == /tmp/* ]] || {
        printf 'error: install test failpoint is restricted to /tmp\n' >&2
        exit 1
    }
    printf 'error: injected install failure after backup\n' >&2
    exit 99
fi

mv "${STAGED}" "${DESTINATION}"
new_destination=1
codesign --verify --deep --strict "${DESTINATION}"

temporary_link="${CLI_DIR}/.spokenfolio.$$.tmp"
rm -f "${temporary_link}"
ln -s "${INSTALLED_EXECUTABLE}" "${temporary_link}"
mv -f "${temporary_link}" "${CLI_LINK}"
new_cli=1

# Run the installed, signed executable directly: unlike `open`, its exit code
# is the migration's exit code and can participate in the rollback decision.
"${INSTALLED_EXECUTABLE}" _migrate-legacy-identity
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
