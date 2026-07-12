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
- `EPUBKit`: bounded ZIP/container/OPF/navigation/XHTML parsing plus EPUB note
  removal and semantic classification. `EPUBImporter` produces a Publication.
- `AudiobookKit/Extraction`: section selection, chapter planning, title
  announcements, and locator-preserving narration paragraphs.
- `AudiobookKit/Pipeline`: bounded ordered synthesis, progress, job identity,
  exclusive resume state, and artifact validation.
- `AudiobookKit/Formats/M4B`: AAC chapter artifacts, MP4 boxes, cover policy,
  durable publication, and the M4B writer.

AudiobookKit imports neither SiriTTSCore nor EPUBKit. A future DRM-free source
format supplies another Publication importer; a future read-along workflow can
consume preserved locators without changing EPUB extraction.

## Application

- `SiriTTSServer/Composition`: compatibility-shaped HTTP speech facade and Siri session composition.
- `SiriTTSServer/HTTP`: Vapor application, routes, middleware, health, and rate limiting.
- `SiriTTSServer/Application`: menu lifecycle, awaited embedded-server control, and connection testing.
- `SiriTTSServer/Commands`: the ArgumentParser root and audiobook commands.
- `SiriTTSServer/GUI`: Create Audiobook child-process UI.
- `SiriTTSBench`: developer-only throughput executable.

The no-argument AppKit mode and private `--siri-worker` mode bypass the public
ArgumentParser tree. All public CLI modes use the root command.

## Verification ownership

- `TTSKitTests`: backend identities, PCM normalization, and response containers.
- `SiriTTSCoreTests`: discovery, framing, pool admission/cancellation/crash behavior, and private-boundary helpers.
- `AudiobookKitTests`: EPUB importer fixtures, source locators, planning,
  ordering, resume, artifacts, and MP4 output.
- `SiriTTSServerTests`: HTTP contracts, configuration, server lifecycle, and GUI-child behavior.
- `scripts/check.sh`: repeatable unit, syntax, documentation, and optional bundle checks.
- Smoke scripts: real Siri synthesis/decode and real EPUB→M4B/resume verification.
