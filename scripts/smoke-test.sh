#!/usr/bin/env bash
# End-to-end contract test for the patched macOS TTS server.
#
# Usage: scripts/smoke-test.sh [SERVER_URL] [VOICE]
#   SERVER_URL  default http://localhost:8787
#   VOICE       optional Siri asset id; otherwise the best installed voice is selected
set -euo pipefail

SERVER="${1:-http://localhost:8787}"
REQUESTED_VOICE="${2:-}"
TMP_DIR="$(mktemp -d -t tts-smoke-XXXXXX)"
trap 'rm -rf "${TMP_DIR}"' EXIT

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok: %s\n' "$1"; }

command -v curl >/dev/null || fail "curl not found"
command -v python3 >/dev/null || fail "python3 not found"

# 1. Health check
curl -sf --max-time 5 "${SERVER}/v1/models" >/dev/null \
    || fail "GET /v1/models unreachable at ${SERVER}"
pass "server reachable (${SERVER})"

# 2. Voice catalog and deterministic default voice selection. Prefer a natural
# Siri asset, then premium, then the first usable installed asset.
CATALOG="${TMP_DIR}/voices.json"
curl -sf --max-time 10 "${SERVER}/v1/audio/voices/all" -o "${CATALOG}" \
    || fail "GET /v1/audio/voices/all"

VOICE_INFO="$(REQUESTED_VOICE="${REQUESTED_VOICE}" python3 - "${CATALOG}" <<'PY'
import json, os, sys

with open(sys.argv[1], encoding="utf-8") as f:
    voices = json.load(f).get("voices", [])
if not voices:
    raise SystemExit("voice catalog is empty")

requested = os.environ.get("REQUESTED_VOICE", "")
if requested:
    matches = [v for v in voices if v.get("id") == requested or v.get("name") == requested]
    if not matches:
        raise SystemExit(f"requested voice is not installed: {requested}")
    selected = matches[0]
else:
    selected = next((v for v in voices if ".natural." in v.get("id", "").lower()), None)
    selected = selected or next((v for v in voices if v.get("quality") == "premium"), None)
    selected = selected or voices[0]

natural = sum(".natural." in v.get("id", "").lower() for v in voices)
neural = sum(".neural." in v.get("id", "").lower() for v in voices)
print(selected["id"])
print(f"{len(voices)} voices; {natural} natural, {neural} neural", file=sys.stderr)
PY
)" || fail "voice catalog validation"
VOICE="${VOICE_INFO}"
pass "voice catalog valid; selected ${VOICE}"

make_payload() {
    local format="$1"
    VOICE="${VOICE}" FORMAT="${format}" python3 - <<'PY'
import json, os
print(json.dumps({
    "model": "tts-1",
    "input": "The quick brown fox jumps over the lazy dog near the quiet river bank today.",
    "voice": os.environ["VOICE"],
    "response_format": os.environ["FORMAT"],
    "speed": 1.0,
}))
PY
}

verify_structure() {
    local format="$1"
    local file="$2"
    python3 - "${format}" "${file}" <<'PY'
import pathlib, sys

fmt, path = sys.argv[1], pathlib.Path(sys.argv[2])
data = path.read_bytes()
if not data:
    raise SystemExit("empty response")
if fmt == "opus" and not data.startswith(b"OggS"):
    raise SystemExit("Opus response is not an Ogg stream")
if fmt == "aac" and (len(data) < 12 or data[4:8] != b"ftyp"):
    raise SystemExit("AAC response is not an M4A/MP4 file")
if fmt == "wav" and not (data.startswith(b"RIFF") and data[8:12] == b"WAVE"):
    raise SystemExit("WAV response has no RIFF/WAVE header")
PY
}

verify_decode() {
    local format="$1"
    local file="$2"
    local expected_codec="$3"
    if command -v ffmpeg >/dev/null; then
        ffmpeg -v error -i "${file}" -f null - \
            || fail "ffmpeg could not decode ${format} audio frames"
        pass "${format} audio frames decode through ffmpeg"
    elif command -v afconvert >/dev/null; then
        local decoded="${TMP_DIR}/decoded-${format}.caf"
        afconvert "${file}" "${decoded}" -f caff -d LEI16@48000 \
            || fail "afconvert could not decode ${format} audio frames"
        [[ -s "${decoded}" ]] || fail "afconvert produced no decoded ${format} audio"
        pass "${format} audio frames decode through afconvert"
    else
        fail "ffmpeg or afconvert is required for real decode verification"
    fi

    if command -v ffprobe >/dev/null; then
        local probe codec rate channels
        probe="$(ffprobe -v error -select_streams a:0 \
            -show_entries stream=codec_name,sample_rate,channels \
            -of csv=p=0 "${file}")" || fail "ffprobe could not decode ${format}"
        IFS=',' read -r codec rate channels <<<"${probe}"
        [[ "${codec}" == "${expected_codec}" ]] \
            || fail "${format} codec is ${codec}, expected ${expected_codec}"
        [[ "${rate}" == "48000" ]] || fail "${format} sample rate is ${rate}, expected 48000"
        [[ "${channels}" == "1" ]] || fail "${format} has ${channels} channels, expected mono"
        pass "${format} metadata (${codec}, ${rate} Hz, mono)"
    elif command -v afinfo >/dev/null; then
        afinfo "${file}" >/dev/null || fail "afinfo could not inspect ${format}"
        pass "${format} metadata (afinfo)"
    else
        printf 'note: ffprobe/afinfo unavailable; codec metadata not independently inspected for %s\n' "${format}"
    fi
}

request_format() {
    local format="$1"
    local extension="$2"
    local expected_type="$3"
    local expected_codec="$4"
    local out="${TMP_DIR}/sample.${extension}"
    local timing ttfb total bytes content_type

    timing="$(curl -sf --max-time 30 -o "${out}" \
        -w $'%{time_starttransfer}\t%{time_total}\t%{size_download}\t%{content_type}' \
        -X POST "${SERVER}/v1/audio/speech" \
        -H 'Content-Type: application/json' \
        -d "$(make_payload "${format}")")" \
        || fail "POST /v1/audio/speech (${format}, voice: ${VOICE})"
    IFS=$'\t' read -r ttfb total bytes content_type <<<"${timing}"
    [[ "${content_type}" == "${expected_type}"* ]] \
        || fail "${format} Content-Type is '${content_type}', expected '${expected_type}'"
    verify_structure "${format}" "${out}" || fail "invalid ${format} container"
    pass "${format} synthesis (${bytes} bytes, first byte ${ttfb}s, total ${total}s)"
    verify_decode "${format}" "${out}" "${expected_codec}"
}

# 3. Every compressed Readest rung and the explicit WAV diagnostic format must
# really work. Readest negotiates Opus then AAC; it does not automatically use WAV.
request_format opus ogg "audio/ogg" opus
request_format aac m4a "audio/mp4" aac
request_format wav wav "audio/wav" pcm_s16le

# 4. Play the universal fallback sample when a player is available (optional).
if [[ "${TTS_SMOKE_NO_PLAYBACK:-0}" == "1" ]]; then
    printf 'note: TTS_SMOKE_NO_PLAYBACK=1, skipping playback\n'
elif command -v afplay >/dev/null; then
    afplay "${TMP_DIR}/sample.wav"
    pass "playback (afplay)"
elif command -v paplay >/dev/null; then
    paplay "${TMP_DIR}/sample.wav"
    pass "playback (paplay)"
else
    printf 'note: no audio player found, skipping playback\n'
fi

printf 'SMOKE TEST PASSED\n'
