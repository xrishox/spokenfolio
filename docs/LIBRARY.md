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
evidence identifies it. A human Storyteller audiobook is preferred for
listening; it can be downloaded into the Book Library (as a download-only
human product, never synthesized and never sent back).

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

A receipt separates the SOURCE asset's identity (asset UUID, the size and
fingerprint the remote book record reports, and a stable source hash when one
is obtainable) from the REPRESENTATION the download endpoint served (its byte
count, digest, and content type). The two are not always the same object:
Storyteller zips a multi-file audiobook per request, so its served size and
hash describe an archive that exists only for that response. Proof requires
the source fields, so a receipt written before this distinction — one with no
recorded source size — counts as unverified and is refreshed by the next probe
rather than shown as proof. An asset whose hash is not comparable is recorded
as such, so the probe (which makes the server build and hash the entire
archive) is not repeated until that asset's identity changes.

Linked local and remote editions appear as one row. Local-only and remote-only
editions remain distinct until exact hash evidence or an explicit reviewed link
connects them. The user can unlink a mistaken association, assert narration
provenance, or correct an identifier. A remote identifier update is optional. Stock
Storyteller's identifier `PUT` replaces the whole relation set and has no
precondition, so it is last-write-wins: SpokenFolio reads, compares, writes,
and refetches, and reports an unexpected change afterward rather than
pretending the race was prevented.

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

## Deletion

Deletion is per-slot and, for a selection of any size, applies one global scope
— local, Storyteller, or both — to the checked slots. A pure planner computes a
per-book manifest shared by both surfaces and the executor, so the confirmation
can never diverge from what runs; a book that lacks a checked slot in the chosen
scope is skipped, never blocking the others.

A local product delete is digest-guarded (mirroring replacement) and staged:
the file is first moved aside to a same-volume quarantine name inside its own
folder, the database mutation runs, and only then are the bytes unlinked. If
the database refuses (a digest guard, a concurrent revision), the file is put
back exactly where the catalog still says it is; if the unlink fails after the
row is gone, that is reported as a failure with the path rather than counted as
a deletion. Concretely, the `local_product` row is removed — cascading its primary-product, dependency, and
ReadAloud audit rows — a TTS product additionally drops the delivery receipt it
no longer backs, and the file plus any Application-Support synthesis-timeline
sidecar are removed. Because an edition cannot exist without its mandatory,
unique source artifact, deleting the **source EPUB** deletes the whole
edition (every product, link, receipt, its owning work when unshared) and the
per-book folder. Any whole-book or human-narrated-content deletion requires an
explicit acknowledgment that is re-verified at execution.

Remote deletion is always per-asset (see [STORYTELLER.md](STORYTELLER.md)) and
never deletes a whole remote book; when the local product is kept, the stale
delivery receipt for that format is dropped so a vanished server asset stops
asserting a verified delivery. Deletions are idempotent (an already-absent slot
succeeds) and are refused per book while that book has active or queued
production, quality, or download work.

That refusal is enforced by `LibraryMutationCoordinator`, a process-wide actor
owned by `StudioServices`. Production runs, quality runs, mirror downloads, and
deletions all take an exclusive lease on the keys they touch — the local
edition, the library row, and the linked remote book — and hold it for the whole
operation. A deletion therefore holds its keys across the remote mutation, the
filesystem changes, and the database changes, so work cannot begin in the gap
between a check and the change it authorized; conversely a job or download
whose book is being deleted is refused or deferred rather than racing. Durable
queued work (a job the scheduler has not dispatched, an audit waiting in its
FIFO) holds no in-memory lease, so the coordinator additionally consults that
persistent state before allowing a deletion. The mirror's `activeRowIDs` remains
display-only; correctness comes from the leases.

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
