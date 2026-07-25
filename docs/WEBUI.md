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

Server and health: `GET /api/server`, `GET /api/voices` (gateway voices),
`GET /api/audiobook-voices` (full Siri inventory + Full Disk Access
warning), `GET /api/settings` (includes `configured` — false until the
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
`POST /api/drafts/queue` (per-draft settings; runs the same
request-builder path as the desktop Create screen).

Library: `GET /api/library?connection=`, `POST /api/library/refresh`
(fetches the connection's live inventory; stale-snapshot fallback),
`POST /api/library/narration`, `POST /api/library/quality-check`
(`{rowIDs, scope: local|storyteller|all}` → enqueues audits),
`PUT /api/library/editions/:recordID/identifier` (ISBN with optional
ETag-guarded Storyteller push), the match flow (`POST
/api/library/match/{find,link,confirm-suggested,decline-suggested}`,
`DELETE /api/library/match`), `POST /api/library/remote-readaloud`
(starts server-side ReadAloud processing with the automatic quality
audit intent), `POST /api/library/process/plan`, and
`POST /api/library/process/queue` — which answers
`409 {"code":"storyteller_match_review","candidates":[...]}` for the
single-book edition-review flow; re-post with `confirmedRemoteBookID`.
The plan request optionally carries the send toggles and then returns
per-book whole-book replacement loss manifests (`replacements`); the
queue request carries `replaceAcknowledgedRowIDs` and `assertNarration`
(see the Replacement section of [STORYTELLER.md](STORYTELLER.md)).
The library payload flags `authExpired` (401 refresh; reconnect in
Settings) and `connectionMissing` (the requested connection id no longer
exists; clients drop their remembered selection). Also:
`POST /api/library/mirror` + `GET /api/library/mirror`
(connection-scoped download-to-library progress),
`POST /api/library/upload?filename=` (raw EPUB import through the shared
digest-verified pipeline), and `GET /api/library/asin/{search,resolve}`
(bounded Audible catalog lookups).

Quality: `GET /api/quality/artifacts`, `GET /api/quality/queue`,
`POST /api/quality/enqueue` (`targets` of kind `local|remote|standalone`,
`thorough` flag), `POST /api/quality/{cancel-current,cancel-waiting,
cancel-all}`.

Storyteller: `GET /api/storyteller/connections`,
`POST /api/storyteller/connections/:id/test`, `DELETE
/api/storyteller/connections/:id`, and the device-auth session flow:
`POST /api/storyteller/device-auth` → `{id,userCode,verificationURL,…}`
(the browser opens the URL), `GET`/`DELETE
/api/storyteller/device-auth/:id`. Bearer tokens never leave the Keychain.

Tools: `GET /api/tools`, `POST /api/tools/stalign/install`.

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

## Known parity gaps

Launch-at-login and Reveal in Finder are capability-flagged off in the
web (paths are shown for copying instead); local file/folder choices go
through uploads or the bounded `/api/fs/list` browser.
