#!/usr/bin/env bash
# TTS throughput experiment runner. Wraps the hidden `audiobook bench`
# subcommand with cooldowns, environment retries, and JSONL collection.
#
# usage:
#   ./scripts/bench-tts.sh <book.epub> <results.jsonl> e1            # worker sweep 1..16 ascending
#   ./scripts/bench-tts.sh <book.epub> <results.jsonl> confirm 12 8  # reverse-order re-runs
#   ./scripts/bench-tts.sh <book.epub> <results.jsonl> e2 <W>        # chapters-seq vs chapters-global
#   ./scripts/bench-tts.sh <book.epub> <results.jsonl> e3 <W>        # window 4x (baseline 2x is in e1)
#   ./scripts/bench-tts.sh <book.epub> <results.jsonl> e4 <W>        # chunk sizes (engine-level utterances)
#   ./scripts/bench-tts.sh <book.epub> <results.jsonl> samples <passage.txt> <outdir>
set -euo pipefail

EPUB="${1:?usage: $0 <book.epub> <results.jsonl> <stage> [args]}"
OUT="${2:?usage: $0 <book.epub> <results.jsonl> <stage> [args]}"
STAGE="${3:?stage required: e1|confirm|e2|e3|e4|samples}"
shift 3
cd "$(dirname "$0")/.."

swift build -c release
BIN=.build/release/siri-tts-server
if [ -f "$OUT" ]; then SEQ="$(wc -l < "$OUT" | tr -d ' ')"; else SEQ=0; fi
STDERR_LOG="$(mktemp "${TMPDIR:-/tmp}/bench-stderr.XXXXXX")"
trap 'rm -f "$STDERR_LOG"' EXIT

run() {
  local exp="$1"
  shift
  SEQ=$((SEQ + 1))
  echo ">>> run $SEQ: $exp $*" >&2
  local attempt=0
  until "$BIN" audiobook bench --epub "$EPUB" --experiment "$exp" --run-seq "$SEQ" "$@" \
    >> "$OUT" 2> "$STDERR_LOG"; do
    attempt=$((attempt + 1))
    cat "$STDERR_LOG" >&2
    if [ "$attempt" -ge 5 ]; then
      echo "!!! giving up on $exp after $attempt attempts" >&2
      return 1
    fi
    echo "    environment not ready or run invalid — retrying in 60s" >&2
    sleep 60
  done
  tail -1 "$OUT" | python3 -c '
import json, sys
d = json.loads(sys.stdin.read())
print("    rtf={:.2f}x  wall={:.0f}s  cpu={:.0f}%  inflight={:.1f}  stall={:.1f}s  "
      "drain={:.1f}s  warmup={:.0f}s  thermal={}".format(
        d["realtimeFactor"], d["wallSeconds"], d["cpuBusyFraction"] * 100,
        d["inFlightAverage"], d["windowStallSeconds"], d["drainSeconds"],
        d["warmupSeconds"], d["thermalEnd"]))' >&2
  sleep "${COOLDOWN:-15}"
}

case "$STAGE" in
  e1)
    for W in 1 2 4 8 12 16; do
      if [ "$W" -ge 8 ]; then COOLDOWN=75; else COOLDOWN=20; fi
      run E1 --workers "$W"
    done
    ;;
  confirm)
    COOLDOWN=60
    for W in "$@"; do
      run E1-confirm --workers "$W" --repeat 2
    done
    ;;
  e2)
    W="${1:?worker count required}"
    COOLDOWN=30
    run E2-seq --workers "$W" --mode chapters-seq
    run E2-global --workers "$W" --mode chapters-global
    ;;
  e3)
    W="${1:?worker count required}"
    COOLDOWN=30
    run E3-window4 --workers "$W" --window-multiplier 4
    ;;
  e4)
    W="${1:?worker count required}"
    COOLDOWN=30
    # Engine receives each chunk as ONE utterance (--no-internal-split);
    # deadline auto-scales with the largest chunk. --chunk-chars 1 packs
    # exactly one paragraph per chunk (the packer flushes when the budget is
    # exceeded and never splits a paragraph).
    run E4-sent3 --workers "$W" --chunk-sentences 3 --no-internal-split
    run E4-paragraph --workers "$W" --chunk-chars 1 --no-internal-split
    run E4-multi2400 --workers "$W" --chunk-chars 2400 --no-internal-split
    ;;
  samples)
    PASSAGE="${1:?passage text file required}"
    OUTDIR="${2:?output directory required}"
    mkdir -p "$OUTDIR"
    gen() {
      echo ">>> sample: $1" >&2
      shift
      "$BIN" audiobook bench --epub "$EPUB" --workers 1 --ignore-env \
        --sample-text "$PASSAGE" "$@" >&2
    }
    gen s1 --sample-out "$OUTDIR/sample-1-per-sentence.wav"
    gen s3 --sample-out "$OUTDIR/sample-2-three-sentences.wav" \
      --chunk-sentences 3 --no-internal-split
    gen para --sample-out "$OUTDIR/sample-3-paragraph.wav" \
      --chunk-chars 1 --no-internal-split
    gen multi --sample-out "$OUTDIR/sample-4-multiparagraph.wav" \
      --chunk-chars 2400 --no-internal-split
    ;;
  *)
    echo "unknown stage: $STAGE" >&2
    exit 64
    ;;
esac

echo "stage $STAGE complete → $OUT" >&2
