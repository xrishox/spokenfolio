# macos-tts-server

A self-contained OpenAI-compatible TTS server for the high-quality Siri voices
already installed on a Mac. It uses Siri's natural/neural models rather than
the lower-tier Accessibility voices, and serves Readest on iOS, Android,
Linux, Windows, or macOS.

## Requirements

- Apple Silicon
- macOS 15 or newer
- Xcode Command Line Tools (`xcode-select --install`)
- A Siri voice downloaded in System Settings

Apple does not publish the Siri framework used here. A macOS update can change
or remove it; the bridge validates the ABI and fails closed when it no longer
matches.

## Install

```bash
git clone https://github.com/xrishox/macos-tts-server.git
cd macos-tts-server
./scripts/install.sh
```

The script performs a pinned release build, creates and verifies
`/Applications/Siri TTS Server.app`, installs
`~/.local/bin/siri-tts-server`, and opens the menu-bar app. It uses an
available Apple Development/Developer ID certificate when possible and falls
back to ad-hoc signing for a local-only build.

On first install, use the menu's **Open Full Disk Access…** item and add/enable
`/Applications/Siri TTS Server.app`. Restart the app, then choose **Run Connection Test**.
That test synthesizes and decodes real negotiated audio; a health check alone
is not treated as success.

The default endpoint is `http://<mac-name>:8787`. It binds to the LAN without
authentication, so use it only on a trusted network or put an authenticated
TLS/VPN proxy in front of it.

## Verify

```bash
~/.local/bin/siri-tts-server doctor
TTS_SMOKE_NO_PLAYBACK=1 ./scripts/smoke-test.sh http://localhost:8787
```

The smoke test discovers a real Siri voice, synthesizes every advertised
fallback, verifies MIME/container structure, and decodes with `ffprobe` or
`afinfo` when available.

To reproduce Readest's ordered ten-request lookahead from another machine:

```bash
scripts/readest-queue-test.sh http://mac-hostname:8787
```

The test synthesizes 20 distinct sentences as Ogg Opus, consumes them in
reading order, and uses `ffprobe` for independent codec validation when it is
installed.

For a CLI-only foreground server:

```bash
~/.local/bin/siri-tts-server serve
```

For development:

```bash
swift test
HTTP_HOST=127.0.0.1 HTTP_PORT=18790 swift run siri-tts-server serve
```

## API and audio contract

| Endpoint | Purpose |
|---|---|
| `POST /v1/audio/speech` | OpenAI-shaped speech request |
| `GET /v1/audio/voices/all` | Rich installed Siri voice catalog |
| `GET /v1/audio/voices` | Flat Siri asset IDs |
| `GET /v1/models` | `tts-1` and `tts-1-hd` compatibility list |
| `GET /health/live` | Process liveness |
| `GET /health/ready` | Siri worker readiness |

`response_format` supports:

1. `opus`: mono 48 kHz Ogg Opus, 48 kbps constrained VBR;
2. `aac`: mono 48 kHz AAC-LC, 64 kbps, M4A/MP4 container;
3. `wav`: mono 48 kHz PCM16 WAV;
4. `pcm`: raw PCM16-LE for diagnostics.

Responses are buffered until synthesis and container finalization succeed, so
clients never receive a successful status with a truncated audio file.

## Configuration

Defaults work without a config file. To customize them, copy
[`config.example.json`](config.example.json) to:

```text
~/Library/Application Support/com.xrishox.macos-tts-server/config.json
```

`SIRI_TTS_CONFIG`, `HTTP_HOST`, and `HTTP_PORT` override the file for CLI runs.
The server deliberately caps itself at four model workers and twenty queued
requests.

## Readest

The Readest fork is based directly on the official
[`readest/readest`](https://github.com/readest/readest) repository:

```bash
git clone --branch custom-openai-tts-implementation \
  https://github.com/xrishox/readest.git
```

Only the OpenAI-compatible TTS client, its settings/UI hooks, and minimal
controller/type registration differ from upstream. Its private ordered window
fetches at most ten known sentences without changing Readest's global preload
behavior. See [`readest/README.md`](readest/README.md).

More detail: [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) and
[`docs/VOICES.md`](docs/VOICES.md).
