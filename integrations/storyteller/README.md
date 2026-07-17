# Storyteller conditional-mutation integration

SpokenFolio can read an ordinary Storyteller v2 API, but deliberately refuses
uploads and identifier edits unless the server can make the precondition and
mutation atomic. `conditional-mutations.patch` adds that narrow protocol to
Storyteller; it does not change its public library model or alignment pipeline.

The patch is based on Storyteller commit
`a8c3173dc63be10f784ecb728b41b6c16f651d15` (2026-07-11). Apply it to a clean
checkout and build Storyteller normally:

```bash
git clone https://gitlab.com/storyteller-platform/storyteller.git
cd storyteller
git checkout a8c3173dc63be10f784ecb728b41b6c16f651d15
git lfs install --local
git lfs pull
git apply /path/to/spokenfolio/integrations/storyteller/conditional-mutations.patch
docker build -t spokenfolio/storyteller:conditional .
```

Git LFS is required: without `git lfs pull`, the alignment `.node` files remain
pointer text and Storyteller's dependency install fails. Configure the resulting
image with the same `/data`, secret, ports, and environment as the official
image. Replacing the image must not replace the data volume.

An authenticated request to `/api/v2/spokenfolio/capabilities` must return 204
with these headers:

```text
Storyteller-Conditional-Create: ifBookMissing-v1
Storyteller-Conditional-Replace: ifAssetMissing-v1
Storyteller-Identifier-Concurrency: etag-v1
```

The create and fill-missing checks run after Storyteller acquires its global
scan lock. Identifier GET returns an order-stable ETag; conditional PUT checks
`If-Match` and writes under that same lock. Conflicts return 409 for TUS
finalization and 412 for stale identifiers. On a future Storyteller upgrade,
rebase this patch, run its web build/lint, then repeat the live conflict tests
before advertising the headers.
