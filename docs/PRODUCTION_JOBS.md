# Durable production jobs

Production writes immutable `request.json`, mutable `state.json`, and
`control.json` inside each job directory. Queue sequence and disposition live
in each job's control file; the scheduler's suspended state and next sequence
live once in the global `scheduler.json`. It then launches `jobs run <uuid>` as
a child. The child owns the job lease and a global production execution lock;
it is the only production authority. AppKit polls state and persists
pause/cancel intent.

Queue order is a monotonic durable sequence, and waiting jobs can be
reordered (drag, or explicit move actions) on both surfaces; the scheduler
rewrites the durable sequence and refuses a stale order if the queue changed
mid-drag. The queue has no artificial book count limit, but imports are
bounded to two and at most one heavyweight production child is active. A
second, delivery-only child may run alongside it: a Storyteller send of
already-finished products is network I/O and does not wait behind synthesis.
A delivery job still waits while any other job for the same book is running
or dispatchable ahead of it, so a queued ReadAloud creation always finishes
before its book is sent. A failed job moves to **Needs Attention** and the
next ready job starts.
Closing the window leaves work running. Quitting pauses the active child and
suspends the queue; a later app launch requires an explicit **Resume Queue**,
which also revives interrupt-paused work (quit, Pause Now, preemption) at its
old queue position. **Run This Book Next** preempts safely: the chosen book
moves to the front, the running book pauses at a chapter checkpoint (pause
intent is persisted before any signal, and the stop window outlasts the
child's own graceful-stop escalation), and the paused book re-queues directly
behind the chosen one. Resume revalidates identity and reuses completed
chapters, so preemption costs at most the in-flight chapter.

Stages are M4B preparation/synthesis/assembly/verification, optional ReadAloud
processing/transcription/markup/alignment/verification, then optional
Storyteller preflight/upload/reconciliation. Only one stage may run at once.
A verified product records its path, size, SHA-256, and verification time. M4B
state additionally records the narration runtime actually selected by the child: backend/model, canonical qualified voice, requested pace/expressivity, revisions, macOS version/build, private-framework metadata, and (for expressive synthesis) confirmed adapter/resource identity.
ReadAloud production synthesizes natural sentences as exact units and derives
alignment timing from the digest-bound synthesis timeline without ASR. Its
publication gate checks bound timeline coverage, structure, content identity,
timing, full audio decode, and EPUB conformance. A material structure,
coverage, identity, or timing finding—or inadequate evidence—prevents the destination commit; only
compatibility advisories may pass with a warning. Full embedded-audio decode
and final EPUBCheck 5.3.0-or-newer conformance are separate mandatory
compatibility axes, run before the same atomic publish, and the results are
attached to the catalog product.

Every new managed request binds an already normalized, EPUBCheck-accepted EPUB
3 source. Legacy catalog sources are upgraded by Calibre under the edition,
library-row, and remote-book mutation lease before the immutable request is
assembled; the file swap and SQLite source-identity update are digest-guarded
and rollback together. At child startup, the exact request-bound digest is
checked again with EPUBCheck before synthesis, ReadAloud processing, or
Storyteller preflight. An older immutable request that still names EPUB 2 is
held for attention rather than silently changing its source identity.

State reads and writes apply the same schema, stage, fraction, checksum, and
unique-product validation. Writes use temporary files, `fsync`, atomic rename,
and a directory sync. A nonblocking close-on-exec `flock` prevents two runners.
The app persists pause or cancel intent before sending SIGINT and escalates an
unresponsive child through SIGTERM to SIGKILL. Pause leaves the job resumable; explicit
cancel makes it terminally cancelled. A retry clears only
unfinished stage status; verified products and resumable artifacts are reused
after their checksums pass. Task cancellation is checked before the
missing-`.finished` protocol guard, so a cooperative pause/cancel is never
misreported as a corrupt child exit. The runner drains both child pipes
through exit, and final diagnostics tolerate a parent that already closed
stderr.

Resumable TUS checkpoints use the same synchronized atomic-state writer. A
malformed checkpoint stops for review instead of silently starting a duplicate
upload.

The source EPUB hash, backend ID, model ID, qualified voice, pace/expressivity presets, narration revisions/settings, section IDs, output paths, ReadAloud settings, and delivery selection are fixed in the request. Schema 6 binds newly created ReadAlouds to exact sentence synthesis timing and rejects production ASR; schema 5 and older jobs retain their persisted interpretation. New Expressive requests store one worker; the executor also clamps older immutable Expressive requests that stored up to eight, recording a warning rather than rewriting the request. The job child forwards the complete effective selection to `audiobook create`, including `--sentence-units` for new ReadAloud production, and the chapter fingerprint includes the distinct format identity. Changing any input creates a new job rather than mutating the meaning of existing work.
An explicit reprocess request is still a new immutable job, but carries the
expected old product digest and replacement authorization. Fresh synthesis is
forced; the output swap and SQLite replacement both fail if that digest is no
longer current. Receipts for a superseded local format are cleared.
Schema-1 and schema-2 requests that predate explicit transcript fields retain
their historical Whisper-tiny identity. They are not rewritten or allowed to
reuse schema-6 sentence artifacts.
Sending products from a completed job therefore creates a delivery-only job
which references and re-verifies those files before using the normal
Storyteller preflight, upload, and reconciliation stages.

The SQLite edition catalog is separate from job history. It records source
identity, metadata, stable output layout, verified E/A/R products, and
connection-scoped remote links/receipts. Each verified product is cataloged as
soon as it is committed, not once at job end: the M4B lands in the catalog
immediately after synthesis, before the potentially many-hour ReadAloud stage
begins. A committed audiobook therefore can never be left on disk untracked by
a later pause or cancel—once the child has published a complete M4B, the job
records and catalogs it before honoring any pending cancel, and the cancel is
observed at the next stage boundary. Cataloging is idempotent, so the
end-of-job reconcile that adds the ReadAloud product re-reconciles the M4B
harmlessly. Corrupt job or control entries fail closed, are reported
individually, and do not hide valid entries. Catalog changes use SQLite
transactions; scheduler and per-job JSON changes use atomic replacement under
cross-process coordination.
