# macos-tts-server

Use installed high-quality Siri voices as an OpenAI-compatible TTS endpoint for
[Readest](https://readest.com). The Mac synthesizes and compresses each
sentence; Readest runs on iOS, Android, Linux, Windows, or macOS and negotiates
the best format its own audio stack can decode.

This repository keeps two intentionally small patch stacks:

1. [dokterbob/macos-speech-server](https://github.com/dokterbob/macos-speech-server)
   gains installed Siri voice discovery, a guarded private-framework bridge,
   Ogg Opus/AAC/WAV output, voice endpoints, and a TTS-only mode.
2. [readest/readest](https://github.com/readest/readest) gains the existing
   custom OpenAI-compatible TTS client, runtime codec negotiation, and an
   ordered ten-request sentence window.

The patch files in `server/patches/` and `readest/patches/` are canonical. The
personal forks are convenience mirrors and are not submitted upstream.

## What it does

- Uses already-installed Siri **natural** and **neural premium** assets instead
  of the lower-tier Accessibility/`AVSpeechSynthesizer` voices.
- Defaults to 48 kbps constrained-VBR Opus in an Ogg container.
- Falls back at runtime to 64 kbps AAC-LC in M4A/MP4, then PCM16 WAV.
- Keeps up to ten sentence fetches in flight while preserving exact playback
  and highlighting order.
- Caps the expensive private engines at four resident voices, four active
  syntheses, and twenty queued requests.
- Leaves authentication and network transport policy to the operator.

## Quick start

First select the desired Siri voice in macOS System Settings and wait for its
download to finish; see [docs/VOICES.md](docs/VOICES.md).

On the Mac:

```bash
server/install.sh
scripts/smoke-test.sh http://localhost:8787
```

The smoke test discovers an installed voice, synthesizes Opus, AAC, and WAV,
checks the MIME/container contract, and independently decodes each file with
`ffprobe` or `afinfo` when available.

For Readest, apply/build the patch stack on the target platform as described in
[readest/README.md](readest/README.md). In its TTS settings, choose
**OpenAI-Compatible TTS**, set the endpoint to
`http://<mac-address>:8787`, and select a Siri asset id.

## Layout

```text
server/install.sh          clone pinned server upstream, apply patches, install LaunchAgent
server/patches/            complete server fork diff
server/speech-server.yaml  0.0.0.0:8787, Siri TTS, STT disabled
scripts/smoke-test.sh      live API/container/decoder contract test
readest/build-appimage.sh  reproducible Linux AppImage build from the Readest patches
readest/patches/           complete Readest fork diff from official upstream
docs/ARCHITECTURE.md       codecs, queueing, fallbacks, and safety limits
docs/VOICES.md             install, list, and verify Siri assets
```

## Service management

```bash
launchctl kickstart -k gui/$(id -u)/com.local.speech-server
launchctl bootout gui/$(id -u)/com.local.speech-server
tail -f ~/Library/Logs/speech-server/*.log
```

The installed config lives at
`~/.config/speech-server/speech-server.yaml`. The upstream installer preserves
an existing config; after upgrading an older installation, set `tts.engine` to
`siri` and add the `tts.siri` limits shown in
[`server/speech-server.yaml`](server/speech-server.yaml) before restarting.

## Private API warning

Apple does not publish or support `SiriTTSService.framework` for third-party
use. The server validates its expected Objective-C ABI and only reads local
assets, but a macOS update may still break synthesis. Do not expose this plain
HTTP service to an untrusted network, and keep the pinned patch stack plus smoke
test when updating macOS.

## Repositories

- Server upstream: https://github.com/dokterbob/macos-speech-server
- Server convenience fork: https://github.com/xrishox/macos-speech-server
- Readest upstream: https://github.com/readest/readest
- Readest convenience fork: https://github.com/xrishox/readest
