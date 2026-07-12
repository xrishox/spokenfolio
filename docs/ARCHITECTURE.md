# Architecture

## Dependency boundaries

```text
SiriTTSCore ─────▶ TTSKit ◀───── AudiobookKit
                                      │
EPUBKit ─────▶ PublicationKit ◀───────┘

SiriTTSServer composes all four libraries; SiriTTSBench composes the
non-HTTP path for developer measurements.
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
of order, but PCM reaches the encoder in source order. The GUI always launches
the same CLI workflow as a child and communicates through NDJSON.

Resume identity covers source digest and importer version, stable section IDs,
backend/model/voice revisions, audio and pause settings, narration policy, and
M4B format version. The schema-v2 migration intentionally ignores older
unfinished work; completed M4B files are unaffected.

M4B implementation details live together under `Formats/M4B`. Its narrow
writer protocol exists for orchestration tests and is not a speculative output
plugin system.

## Future extension seams

A new local TTS implementation adds a reviewed backend factory/session and
chooses its own safe runtime model. A future DRM-free book format adds an
importer that produces Publication. Neither extension requires changing the
audiobook ordering, resume, or M4B layers.

Read-along publishing is intentionally absent. Stable source locators are
preserved so a later Storyteller/stalign or native EPUB Media Overlay workflow
can be added as a separate publisher without redoing extraction or coupling it
to the M4B writer.

## Operational boundaries

HTTP audio is complete and memory-only. Audiobook work/output is the explicit
durable exception. The service remains a trusted-LAN tool without built-in TLS
or authentication; rate limits protect resources, not access.

The menu owns an awaited server lifecycle controller. Restart is strictly
stop, shutdown, then start, preventing overlapping listeners. App identity and
stable code signing remain important because Full Disk Access follows code
identity.
