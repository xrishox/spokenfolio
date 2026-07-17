# Design and integration history

## Why this exists

When this prototype was created, the production verifier answered an important
but narrower question: was the publication a readable EPUB with SMIL references
and decodable embedded audio? The prototype explored content-level checks needed
to discover cases such as:

- the EPUB metadata names the expected title but its body contains another book;
- audio and text use different translations;
- the audiobook is abridged or from an incompatible edition;
- the correct audio is embedded but SMIL timestamps point at another location;
- alignment is good while notes, an index, or a bundled preview remain silent;
- a generation run produced no usable overlay at all.

These cases require independent evidence. No single score is sufficient.

## Media Overlay model

For each spine content document, an EPUB Media Overlay is connected through the
package manifest's `media-overlay` relationship. The target is a SMIL document.
Each relevant SMIL `par` pairs:

- a `text` source resolving to an XHTML member and fragment ID; and
- an `audio` source resolving to embedded media with `clipBegin` and `clipEnd`.

The analyzer checks archive safety, container and package resolution, manifest
and spine membership, text fragments, audio members, clocks, monotonicity,
duration metadata, orphan audio, and clip bounds. It also counts how many
sentence-marked spine fragments are actually referenced.

Storyteller currently emits Opus carried in MP4 and labels it `audio/mp4`.
Storyteller can consume that representation, but Opus-in-MP4 is not guaranteed
as an EPUB 3.3 core media type. Treat this as a cross-reader portability warning,
not evidence of incorrect alignment.

## Evidence layers

### 1. Structural integrity

Broken links, missing SMIL, missing embedded audio, invalid clocks, unsafe ZIP
paths, and inconsistent durations are direct publication defects. These checks
do not inspect what is spoken.

### 2. Exact retained provenance

Embedded audio is matched to Storyteller's retained transcoded sidecar using
basename, byte length, and CRC-32. Clip timing is compared to the word timeline
only when that provenance matches. This prevents a transcript from one file
being used to validate another file accidentally.

### 3. Clip-level text similarity

For each sufficiently long referenced sentence, timeline words within the SMIL
interval are normalized and compared with the XHTML fragment. The report keeps
weighted similarity, low-score fractions, quantiles, consecutive low runs, and
short evidence excerpts. A long run is generally more meaningful than one bad
heading.

### 4. Whole-book content identity

Unique normalized five-word sequences are compared across the source EPUB and
all retained transcripts. Direction matters:

- near-zero coverage in both directions suggests a wrong work or translation;
- high transcript coverage but low EPUB coverage suggests the audio is an
  abridgment or covers a shorter/different edition;
- high coverage in both directions suggests the same underlying work, so a low
  clip score is more likely a timestamp problem.

The thresholds are triage heuristics. Credits, repeated boilerplate, ASR errors,
poetry, unusual typography, and short books can distort them.

### 5. Omission context

Unreferenced sentence-marked XHTML is grouped by document. Filename, headings,
and excerpts provide a conservative front/back-matter hint. Notes and indexes
should not turn an otherwise healthy narration into a false failure, while a
missing main chapter should.

### 6. Fresh ASR

Retained transcripts can be stale or generated against the wrong media. The
optional stage extracts audio from the audited EPUB itself and transcribes a
45-second window. Worst-region samples confirm local defects. Evenly distributed
samples support a whole-book conclusion. These two sampling modes must not be
interpreted as equivalent.

### 7. Human adjudication

Opening credits, visible EPUB prose, named translator, edition metadata, and
omitted-document excerpts remain decisive for some cases. `adjudicate.py`
provides conservative defaults and accepts reviewed overrides as JSON. It does
not encode conclusions about a particular personal library.

## Safety and boundedness

This prototype is offline and assumes a trusted local corpus. Production reuse
therefore could not copy these scripts directly. The integrated implementation
uses `DocumentIOKit`/`EPUBKit` bounded parsing and explicit limits for archives,
XML, transcripts, findings, excerpts, fresh-ASR samples, and external processes.

The source Storyteller tree must stay read only. Durable output belongs in a
caller-selected work directory and should use atomic commits. Never log entire
book text, transcripts, credentials, PCM, or generated audio.

## Production disposition

The useful design was subsequently integrated behind typed boundaries:

- `DocumentIOKit` and `EPUBKit` provide bounded archive, XML, and publication
  access; `ReadAloudKit` owns overlay inspection and quality evidence.
- Storyteller downloads and retained-report adaptation stay in the
  `SpokenFolioApp` composition layer rather than leaking into core metrics.
- Independent ASR remains an explicit quality-audit stage using the pinned
  stalign boundary; ordinary structural verification does not invoke it.
- CLI/report formatting remains in the executable composition layer, while
  SQLite persistence uses neutral `LibraryKit` records.

These Python scripts remain an isolated offline diagnostic and design record.
Their schemas and thresholds are not production contracts.
