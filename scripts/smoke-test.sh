#!/usr/bin/env bash
# Contract smoke test for the macOS TTS server. Works from macOS or Linux.
#
# Usage: scripts/smoke-test.sh [SERVER_URL] [VOICE]
#   SERVER_URL  default http://localhost:8787
#   VOICE       default Samantha (name or full identifier)
set -euo pipefail

SERVER="${1:-http://localhost:8787}"
VOICE="${2:-Samantha}"
OUT="$(mktemp -t tts-smoke-XXXXXX).wav"
trap 'rm -f "${OUT}"' EXIT

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok: %s\n' "$1"; }

command -v curl >/dev/null || fail "curl not found"
command -v python3 >/dev/null || fail "python3 not found"

# 1. Health check
curl -sf --max-time 5 "${SERVER}/v1/models" >/dev/null || fail "GET /v1/models unreachable at ${SERVER}"
pass "server reachable (${SERVER})"

# 2. Voice catalog
curl -sf --max-time 10 "${SERVER}/v1/audio/voices/all" | python3 -c '
import json, sys
voices = json.load(sys.stdin)["voices"]
print(f"ok: {len(voices)} voices in catalog")
best = {}
for v in voices:
    if v["quality"] in ("enhanced", "premium"):
        best.setdefault(v["quality"], []).append(v["id"])
if not best:
    print("WARNING: only default-quality voices installed.")
    print("         Download Enhanced/Premium voices in System Settings ->")
    print("         Accessibility -> Spoken Content -> System Voices for better quality.")
else:
    for q, ids in sorted(best.items()):
        print(f"ok: {len(ids)} {q} voices (e.g. {ids[0]})")
' || fail "GET /v1/audio/voices/all"

# 3. Synthesis + first-byte latency
TIMING=$(curl -sf --max-time 30 -o "${OUT}" \
    -w '%{time_starttransfer} %{time_total} %{size_download}' \
    -X POST "${SERVER}/v1/audio/speech" \
    -H 'Content-Type: application/json' \
    -d "{\"model\":\"tts-1\",\"input\":\"The quick brown fox jumps over the lazy dog near the quiet river bank today.\",\"voice\":\"${VOICE}\",\"response_format\":\"wav\"}") \
    || fail "POST /v1/audio/speech (voice: ${VOICE})"

read -r TTFB TOTAL BYTES <<<"${TIMING}"
head -c 4 "${OUT}" | grep -q RIFF || fail "response is not a WAV file"
pass "synthesis ok (voice: ${VOICE}, ${BYTES} bytes, first byte ${TTFB}s, total ${TOTAL}s)"

# 4. Play if a player is available (optional)
if command -v afplay >/dev/null; then afplay "${OUT}"; pass "playback (afplay)"
elif command -v paplay >/dev/null; then paplay "${OUT}"; pass "playback (paplay)"
else printf 'note: no audio player found, skipping playback\n'; fi

printf 'SMOKE TEST PASSED\n'
