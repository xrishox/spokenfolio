# EPUB to M4B audiobooks

Audiobook creation runs locally through the CLI or **Create Audiobook…** in the
menu app. It does not use HTTP and has its own Siri worker pool.

```bash
siri-tts-server audiobook voices
siri-tts-server audiobook chapters book.epub
siri-tts-server audiobook export-text book.epub
siri-tts-server audiobook create book.epub
siri-tts-server audiobook verify "Book - Author.m4b"
```

The default output is `<Title> - <Author>.m4b` beside the EPUB, using mono
48 kHz AAC-LC at 256 kbps. Available bitrates are 32, 64, 128, and 256 kbps.
Cover art is embedded when present.

## Narration policy

The extractor retains headings, paragraphs, lists, tables, block quotes, and
ordinary hyperlink text. It removes markup, images, figures, scripts, page
anchors, navigation furniture, noteref markers, and footnote/endnote apparatus.

EPUB 3 semantics and ARIA document roles are authoritative. EPUB 2 heuristics
require multiple signals, and note-only spine files are excluded even when
marked linear. Cover, title, copyright, printed TOC, index, notes,
about-the-author, also-by, and excerpt sections are excluded by default.
Unclassified sections remain included so prose fails open.

Inspect `chapters` and `export-text` before a long run. They do not synthesize;
`export-text` deliberately writes the exact planned prose. Override decisions
with indices, ranges, or displayed slugs:

```bash
siri-tts-server audiobook create book.epub \
  --exclude-sections 3,acknowledgments \
  --include-sections about-author
```

TOC titles become chapter markers. Titles are announced unless the chapter
already begins with the same title; a bare leading chapter number can be
absorbed into the announcement.

Encrypted/DRM EPUBs, multidisk archives, and ZIP64 archives are unsupported.

## Synthesis and resume

Ordinary paragraphs are sent as one utterance for continuous prosody. Every
request is capped at 4,000 characters; pathological sentences split at clause,
whitespace, then Unicode boundaries without an inserted pause. Deadlines scale
from 60 to 300 seconds using actual bounded unit length.

The automatic audiobook pool is `min(8, performance cores)`, configurable from
1–16. Measurements on an M4 Max saturated near eight workers at roughly 16×
real time; other Macs, voices, and books vary. A bounded 2×worker window may
finish out of order but writes PCM strictly in source order.

Each job has an exclusive lock and a key covering book contents, voice/model
version, bitrate, section/title/pause settings, extraction policy, synthesis
policy, and format version. Completed chapter artifacts authenticate packet
data, timing, AAC configuration, and settings before reuse. A simultaneous
identical job is rejected.

Default work root:

```text
~/Library/Application Support/com.xrishox.macos-tts-server/audiobook-jobs/
```

Ctrl-C or GUI cancel uses SIGINT. Completed chapters remain; the in-progress
chapter is discarded. An identical command resumes. Successful work is removed
unless `--keep-work` is supplied. A format/policy upgrade may intentionally
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

## GUI behavior

The Create Audiobook window selects the EPUB, sections, voice, bitrate, and
output, then launches the same CLI path with NDJSON progress. Closing the window
hides it while the child continues. A disappeared GUI closes the progress pipe;
the child continues without progress output. Explicit cancellation and protocol
failure use the resume-safe SIGINT path. The audiobook and HTTP pools isolate
workers, queues, and crash circuits, but still share hardware resources.
