# Readest OpenAI-compatible Siri TTS client

Official upstream: https://github.com/readest/readest

Fork: https://github.com/xrishox/readest

Branch: `custom-openai-tts-implementation`

The branch is rebased directly on official `upstream/main`. Its changes are
limited to new OpenAI-compatible TTS client/transport/codec/window files,
their tests, a dedicated settings block, and the minimum controller/types/UI
registration needed to expose the voices. It does not change Readest's global
preload count or the behavior of Edge, native, or browser speech clients.

## Behavior

- Valid runtime decode probes select Opus, AAC/M4A, then WAV.
- The working codec is pinned per endpoint session.
- Decode/explicit-format failures retry the same sentence on the next codec.
- Auth, rate limits, and network failures never trigger codec downgrade.
- One client-local ordered window admits current plus nine known sentences.
- Fetches complete concurrently; decode, highlighting, and playback stay in
  book order and cancel as one generation.
- The Settings connection test requires real synthesis and audio decode.

## Build

Use Readest's normal platform instructions after cloning the fork branch:

```bash
git clone --branch custom-openai-tts-implementation \
  https://github.com/xrishox/readest.git
cd readest
pnpm install
pnpm --filter @readest/readest-app setup-vendors
```

For a Linux AppImage, this repository also provides:

```bash
./readest/build-appimage.sh
```

## Configure

In Readest's TTS settings, enter `http://<mac-name>:8787` under
**OpenAI-Compatible TTS**. Leave the API key empty for the default trusted-LAN
server. Press **Test**; success reports the decoded codec and voice count.
Then choose the full Siri asset ID in Read Aloud.

## Rebase maintenance

```bash
git remote add upstream https://github.com/readest/readest.git
git fetch upstream
git rebase upstream/main
pnpm --filter @readest/readest-app test:pr:web:unit
pnpm --filter @readest/readest-app lint
pnpm format:check
git push --force-with-lease origin custom-openai-tts-implementation
```

`git diff --name-only upstream/main...HEAD` should remain confined to
`apps/readest-app/src` TTS/settings integration and its tests.
