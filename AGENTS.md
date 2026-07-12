# Project instructions

## Product

This Apple-Silicon/macOS-15 project exposes installed Siri natural, neural, and
Gryphon voices through an OpenAI-compatible TTS API and creates local EPUB→M4B
audiobooks through a CLI and menu-bar GUI. It deliberately uses Apple's
undocumented `SiriTTSService.framework`, so private ABI and asset changes are
the primary compatibility risk.

Requirements are Swift 6.2, Xcode Command Line Tools, a downloaded compatible
Siri voice, and Full Disk Access when shared models require it. Never download,
patch, relocate, or delete Apple voice assets.

## Architecture invariants

The package has five reusable library targets and two executable targets:

- `TTSKit`: backend-neutral identities, sessions, typed PCM, normalization,
  sentence detection, and in-memory response encoding.
- `SiriTTSCore`: Siri discovery, private bridge, workers/pool, and IPC; depends
  on TTSKit and never imports Vapor.
- `PublicationKit`: format-neutral metadata, sections, navigation, and source locators.
- `EPUBKit`: bounded EPUB parsing and EPUB-specific extraction/classification.
- `AudiobookKit`: format-neutral planning, ordered synthesis, resume, and M4B output.
- `SiriTTSServer` executable target: composition, Vapor, menu app, audiobook CLI, and GUI.
- `SiriTTSBench` executable target: developer-only throughput experiments.

`siri-tts-server` is the product executable. `siri-tts-bench` is a separate
developer executable and is not bundled in the menu application.

Preserve these rules:

1. The gateway never loads the private synthesis engine. Only worker children do.
2. One worker owns one loaded voice and processes one request at a time.
3. Cancellation, timeout, malformed IPC, and unsafe failure recycle the worker.
4. Validate private classes, selectors, encodings, and mono 48 kHz PCM before readiness.
5. Return HTTP 200 only after complete synthesis and container finalization.
6. HTTP speech remains in memory. Audiobook output/work files are the deliberate durable exception.
7. HTTP output is mono 48 kHz: Opus 64 kbps constrained VBR, AAC-LC 64 kbps
   M4A, and explicit WAV/PCM diagnostics.
8. Successful audio has exact `Content-Length`, correct MIME type, and `no-store`.
9. HTTP remains bounded to four workers, twenty waiters, twelve outstanding
   requests per IP, validated deadlines, and bounded client tracking.
10. Canonical voice IDs are authoritative; ambiguous aliases fail.
11. Audiobook jobs use a separate 1–16-worker pool. Pools isolate queues and
    crashes but still contend for shared hardware.
12. Audiobook units are source ordered, at most 4,000 characters, and use
    bounded adaptive deadlines.
13. Resume reuse requires an exclusive job lease plus validated content,
    settings, model, extraction, synthesis-policy, and format identity.
14. Partial M4B output never appears at the destination; no-overwrite commits
    cannot clobber a file created during synthesis.
15. EPUB note semantics are authoritative, conservative heuristics require
    conjunctions, note-only files are excluded, and unclassified prose fails open.
16. Ordinary hyperlink text remains prose; markup, noterefs, and note apparatus do not.
17. The GUI runs `audiobook create --progress ndjson` as a child. Closed
    progress pipes do not kill the child; explicit cancellation is SIGINT.
18. `AGENTS.md` and `CLAUDE.md` stay byte-for-byte identical.

Executable modes:

- no arguments: menu app and HTTP gateway;
- `serve`: foreground gateway;
- `doctor`: diagnostics;
- `audiobook <create|chapters|export-text|voices|verify>`;
- `--siri-worker <voice-id>`: internal only.

## Public contracts

Primary routes:

- `POST /v1/audio/speech`
- `GET /v1/audio/voices`
- `GET /v1/audio/voices/all`
- `GET /v1/models`
- `GET /health/live`
- `GET /health/ready`

Speech accepts `tts-1` or `tts-1-hd`, at most 4,096 characters, speed
`1.0`, and `opus`, `aac`, `wav`, or `pcm`. Errors use the OpenAI-style
`{"error": ...}` envelope. Degraded startup keeps liveness available while
readiness/models/speech return the specific structured 503. Read
`docs/API.md` before changing HTTP behavior.

The service has no authentication, TLS, or permissive CORS and is intended for
a trusted LAN. Rate limiting is not a security boundary.

## Readest boundary

Readest is separate:

- upstream: `https://github.com/readest/readest`
- fork: `https://github.com/xrishox/readest`
- branch: `custom-openai-tts-implementation`

Keep changes concentrated in OpenAI TTS modules/tests/settings and narrow
controller hooks, except the documented AppImage helper files. The client
policy is Opus then AAC, a 120-second/50-sentence volatile buffer, ten fetch
tasks with at most nine background loads, 64-entry/64-MiB/ten-minute memory
cache, ten consumed replay sentences, and source-ordered decode/playback. No
automatic WAV/MP3 and no persistent cache. See `docs/READEST_INTEGRATION.md`.

## Development and verification

Use test-first changes. At minimum:

```bash
swift test
```

Real HTTP verification:

```bash
HTTP_HOST=127.0.0.1 HTTP_PORT=18790 swift run siri-tts-server serve
TTS_SMOKE_NO_PLAYBACK=1 ./scripts/smoke-test.sh http://127.0.0.1:18790
```

Real audiobook verification:

```bash
./scripts/audiobook-smoke.sh "path/to/book.epub"
```

Packaging verification:

```bash
bash -n scripts/*.sh
./scripts/build-app.sh
codesign --verify --deep --strict "dist/Siri TTS Server.app"
```

Set `AUDIOBOOK_TEST_EPUB` for real-book parsing/view-model tests and also
`AUDIOBOOK_TEST_E2E=1` for real child-process synthesis tests.

A health check never proves the private path. Synthesize and read decoded audio
frames. Tests may use temporary decoder files; production HTTP synthesis may not.

## Signing and files

Prefer a stable Apple Development or Developer ID identity. If a discovered
identity cannot sign, fail rather than silently falling back to ad-hoc signing.
`CODE_SIGN_IDENTITY=-` explicitly accepts ad-hoc identity and possible Full
Disk Access reauthorization. Build and verify before stopping the installed app;
refuse installation while audiobook creation is active and roll back failed swaps.

Preserve user changes in a dirty worktree. Use `rg` for search and
`apply_patch` for edits. Never use destructive git commands without explicit
authorization. Do not log request text, credentials, PCM, or generated audio.
Validate untrusted sizes before allocation and keep concurrency boundaries
Sendable-safe.

## Documentation ownership

- `README.md`: concise entry point.
- `docs/API.md`: normative HTTP/audio contract.
- `docs/ARCHITECTURE.md`: design, data flow, and invariants.
- `docs/CODEBASE.md`: stable ownership map.
- `docs/OPERATIONS.md`: install, signing, run, update, and recovery.
- `docs/VOICES.md`: asset variants and discovery.
- `docs/AUDIOBOOKS.md`: narration, resume, M4B, and GUI/CLI behavior.
- `docs/READEST_INTEGRATION.md`: client negotiation, buffering, and rebase boundary.

Run `./scripts/check.sh` for the repeatable non-private verification set.

Put each fact in its canonical guide and link to it elsewhere instead of
duplicating it. Update documentation and contract tests whenever behavior,
limits, formats, configuration, or lifecycle changes.
