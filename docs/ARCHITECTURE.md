# Architecture

## Dependency boundaries

```text
SiriTTSCore ───────────────▶ TTSKit ◀──────── AudiobookKit
                                                   │
EPUBKit ───────────────▶ PublicationKit ◀──────────┘
  ▲                          ▲  ▲
  └──── ReadAloudKit ────────┘  ├──── BookJobKit
                                └──── StorytellerKit

SpokenFolioApp composes all libraries. SiriTTSBench composes the
non-HTTP speech/publication path for developer measurements.
```

TTSKit describes local backends, workload-scoped sessions, qualified voices,
and typed PCM. SiriTTSCore is one compiled backend and keeps its private bridge
and worker implementation private. PublicationKit is the format-neutral book
model; EPUBKit imports EPUB into it. AudiobookKit consumes only PublicationKit
and TTSKit, so neither Siri nor EPUB is a pipeline assumption.

Backends are registered at compile time. There is no runtime plugin ABI.
HTTP and audiobook work create separate sessions so queues, workers, crash
circuits, and shutdown remain isolated.

## HTTP request path

```text
Readest → Vapor validation/limits → compatibility TTS facade
        → Siri session → framed worker IPC → private engine
        → typed PCM → 48 kHz mono normalization
        → complete in-memory Opus/AAC/WAV/PCM → HTTP response
```

The gateway never loads `SiriTTSService.framework`. Each worker owns one voice
and handles one request at a time. Cancellation, timeout, malformed IPC, and
unsafe failure recycle the worker. Unexpected crashes share a bounded retry
and open the pool circuit after three failures in 60 seconds.

The backend/session contract carries backend, model, voice, revisions, sample
rate, and channel count explicitly. Existing Siri IDs remain the public
compatibility identifiers. Any future engine output is normalized before it
can enter the fixed mono 48 kHz HTTP or audiobook contract.

If Siri initialization or permission fails, Vapor remains live for diagnostics.
Readiness, models, and speech return the structured startup failure until restart.

## Publication and audiobook path

```text
EPUB → EPUBImporter → Publication + stable source locators
     → section selection/chapter planning → narration units
     → dedicated backend session → ordered PCM → AAC chapter artifacts
     → verified single-pass M4B assembly → atomic destination
```

EPUBKit owns ZIP/OPF/navigation/XHTML details and conservative note filtering.
Publication blocks retain document, fragment, and block identity; multiple TOC
fragments inside one XHTML document therefore remain distinct chapters.
Unknown prose fails open.

Audiobook synthesis sends ordinary paragraphs as one utterance, bounds units
to 4,000 characters, and uses a 2×worker reorder window. Completion may be out
of order, but PCM reaches the encoder in source order. Studio writes an
immutable production request, then its single-child scheduler launches the
internal runner. The runner atomically persists authoritative state; the app
polls revisions and never treats child stdout as a production contract.

Resume identity covers source digest and importer version, stable section IDs,
backend/model/voice revisions, audio and pause settings, narration policy, and
M4B format version. The schema-v2 migration intentionally ignores older
unfinished work; completed M4B files are unaffected.

M4B implementation details live together under `Formats/M4B`. Its narrow
writer protocol exists for orchestration tests and is not a speculative output
plugin system.

## Production publishing path

```text
edition catalog → immutable request.json → leased durable runner → verified M4B
  → optional stalign stages → verified ReadAloud EPUB
  → optional conflict preflight → resumable TUS upload → reconciliation
```

BookJobKit owns versioned requests, atomic state, cancellation intent, leases,
and product checksums. ReadAloudKit owns its external-tool boundary and never
depends on AppKit or Storyteller. StorytellerKit owns device authorization,
typed API data, same-origin resumable upload, and conservative conflict
planning. SpokenFolioApp is the composition layer and stores Storyteller tokens
in Keychain.

The Studio is only a controller: a `jobs run` child is the durable authority.
Its durable FIFO scheduler permits exactly one heavyweight child, continues
after per-book failures, and requires explicit resume after app relaunch.
Closing the window does not invalidate job state. The edition catalog retains
source identity, managed E/A/R products, and remote receipts independently of
job history. Each published product must pass independent verification before
upload. The server-assigned Storyteller book UUID is persisted because
Storyteller does not guarantee preservation of the upload hint.

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
