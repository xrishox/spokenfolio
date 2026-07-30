# Desktop app

SpokenFolio is a normal Dock application with one persistent window. Its five
top-level destinations are **Production**, **Library**, **ReadAloud Quality**,
**TTS Server**, and **Settings**. The sidebar and secondary inspectors collapse
at narrow widths; primary actions remain in fixed headers or action bars rather
than scrolling out of view. Saved window frames that are too small for the
current interface are enlarged when the display permits it.

Closing the window leaves the embedded gateway and active production child
running. Reopening from the Dock reuses the same window at its last size and
position. Quitting persists queue suspension, interrupts active production as a
resumable pause, waits for the child, releases locks, and then shuts down the
gateway. Unqueued Create drafts trigger a warning that states how many will be
discarded, because they are intentionally volatile. System-initiated logout,
restart, and shutdown skip that question: active work still pauses resumably
and volatile drafts are discarded.

## Production

Production has three visible modes:

- **Create** imports a multi-file or drag-and-drop EPUB batch. A selected book
  uses the batch defaults unless customized. TTS model, model-qualified voice,
  capability-driven pace/expressivity sliders, AAC bitrate, workers, paragraph
  and chapter pauses, title announcements, ReadAloud Opus bitrate and exact
  sentence timing (no ASR), output location, section inclusion, and optional
  Storyteller delivery remain explicit.
  Worker controls use the selected model's advertised maximum: installed Siri
  permits 1–8, while selecting Siri Expressive immediately resolves the
  effective count to one. Remembered values above that maximum are clamped
  with a visible warning.
  Import is an EPUB 3 gate: existing EPUB 3 bytes must pass EPUBCheck 5.3.0 or
  newer and stay untouched; EPUB 2 is converted by Calibre and independently
  checked before cataloging.
- **Queue** shows active, waiting, paused, and needs-attention jobs in durable
  FIFO order. Waiting jobs reorder by drag or Move to Top/Up/Down/Bottom,
  **Run This Book Next** preempts the running book (safe chapter-checkpoint
  pause, re-queued directly behind the chosen one), and
  a delivery-only job (a Storyteller send of finished products) runs in its
  own lane beside the synthesis child instead of waiting behind it. Add
  EPUBs, resume, pause after current, pause now, cancel waiting,
  search, multi-selection, and applicable bulk actions remain available while a
  job runs. The inspector shows the stage timeline, backend/model/voice/preset request settings, backend-specific runtime/macOS provenance, errors, and every verified product.
- **History** separates completed and cancelled work, supports search and
  sortable columns, and reuses the outcome inspector.

Successfully queued drafts leave Create; import or enqueue failures remain with
their reason. Reprocessing creates a new digest-guarded replacement job rather
than editing completed history or performing an unverified overwrite.

## Library and quality

Library is the sole book inventory. Its sortable, searchable table combines
local editions with the selected Storyteller snapshot, supports normal macOS
multi-selection, and keeps row actions in a selection bar and inspector rather
than embedding a toolbar in every row. One goal-oriented **Process** sheet owns
every pipeline action for the selection: it shows the source (a cataloged local
EPUB, or a download from Storyteller when only the remote ebook exists —
the backfill path), toggles for creating or digest-guarded recreating the
audiobook and the ReadAloud with their full settings (TTS model, qualified voice, pace/expressivity when supported, AAC bitrate, workers, pauses, Opus bitrate, and exact sentence timing without ASR),
and an optional Send to Storyteller step with product selection, a declared
sent-narration provenance (SpokenFolio TTS or Human), and inline edition
review. When a selected product targets an occupied remote slot with
different content, the sheet shows the whole-book replacement loss manifest
and requires an explicit acknowledgment before queueing (see the Replacement
section of [STORYTELLER.md](STORYTELLER.md)). Add to Queue creates durable
jobs directly in the Production queue. Sending already-processed products
later uses the same sheet through **Send to Storyteller…**. The Library
toolbar also imports local EPUBs directly (**Import Books…**) and mirrors
Storyteller books into the local Book Library (**Download All from
Storyteller…**, or per-row Download to Library) — a chooser selects which
formats to pull (EPUB, human audiobook, human ReadAloud), sharing the same
import and mirror services as the WebUI; downloads run up to three books at a
time and record proof receipts so downloaded slots can show verified. A
selection-bar **Delete…** action (single or multi-select) opens a per-slot
chooser: check any product slots, pick one scope — Local, Storyteller, or Both
— and see a per-book manifest of exactly what is removed. A book missing a
checked slot is skipped, never blocking the rest. Deleting the source EPUB
removes the whole local book and is called out in red; any whole-book or
human-narrated loss requires an explicit acknowledgment. Remote deletion is
per-asset only and never deletes a whole Storyteller book; books with active or
queued work are skipped with a reason. See [LIBRARY.md](LIBRARY.md). The inspector otherwise owns identity,
provenance, quality, server-side ReadAloud processing, reveal, match,
unlink, and identifier actions, including ASIN discovery (find via the
online catalog, set manually, and see what the saved ASIN identifies beside
the local title). See [LIBRARY.md](LIBRARY.md) for identity and
completeness rules.

ReadAloud Quality has one row per concrete local, Storyteller, or standalone
ReadAloud artifact. The latest applicable semantic result is shown even if a
newer audit attempt failed; prior attempts remain selectable history. Fixed
scope buttons expose all, attention, unchecked, and likely-correct artifacts.
Command-click, Shift-click, and Select All Results provide batch selection;
Check Selected queues the batch. The result inspector shows verdict, evidence
adequacy, metrics, suspected causes, bounded excerpts, and findings. One audit
runs at a time. The current book is always visible in a compact status bar with
fixed Cancel Current and Cancel All controls; the full FIFO opens as a temporary
drawer for selected waiting-item removal.

Local ReadAloud creation performs EPUB conformance, full audio decode, and
digest-bound timing/coverage comparison before publication without running
speech recognition. Material review findings and insufficient evidence fail the
creation; compatibility-only advisories may remain warnings.
Storyteller processing creates a durable automatic-audit intent and queues the
remote artifact after alignment finishes.

## Services and settings

TTS Server presents the endpoint, readiness, model/voice/control selector, and diagnostics. Its volatile editable **Test & Play** panel accepts up to 4,096 characters, performs real Opus and AAC synthesis, verifies MIME and decoded mono 48 kHz frames, then plays the AAC result. A health endpoint alone does not prove private synthesis or device codecs.

First launch (on either surface) asks where to keep the book library,
prefilled with the default `~/Books/SpokenFolio`; confirming writes the
studio settings file and ends onboarding.

Settings uses visible **General**, **Storage**, **ReadAloud**, and
**Storyteller** scopes. Storage controls the Book Library folder — all book
files (imported EPUBs, Storyteller downloads, TTS audiobooks, and TTS
ReadAlouds) live there, one folder per book, and changing the location moves
the whole library after an explicit confirmation. The move is refused with a
reason while production, quality, or download work is active; per-book
failures are reported and leave those books at the old location.
General owns Launch at Login; ReadAloud reports the installed and latest stable
external stalign releases, offers a confirmed compatibility-tested update, and
reports EPUBCheck/Calibre readiness; Storyteller manages device authorization, connection health,
permissions, reconnect, and confirmed disconnect. Storyteller book inventory
appears only in Library. Apple voice assets remain managed by macOS.

Create and Library Process expose the same Paragraphs/Sentences synthesis-unit
setting as the WebUI. Paragraphs are the default; sentence mode sends each
natural sentence as its own timed TTS request. Both modes retain exact
request-level timing for no-ASR ReadAloud creation.

The former app identity is migrated transactionally before startup. Owned
application support and window state move immediately; Storyteller credentials
move lazily on first use so Keychain authorization can be presented safely. The
old credential is not deleted until the new copy verifies.
