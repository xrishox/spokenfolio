# Readest integration

Readest is a separate repository:

- upstream: `https://github.com/readest/readest`
- maintained fork: `https://github.com/xrishox/readest`
- branch: `custom-openai-tts-implementation`

The server imports no Readest code. The fork keeps Siri behavior in dedicated
OpenAI-compatible TTS modules, tests, settings, and narrow controller hooks.
Two AppImage build-helper files are an explicit packaging exception.

## Configure

In Readest's **OpenAI-Compatible TTS** settings, enter
`http://<mac-host>:8787`, leave the key empty for the trusted-LAN deployment,
select `tts-1`, press **Test**, then choose a canonical Siri voice ID.

The connection test calls models and voices, synthesizes real speech, and
decodes it through the runtime codec path. Native shells use platform HTTP;
browser-hosted HTTPS builds may reject plain HTTP because of mixed content or
CORS.

## Codec contract

The ordered ladder is:

```text
Ogg Opus 64 kbps → AAC-LC/M4A 64 kbps → unsupported
```

Readest probes embedded valid files through `AudioContext.decodeAudioData`,
then pins the first working format for the endpoint session. If a real speech
response cannot decode, it evicts those bytes and retries the same sentence on
the next codec.

DNS, connection, timeout, authentication, rate/queue, transient server, and
invalid speech/voice errors do not trigger codec downgrade because they do not
prove decoder incompatibility. There is no automatic WAV or MP3 rung.

## Ordering and mobile buffer

Foreground synthesis uses speed `1.0`; playback speed is local, so cached bytes
remain reusable. A ten-wide ordered window may fetch concurrently but exposes
results to decode only by source position.

After the first audible sentence pins the codec, detached Foliate traversal
collects future sentence marks across chapters without moving the live cursor.
The horizon ends at 120 estimated playback seconds or 50 sentences.

One priority task pool admits ten active fetches. Background resilience work
has at most nine active loads, leaving capacity for playback. Foreground work
drains first; admission within each priority stays source ordered. Completions
and cached bytes may arrive out of order, but decode, highlights, and playback
do not.

The scheduler continuously replenishes the tail as speech becomes audible.
Failures retry after 1, 2, 5, then repeated 10-second delays while the candidate
remains needed. Navigation or invalidation cancels stale speculative work.

## Volatile cache

Compressed responses share one process-memory LRU cache:

- 64 entries;
- 64 MiB;
- ten-minute sliding TTL with proactive expiry;
- previous ten consumed sentences retained for short replay.

Each decode receives a copy because WebKit may detach an `ArrayBuffer`. Keys
include endpoint, API-key fingerprint, model, voice, text, format, and speed;
the key itself does not contain the API key. There is no IndexedDB,
localStorage, filesystem, Tauri media file, or server-side audio cache.

## Fork boundary and rebase

Principal custom modules are under `apps/readest-app/src/services/tts/` plus
`libs/openaiTTS.ts`. Narrow integration points are `TTSController`, the reader
TTS hook, settings, types, and their mirrored tests. Do not change global
preload behavior or unrelated speech clients.

```bash
git remote add upstream https://github.com/readest/readest.git
git fetch upstream origin
git checkout custom-openai-tts-implementation
git rebase upstream/main

CI=1 NODE_OPTIONS=--no-experimental-webstorage pnpm test
pnpm lint
pnpm format:check
pnpm --filter @readest/readest-app build
```

Review the surface with:

```bash
git diff --name-only upstream/main...HEAD
```

Expected exceptions outside TTS/settings source are the fork's local AppImage
documentation and repair script. Push a rebase only with
`git push --force-with-lease`.

## Verification

Server `doctor` plus `scripts/smoke-test.sh` proves the Mac private API and
containers. Readest unit tests cover codec fallback, task priority, ordered
consumption, cross-chapter lookahead, retry/invalidation, and cache bounds. A
device connection test proves the actual WebView decoder and network path.

During an outage, playback lasts as long as already completed future bytes.
The server has no session to recover; Readest resumes background requests when
connectivity returns.
