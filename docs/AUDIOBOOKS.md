# EPUB to M4B audiobooks

Audiobook creation runs locally through the CLI or **Production → Create** in the desktop app. It does not use HTTP and has a dedicated session/pool for the selected backend. `audiobook voices` remains the legacy installed-Siri inventory command; desktop/WebUI selectors and `/v1/audio/voices/all` expose every available model.

```bash
spokenfolio audiobook voices
spokenfolio audiobook chapters book.epub
spokenfolio audiobook export-text book.epub
spokenfolio audiobook audit ~/Books --output ~/Books-Audit
spokenfolio audiobook create book.epub
spokenfolio audiobook verify "Book - Author.m4b"
```

The default output is `<Title> - <Author>.m4b` beside the EPUB, using mono
48 kHz AAC-LC at 256 kbps. Available bitrates are 32, 64, 128, and 256 kbps.
Cover art is embedded when present.

## Narration policy

See [Siri narration quality research](SIRI_NARRATION_QUALITY.md) for the evidence
catalog, private-engine probe contract, ranked candidate fixes, and strict
old/new corpus gates. That research does not change the production policy below.

The extractor retains headings, paragraphs, lists, tables, block quotes, and
ordinary hyperlink text. It removes markup, images, figures, scripts, page
anchors, navigation furniture, noteref markers, and footnote/endnote apparatus.
Only semantic/structural evidence removes content: URL-looking visible prose and
ordinary parentheses or brackets are preserved. When a removed inline noteref
was the sole content of a wrapper, that empty wrapper and adjacent punctuation
spacing are repaired locally.

Before planning begins, the managed import path requires EPUB 3 and official
EPUBCheck conformance. EPUB 3 inputs are not rewritten. EPUB 2 inputs are
converted by Calibre in bounded private scratch space with explicit EPUB 3
output, canonicalized to a stable digest, then independently parsed and
checked before their normalized bytes become the digest-bound source. This gate runs again on the exact source at
durable-job startup so synthesis never discovers a format problem after hours
of work.

EPUB 3 semantics and ARIA document roles are authoritative. EPUB 2 heuristics
require multiple signals, and note-only spine files are excluded even when
marked linear. Cover, title, copyright, printed TOC, index, notes,
about-the-author, also-by, excerpt, and clearly titled publisher-promotion
sections are excluded by default.
EPUB spine items marked `linear="no"` are auxiliary and excluded by default,
but an explicit section include can select them.
A TOC-anchored excerpt, also-by, or promotional document also owns the
unanchored spine documents that follow it until the next TOC-anchored
document; that owned range classifies as the same excluded role, because bonus
excerpts routinely anchor only a title page while the excerpt prose ships in
follow-on files with no TOC entry. An explicit section include can still
rescue a document inside the owned range.
Numbering apparatus is not narrated: bare numbers isolated in their own
inline elements are dropped when they are styled as apparatus (superscript,
or reduced size via inline or single-class stylesheet rules) and form a
dense, mostly ascending run of at least five in one document, and are not
glued to a preceding word. This removes scripture verse numbers and
superscripted endnote markers while structurally protecting prose numbers
(plain text can never match), lone inline chapter numbers (density), and
exponents (glued). An unstyled group joins only when a styled group in the
same document fired independently and merging preserves one ascending
sequence.
Citation tables are note apparatus: a table narrates cell-by-cell in
general, but when every data row's first cell is a bare 1–4-digit number,
at least 80% of them are wrapped in fragment-target anchors, and the
document's rows form a mostly ascending run of at least five, the tables
and an immediately preceding apparatus label ("Endnotes", "Notes", …) are
excluded. Data tables, bullet-list tables, and numbered how-to tables never
match because their first cells are not anchored numbers. An untitled spine
file dominated by index entries (at least 30 short lines ending in page
number runs, and at least half of all blocks) classifies as an index;
titled index variants ("Name Index", "Index of Subjects") are recognized
by vocabulary.
Presentational all-caps name occurrences fold to the book's own attested
mixed-case form, because the private engine letter-spells some
out-of-vocabulary caps names (probe-verified: "SER" → S-E-R, "ALAYAYA" →
letters) while their mixed-case twins always speak correctly. An
occurrence folds only when the book attests the twin mid-sentence at
least three times, the all-lowercase form never appears mid-sentence, and
the occurrence is a single-caps-token block (chapter-title shape) or a
block-initial caps run followed by non-caps content (roster shape), with
the whole run vetoed if any of its tokens has lowercase evidence. Every
fold targets text the engine already speaks correctly elsewhere in the
same book, so audio can only improve or stay identical; acronyms (no
mixed-case twin), caps common words, whole-block caps prose, epigraphs,
and "CHAPTER ONE" labels are structurally unreachable. Plain-text bracketed markers glued to sentence ends (`word.[12]`,
including chains and markers after closing quotes) are removed under the
same discipline: only 1–3-digit numbers, only glued directly after
sentence-final punctuation, and only in a dense, mostly ascending run of at
least five in one document — so IEEE-style `in [12]`, `[sic]`, standalone
brackets, math subscripts, and `[1945]` year glosses can never match. Any
change to this logic is verified by extracting the full test
corpus with old and new binaries and diffing every book.
Unclassified sections remain included so prose fails open.

`aria-hidden="true"` content is always silent. Inline `hidden`, `display:none`,
and `visibility:hidden` content is treated as an alternate representation: it
is ignored beside substantial visible prose, but may supply narration for a
media-only fixed-layout page. The importer reports either decision as a warning.

Inspect `chapters` and `export-text` before a long run. They do not synthesize;
`export-text` deliberately writes the exact planned prose. Override decisions
with indices, ranges, or displayed slugs:

```bash
spokenfolio audiobook create book.epub \
  --exclude-sections 3,acknowledgments \
  --include-sections about-author
```

For a library-wide fake-TTS exercise, `audiobook audit` recursively loads every
EPUB, applies the production section/chapter/sentence/request-unit pipeline,
exports the exact narration, and writes JSON plus Markdown reports. It hashes
each EPUB before and after to prove the audit was read-only. The output path
must not already exist:

```bash
spokenfolio audiobook audit ~/Books --output ~/Books-Audit
```

Review findings (for example a visible literal URL) are not automatic deletion
rules and do not fail the command. Import, planning, source-integrity, or request
bound failures do fail it.

TOC titles become chapter markers. Titles are announced unless the chapter
already begins with the same title; a bare leading chapter number can be
absorbed into the announcement.

Encrypted/DRM EPUBs, multidisk archives, and ZIP64 archives are unsupported.
Classic ZIP input is bounded to 10,000 entries, 64 MiB per uncompressed entry,
1.25 GiB total uncompressed content, and a 1.5 GiB archive file. These limits
are checked before entry allocation.

## Synthesis and resume

Ordinary paragraphs are sent as one utterance for continuous prosody. Every
request is capped at 4,000 characters; pathological sentences split at clause,
whitespace, then Unicode boundaries without an inserted pause. Deadlines scale
from 60 to 300 seconds using actual bounded unit length.

A unit whose text has no Unicode letter and no numeric character (a
scene-break "—", a fill-in rule "____") may be refused outright by the selected
engine. Such a refusal falls back to silence — the unit contributes only its
pause — instead of failing the book, because no speakable content exists to
lose. A refusal on any unit containing a letter or numeral still aborts the
run when it is a single sentence. When a speakable multi-sentence paragraph
is rejected, audiobook production retries its natural sentences (using the
same bounded sentence limiter), concatenates their PCM without internal
silence, rebases word timings, and inserts the normal paragraph pause only
after the complete paragraph. A bounded warning records only the chapter,
unit, and fallback-piece count; book text is never logged. If any fallback
piece is also rejected, the run fails normally. Speechless units the engine
accepts keep their real audio. The HTTP
speech route intentionally keeps returning the explicit structured error for
letterless input: an interactive caller can react; a book production run
cannot.

Production settings are remembered. Whatever the last queued book used —
TTS model and voice, pace and expressivity, bitrate, workers, title
announcements, pauses, ReadAloud options, and the Storyteller delivery
choices — is stored in `studio-settings.json` and becomes the starting point
for every later form on both the desktop app and the WebUI. It is a starting
point only: each value is re-validated on load, so an uninstalled voice, a
bitrate or worker count outside current limits, or a removed Storyteller
connection silently falls back to the configured default instead of being
offered again. A remembered worker count counts as user-set unless the
selected model's hard maximum is lower.

The installed-Siri automatic audiobook pool is
`max(2, min(8, performance cores))`, with a four-worker fallback if the
performance-core query is unavailable, and remains configurable from 1–8.
Siri Expressive production is fixed at one worker. In a clean uncached probe,
one FM worker completed at 4.30× real time with 16.87-second p95 request
latency, while eight workers overloaded Apple's effectively serialized FM
queue and timed out after 60 seconds. Configured, remembered, submitted, and
older durable Expressive requests above one are reduced to one with a warning.
The developer-only Golden Gate benchmark remains unrestricted so future OS and
hardware behavior can be measured. A bounded 2×worker window may finish out
of order but writes PCM strictly in source order.

Each job has an exclusive lock and a key covering source contents and importer version, stable section IDs, backend/model/voice revisions, pace and expressivity presets, bitrate, section/title/pause settings, narration policy, and M4B format version. Changing any selection or preset cannot reuse stale chapters. Installed Siri binds the running macOS/build and private framework version; Golden Gate additionally records the confirmed FM adapter and resource identity/revision. The cataloged M4B retains the exact requested selection and bounded actual runtime provenance emitted by the authoritative synthesis child.
Completed chapter artifacts authenticate packet data, timing, AAC
configuration, and settings before reuse. A simultaneous identical job is
rejected.

Default work root:

```text
~/Library/Application Support/com.xrishox.spokenfolio/audiobook-jobs/
```

Ctrl-C or an app pause/cancel interrupts the child. Stdout and stderr remain
drained until the child exits, and a closed parent pipe cannot crash the
child's final diagnostic. Persisted pause intent leaves the job resumable;
persisted cancel intent makes it terminal. Completed chapters remain;
the in-progress chapter is discarded. An identical command resumes. The provider/publication
manifest migration intentionally ignores older unfinished work. Successful work is removed
unless `--keep-work` is supplied. A format or policy upgrade may intentionally
invalidate old incomplete work; finished M4B files are unaffected.

## Create options

```text
--backend siri|siri-fm
--model siri-private|siri-expressive
--voice <canonical-id-or-alias>
--pace <1-5>
--expressivity <1-5>
--bitrate 32|64|128|256
--workers <1-8>
--output <path.m4b>
--include-sections <list>
--exclude-sections <list>
--paragraph-pause <0-10>
--chapter-pause <0-10>
--announce-titles | --no-announce-titles
--work-dir <directory>
--keep-work
--force
--overwrite
--replace-existing-sha256 <digest>
--max-chapters <n>
--quiet
--progress human|ndjson
```

The standalone CLI defaults to `siri/siri-private`; `audiobook.defaultVoice` remains a legacy-Siri default. Selecting `siri-fm/siri-expressive` requires an FM voice and defaults omitted pace/expressivity to neutral `3`. Legacy Siri rejects either preset.

Without `--overwrite`, the final atomic commit also refuses to replace a file
that appeared during synthesis. `--force` discards resume work only after the
job lock is acquired. `--replace-existing-sha256` is an internal guarded form
of overwrite used by Production reprocessing; it refuses the final swap if the
existing file changed during synthesis.

Configuration defaults live under the top-level `audiobook` key:

```json
{
  "defaultBitrateKbps": 256,
  "paragraphPauseSeconds": 0.6,
  "chapterPauseSeconds": 1.75,
  "announceTitles": true,
  "maxWorkers": 0,
  "defaultVoice": null,
  "workDirectory": null
}
```

## Output and verification

The project-owned MP4 writer emits:

- mono 48 kHz AAC-LC at the selected bitrate;
- Apple/QuickTime chapter track plus Nero `chpl` (limited to 255 entries while
  the Apple track retains all chapters);
- `stik=2`, `pgap=1`, gapless edit metadata, title/author/narrator/genre/date/
  description, and optional cover art;
- sample-derived chapter boundaries with an intentional 0.25-second head pad.

By default a digest-bound `<name>.synthesis-timeline.json` sidecar is written
next to the M4B: schema-2 per-sentence and engine word/segment narration
anchors plus each chapter's narrated source documents, bound to the M4B and
per-chapter artifact SHA-256 digests. Engine timing ranges and timestamps are
validated against the exact utterance and decoded PCM. Malformed timing fails;
when an engine supplies no callbacks, the exact whole-utterance span is
retained as one segment. Independently synthesized fallback pieces contribute
their exact concatenation boundaries. Neither case falls back to
character-proportional estimates. The combined sidecar records the presented
track timebase explicitly so AAC priming is applied correctly to first,
middle, and final chapters. It is
what lets `readaloud create` default to exact no-ASR alignment (see
docs/READALOUD.md); `--no-emit-timeline` disables it.

Durable jobs that create a ReadAloud synthesize every bounded natural sentence
as one utterance. No silence is added between sentences in a paragraph; the
configured paragraph pause follows only its final sentence. This gives
Expressive/FM, which has no word callbacks, an exact sentence span without
speech recognition. M4B-only jobs retain paragraph synthesis and its
failure-only sentence fallback. The synthesis policy and format identity keep
paragraph and sentence artifacts from being mixed during resume.

Chapter files, manifests, and output are synchronized and atomically committed.
A partial M4B never appears at the requested destination. At 256 kbps, output
is about 115 MB per audio hour; resumable artifacts use roughly the same space.

`audiobook verify` skips the large `mdat` while reading metadata, validates both
chapter systems and required markers, then decodes every audio frame in bounded
buffers. Use `--no-decode` for a fast structural report.

```bash
./scripts/audiobook-smoke.sh "path/to/book.epub"
```

The smoke test performs real synthesis, deep decode, container checks, and an
identical resume run. Common compatible players include Apple Books,
BookPlayer, Audiobookshelf, Plexamp, VLC, and FFmpeg-based software.

## Desktop Production behavior

Production accepts any number of EPUBs through multi-select or drag and drop. It
imports at most two concurrently, applies shared narration/ReadAloud/delivery
defaults, and permits per-book section, model-qualified voice, pace, expressivity, and output overrides. macOS 26 shows only the legacy model. Queued
books run one at a time so two heavyweight production children never compete.
One failed book does not stop the rest of the queue. After relaunch, unfinished
work remains suspended until **Resume Queue** is explicit.

The default managed location is `~/Books/SpokenFolio`; first launch asks for
it, and it can be changed later under **Settings** (which moves the whole
library — see [STUDIO.md](STUDIO.md)) or overridden per book. Each edition has
one durable catalog record, keyed first by the source EPUB SHA-256, and one
folder holding self-identifying product files:

```text
<Title> - <Author>/
├── <Title> - <Author>.epub
├── <Title> - <Author> - TTS Audiobook.m4b
└── <Title> - <Author> - TTS ReadAloud.epub
```

The author is omitted when absent; a duplicate title/author gets a short
` [hash]` suffix on the folder. The books tree contains only these product
files — synthesis-timeline records and all work state live in Application
Support. The original selection is untouched; the staged EPUB
is a verified copy. A true naming collision receives a short source-hash suffix
instead of overwriting another edition. The Library shows available E/A/R
products and can add an audiobook, ReadAloud, or Storyteller delivery later.
For an existing M4B, **Reprocess Audiobook** creates a new immutable job,
forces fresh synthesis, and replaces the file and SQLite product only if the
original digest is still current. Recreating the ReadAloud in the same job
replaces it too; otherwise its old alignment dependency remains and the Library
marks that package incoherent until the ReadAloud is regenerated.
Its persistent identity and completeness rules are documented in
[LIBRARY.md](LIBRARY.md).

The app writes immutable durable requests and launches `jobs run <uuid>`.
Atomic job state is authoritative and the app polls its revisions. Closing the
window does not stop the active child. Pause and cancel persist distinct intent
before sending SIGINT through the resume-safe path. The
audiobook and HTTP pools isolate workers, queues, and crash circuits, but still
share hardware resources.
