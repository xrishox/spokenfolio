# Storyteller delivery

Studio connects through Storyteller’s device-authorization endpoints. The user
approves the displayed code in Storyteller; the token is saved in macOS
Keychain. Server URLs must be HTTP(S) origins. HTTP is suitable only on a
trusted network; HTTPS is preferred.
Saved connection metadata is not treated as an authenticated session: Studio
validates the token against the server before offering delivery. If a server
restore or restart revokes it, Studio reports the expired session and offers
**Reconnect…**.
The origin entered in Studio is authoritative for device approval links. The
client preserves the returned approval path and code but rebases links that
contain an internal container/bind address onto that configured origin.
The approved account must have `bookList`; creating a remote book also needs
`bookCreate`, and filling a missing format on an existing book needs
`bookUpdate`. SpokenFolio checks these permissions before transfer.

A job may send any selected combination of the untouched source EPUB, verified
AAC M4B, and verified ReadAloud EPUB. Uploads use TUS with bounded chunks,
persisted offsets, source-size/date checks, bearer authentication, and
same-origin upload locations. Authorization is never followed through an HTTP
redirect.

Before transfer the client lists the library. Identity precedence is a saved
connection-specific link, an exact asset hash when the server supports the
bounded one-byte probe, a checksum-valid ISBN/ASIN/DOI, then reviewable exact or
similar title/author metadata. Only validated links, hashes, and identifiers
auto-attach; metadata alone never auto-merges. Ambiguous
matches offer **Attach Existing** or **Create Separate**; the latter records the
rejected candidates so the same prompt does not recur.

A linked book only fills missing formats. An occupied format is skipped only
when a saved receipt still matches the remote asset identity or its complete
SHA-256 matches the selected local product. Otherwise delivery stops as a
conflict and never overwrites the asset. Older servers without the one-byte
hash probe still support identifier and manual-review matching.

Storyteller may replace an upload UUID hint with its own book UUID, so the
assigned UUID is discovered after the first product and stored in job and
catalog state. Reconciliation requires every selected asset to appear and saves
its remote asset ID, size, fingerprint, and available hash before success.

On Studio's Create screen, choose a server and any products to send after local
production. Use **Library → Send…** to deliver an existing product later. This
creates a delivery-only job that re-verifies the selected files; it does not
mutate or rerun completed synthesis.

The test suite can exercise a disposable instance without committing secrets:

```bash
STORYTELLER_TEST_URL=http://host:8002 \
STORYTELLER_TEST_TOKEN=... swift test --filter StorytellerTests.testLiveServerWhenConfigured
```

Adding `STORYTELLER_TEST_READALOUD=/path/to/verified.epub` performs a real TUS
upload, verifies standalone ReadAloud classification, and deletes the test book.
