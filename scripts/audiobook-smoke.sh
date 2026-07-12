#!/usr/bin/env bash
# Real end-to-end audiobook smoke test: plan a real EPUB, inspect its
# narration text, synthesize a two-chapter M4B with a real Siri voice,
# verify the container, and prove per-chapter resume.
#
# usage: ./scripts/audiobook-smoke.sh <book.epub>
set -euo pipefail

EPUB="${1:?usage: $0 <book.epub>}"
[ -f "$EPUB" ] || { echo "FAIL: no such EPUB: $EPUB" >&2; exit 1; }
EPUB="$(cd "$(dirname "$EPUB")" && pwd -P)/$(basename "$EPUB")"
cd "$(dirname "$0")/.."

fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok: $*"; }

swift build -q
BIN=.build/debug/siri-tts-server

TMP="$(mktemp -d "${TMPDIR:-/tmp}/audiobook-smoke.XXXXXX")"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# 1. Section/chapter planning.
"$BIN" audiobook chapters "$EPUB" > "$TMP/chapters.txt" 2> "$TMP/chapters-warnings.txt"
grep -q "^Sections (" "$TMP/chapters.txt" || fail "chapters listing has no sections table"
grep -q "^Chapters (" "$TMP/chapters.txt" || fail "chapters listing has no chapter list"
ok "chapters listing ($(grep -c '^' "$TMP/chapters.txt") lines)"
planned="$(sed -nE 's/^Chapters \(([0-9]+)\):/\1/p' "$TMP/chapters.txt" | head -n 1)"
[ -n "$planned" ] || fail "could not determine planned chapter count"
expected=$(( planned < 2 ? planned : 2 ))

# 2. Narration text export: no markup or note apparatus may leak.
"$BIN" audiobook export-text "$EPUB" --output "$TMP/text" > /dev/null
count="$(find "$TMP/text" -name '*.txt' | wc -l | tr -d ' ')"
[ "$count" -gt 0 ] || fail "export-text produced no chapter files"
if grep -rlE '<(p|div|span|a|img)[ >]|epub:type' "$TMP/text" > /dev/null 2>&1; then
  fail "HTML markup leaked into narration"
fi
ok "export-text ($count chapter files, no markup or note leakage)"

# 3. Real synthesis into a two-chapter M4B at the smallest bitrate.
"$BIN" audiobook create "$EPUB" \
  --max-chapters 2 --bitrate 32 \
  --output "$TMP/smoke.m4b" --work-dir "$TMP/work" --keep-work --quiet \
  || fail "audiobook create failed"
[ -s "$TMP/smoke.m4b" ] || fail "no audiobook file was produced"
ok "created $(du -h "$TMP/smoke.m4b" | cut -f1 | tr -d ' ') audiobook"

# 4. Container verification through AVFoundation and the box walker.
"$BIN" audiobook verify "$TMP/smoke.m4b" > "$TMP/verify.txt"
grep -q "stik:      2 (audiobook)" "$TMP/verify.txt" || fail "stik=2 missing"
grep -q "pgap:      1 (gapless)" "$TMP/verify.txt" || fail "pgap missing"
grep -q "Chapters:  $expected (Apple chapter track), $expected (Nero chpl)" "$TMP/verify.txt" \
  || fail "expected $expected chapters in both chapter systems: $(grep Chapters: "$TMP/verify.txt")"
grep -q '^Decoded:   [1-9][0-9]* PCM frames' "$TMP/verify.txt" \
  || fail "verify did not decode audio frames"
ok "verify: stik=2, pgap=1, both chapter systems, full frame decode"

afinfo "$TMP/smoke.m4b" | grep -q "1 ch,  48000 Hz, aac" \
  || fail "afinfo does not report mono 48 kHz AAC"
ok "afinfo: mono 48 kHz AAC"

if command -v ffprobe > /dev/null 2>&1; then
  chapters="$(ffprobe -v quiet -print_format json -show_chapters "$TMP/smoke.m4b" \
    | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["chapters"]))')"
  [ "$chapters" = "$expected" ] || fail "ffprobe sees $chapters chapters, expected $expected"
  ffmpeg -v error -i "$TMP/smoke.m4b" -f null - \
    || fail "ffmpeg could not decode the completed audiobook"
  ok "ffmpeg: $expected chapters and complete audio decode"
else
  echo "note: ffprobe not installed, skipping independent chapter check"
fi

# 5. Resume: an identical re-run must reuse every chapter.
"$BIN" audiobook create "$EPUB" \
  --max-chapters 2 --bitrate 32 \
  --output "$TMP/smoke.m4b" --work-dir "$TMP/work" --keep-work --overwrite \
  > /dev/null 2> "$TMP/resume.txt" || fail "resume run failed"
grep -q "($expected already complete)" "$TMP/resume.txt" \
  || fail "resume did not reuse completed chapters: $(cat "$TMP/resume.txt")"
ok "resume reused both chapters"

echo "AUDIOBOOK SMOKE TEST PASSED"
