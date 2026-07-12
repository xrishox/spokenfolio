# Architecture and design

## Responsibilities

The Mac server is stateless for HTTP speech: it discovers installed voices,
schedules isolated synthesis, and returns one complete in-memory audio file.
Readest owns codec negotiation, source ordering, playback, and its volatile
mobile lookahead buffer. Audiobook creation is a separate local product path
whose M4B and resumable chapter files are intentionally durable.

```text
Readest                                  Siri TTS Server
┌──────────────────────────┐             ┌──────────────────────────┐
│ Opus 64k → AAC 64k       │   HTTP      │ Vapor gateway            │
│ buffer ≤120 s/50 marks   ├────────────▶│ queue ≤20, workers ≤4    │
│ ordered decode/playback  │             └────────────┬─────────────┘
└──────────────────────────┘                          │ framed IPC
                                        ┌────────────▼─────────────┐
                                        │ private Siri worker      │
                                        │ one voice, one request   │
                                        └──────────────────────────┘

EPUB → extraction/planning → dedicated worker pool → chapter AAC artifacts
     → single-pass M4B assembly → atomic final output
```

## Process boundaries

The Vapor gateway never loads `SiriTTSService.framework`. It launches the same
executable with `--siri-worker <voice-id>`; each child owns one model and
handles one request at a time. Length-prefixed JSON and bounded PCM travel over
pipes. Cancellation, timeout, malformed IPC, or an unsafe failure kills and
recycles the worker. One crash retry shares the original request deadline, and
three unexpected crashes in 60 seconds open the pool circuit.

The private bridge dynamically validates required classes, selectors,
Objective-C encodings, engine initialization, and mono signed PCM16 at 48 kHz.
Only installed natural, neural, and Gryphon assets with a compatible graph are
listed. The project never downloads or modifies Apple assets.

If Siri initialization or model permission fails, the HTTP gateway remains
live for diagnostics. Liveness and voice discovery remain available where
possible; readiness, models, and speech return the specific structured 503
until the app is restarted after recovery.

## Audio and ordering

HTTP inputs are at most 4,096 characters. The gateway synthesizes their
sentences in source order, finalizes Opus, AAC/M4A, WAV, or raw PCM entirely in
memory, and only then returns HTTP 200 with exact length and `no-store`.

Readest probes its real decoder and pins Ogg Opus, then AAC-LC/M4A. It may fetch
out of order, but decode, highlighting, and playback remain source ordered. Its
compressed cache is process memory only. The server keeps no client cursor,
session, or generated-audio cache.

## Audiobook design

`AudiobookKit` parses bounded, checksum-verified EPUB ZIP data, extracts prose,
classifies sections, and plans TOC chapters. EPUB 3 note semantics are
authoritative; conservative EPUB 2 heuristics require multiple signals;
unclassified prose is retained.

Audiobook synthesis has its own 1–16-worker pool and crash circuit. This
isolates queues and failures from HTTP, though both pools still compete for CPU
and shared matrix hardware. Paragraphs normally remain one utterance; every
unit is capped at 4,000 characters and pathological sentences split at clause,
whitespace, then Unicode boundaries. A bounded 2×worker window may complete out
of order but feeds the streaming chapter encoder in source order.

Each job is exclusively locked. Its key covers the EPUB hash, voice and asset
version, audio settings, section selection, title/pause policy, extractor
version, synthesis policy, and container format. Chapter artifacts authenticate
their packet data and semantic metadata before reuse. Completed files and
manifests are synchronized and atomically committed.

The M4B writer plans exact sizes and offsets before writing, streams chapter
packets once, and emits AAC-LC audio, Apple and Nero chapters, iTunes metadata,
optional cover art, and gapless edit metadata. The final destination appears
only after complete size verification; no-overwrite commits cannot clobber a
file that appeared during synthesis.

The GUI never runs the audiobook pipeline in-process. It spawns
`audiobook create --progress ndjson`; cancellation sends SIGINT. If the GUI
disappears and closes its progress pipe, the child disables progress output and
continues safely. Malformed protocol input and explicit app termination use the
same resumable cancellation path.

## Bounds and security model

The service is for a trusted LAN: no authentication, TLS, or permissive CORS is
built in. Rate limiting is resource protection, not access control. HTTP is
bounded to four workers, twenty queued requests, twelve outstanding requests
per IP, a 20-token/2-per-second bucket, and 4,096 tracked clients with ten-minute
idle expiry. IPC headers are capped at 64 KiB and PCM replies at 128 MiB.

The app bundle embeds required Swift compatibility libraries and is signed as a
unit. The installer verifies a staged build before downtime, identifies running
processes by executable vnode, refuses to interrupt audiobook creation, and
rolls back a failed replacement. Stable signing identity matters because Full
Disk Access follows code identity.
