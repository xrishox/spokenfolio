# Codebase map

The Swift package produces one executable from three targets.

## `SiriTTSCore`

Owns voice discovery, Full Disk Access preflight, the private-framework bridge,
worker process entrypoint/client/pool, IPC framing, sentence detection, and
in-memory HTTP audio encoders. It never imports Vapor.

The private ABI belongs only in `SiriPrivateTTSBridge.swift`. Worker objects
must remain outside the gateway process, and every new IPC field needs framing
and hostile-size coverage.

## `AudiobookKit`

- `EPUB/`: bounded ZIP access plus container, OPF, navigation, and XHTML parsing.
- `Extraction/`: prose extraction, note filtering, section classification,
  title deduplication, and chapter planning.
- `Pipeline/`: bounded narration units, ordered synthesis, progress events,
  exclusive job/resume state, and artifact validation.
- `Output/` and `MP4/`: streaming AAC chapters, durable file commits, cover
  normalization, M4B planning/writing, and bounded box inspection.

It depends only on `SiriTTSCore` and system frameworks. Changes to extraction,
classification, planning, or announcements require an extractor-version bump.
Changes to utterance grouping require a synthesis-policy bump. Artifact or M4B
layout changes require a format-version bump.

## `SiriTTSServer`

Owns the Vapor routes/middleware, degraded readiness state, menu-bar lifecycle,
OpenAI-shaped errors, audiobook CLI, and Create Audiobook GUI. Vapor dependency
injection for the Core service lives in `TTSServiceVapor.swift`.

Executable modes are:

- no arguments: menu app plus HTTP gateway;
- `serve`: foreground gateway;
- `doctor`: environment diagnostics;
- `audiobook ...`: EPUB/M4B CLI;
- `--siri-worker <voice-id>`: internal child mode.

The GUI launches the CLI child and consumes NDJSON progress. Do not move
pipeline execution into AppKit callbacks.

## Request lifecycle

1. Vapor applies body and per-IP resource limits.
2. The speech controller validates model, text, speed, format, readiness, and voice.
3. The service resolves the canonical asset and leases a voice-affine worker.
4. The worker validates/loads Siri and returns 48 kHz mono PCM over bounded IPC.
5. The gateway finalizes the complete requested container in memory.
6. HTTP returns exact content type, content length, and `Cache-Control: no-store`.

## Tests and operational checks

- `SiriTTSCoreTests`: framing, discovery, sentence behavior, and audio encoding.
- `AudiobookKitTests`: hostile EPUB/ZIP data, extraction, planning, resume,
  ordering, AAC artifacts, MP4 golden data, large offsets, and full decode.
- `SiriTTSServerTests`: HTTP contracts, configuration, GUI child protocol, and
  view-model lifecycle.
- `scripts/smoke-test.sh`: real HTTP Siri synthesis and frame decoding.
- `scripts/audiobook-smoke.sh`: real EPUB planning, M4B creation, deep verify,
  and resume reuse.

When changing a public contract, update its canonical guide and the matching
contract test in the same change. See [ARCHITECTURE.md](ARCHITECTURE.md) for
invariants and [OPERATIONS.md](OPERATIONS.md) for release verification.
