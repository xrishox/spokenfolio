# Codebase map

The package separates reusable speech and publication domains from the Siri,
EPUB, M4B, HTTP, and AppKit implementations that use them.

## Speech

- `TTSKit`: backend/model/voice identities, compile-time backend registry,
  workload-scoped sessions, typed PCM16, 48 kHz mono normalization, sentence
  detection, and complete in-memory Opus/AAC/WAV encoding.
- `LocalTTSWorkerKit`: bounded request/result framing, process-neutral clients,
  voice-affine worker pools, queue/deadline handling, retry/recycle, and
  per-backend crash circuits.
- `SiriTTSCore/Voice`: installed-asset discovery, permission preflight, and the
  `siri/siri-private` backend adapter.
- `SiriTTSCore/Bridge`: the installed-Siri private-framework ABI quarantine.
- `SiriTTSCore/Worker`: Siri child entrypoint and transport adapter over the shared pool.
- `GoldenGateTTSCore/Voice`: macOS-27+ FM catalog child and the
  `siri-fm/siri-expressive` adapter.
- `GoldenGateTTSCore/Bridge`, `Audio`, and `Worker`: dynamic daemon ABI,
  instrumentation/provenance validation, Float32/Opus decode, and isolated child transport.

Both concrete backends are process-isolated. The gateway sees only bounded catalog,
PCM, timing, and provenance values.

## Books and output

- `PublicationKit`: format-neutral metadata, covers, ordered sections,
  navigation, blocks, and stable source locators.
- `DocumentIOKit`: bounded ZIP central-directory/payload validation, canonical
  safe paths, CRC verification, and entity-safe bounded XML parsing.
- `EPUBKit`: container/OPF/navigation/XHTML semantics plus EPUB note removal
  and classification. `EPUBImporter` produces a Publication.
- `AudiobookKit/Extraction`: section selection, chapter planning, title
  announcements, and locator-preserving narration paragraphs.
- `AudiobookKit/Pipeline`: bounded ordered synthesis, progress, job identity,
  exclusive resume state, and artifact validation.
- `AudiobookKit/Formats/M4B`: AAC chapter artifacts, MP4 boxes, cover policy,
  durable publication, and the M4B writer.
- `LibraryKit`: the GRDB/SQLite catalog, works and editions, local artifacts,
  connection-scoped remote snapshots, reviewed identity assertions, audit log,
  persistent ReadAloud quality history, and universal 0–10 completeness evaluator.
- `BookJobKit`: immutable production requests, atomic job/control/scheduler
  state, leases, catalog compatibility/migration, and managed product layout.
- `ReadAloudKit`: pinned tool discovery/install, staged stalign execution,
  resume manifest, Opus processing, interchangeable Whisper/Apple transcript
  adapters, bounded Media Overlay inspection, semantic quality evidence, and
  conservative adjudication.
- `StorytellerKit`: device authorization, typed API client, canonical
  publication identity, conservative match resolution, and resumable TUS transfer.

AudiobookKit imports neither SiriTTSCore nor EPUBKit. A future DRM-free source
format supplies another Publication importer; a future read-along workflow can
consume preserved locators without changing EPUB extraction.

## Application

- `SpokenFolioApp/Composition`: compiled backend registry, configured default selection, model-qualified routing, shared HTTP admission, and compatibility-shaped speech facade.
- `SpokenFolioApp/HTTP`: Vapor application, routes, middleware, health, and rate limiting.
- `SpokenFolioApp/Application`: product identity/migration, desktop lifecycle,
  awaited embedded-server control, and connection testing.
- `SpokenFolioApp/Commands`: the ArgumentParser root, audiobook/ReadAloud
  commands, and hidden durable-job runner.
- `SpokenFolioApp/GUI`: navigation and feature views, bounded batch import,
  shared/per-book configuration, edition Library, adaptive window layout,
  Storyteller review, settings, and tools.
- `SpokenFolioApp/Jobs`: single-child durable scheduler and process control.
- `SpokenFolioApp/Storyteller`: connection metadata and Keychain token storage.
- `SpokenFolioApp/ReadAloud`: local/remote audit orchestration and persistence mapping.
- `SiriTTSBench`: developer-only installed-Siri throughput executable.
- `GoldenGateTTSBench`: developer-only expressive worker-scaling executable using production unit sizing and the 2× reorder window.

The no-argument AppKit mode and private `--siri-worker`, `--golden-gate-worker`, and `--golden-gate-catalog` modes bypass the public ArgumentParser tree. All public CLI modes use the root command. See
[STUDIO.md](STUDIO.md) for the app lifecycle and navigation contract.

## Verification ownership

- `TTSKitTests`: backend identities, PCM normalization, and response containers.
- `LocalTTSWorkerKitTests`: shared framing and bounded worker transport contracts.
- `SiriTTSCoreTests`: installed-asset discovery and Siri-specific worker/private-boundary helpers.
- `GoldenGateTTSCoreTests`: capabilities, instrumentation evidence, and audio conversion fixtures.
- `AudiobookKitTests`: EPUB importer fixtures, source locators, planning,
  ordering, resume, artifacts, and MP4 output.
- `SpokenFolioAppTests`: HTTP contracts, configuration, server lifecycle, and GUI-child behavior.
- `DocumentIOKitTests`, `LibraryKitTests`, `BookJobKitTests`, `ReadAloudKitTests`,
  `StorytellerKitTests`: hostile documents, catalog transactions, durable state,
  external-tool failure, conflict, API and transfer contracts. Storyteller
  live tests are explicitly environment-gated.
- `scripts/check.sh`: repeatable unit, syntax, documentation, and optional bundle checks.
- Smoke scripts: real Siri synthesis/decode and real EPUB→M4B/resume verification.
