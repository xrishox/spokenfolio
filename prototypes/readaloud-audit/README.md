# ReadAloud alignment audit prototype

This directory preserves the corpus-audit logic developed while investigating
Storyteller ReadAloud EPUBs. It is intentionally isolated from the Swift
package: it is not listed in `Package.swift`, imported by an application target,
or called by a production command.

Its goal is to answer several different questions that a structurally valid
EPUB alone cannot answer:

1. Does the EPUB contain a resolvable EPUB Media Overlay graph?
2. Do the SMIL clips point at the intended XHTML fragments and embedded audio?
3. Does retained word-timeline evidence agree with the text at those exact
   timestamps?
4. Are the audiobook and EPUB actually the same work, translation, and edition?
5. Is low coverage caused by missing main prose, or merely un-narrated notes,
   indexes, previews, and other extras?

The scripts use a read-only Storyteller asset tree and a separate disposable
workspace. Generated reports can contain short source-text and transcript
excerpts, so keep the output outside the repository and do not commit it.

## Expected asset layout

The prototype expects Storyteller's current work layout:

```text
assets/
  Book folder/
    aligned/*.epub
    text/*.epub
    audio/*
    transcoded audio/*.mp4
    transcriptions/*.json
    .storyteller/report.json
```

`aligned/` is required. Other directories enrich the result: `text/` and
`transcriptions/` enable whole-book identity checks, while exact retained
`transcoded audio/` and word timelines enable clip-level scoring.

## Requirements

- Python 3.11 or newer; the core scripts use only the standard library.
- `ffprobe` for audio duration, codec, and provenance checks.
- Optional fresh ASR: `ffmpeg`, `whisper-cli` from whisper.cpp, and a local
  Whisper model. The scripts never download a model or tool.

## Typical workflow

Choose paths outside the repository:

```bash
ASSETS="/path/to/Storyteller/Config/assets"
WORK="/tmp/readaloud-audit"
```

First copy and checksum the aligned artifacts. This preserves book-folder
names, including books with identical visible titles but different folder
suffixes:

```bash
python3 prototypes/readaloud-audit/copy_aligned.py \
  --assets-root "$ASSETS" \
  --destination "$WORK/readalouds"
```

Run the resumable structural, coverage, and retained-timeline audit:

```bash
python3 prototypes/readaloud-audit/audit_readalouds.py \
  --assets-root "$ASSETS" \
  --readaloud-root "$WORK/readalouds" \
  --output "$WORK/audit"
```

Run whole-book identity comparison. Five-word phrase overlap is especially
useful for identifying a wrong work or a different translation:

```bash
python3 prototypes/readaloud-audit/check_content_identity.py \
  --assets-root "$ASSETS" \
  --output "$WORK/audit/content_identity.json"
```

Explain low overlay coverage by locating uncovered marked documents:

```bash
python3 prototypes/readaloud-audit/analyze_omissions.py \
  --readaloud-root "$WORK/readalouds" \
  --audit-output "$WORK/audit"
```

Fresh ASR is optional and should be reserved for ambiguous cases. By default it
uses the worst regions found by the retained-timeline audit:

```bash
python3 prototypes/readaloud-audit/fresh_asr.py \
  --readaloud-root "$WORK/readalouds" \
  --audit-output "$WORK/audit" \
  --whisper-cli /path/to/whisper-cli \
  --model /path/to/ggml-large-v3-turbo.bin \
  --book "Exact Storyteller book folder"
```

To test whether a timestamp problem spans a whole book, sample evenly instead
of selecting known-bad regions:

```bash
python3 prototypes/readaloud-audit/fresh_asr.py \
  --readaloud-root "$WORK/readalouds" \
  --audit-output "$WORK/audit" \
  --whisper-cli /path/to/whisper-cli \
  --model /path/to/model.bin \
  --book "Exact Storyteller book folder" \
  --samples 12 \
  --distributed
```

Finally combine the stages into review-oriented output:

```bash
python3 prototypes/readaloud-audit/adjudicate.py \
  --audit-output "$WORK/audit" \
  --content-identity "$WORK/audit/content_identity.json" \
  --omissions "$WORK/audit/omission_analysis.json" \
  --fresh-asr "$WORK/audit/fresh_asr_summary.json"
```

`adjudicate.py` accepts `--decisions decisions.json` for reviewed overrides.
See `decisions.example.json`. Human conclusions live in data rather than in
book-specific branches in reusable code.

Every expensive stage supports book selection, and the main analyzer stores
per-book state under `<audit-output>/state`. Use `--force` only when the input
or analyzer logic changed.

## Important interpretation rule

A valid OPF/SMIL graph proves only that references and timestamps are shaped
correctly. It does not prove that the embedded sound is reading the referenced
sentence. A wrong audiobook, another translation, or broadly displaced clips
can pass a purely structural verifier. See [DESIGN.md](DESIGN.md) for the
evidence model and integration boundary.

## Prototype status

The output schema and thresholds are deliberately not production contracts.
The useful evidence model has since been reimplemented behind bounded
`DocumentIOKit`, `EPUBKit`, `ReadAloudKit`, and `LibraryKit` interfaces. These
Python files remain isolated from `Package.swift` as an executable historical
reference and trusted-corpus diagnostic; production does not import or invoke
them.

Run the isolated helper tests with:

```bash
python3 -m unittest discover -s prototypes/readaloud-audit/tests
```
