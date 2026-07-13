# EPUB to M4B audiobooks

Audiobook creation runs locally through the CLI or the desktop app's **Create**
section. It does not use HTTP and has its own Siri worker pool.

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

The extractor retains headings, paragraphs, lists, tables, block quotes, and
ordinary hyperlink text. It removes markup, images, figures, scripts, page
anchors, navigation furniture, noteref markers, and footnote/endnote apparatus.
Only semantic/structural evidence removes content: URL-looking visible prose and
ordinary parentheses or brackets are preserved. When a removed inline noteref
was the sole content of a wrapper, that empty wrapper and adjacent punctuation
spacing are repaired locally.

EPUB 3 semantics and ARIA document roles are authoritative. EPUB 2 heuristics
require multiple signals, and note-only spine files are excluded even when
marked linear. Cover, title, copyright, printed TOC, index, notes,
about-the-author, also-by, excerpt, and clearly titled publisher-promotion
sections are excluded by default.
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
and 1.25 GiB total uncompressed content. These limits are checked from the
central directory before entry allocation.

## Synthesis and resume

Ordinary paragraphs are sent as one utterance for continuous prosody. Every
request is capped at 4,000 characters; pathological sentences split at clause,
whitespace, then Unicode boundaries without an inserted pause. Deadlines scale
from 60 to 300 seconds using actual bounded unit length.

The automatic audiobook pool is `min(8, performance cores)`, configurable from
1–16. Measurements on an M4 Max saturated near eight workers at roughly 16×
real time; other Macs, voices, and books vary. A bounded 2×worker window may
finish out of order but writes PCM strictly in source order.

Each job has an exclusive lock and a key covering source contents and importer
version, stable section IDs, backend/model/voice revisions, bitrate,
section/title/pause settings, narration policy, and M4B format version.
Completed chapter artifacts authenticate packet data, timing, AAC
configuration, and settings before reuse. A simultaneous identical job is
rejected.

Default work root:

```text
~/Library/Application Support/com.xrishox.spokenfolio/audiobook-jobs/
```

Ctrl-C or an app pause/cancel interrupts the child. Completed chapters remain;
the in-progress chapter is discarded. An identical command resumes. The provider/publication
manifest migration intentionally ignores older unfinished work. Successful work is removed
unless `--keep-work` is supplied. A format or policy upgrade may intentionally
invalidate old incomplete work; finished M4B files are unaffected.

## Create options

```text
--voice <canonical-id-or-alias>
--bitrate 32|64|128|256
--workers <1-16>
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
--max-chapters <n>
--quiet
--progress human|ndjson
```

Without `--overwrite`, the final atomic commit also refuses to replace a file
that appeared during synthesis. `--force` discards resume work only after the
job lock is acquired.

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

## Studio behavior

Studio accepts any number of EPUBs through multi-select or drag and drop. It
imports at most two concurrently, applies shared narration/ReadAloud/delivery
defaults, and permits per-book section, voice, and output overrides. Queued
books run one at a time so two heavyweight production children never compete.
One failed book does not stop the rest of the queue. After relaunch, unfinished
work remains suspended until **Resume Queue** is explicit.

The default managed location is `~/Books/Processed`; change it under
**Settings**, or override the whole directory for one book. Existing cataloged
books never move automatically. Each edition has one durable catalog record,
keyed first by the source EPUB SHA-256, and these flat product names:

```text
<Title> - <Author> (E).epub
<Title> - <Author> (A).m4b
<Title> - <Author> (R).epub
```

The author is omitted when absent. The original selection is untouched; `(E)`
is a verified copy. A true naming collision receives a short source-hash suffix
instead of overwriting another edition. The Library shows available E/A/R
products and can add an audiobook, ReadAloud, or Storyteller delivery later.

The app writes immutable durable requests and launches `jobs run <uuid>`.
Atomic job state is authoritative and the app polls its revisions. Closing the
window does not stop the active child. Pause and cancel persist distinct intent
before sending SIGINT through the resume-safe path. The
audiobook and HTTP pools isolate workers, queues, and crash circuits, but still
share hardware resources.
