# ReadAloud generation

A ReadAloud is an EPUB 3 publication with Media Overlay (SMIL) timing and
embedded 48 kHz mono or stereo Opus audio. The ordinary audiobook remains AAC in M4B;
Opus is used only inside the ReadAloud.

The current backend pins stalign 0.1.52. Its executable is downloaded only by
an explicit Tools action over bounded HTTPS, then checked by SHA-256, Apple
signing team, and version before installation. ffmpeg and ffprobe remain system dependencies. Supported Opus rates
are 16, 32, 64, and 96 kbps; 32 kbps is the default used by Storyteller.
Set `FFMPEG_PATH` to choose a nonstandard ffmpeg; ffprobe is resolved beside it
or from the normal managed/Homebrew/PATH search.

The backend stages immutable copies of both inputs, then runs separate processing,
transcription, markup, and alignment stages. A stage-identity manifest reuses valid
processed audio and completed per-track transcriptions only when their file
digests and ASR provenance still match. Synthetic chapter announcements are
disabled because words absent from the EPUB cannot align.
Alignment input is one paired directory of same-stem audio and transcript files:
stalign pairs the two positionally over alphabetically enumerated per-extension
listings (Node readdir is sorted), so SpokenFolio validates stem-set equality —
raw on-disk enumeration order is deliberately irrelevant.
CLI resume across separate invocations requires the same explicit `--work-dir`;
desktop jobs keep a stable managed work directory automatically. Production
carries the publication language when present; the CLI defaults to `en-US` and
accepts an explicit `--language` override.

## Transcription

Apple Speech is the default. It verifies locale support, installs the system
speech asset when needed, transcribes locally, and emits the same validated
stalign JSON boundary without modifying the pinned stalign binary. It does not
change or use Siri voice assets. Recognizer customization was evaluated and
deliberately not adopted: contextual-string hints are a no-op for the
long-form module (byte-identical recognition on a 99-track book), and the
dictation module with a book-trained custom language model doubled raw
proper-noun hits but did not change stalign's sentence alignment at all
while introducing homophone and formatting regressions on prose.

The CLI and Production UI can instead select Whisper from the model set exposed
by `ReadAloudWhisperModel` for the pinned stalign release. Whisper defaults to
`large-v3-turbo`; an English-only
`.en` model is rejected for non-English publications. Whisper downloads and
cache access are serialized in the managed stalign HOME.

Parakeet v3 is deliberately not exposed. The evaluated MLX and FluidAudio
runtimes were very fast but silently omitted multi-second passages in long-form
audio, which is unsafe for alignment until a reliable coverage guard exists.

Success uses the shared bounded archive/XML reader rather than materializing
untrusted ZIP paths. It requires EPUB container files, unique canonical paths,
ordered positive SMIL clip times, text fragments that exist in their target
XHTML, a one-to-one embedded-audio set, bounded extraction, and complete ffprobe
decoding as 48 kHz Opus with one or two channels. Clip ranges may not exceed the decoded audio
duration. Apple output uses a narrowly bounded EPUB-aware repair only when a
short heading has a unique label/number match; prose and ambiguous matches are
never rewritten. Production also compares the retained word timelines with the exact
SMIL text intervals before publication; confirmed fundamental defects stop the
atomic commit. Every locally created ReadAloud runs this quality gate; Production
stores its report with the Library product.

## Quality audits

**ReadAloud Quality** audits arbitrary local ReadAloud EPUBs and ReadAlouds on
an authorized Storyteller server. Results and progress are retained in the
Library SQLite database. A Storyteller audit downloads the ReadAloud and, when
available, its EPUB source; it never downloads the remote audiobook.

Local files, Storyteller books, and selected Library rows can be queued in
batches. The SQLite-backed FIFO runs one audit at a time, rejects duplicate
queued/running targets, and retains waiting work across relaunch. A graceful
quit returns the active item to the queue; crash recovery marks only the
interrupted active run as failed. Library selection can queue local, remote, or
both ReadAloud copies explicitly. The queue drawer supports native
multi-selection, removal of selected waiting runs, clearing all waiting work,
and cancellation of the active audit. User cancellation is terminal; graceful
application shutdown instead returns the active run to the FIFO. Starting
ReadAloud processing from Storyteller records a durable intent; SpokenFolio
polls processing state and automatically enters the finished remote asset into
the same quality FIFO.

The Quality workspace has one inventory row per concrete local, Storyteller, or
standalone ReadAloud. It includes artifacts that have not been checked and uses
Library titles rather than internal IDs. Fixed scopes show all, attention,
unchecked, and likely-correct artifacts; native table headers sort the visible
inventory. The table supports Command-click, Shift-click, and an explicit
Select All Results action; Check Selected queues the whole selection. Selecting
one artifact exposes its latest applicable semantic result, metrics, excerpts,
suspected causes, and complete bounded finding set. A newer
failed attempt does not hide an earlier result that still matches the exact
artifact, source, analyzer, and policy identities. All attempts remain in the
artifact's history. The active title truncates inside a fixed status region;
Cancel Current and Cancel All remain fixed at its trailing edge. Cancel All
stops the active audit and clears every waiting audit in one action. The full
FIFO appears only in an expandable drawer so it does not displace the outcome.

The auditor keeps independent evidence dimensions:

- bounded EPUB/OPF/SMIL/XHTML structure and decoded media duration;
- primary-prose overlay coverage, excluding classified notes, indexes,
  previews, and similar apparatus. Aligners legitimately skip sentences that
  inline markup interrupts (noterefs, italicized phrases, drop caps), so
  note-heavy books show large scattered token omission in healthy artifacts.
  Coverage is therefore judged broken only by contiguous document-order
  omission — a fully unnarrated primary section or an unbroken uncovered run
  of at least 800 tokens — while low scattered coverage below 95% surfaces as
  a review finding instead;
- bidirectional five-word overlap for work/edition compatibility;
- exact SMIL-interval text comparison against provenance-bound word timelines;
- evenly distributed fresh-ASR samples, or full transcription in Thorough mode.

Verdicts are `likelyCorrect`, `needsReview`, `likelyBroken`, `broken`, or
`inconclusive`. Findings distinguish missing media or prose, likely wrong
work/translation/language, possible abridged or incompatible edition, broadly
displaced timing, and localized timing defects. These are conservative
diagnoses: very low overlap can narrow the cause to that set, but cannot prove
which input is wrong or reliably distinguish a translation from a different
work without external edition metadata. Storyteller-retained transcripts remain
advisory unless their provenance can be bound to the embedded audio; the normal
remote audit therefore uses independent ASR.

Independent audit ASR is separate from the creation engine selection and
currently uses stalign's multilingual Whisper `small` model. Standard mode uses
12 evenly distributed 45-second samples, increased to 24 for books longer than
12 hours or with more than 24 audio sections. Thorough mode transcribes every
embedded audio track sequentially with that same audit model. Reports store
bounded metrics and short excerpts, never complete book text, transcripts, PCM,
audio, or credentials.

```bash
spokenfolio readaloud create book.epub --audiobook book.m4b \
  --output book-readaloud.epub --bitrate 32
spokenfolio readaloud create book.epub --audiobook book.m4b \
  --output book-whisper.epub --asr whisper --whisper-model large-v3-turbo
spokenfolio readaloud create book.epub --audiobook book.m4b \
  --output book-apple.epub --asr apple
spokenfolio readaloud verify book-readaloud.epub
spokenfolio readaloud audit book-readaloud.epub --source-epub book.epub
spokenfolio readaloud audit book-readaloud.epub --thorough --json
```
