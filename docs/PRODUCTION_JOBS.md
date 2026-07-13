# Durable production jobs

Studio writes immutable `request.json`, mutable `state.json`, and a separate
queue/control file per job, then launches `jobs run <uuid>` as a child. The
child owns the job lease and a global Studio execution lock; it is the only
production authority. AppKit polls state and persists pause/cancel intent.

Queue order is a monotonic durable sequence. The queue has no artificial book
count limit, but imports are bounded to two and exactly one production child is
active. A failed job moves to **Needs Attention** and the next ready job starts.
Closing the window leaves work running. Quitting pauses the active child and
suspends the queue; a later app launch requires an explicit **Resume Queue**.

Stages are M4B preparation/synthesis/assembly/verification, optional ReadAloud
processing/transcription/markup/alignment/verification, then optional
Storyteller preflight/upload/reconciliation. Only one stage may run at once.
A verified product records its path, size, SHA-256, and verification time.

State writes use temporary files, `fsync`, atomic rename, and a directory
sync. A nonblocking `flock` prevents two runners. The app persists pause or
cancel intent before sending SIGINT. Pause leaves the job resumable; explicit
cancel makes it terminally cancelled. A retry clears only
unfinished stage status; verified products and resumable artifacts are reused
after their checksums pass.

The source EPUB hash, narration revisions/settings, section IDs, output paths,
ReadAloud settings, and delivery selection are fixed in the request. Changing
them creates a new job rather than mutating the meaning of existing work.
Sending products from a completed job therefore creates a delivery-only job
which references and re-verifies those files before using the normal
Storyteller preflight, upload, and reconciliation stages.

The edition catalog is separate from job history. It records source identity,
metadata, stable output layout, verified E/A/R products, and per-Storyteller
remote links/receipts. Corrupt job or catalog entries are reported individually
and do not hide valid entries. Catalog and scheduler state are atomically
replaced under cross-process locks.
