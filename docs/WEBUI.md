# WebUI and Studio web API

The gateway serves a browser interface at `/ui/` and its JSON surface under
`/api`. Both are trusted-LAN like the TTS API: no authentication, no TLS, no
CORS (the UI is same-origin). This document is the normative contract for
`/ui`, `/api`, and the event stream; `docs/API.md` remains the contract for
the OpenAI-compatible TTS surface.

## Hosting model

Route assembly lives in `makeServerApplication(config:studio:)`. The
`studio:` parameter carries the process-wide `StudioServices` graph
(job scheduler, quality queue, drafts, device-auth sessions, event broker):

- The desktop app hosts it always — GUI and WebUI observe the same queues.
- `spokenfolio serve --studio` hosts it headlessly and pauses the queue,
  the active child, and the quality queue gracefully on SIGINT/SIGTERM.
- Plain `serve` is TTS-only: static UI and status reads still work, and
  Studio-backed routes return `503 {"error":{"code":"studio_unavailable"}}`.

`scheduler.lock` and `quality.lock` keep the scheduler and quality queue
process singletons across the GUI and headless hosts.

## Static UI

- `GET /` → `303 /ui/`; `GET /ui/**` serves the Vite bundle from the SwiftPM
  resource bundle with an SPA fallback for extensionless paths.
- Hashed assets (`/ui/assets/*`): `Cache-Control: public, max-age=31536000,
  immutable`; the HTML shell: `no-cache`. Misses return HTML 404s, never the
  OpenAI error envelope. Traversal components are rejected.
- The UI stays servable in degraded startup; the Server page shows the
  structured failure and Full Disk Access guidance.

## Errors and events

`/api` errors use `{"error":{"code","message"}}` with `no-store`. A single
`GET /api/events` SSE stream carries complete per-topic snapshots (topics:
`server`, `queue`, `jobs`, `drafts`, `quality`, `tools`) with a monotonic
sequence — reconnect needs no replay; one event per topic restores state.
15-second heartbeat comments; at most 16 concurrent streams (429 beyond).
Every snapshot has a GET twin, so polling is the degraded fallback.

## Routes

Server and health: `GET /api/server`, `GET /api/voices` (legacy Siri projection), `GET /api/tts/catalog` (available public models, qualified voices, capabilities, recommended and maximum audiobook workers, and configured default selection), `GET /api/production/defaults` (the one server-owned starting point for every
production form: qualified default selection, audiobook and ReadAloud
settings, `workerSource` — `explicit`, `recommended`, `hardware`, or
`remembered` — an optional `workerWarning`, the
Full Disk Access warning, and the Storyteller connection summaries; it
carries no catalog of its own), `GET /api/settings` (includes `configured` — false until the
first-run onboarding modal saves a Book Library location — and the live
`relocation` status), `PUT /api/settings/processed-directory` (creates the
folder, and when the library has books starts the whole-library move;
refusals return `409 relocation_blocked`), `GET /api/settings/relocation`
(move progress for polling), `GET /api/fs/list?path=&files=epub` (bounded
to the home folder, symlink-escape-safe, no dotfiles; backs the folder
picker).

Jobs and queue: `GET /api/queue` (includes `deliveryActiveJobID`, the
delivery-only child running alongside the heavyweight job),
`GET /api/jobs?scope=queue|history|all`,
`GET /api/jobs/:id`, bulk `POST /api/jobs/{pause,resume,cancel}` with
`{ids:[UUID]}`, `POST /api/queue/{pause,resume,cancel-waiting}`, and
`POST /api/queue/reorder` with the complete ordered `{ids:[UUID]}` of
non-running, non-terminal jobs (`409 queue_changed` when stale), and
`POST /api/queue/run-next` with `{id}` (preempt: the book runs next and a
running book pauses safely behind it; `409 run_next_failed` on refusal).

Create drafts: `POST /api/drafts/upload?filename=` (raw
`application/epub+zip` body, streamed to bounded scratch storage, 2 GiB
cap), `POST /api/drafts/from-path`, `GET /api/drafts[/:id]`,
`GET /api/drafts/:id/cover`, `PATCH /api/drafts/:id` (section toggles),
`DELETE /api/drafts/:id`, `POST /api/drafts/:id/retry`, and
`POST /api/drafts/queue` (per-draft settings; runs the same request-builder path as the desktop Create screen). Each entry carries the durable `backendID`, `modelID`, `voiceID`, `pacePreset`, and `expressivityPreset` selection.
Queueing crosses the shared EPUB 3 gate before cataloging: EPUB 3 is
EPUBCheck-validated without rewriting, and EPUB 2 is converted by Calibre then
independently validated.

Library: `GET /api/library?connection=`, `POST /api/library/refresh`
(fetches the connection's live inventory; stale-snapshot fallback),
`POST /api/library/narration`, `POST /api/library/quality-check`
(`{rowIDs, scope: local|storyteller|all}` → enqueues audits),
`PUT /api/library/editions/:recordID/identifier` (ISBN with optional
last-write-wins Storyteller push), the match flow (`POST
/api/library/match/{find,link,confirm-suggested,decline-suggested}`,
`DELETE /api/library/match`), `POST /api/library/remote-readaloud`
(starts server-side ReadAloud processing with the automatic quality
audit intent), `POST /api/library/process/plan`, and
`POST /api/library/process/queue` — which answers
`409 {"code":"storyteller_match_review","candidates":[...]}` for the
single-book edition-review flow; re-post with `confirmedRemoteBookID`.
The plan returns the books, the skipped ones, and the same
`ProductionDefaults` object as `GET /api/production/defaults`; models and
voices are never embedded in it, because clients read the catalog once from
`GET /api/tts/catalog`. The plan request optionally carries the send toggles
and then returns
per-book whole-book replacement loss manifests (`replacements`); the
queue request carries `replaceAcknowledgedRowIDs` and `assertNarration`
(see the Replacement section of [STORYTELLER.md](STORYTELLER.md)).
Both production forms display ReadAloud timing as exact sentence synthesis
with no ASR. Their compatibility payload fields are always submitted as
`readAloudASREngineID: "synthesis"` and a null model; stale remembered
recognition settings are not restored.
Deletion is `POST /api/library/delete/plan` (`{rowIDs, slots, scope:
local|storyteller|both}` → a per-book manifest with `wholeBookLocal`,
`losesHumanContent`, `localSlots`, `remoteSlots`, plus `skipped`) and
`POST /api/library/delete` (adds `acknowledgedRowIDs`, re-verified server-side
so any whole-book or human-narrated loss is refused without it; returns the
per-book outcomes and the fresh library). Local files, catalog rows, and
timeline sidecars go together; remote deletes are per-asset only (see the
Deletion sections of [LIBRARY.md](LIBRARY.md) and
[STORYTELLER.md](STORYTELLER.md)).
The library payload flags `authExpired` (401 refresh; reconnect in
Settings) and `connectionMissing` (the requested connection id no longer
exists; clients drop their remembered selection). Also:
`POST /api/library/mirror` + `GET /api/library/mirror`
(connection-scoped download-to-library progress),
`POST /api/library/verify-remote` (`{rowIDs}` — live hash probes rewrite
delivery receipts; rows carry `storytellerSlots` per slot as
"verified"/"present"/null, where null means unknown and clients display
nothing),
`POST /api/library/upload?filename=` (raw EPUB import through the shared
digest-verified pipeline), and `GET /api/library/asin/{search,resolve}`
(bounded Audible catalog lookups).

Quality: `GET /api/quality/artifacts`, `GET /api/quality/queue`,
`POST /api/quality/enqueue` (`targets` of kind `local|remote|standalone`,
`thorough` flag), `POST /api/quality/{cancel-current,cancel-waiting,
cancel-all}`.
Completed quality runs expose `epubCompliance` (EPUB/checker versions and
bounded fatal/error/warning counts) independently of alignment evidence.
Creation and delivery require EPUBCheck 5.3.0 or newer, full audio decode, and
complete or sampled alignment evidence; compatibility-only advisories are the
only review findings that do not block publication.

Tools: `GET /api/tools` reports `stalign`, `media`, and `publications`.
The stalign result includes installed/available stable versions, installed
SHA-256, compatibility-probe state, and whether an update is available.
`POST /api/tools/stalign/install` is an explicit install/update action: it
discovers the current stable upstream package, verifies registry digest,
publisher signature, CLI surface, and a real EPUB markup probe, then swaps it
transactionally. It returns `409 tool_update_blocked` while production or a
quality check is active and never updates merely because status was read.
The publications status reports mandatory EPUBCheck plus Calibre, which is
optional unless an EPUB 2 source needs conversion.

Storyteller: `GET /api/storyteller/connections`,
`POST /api/storyteller/connections/:id/test`, `DELETE
/api/storyteller/connections/:id`, and the device-auth session flow:
`POST /api/storyteller/device-auth` → `{id,userCode,verificationURL,…}`
(the browser opens the URL), `GET`/`DELETE
/api/storyteller/device-auth/:id`. Bearer tokens never leave the Keychain.

## Frontend

`webui/` — React 19 + TypeScript (strict) + Vite, TanStack
Router/Query/Table/Virtual, Zustand for volatile client state, CSS Modules
over design tokens (light/dark via `prefers-color-scheme`), Lucide icons.
`npm run dev` proxies `/api`, `/v1`, `/health` to `127.0.0.1:8787` (run
`spokenfolio serve --studio` or the desktop app). `npm run build` emits
into `Sources/SpokenFolioApp/WebUI/dist` (gitignored assets; tracked
shell); `scripts/build-app.sh` builds it and copies the SwiftPM resource
bundle into the signed app; `scripts/check-web.sh` joins
`scripts/check.sh` when node is available.

Production Create, Library Process, and TTS Server share the same backend-neutral model/voice selector. Create and Library Process are built from one set of field groups — `TTSSelectionFields`, `AudiobookSettingsFields`, `ReadAloudSettingsFields`, and `StorytellerDeliveryFields` — mirroring `ProcessingSettingsSections.swift` so the desktop and web forms cannot drift, and both start from `GET /api/production/defaults`, which carries the settings the last queued book used (see [AUDIOBOOKS.md](AUDIOBOOKS.md)); `workerSource: "remembered"` tells a client where the count came from. A model's recommended worker count applies only when the user has not set one, but `maximumAudiobookWorkers` is always enforced. Selecting Siri Expressive immediately resolves workers to one, constrains the numeric control to one, and shows `workerWarning` when a remembered value was reduced. Pace and expressivity render as accessible `1...5` sliders only when the model supports them. The Server **Test & Play** panel posts same-origin speech requests, validates Opus then AAC MIME/nonempty bodies, plays AAC through an `HTMLAudioElement`, and revokes every replaced/completed object URL. macOS 26 catalogs omit `siri-expressive` rather than showing a nonfunctional option.
The shared audiobook fields also expose `unitGranularityID` as Paragraphs
(default) or Sentences; it is stored in the immutable job and remembered for
the next form on both surfaces.

## Known parity gaps

Launch-at-login and Reveal in Finder are capability-flagged off in the
web (paths are shown for copying instead); local file/folder choices go
through uploads or the bounded `/api/fs/list` browser.
