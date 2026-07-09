# macos-tts-server

Apple/macOS text-to-speech voices for the [Readest](https://readest.com) ebook reader on Linux.
The Mac synthesizes speech; Linux plays it. Two light forks, nothing else:

1. **Mac server** — [macos-speech-server](https://github.com/dokterbob/macos-speech-server)
   (OpenAI-compatible `POST /v1/audio/speech`, Apple system voices via AVSpeechSynthesizer)
   plus small patches in `server/patches/`: voice-discovery endpoints, full-identifier voice
   selection, and a TTS-only mode (`stt: engine: none`, no ASR model downloads).
2. **Readest fork** — an "OpenAI-compatible TTS" client (branch `custom-openai-tts`) with a
   configurable endpoint and voice picker, using Tauri's HTTP plugin so the desktop webview
   has no CORS/CSP issues. Built as our own AppImage.

The server is an ordinary HTTP service on `0.0.0.0:8787`; reach it over whatever network you
have (VPN, LAN — not this project's concern).

## Quick start

Mac (this repo):

```bash
server/install.sh                              # clone upstream, apply patches, build,
                                               # install LaunchAgent (auto-starts at login)
scripts/smoke-test.sh http://localhost:8787    # verify: voices, synthesis, latency
```

For high-quality voices, download Enhanced/Premium voices first — see `docs/VOICES.md`.

Linux (verify reachability, then set up Readest):

```bash
scripts/smoke-test.sh http://<mac-address>:8787   # needs curl + python3; plays via paplay
```

Readest: see `readest/README.md` for building the patched AppImage. In Readest's TTS
panel, set the endpoint URL to `http://<mac-address>:8787`, pick a voice, read.

## Layout

```
server/install.sh        Mac-side installer (clone + patch + build + LaunchAgent)
server/patches/          the entire server fork diff
server/speech-server.yaml server config (0.0.0.0:8787, avspeech, TTS-only)
scripts/smoke-test.sh    contract test against any server URL (macOS or Linux)
readest/                 Readest fork notes + AppImage build script
docs/ARCHITECTURE.md     wire contract and design notes
docs/VOICES.md           downloading Enhanced/Premium Apple voices
```

## Service management (Mac)

```bash
launchctl kickstart -k gui/$(id -u)/com.local.speech-server   # restart
launchctl bootout gui/$(id -u)/com.local.speech-server        # stop
tail -f ~/Library/Logs/speech-server/*.log                    # logs
```

Config lives at `~/.config/speech-server/speech-server.yaml` after install.

## Forks

- Server: https://github.com/xrishox/macos-speech-server (branch `voices-endpoint`)
- Readest: https://github.com/xrishox/readest (branch `custom-openai-tts`)

Both forks are personal and are never submitted upstream. The patch files in
`server/patches/` and `readest/patches/` remain the canonical source for the
install/build scripts, so the forks are convenience mirrors.
