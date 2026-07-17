# Codebase map

The package separates reusable speech and publication domains from the Siri,
EPUB, M4B, HTTP, and AppKit implementations that use them.

## Speech

- `TTSKit`: backend/model/voice identities, compile-time backend registry,
  workload-scoped sessions, typed PCM16, 48 kHz mono normalization, sentence
  detection, and complete in-memory Opus/AAC/WAV encoding.
- `SiriTTSCore/Voice`: installed-asset discovery, permission preflight, and the
  Siri backend adapter.
- `SiriTTSCore/Bridge`: the private-framework ABI quarantine.
- `SiriTTSCore/Worker`: framed IPC, child entrypoint/client, and the
  voice-affine bounded worker pool.

Process isolation remains Siri-specific. A future compiled backend implements
the TTSKit factory/session contracts and owns its own runtime strategy.

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

- `SpokenFolioApp/Composition`: compatibility-shaped HTTP speech facade and Siri session composition.
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
- `SiriTTSBench`: developer-only throughput executable.

The no-argument AppKit mode and private `--siri-worker` mode bypass the public
ArgumentParser tree. All public CLI modes use the root command. See
[STUDIO.md](STUDIO.md) for the app lifecycle and navigation contract.

## Verification ownership

- `TTSKitTests`: backend identities, PCM normalization, and response containers.
- `SiriTTSCoreTests`: discovery, framing, pool admission/cancellation/crash behavior, and private-boundary helpers.
- `AudiobookKitTests`: EPUB importer fixtures, source locators, planning,
  ordering, resume, artifacts, and MP4 output.
- `SpokenFolioAppTests`: HTTP contracts, configuration, server lifecycle, and GUI-child behavior.
- `DocumentIOKitTests`, `LibraryKitTests`, `BookJobKitTests`, `ReadAloudKitTests`,
  `StorytellerKitTests`: hostile documents, catalog transactions, durable state,
  external-tool failure, conflict, API and transfer contracts. Storyteller
  live tests are explicitly environment-gated.
- `scripts/check.sh`: repeatable unit, syntax, documentation, and optional bundle checks.
- Smoke scripts: real Siri synthesis/decode and real EPUB→M4B/resume verification.
