# Architecture

## Dependency boundaries

```text
                 ┌──── SiriTTSCore ────────┐
TTSKit ◀─────────┤                          ├────▶ LocalTTSWorkerKit
  ▲              └──── GoldenGateTTSCore ──┘
  └──────── AudiobookKit
                  │
DocumentIOKit ◀── EPUBKit ─▶ PublicationKit ◀──── LibraryKit ◀──── BookJobKit
      ▲                           ▲
      └──────── ReadAloudKit ─────┘

StorytellerKit remains transport-focused. SpokenFolioApp maps its remote data
into LibraryKit and coordinates BookJobKit production.

SpokenFolioApp composes all libraries. SiriTTSBench and GoldenGateTTSBench are
separate non-HTTP developer measurement executables.
```

TTSKit describes local backends, workload-scoped sessions, qualified voices, controls, model-specific recommended/maximum audiobook workers, and typed PCM. LocalTTSWorkerKit owns bounded framing, voice affinity, admission, retry, timeout, recycling, and per-backend circuits. SiriTTSCore implements `siri/siri-private`; GoldenGateTTSCore implements macOS-27+ `siri-fm/siri-expressive`, including its catalog child, private daemon bridge, observed Float32/Opus decoding, and fail-closed instrumentation evidence. PublicationKit is the format-neutral book model; DocumentIOKit owns bounded ZIP/XML mechanics and EPUBKit imports EPUB semantics into PublicationKit. EPUBKit also owns the fail-closed EPUB 3 boundary: safe version inspection, Calibre coordination for EPUB 2 only, and bounded EPUBCheck evidence. AudiobookKit consumes only PublicationKit and TTSKit, so neither Siri nor EPUB is a pipeline assumption.

Backends are registered at compile time. There is no runtime plugin ABI.
HTTP and audiobook work create separate sessions so queues, workers, crash
circuits, and shutdown remain isolated.

## HTTP request path

```text
Readest → Vapor validation/global admission → model-qualified TTS router
        → selected backend session → LocalTTSWorkerKit framed IPC
        → backend-specific worker/private engine → typed PCM
        → 48 kHz mono normalization → complete in-memory container → HTTP
```

The gateway never loads private synthesis APIs. Installed Siri uses a voice worker; Golden Gate discovers FM voices through a bounded one-shot catalog child and synthesizes in a voice worker. Each worker owns one voice and handles one request at a time. Cancellation, timeout, malformed IPC, and unsafe failure recycle the worker. Unexpected crashes receive a bounded retry and affect only that backend's circuit. The signed app deliberately has hardened runtime without App Sandbox; process isolation and bounded IPC, not a sandbox entitlement, are the failure boundary.

The backend/session contract carries backend, model, qualified voice, optional pace/expressivity, revisions, sample rate, channel count, and bounded runtime provenance explicitly. Existing Siri IDs remain the public compatibility identifiers. Golden Gate live output may be mono 24 kHz Float32 and cached output may be 48 kHz Opus; both are decoded and normalized before entering the fixed mono 48 kHz HTTP or audiobook contract.

On macOS 26 the expressive backend is omitted and installed Siri remains usable. If the configured default backend fails, Vapor remains live for diagnostics and readiness/models/speech return the structured startup failure until restart; a failed non-default backend does not disable a healthy default.

## Publication and audiobook path

```text
EPUB → EPUBImporter → Publication + stable source locators
     → section selection/chapter planning → narration units
     → dedicated backend session → ordered PCM → AAC chapter artifacts
     → verified single-pass M4B assembly → atomic destination
```

DocumentIOKit owns safe archive paths, decompression budgets, CRC checks, and
entity-safe XML. EPUBKit owns OPF/navigation/XHTML semantics and conservative note filtering.
Publication blocks retain document, fragment, and block identity; multiple TOC
fragments inside one XHTML document therefore remain distinct chapters.
Fragment-only navigation and landmarks classify their boundary, never the
semantic role of the entire shared XHTML resource.
Unknown prose fails open.

Audiobook synthesis sends ordinary paragraphs as one utterance, bounds units
to 4,000 characters, and uses a 2×worker reorder window. A clean synthesis
refusal retries a speakable multi-sentence paragraph as bounded natural
sentence pieces; their PCM is joined without silence and their timing offsets
are rebased before the one normal paragraph pause. Completion may be out of
order, but PCM reaches the encoder in source order. Installed Siri permits up
to eight audiobook workers; Siri Expressive has a model capability maximum of
one in every production surface. Production writes an
immutable production request, then its single-child scheduler launches the
internal runner. The runner atomically persists authoritative state; the app
polls revisions and never treats child stdout as a production contract.

Resume identity covers source digest and importer version, stable section IDs, backend/model/voice revisions, pace and expressivity presets, audio and pause settings, narration policy, adapter/resource provenance, and M4B format version. The current manifest migration intentionally ignores incompatible older unfinished work; completed M4B files are unaffected.

M4B implementation details live together under `Formats/M4B`. Its narrow
writer protocol exists for orchestration tests and is not a speculative output
plugin system.

## Production publishing path

```text
SQLite edition catalog → immutable request.json → leased durable runner → verified M4B
  → optional stalign stages → verified ReadAloud EPUB
  → optional conflict preflight → resumable TUS upload → reconciliation
```

BookJobKit owns versioned requests, validated atomic state, cancellation intent,
leases, and unique product checksums. ReadAloudKit owns its external-tool boundary and never
depends on AppKit or Storyteller. StorytellerKit owns device authorization,
typed API data, same-origin resumable upload, and conservative conflict
planning. SpokenFolioApp is the composition layer and stores Storyteller tokens
in Keychain.

The desktop app is only a controller: a `jobs run` child is the durable authority.
Its durable FIFO scheduler permits exactly one heavyweight child, continues
after per-book failures, and requires explicit resume after app relaunch.
Closing the window does not invalidate job state. Cancellation escalates from
SIGINT to SIGTERM and SIGKILL when a child does not stop. LibraryKit retains source
identity, managed E/A/R products, connection-scoped remote snapshots, reviewed
links, and remote receipts independently of job history. Each published product
must pass independent verification before upload. Remote package coherence is
proved by matching delivery receipts or an explicit assertion, never inferred
from three co-located assets. The server-assigned Storyteller book UUID is
persisted because Storyteller does not guarantee preservation of the upload hint.

Everything that mutates a book — a production child, a quality run, a mirror
download, a deletion — first takes an exclusive lease from
`LibraryMutationCoordinator`, the process-wide actor `StudioServices` owns, and
holds it for the whole operation. Keys are the local edition, the library row,
and the linked remote book. This is what makes "no work is running" safe to act
on: without it, the answer is only true for the instant it was read. Queued
durable work outlives the process and holds no lease, so the coordinator also
consults that persistent state before a deletion proceeds.

ReadAloudKit also separates structural inspection, format-neutral quality
metrics, and adjudication. Production binds its retained transcriptions to its
own staged audio through request, processed-file, and transcription-file
digests, and rejects fundamental identity/timing failures before the
ReadAloud destination is committed. SpokenFolioApp adapts local products or
bounded Storyteller downloads into that engine; LibraryKit persists neutral run
records and findings without depending on EPUB, ASR, or Storyteller types.
Apple Speech transcription is the default. The Whisper adapter accepts a selected
model and defaults to `large-v3-turbo`. Both emit the same validated stalign timeline boundary, so markup,
alignment, verification, resume identity, and quality gates remain engine-neutral.

## Future extension seams

A new local TTS implementation adds a reviewed backend factory/session and
chooses its own safe runtime model. A future DRM-free book format adds an
importer that produces Publication. Neither extension requires changing the
audiobook ordering, resume, or M4B layers.

Additional read-along backends implement the ReadAloudKit boundary. Additional
delivery targets belong beside StorytellerKit and consume verified products;
they do not enter EPUB extraction, synthesis, or M4B writing.

## Operational boundaries

HTTP audio is complete and memory-only. Audiobook work/output is the explicit
durable exception. The service remains a trusted-LAN tool without built-in TLS
or authentication; rate limits protect resources, not access.

The desktop runtime owns an awaited server lifecycle controller. Restart is strictly
stop, shutdown, then start, preventing overlapping listeners. App identity and
stable code signing remain important because Full Disk Access follows code
identity.
