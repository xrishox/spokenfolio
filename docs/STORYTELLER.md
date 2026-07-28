# Storyteller delivery

Settings → Storyteller connects through Storyteller’s device-authorization
endpoints. The cancellable authorization sheet shows the approval code and URL;
the resulting token is saved in macOS Keychain. Connection settings show the
account, origin, permissions, and health. Server URLs
must be HTTP(S) origins. HTTP is suitable only on a trusted network; HTTPS is
preferred. Storyteller book inventory is not duplicated in Settings; it appears
in Library.
Saved connection metadata is not treated as an authenticated session: the app
validates the token against the server before offering delivery. If a server
restore or restart revokes it, the app reports the expired session and offers
**Reconnect…**.
The origin entered in Settings is authoritative for device approval links. The
client preserves the returned approval path and code but rebases links that
contain an internal container/bind address onto that configured origin.
The approved account must have `bookList` and `bookRead`; creating a remote
book also needs `bookCreate`, and filling or replacing a format on an existing
book needs `bookUpdate`. `bookRead` is required for every transfer, not only
for reads: upstream guards `GET /api/v2/books/:id` and
`GET /api/v2/books/:id/files` with it, and without them neither the preflight
before a mutation nor the reconciliation after it is possible. Upstream's
`bookDownload` guards its own reading/sync endpoints and is never required
here. SpokenFolio checks these permissions before transfer.

Storyteller is an upstream project SpokenFolio never modifies (see the
Storyteller boundary in the project instructions). Every request targets the
real, stock Storyteller API, verified against upstream source
(`gitlab.com/storyteller-platform/storyteller`): the v2 book/list/user
routes, the OAuth device flow, TUS uploads at `/api/v2/books/upload` and
`/api/v2/books/:id/replace-asset/upload`, ranged file downloads with the
server's `X-Storyteller-Hash` sha256 header, reports, and delete. Stock
Storyteller offers no server-side conditional mutations, so safety is
client-enforced: preflight against the live book list, skip-if-identical
proofs, per-asset acknowledgment before any overwrite, and post-upload
reconciliation with size and hash verification. The narrow races that
leaves (another writer between preflight and finalize) are accepted and
documented rather than papered over.

A job may send any selected combination of the normalized source EPUB, verified
AAC M4B, and verified ReadAloud EPUB. Creating a NEW remote book is the one
exception: stock `POST /api/v2/books/upload` derives the format from the file
it receives — `application/epub+zip` becomes the book's ebook, audio becomes
its audiobook — and has no readaloud branch and honors no format hint. A
delivery whose first upload would be a ReadAloud is refused with that reason
instead of seeding a book whose narrated EPUB is filed as its source EPUB;
including the source EPUB (or the audiobook) makes it legal. Uploads use TUS with bounded chunks,
persisted offsets, source-size/date checks before and throughout transfer,
bearer authentication, and
same-origin upload locations. Corrupt resume state stops for review rather than
starting a second upload; JSON/error responses are size-bounded. Authorization is never followed through an HTTP
redirect.

The exact source EPUB is revalidated as compliant EPUB 3 before Storyteller
preflight. A selected ReadAloud additionally passes EPUBCheck, strict Media
Overlay/audio verification, and the applicable alignment-quality gate before
upload. Conversion and checking are entirely local; SpokenFolio never changes
Storyteller to accommodate a publication.

A `409` carrying `Upload-Offset` is treated as TUS offset drift. A `409`
without that header remains a Storyteller mutation conflict; it is never
misreported as resumable offset state.

Before transfer the client lists the library. A saved connection-specific link
or exact remote asset hash may auto-attach. ISBN/ASIN/DOI and similar
title/author metadata are review evidence, not proof that two files are the same
edition. Ambiguous matches require explicit candidate selection and offer
**Attach Existing** or **Create Separate**; no uncertain candidate is
preselected. The latter records rejected candidates so the same prompt does not
recur.

A linked book only fills missing formats. An occupied format is skipped only
when a saved receipt still matches the remote asset identity or its complete
SHA-256 (via the one-byte ranged hash probe) matches the selected local
product. Otherwise delivery stops as a conflict and never overwrites the
asset without the explicit per-asset acknowledgment described under
Replacement below. These checks are client-side; a writer racing between
preflight and finalize is detected afterward by reconciliation rather than
prevented by the server.

## Replacement

Replacement is per-asset through Storyteller's own
`replace-asset/upload` API: each acknowledged format is replaced
individually and nothing else on the book is touched — no book is ever
deleted during delivery. The Process sheet detects at plan time when a
selected product targets a slot that is occupied (an available remote
asset) with content that is not provably identical, and lists exactly
those files in a per-book manifest; replacing a human-narrated
audiobook or ReadAloud slot gets an explicit red warning. Queueing such
a book requires an explicit acknowledgment; the acknowledged per-asset
snapshots (asset IDs, sizes, hashes) are encoded in the durable request.

At execution the child re-verifies each acknowledged asset against its
snapshot immediately before replacing it. Confirmations are ceilings:
an asset that appeared or changed identity, size, or content since the
user confirmed aborts as a conflict, while a slot whose asset has since
vanished (including a broken server-side ReadAloud with no available
file) is simply filled — that destroys nothing. A broken or
still-processing server-side asset does not occupy its slot: it is
fillable without acknowledgment.

The send step also carries a declared narration provenance for a delivered
ReadAloud ("SpokenFolio TTS" by default, or "Human"); after successful
reconciliation it is recorded as a narration assertion so Library slots
reflect the declaration immediately.

## Deletion

Deleting a Storyteller asset uses upstream's real per-asset endpoint,
`DELETE /api/v2/books/:id/replace-asset?format=…` (guarded server-side by
`bookUpdate`, not `bookDelete`), which removes one format and returns the
updated book — it never deletes the book. It **detaches the format**: upstream
removes the database row, then deletes the file only when it is a ReadAloud or
lives inside the server's assets directory, and a failed deletion is logged
rather than surfaced. A reference-mode ebook or audiobook stored outside that
directory stays on the server's filesystem, so this is not a guarantee that
bytes were erased. Each remote deletion re-verifies the
asset against its confirmation snapshot with the same ceiling semantics as
replacement (a changed or newly-appeared asset aborts; a vanished one needs no
work), then asserts the format is absent in the returned book. Verification is
shared with replacement (`StorytellerMutationVerifier`) and compares the asset
UUID, size, and fingerprint; when the confirmation captured a content hash,
that hash must be re-proved live, and a probe that fails or returns nothing
comparable aborts the deletion rather than passing it. Stock Storyteller has
no `If-Match` or any other precondition, so this check proves the asset was
unchanged a moment earlier, not that it stays unchanged during the request: it
assumes no concurrent Storyteller writer. The whole-book
`DELETE /api/v2/books` endpoint is used only by disposable-book test cleanup,
never by the app. See the Deletion section of [LIBRARY.md](LIBRARY.md) for how
local and remote deletes combine.

Known accepted gaps: a removed connection leaves its catalog links and
receipts orphaned (harmless; re-linking a new connection rebuilds them), and
Keychain cleanup on connection removal is not transactional with the
SQLite snapshot removal.

Storyteller may replace an upload UUID hint with its own book UUID, so the
assigned UUID is discovered after the first product and stored in job and
catalog state. Reconciliation requires every selected asset to appear and saves
its remote asset ID, size, fingerprint, and available hash before success.

In Production → Create, enable Storyteller delivery and choose any products to
send after local production. Use the Library inspector's **Send…** action to
deliver an existing product later. This
creates a delivery-only job that re-verifies the selected files; it does not
mutate or rerun completed synthesis.

The Library persists a complete snapshot per connection, including remote asset
status and ReadAloud processing progress. A successful refresh tombstones books
that disappeared; a failed refresh retains the last snapshot as stale. Local and
remote editions fold into one row only after reviewed identity. Narration remains
unknown unless production evidence or an explicit assertion marks it as TTS or
human. See [LIBRARY.md](LIBRARY.md) for levels and backfill behavior.

For a remote human audiobook, **Start ReadAloud** first shows the candidate
and requires explicit confirmation before asking Storyteller to align it.
**Download from Storyteller** mirrors any chosen remote format — EPUB, human
audiobook, human ReadAloud — into the book's Library folder as download-only
human products; each download records a proof receipt so its slot can show
verified. `/files` answers either with the stored file or with a
representation Storyteller generates for the request: a multi-file audiobook
is zipped on demand, and its `Content-Length`, `X-Storyteller-Hash`, and ETag
then describe that ZIP rather than anything on the server's disk. Downloads
are therefore committed under the extension the response actually declares
(`Content-Disposition`, then `Content-Type`), a generated audiobook ZIP is
refused rather than cataloged as an `.m4b`, and receipts record the source
asset's identity separately from the served representation's size and digest. Human downloads are never sent back to Storyteller. (The ReadAloud
quality-audit path is separate and still never downloads the audiobook.)

**ReadAloud Quality** lists available remote ReadAlouds for the selected
authorized connection. An audit uses the bounded ReadAloud/EPUB download route,
the processing report, and bounded retained-transcription routes. Server
transcripts are advisory unless they can be tied to the embedded audio, so the
normal audit independently samples the audio. The disposable download workspace
is removed after the report is saved in SQLite. This path also never requests a
Storyteller audiobook.

The test suite can exercise a disposable instance without committing secrets:

```bash
STORYTELLER_TEST_URL=http://host:8002 \
STORYTELLER_TEST_TOKEN=... swift test --filter StorytellerTests.testLiveServerWhenConfigured
```

Adding `STORYTELLER_TEST_READALOUD=/path/to/verified.epub` performs a real TUS
upload, verifies standalone ReadAloud classification, and deletes the test book.
