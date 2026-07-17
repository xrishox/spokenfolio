# Storyteller delivery

Settings → Storyteller connects through Storyteller’s device-authorization
endpoints. The cancellable authorization sheet shows the approval code and URL;
the resulting token is saved in macOS Keychain. Connection settings show the
account, origin, permissions, health, and safe-mutation capability. Server URLs
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
The approved account must have `bookList`; creating a remote book also needs
`bookCreate`, and filling a missing format on an existing book needs
`bookUpdate`. SpokenFolio checks these permissions before transfer.

Library refresh remains available against an unmodified Storyteller server.
Mutation additionally requires `/api/v2/spokenfolio/capabilities` to advertise
all three reviewed contracts:

- `ifBookMissing-v1` makes create-if-absent atomic with Storyteller's scan lock;
- `ifAssetMissing-v1` makes fill-if-missing atomic with replacement; and
- `etag-v1` protects identifier edits with `If-Match`.

If any capability is absent, the connection is read-only. SpokenFolio does not
fall back to a preflight followed by an unsafe write, because another client or
scanner could change the book between those operations.
Deployment and rebase instructions for the small server-side patch are in
[`integrations/storyteller`](../integrations/storyteller/README.md).

A job may send any selected combination of the untouched source EPUB, verified
AAC M4B, and verified ReadAloud EPUB. Uploads use TUS with bounded chunks,
persisted offsets, source-size/date checks before and throughout transfer,
bearer authentication, and
same-origin upload locations. Corrupt resume state stops for review rather than
starting a second upload; JSON/error responses are size-bounded. Authorization is never followed through an HTTP
redirect.

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
SHA-256 matches the selected local product. Otherwise delivery stops as a
conflict and never overwrites the asset. Upload finalization sends the matching
conditional metadata, so this guarantee still holds if remote state changes
after preflight.

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

For a remote human audiobook, **Start ReadAloud** first shows the candidate and
requires explicit confirmation before asking Storyteller to align it. SpokenFolio
can download a remote EPUB for TTS backfill, but never downloads a remote
audiobook.

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
