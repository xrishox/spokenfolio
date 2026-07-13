# ReadAloud generation

A ReadAloud is an EPUB 3 publication with Media Overlay (SMIL) timing and
embedded 48 kHz mono Opus audio. The ordinary audiobook remains AAC in M4B;
Opus is used only inside the ReadAloud.

The current backend pins stalign 0.1.52. Its executable is downloaded only by
an explicit Tools action, then checked by SHA-256, Apple signing team, and
version. ffmpeg and ffprobe remain system dependencies. Supported Opus rates
are 16, 32, 64, and 96 kbps; 32 kbps is the default used by Storyteller.
Set `FFMPEG_PATH` to choose a nonstandard ffmpeg; ffprobe is resolved beside it
or from the normal managed/Homebrew/PATH search.

The backend runs separate processing, transcription, markup, and alignment
commands in a controlled HOME/TMPDIR. A fingerprinted manifest reuses valid
processed audio and transcriptions. Synthetic chapter announcements are
disabled because words absent from the EPUB cannot align.
CLI resume across separate invocations requires the same explicit `--work-dir`;
desktop jobs keep a stable managed work directory automatically. The default
transcription language follows the publication language when supported and
otherwise requires an explicit override.

Success requires a readable EPUB ZIP, unique safe entry paths, SMIL audio
references with clip boundaries, a matching embedded-audio count, and complete
ffprobe decoding as mono 48 kHz Opus. Publication is atomic; a partial EPUB is
never placed at the requested destination.

```bash
spokenfolio readaloud create book.epub --audiobook book.m4b \
  --output book-readaloud.epub --bitrate 32
spokenfolio readaloud verify book-readaloud.epub
```
