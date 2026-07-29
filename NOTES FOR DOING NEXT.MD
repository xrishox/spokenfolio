# Notes for doing next

## Current task

Implement exact ReadAloud sentence timing without ASR. New durable ReadAloud
jobs synthesize every natural sentence as its own utterance, retain its exact
TTS span in the digest-bound timeline, and use that timeline for alignment.
The desktop and WebUI show this as a fixed production contract rather than an
ASR choice. Separate audit tools may still use ASR as independent evidence.

Siri Expressive production must remain capped at **one worker in both modes**.
Apple's FM service is effectively serialized: prior clean measurements showed
one worker completing at 4.30x realtime while eight workers timed out after
60 seconds. Sentence-sized requests do not create independent synthesizers.
The developer benchmark remains unrestricted.

Implementation result:

1. Added/tested a narration granularity passed into `AudiobookSynthesizer`.
   Sentence mode must preserve source order, apply no pause between sentence
   pieces, and apply the normal paragraph pause only after the last sentence.
   Paragraph mode keeps the existing failure-only sentence fallback.
2. Schema-6 ReadAloud jobs pass sentence granularity during production and
   temporary resynthesis. M4B-only production stays paragraph-based.
3. Existing M4Bs without sentence-policy provenance are conservatively
   resynthesized instead of being aligned with guessed timing.
4. Desktop and WebUI production both show exact sentence timing with no ASR;
   compatibility payloads are forced to synthesis timing.
5. Bumped the synthesis policy version so resumable paragraph artifacts cannot
   mix with sentence-mode artifacts.
6. Kept the model-specific `maximumAudiobookWorkers == 1` enforcement for
   Expressive and test that selecting sentence timing cannot bypass it.
7. Production completion uses retained digest-bound timing evidence and does
   not run a fresh-ASR pass. Explicit quality audits remain separate.

## Why this is needed

The failed Clash of Kings ReadAloud used Siri Expressive's coarse paragraph
timeline. Stalign assigned that same paragraph span to every source sentence,
then collapsed later sentence clips to roughly 1 ms at the paragraph end.
Only about 36.72% of eligible clips overlapped retained exact timing. The
artifact correctly failed quality validation; it must not be treated as a
successful ReadAloud.

The old Siri backend worked without ASR because it emitted word/phrase timing
callbacks. Expressive/FM currently emits only a coarse utterance span.

## Existing uncommitted work to preserve

There are intentional changes in `ReadAloudKit`, its tests, and
`docs/READALOUD.md` which:

- repair exactly matched short narrated documents that stalign omitted;
- make coarse timing evidence and overlap coverage honest;
- avoid an expensive false-positive SMIL-reference scan;
- keep failures fail-closed rather than accepting bad timings.

Do not discard or overwrite these changes. Focused tests pass, but the full
suite must be rerun after the timing-strategy implementation.

## Benchmark requested before implementation continues

Use the same first three chapters of the managed Moby-Dick EPUB and sentence
granularity for three isolated developer runs with 1, 4, and 8 Expressive
workers. Record wall time, synthesized audio duration, realtime factor,
per-unit latency distribution, failure/retry/timeout counts, and output
decode validation. Do not stop or restart the installed app, and do not alter
the production worker cap based on a developer-only override.

### Benchmark result (2026-07-29)

Completed with `en-US-F`, pace 3, expressivity 3, and the first three actual
story chapters: I: Loomings, II: The Carpetbag, and III: The Spouter-Inn.
The fixed workload contained 428 production-split natural sentences, 51,545
spoken characters, and a 658-character maximum unit.

| Workers | Wall | Decoded audio | Realtime | p50 | p95 | Max |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 1,578.09s | 4,396.80s | 2.79x | 6.91s | 11.94s | 17.17s |
| 4 | 1,546.44s | 4,385.36s | 2.84x | 28.12s | 39.32s | 46.27s |
| 8 | 1,554.82s | 4,386.48s | 2.82x | 59.20s | 70.70s | 76.10s |

All runs completed all 428 units, normalized every response to typed PCM, and
produced a nonzero whole-run checksum. No error or worker replacement was
observed, and macOS reported no thermal warning. The adaptive deadline was
83 seconds because of the 658-character maximum sentence, so the eight-worker
76.10-second tail survived but left little safety margin.

Four workers improved measured realtime throughput by only about 2% over one;
eight improved it by about 1% and was slightly slower than four. Those
differences are too small to distinguish from single-run/environmental
variance. Meanwhile p50 latency scaled from 6.91 seconds to 28.12 and 59.20
seconds. Sentence granularity therefore improves survivability compared with
the earlier long-paragraph overload, but does not unlock meaningful FM
parallel throughput. Keep the production Expressive maximum at one worker.

The installed app remained running throughout. The benchmark harness gained
a developer-only `--sentence-units` option and p50/maximum latency reporting;
it still deliberately bypasses the production worker capability.

### One-worker sentence versus paragraph result (2026-07-29)

Compared the same exact Moby-Dick chapters I–III on the previously unused
`en-US-G` Expressive voice, pace 3, expressivity 3, and one worker:

| Mode | Requests | Wall | Decoded audio | Realtime | p50 | p95 | Max | Fallback |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Paragraph | 109 | 1,129.97s | 3,089.44s | 2.73x | 12.45s | 54.53s | 218.34s | 3 paragraphs / 45 pieces |
| Sentence | 428 | 944.44s | 3,060.24s | 3.24x | 4.14s | 10.00s | 15.46s | none |

Sentence mode completed 185.53 seconds (3m05.53s), or 16.4%, sooner and
delivered an 18.7% higher realtime factor. It also avoided the three
paragraph token-loop refusals and their cumulative fallback latency.
Utterance-boundary prosody made sentence audio 29.20 seconds (0.95%) shorter,
so wall time is the best end-to-end user comparison while realtime factor
normalizes the generated-duration difference.

Interpret this as a directional single-run result, not a stable performance
guarantee. The paragraph fallbacks synthesized 45 exact sentence pieces before
the sentence run, so Apple could have served up to 10.5% of sentence requests
from cache. Both runs ended in thermal state `fair`; sentence mode was
explicitly allowed to cool to `nominal` before it began, while the paragraph
start state was not captured by `ProcessInfo`. A strict performance-policy
decision would need alternating repetitions on another fresh
voice/control combination. The reliability result is unambiguous: paragraph
mode needed its failure-only fallback, while all 428 sentence units succeeded.

### Clash of Kings sentence-path live test (2026-07-29)

Added the minimal tested synthesis seam needed for a real validation run:

- `NarrationUnitGranularity` supports paragraph or sentence planning.
- Sentence mode emits each natural bounded sentence as one unit, adds no
  silence between units in the same paragraph, and retains the configured
  paragraph pause only after the last sentence.
- The synthesis policy is now version 6 so paragraph artifacts cannot be
  reused by sentence mode.
- `audiobook create --sentence-units` exposes this as a developer/testing aid.
  Schema-6 production derives the same mode automatically for ReadAloud jobs,
  and both Studio surfaces present the no-ASR contract.

The new unit test and all 15 `SynthesizerTests` pass. A real test used the
53,841-character Prologue of A Clash of Kings with the failed job's exact
Expressive selection (`en-US-F`, pace/expressivity 3, one worker):

- Synthesis completed without a rejected sentence in 19m21s.
- The verified M4B is 53m08s and independently decodes 153,042,880 mono
  48-kHz PCM frames.
- Its digest-bound timeline contains 781 exact `.unit` sentence spans, 100%
  timeline coverage, no nonpositive spans, no overlap, and monotonic order.
- Stalign aligned all 781 of 781 source sentences in the Prologue document.
- The resulting partial ReadAloud passes EPUBCheck 5.3.0 as EPUB 3.3, Media
  Overlay verification, and complete decode of its one embedded Opus track.
- Prologue timing evidence improved versus the failed paragraph job:
  clip-weighted similarity 0.762 versus 0.583, low-clip fraction 10.2% versus
  45.9%, longest low-clip run 2 versus 15, fresh-ASR similarity 0.921 versus
  0.725, and zero severe ASR samples versus four.

The full-source quality verdict is intentionally `likelyBroken` because this
bounded test narrated only the Prologue while retaining the complete 101-spine
book. Its only findings are `missingPrimaryNarration` for 50 later documents;
there is no finding against the narrated Prologue. Therefore the original
collapsed-timing failure is fixed on the substantial live chapter, but a
whole-book pass has not yet been proven and would require full resynthesis.
