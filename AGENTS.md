# Project instructions

## Product

This Apple-Silicon/macOS-26+ project exposes installed Siri natural, neural, and
Gryphon voices through an OpenAI-compatible TTS API and creates local EPUB→M4B
audiobooks through a CLI and normal macOS desktop app. It deliberately uses Apple's
undocumented `SiriTTSService.framework`, so private ABI and asset changes are
the primary compatibility risk.

Requirements are Swift 6.2, macOS 26 or newer, Xcode Command Line Tools, a downloaded compatible
Siri voice, and Full Disk Access when shared models require it. Never download,
patch, relocate, or delete Apple voice assets.

## Architecture invariants

The package has ten reusable library targets and two executable targets:

- `TTSKit`: backend-neutral identities, sessions, typed PCM, normalization,
  sentence detection, and in-memory response encoding.
- `SiriTTSCore`: Siri discovery, private bridge, workers/pool, and IPC; depends
  on TTSKit and never imports Vapor.
- `PublicationKit`: format-neutral metadata, sections, navigation, and source locators.
- `DocumentIOKit`: bounded, path-safe ZIP and entity-safe XML parsing shared by
  publication import and artifact verification.
- `EPUBKit`: bounded EPUB parsing and EPUB-specific extraction/classification.
- `AudiobookKit`: format-neutral planning, ordered synthesis, resume, and M4B output.
- `LibraryKit`: SQLite-backed works, editions, local products, remote snapshots,
  identity assertions, quality history, and universal completeness evaluation.
- `BookJobKit`: immutable production requests, atomic state, leases, cancellation, and products.
- `ReadAloudKit`: pinned stalign boundary, resumable stages, Opus, Media Overlay
  verification, and bounded alignment-quality evidence.
- `StorytellerKit`: device authorization, conflict planning, and resumable TUS delivery.
- `SpokenFolioApp` executable target: composition, Vapor, desktop lifecycle, audiobook CLI, and GUI.
- `SiriTTSBench` executable target: developer-only throughput experiments.

`spokenfolio` is the product executable. `siri-tts-bench` is a separate
developer executable and is not bundled in the desktop application.

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
17. Studio writes a durable job and runs `jobs run <uuid>` as a child. The
    child is authoritative; explicit cancellation is persisted and sent as SIGINT.
18. `AGENTS.md` and `CLAUDE.md` stay byte-for-byte identical.
19. Studio has one durable FIFO scheduler and at most one heavyweight child.
    Relaunch leaves unfinished work suspended until the user resumes the queue.
20. The edition catalog is independent of job history and owns verified E/A/R
    products, managed output layout, and connection-specific remote receipts.
21. The normal app has one Dock-visible window. Closing it leaves the gateway
    and active jobs running; quitting awaits a safe job pause and server shutdown.
22. SQLite is the sole live library authority. Storyteller snapshots are scoped
    to a connection; bearer tokens remain in Keychain and real remote audiobooks
    are never downloaded.
23. Remote mutation requires Storyteller's advertised conditional-create,
    conditional-replace, and identifier-ETag protocol. An older server is
    read-only rather than vulnerable to check-then-write races.
24. Untrusted publication archives and XML go through DocumentIOKit. Do not
    materialize archive paths with a general-purpose extraction command.
25. ReadAloud quality keeps structure, coverage, content identity, timing, and
    compatibility as separate evidence. Low overlap suggests causes; it does
    not prove which asset, edition, or translation is wrong.
26. Remote quality audits may download bounded EPUB/ReadAloud artifacts and
    reports, but never Storyteller audiobooks. Persist only bounded metrics,
    findings, short excerpts, and tool identity—not book text, transcripts,
    PCM, audio, or credentials.
27. Resumed ReadAloud transcripts are trusted only when the stage manifest
    binds their file digest to the exact processed-audio digest and request fingerprint.
28. ReadAloud creation defaults to the exact synthesis-timeline transcript
    (no ASR), which requires the audiobook's digest-bound sidecar (written by
    default at creation) and never falls back silently. Apple Speech and
    Whisper remain selectable ASR modes; Whisper supports explicit model
    choice and defaults to `large-v3-turbo` when selected.
29. Synthesis-timeline alignment may neutralize never-narrated documents in
    the copy stalign searches (restored byte-for-byte in the output) and
    re-align provably-narrated documents in isolation, but the merged
    artifact always passes the full verifier and quality audit.
30. The gateway serves the WebUI at `/ui` and the Studio JSON surface at
    `/api`, trusted-LAN with no auth; static UI and status reads never
    require engine readiness, and the gateway process still never loads
    the private synthesis engine.
31. The job scheduler and quality queue are process-singleton services
    guarded by `scheduler.lock` and `quality.lock`; every interface (GUI,
    CLI, web) mutates job and quality state only through these services,
    which exist independently of any GUI.
32. Web uploads stream to bounded scratch storage and import through the
    same digest-verified pipeline as local files; Storyteller bearer
    tokens never leave the Keychain via HTTP.

Executable modes:

- no arguments: desktop app and HTTP gateway;
- `serve`: foreground gateway;
- `doctor`: diagnostics;
- `audiobook <create|chapters|export-text|voices|verify|audit>`;
- `readaloud <create|verify|audit|doctor|tools>`;
- `serve --studio`: headless gateway plus Studio services (scheduler,
  quality queue, web API backend);
- `jobs run <uuid>`: internal durable production child;
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
HTTP_HOST=127.0.0.1 HTTP_PORT=18790 swift run spokenfolio serve
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
codesign --verify --deep --strict "dist/SpokenFolio.app"
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
refuse installation while book production or ReadAloud work is active and roll
back failed swaps.

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
- `docs/PRODUCTION_JOBS.md`: durable authority, lifecycle, cancellation, and retry.
- `docs/STUDIO.md`: desktop navigation, window lifecycle, settings, and migration.
- `docs/READALOUD.md`: tool policy, Opus, stages, and verification.
- `docs/STORYTELLER.md`: authorization, duplicate policy, transfer, and reconciliation.
- `docs/LIBRARY.md`: identity, persistent catalog, completeness levels, and backfill.
- `docs/WEBUI.md`: the `/ui` and `/api` contract, event stream, and web toolchain.

Run `./scripts/check.sh` for the repeatable non-private verification set.

Put each fact in its canonical guide and link to it elsewhere instead of
duplicating it. Update documentation and contract tests whenever behavior,
limits, formats, configuration, or lifecycle changes.
