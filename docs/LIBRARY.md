# Library and completeness

The Library is the persistent view of editions known locally and on one selected
Storyteller connection. `LibraryKit` owns its SQLite database at
`~/Library/Application Support/com.xrishox.spokenfolio/library.sqlite`; job files remain a
separate execution record and Storyteller bearer tokens remain in Keychain.

## Identity and state

A work is the abstract title; an edition is a particular published text. Local
products, remote links, identifiers, and completeness attach to an edition so a
translation, revision, or abridgement cannot be silently folded into another.
Exact asset hashes are automatic identity evidence. ISBN, ASIN, DOI, title, and
author are review evidence unless a saved user assertion already establishes the
link. Identifier edits are assertions in the catalog and do not rewrite the
source EPUB.

Each Storyteller refresh writes a complete, connection-scoped generation in one
transaction. Books absent from a successful generation are tombstoned; a failed
refresh keeps the last snapshot visibly stale. Disconnecting a server retains
its history. The selected server alone contributes remote state to the Library
display.

## Universal level

Every edition uses the same best-known 0–10 scale. It is a status measurement,
not a per-book goal or task list.

| Level | Meaning |
|---:|---|
| 0 | No usable text or audio, or known broken state |
| 1 | A readable EPUB exists on one side |
| 2 | The same edition's EPUB exists locally and remotely |
| 3 | An audiobook exists, but no coherent complete package does |
| 4 | A ReadAloud or all E/A/R components exist, but coherence is incomplete or unknown |
| 5 | A verified local TTS EPUB/audiobook/ReadAloud package exists |
| 6 | A verified remote E/A/R package exists; narration provenance is unknown |
| 7 | Level 6 with remote TTS provenance |
| 8 | Level 6 with remote human narration |
| 9 | Level 8 plus local EPUB and TTS audiobook fallback |
| 10 | Level 8 plus a complete verified local TTS E/A/R package |

E/A/R means source EPUB, audiobook, and ReadAloud EPUB. Locally, “verified” means
each product passed its producer verification, retains its recorded size, has
not been modified since verification, and has matching source/alignment dependency
hashes. Older products without that proof remain usable but do not receive a
coherent-package score. Remotely, three ready assets are not sufficient by
themselves: coherence requires matching delivery receipts or an explicit user
provenance/coherence assertion.
Unknown remote narration stays unknown until the user or durable production
evidence identifies it. A human Storyteller audiobook is preferred for listening;
SpokenFolio never downloads it.

Local M4B products retain their exact Siri synthesis provenance. The Library
shows the backend/model, canonical voice and asset revision, and macOS and
private-framework versions recorded by the synthesis child. Legacy products
without runtime provenance remain usable and are labeled as such.

## Reconciliation and actions

Each cataloged edition owns one folder in the Book Library
(`<Title - Author>/` with self-identifying EPUB/M4B/ReadAloud files — see
[AUDIOBOOKS.md](AUDIOBOOKS.md)); nothing but product files appears there.

On the Storyteller-facing views, each slot chip carries a border showing
what is KNOWN to be on the linked server book: a solid border means a
delivery or mirror receipt proves the server copy is identical to the
current local file (re-validated against live asset identity, size, and
fingerprint on every refresh), a dashed border means a file is there and
its slot attribution is certain, and no border means absent or unknown —
nothing is guessed. **Verify Storyteller Files** rechecks on demand with
full server-side hash probes and rewrites the receipts to match reality.

Linked local and remote editions appear as one row. Local-only and remote-only
editions remain distinct until exact hash evidence or an explicit reviewed link
connects them. The user can unlink a mistaken association, assert narration
provenance, or correct an identifier. A remote identifier update is optional and
uses `If-Match`; a conflict forces refresh and review.

The Library is a searchable, sortable native table with a selected-book
inspector. Rows contain state rather than embedded action toolbars. Normal macOS
Command-click, Shift-range, and Command-A selection is supported. Visible bulk
buttons record Human, TTS, or Unknown for every selected ready Storyteller
ReadAloud in one database transaction; mixed selections with ineligible rows are
rejected rather than partially updated.

The same selection can enqueue quality checks for local ReadAlouds,
Storyteller ReadAlouds, or every available copy. Those checks use the durable
FIFO described in [READALOUD.md](READALOUD.md).

Reprocessing an audiobook is an explicit digest-guarded product replacement.
If its existing ReadAloud is not regenerated at the same time, the retained
alignment dependency no longer matches the new M4B and coherence drops until a
new ReadAloud is produced. Receipts for the superseded local format are removed.
An existing ReadAloud can likewise be recreated in place (for example with
different speech-recognition settings) as a digest-guarded ReadAloud-only job.

Remote-only rows with an EPUB support backfill through the Process sheet: the
source step downloads only the EPUB, and the selected steps create normal
durable full-pipeline jobs that can return the verified local E/A/R package to
the same remote book. Processing is FIFO and restartable; selection does not
bypass ordinary job verification.

The first launch after upgrade atomically migrates the legacy JSON catalog into
SQLite under a migration lock. The JSON is retained as recovery input but is no
longer written. Migration validates and checkpoints a temporary database before
renaming it; malformed legacy input stops migration instead of creating a
partial catalog.

## ReadAloud quality history

Each quality run targets exactly one local product, one connection/book/asset
triple, or one standalone absolute path. SQLite stores its queued/running/final
lifecycle, bounded progress, artifact and reference hashes, analyzer/tool/model
identity, verdict, evidence adequacy, metrics, and bounded findings. Re-running
an audit appends history rather than replacing the prior conclusion. New local
ReadAloud production records its pre-publication quality report against the
catalog product; remote results remain scoped to the exact Storyteller
connection and asset UUID.

The ReadAloud Quality inventory shows one row for each concrete artifact,
including unchecked artifacts. It chooses the newest completed report that
still matches the artifact/reference hashes and current analyzer policy. A
newer execution failure is retained in history but cannot shadow valid semantic
evidence.
