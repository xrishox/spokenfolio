# Build, installation, and operations

## Requirements and fresh install

- Apple Silicon, macOS 15+, Swift 6.2, and Xcode Command Line Tools
- Git/network access for initial dependency resolution
- A completely downloaded compatible Siri voice

```bash
git clone https://github.com/xrishox/macos-tts-server.git
cd macos-tts-server
./scripts/install.sh
```

The installer builds first, embeds required Swift compatibility libraries,
signs and verifies a staged app, then stops the installed server. It detects
processes even when launched through the CLI symlink. An active audiobook job
blocks installation; finish it or cancel it with SIGINT first. Replacement is
rollback-safe, and the CLI link is updated atomically.

## Siri voice and Full Disk Access

Download a voice under **Apple Intelligence & Siri → Siri Voice** and wait for
its preview to work. The project never downloads Apple assets itself.

If requested, grant Full Disk Access to:

```text
/Applications/Siri TTS Server.app
```

Quit and reopen the complete app after changing privacy access; restarting only
the embedded HTTP task is not sufficient. Then choose **Run Connection Test**.

## Signing

`scripts/build-app.sh` uses an explicit `CODE_SIGN_IDENTITY`, otherwise the
first usable Apple Development or Developer ID Application identity, otherwise
ad-hoc signing. If an installed identity cannot sign, the build fails instead
of silently changing identity and invalidating privacy grants.

Explicit ad-hoc build:

```bash
CODE_SIGN_IDENTITY=- ./scripts/install.sh
```

Inspect the installed bundle:

```bash
codesign --verify --deep --strict --verbose=2 "/Applications/Siri TTS Server.app"
otool -l "/Applications/Siri TTS Server.app/Contents/MacOS/siri-tts-server"
```

## Run and diagnose

```bash
open "/Applications/Siri TTS Server.app"       # normal menu app
siri-tts-server serve                           # foreground diagnostics
siri-tts-server doctor                          # assets and permissions
HTTP_HOST=127.0.0.1 HTTP_PORT=18790 swift run siri-tts-server serve
```

Do not run the menu app and foreground server on the same port. If Siri startup
fails, the gateway remains live in degraded mode: `/health/live` succeeds while
readiness/models/speech return a structured 503. Correct the problem and restart
the app; there is no automatic private-engine recovery.

Real HTTP verification:

```bash
TTS_SMOKE_NO_PLAYBACK=1 ./scripts/smoke-test.sh http://127.0.0.1:8787
```

The smoke test discovers a real voice, synthesizes Opus, AAC, and WAV, checks
their contracts, reads decoded frames through FFmpeg or `afconvert`, and removes
all temporary files.

Real audiobook verification:

```bash
./scripts/audiobook-smoke.sh "/absolute/or/relative/book.epub"
```

It plans and exports narration, creates at most two chapters with a dedicated
worker pool, validates both chapter systems and metadata, decodes the complete
M4B, and proves an identical run reuses its artifacts.

## Configuration

Copy `config.example.json` to:

```text
~/Library/Application Support/com.xrishox.macos-tts-server/config.json
```

| Field | Default | Valid values |
|---|---:|---|
| `host` | `0.0.0.0` | bind hostname/address |
| `port` | `8787` | 1–65535 |
| `defaultVoice` | automatic | canonical ID or unambiguous alias |
| `maxWorkers` | `4` | 1–4 |
| `maxQueuedRequests` | `20` | 0–20 |
| `requestDeadlineSeconds` | `25` | 1–120 |

The nested `audiobook` object controls bitrate, pauses, title announcements,
worker count, voice, and work directory; see [AUDIOBOOKS.md](AUDIOBOOKS.md).

Environment overrides:

- `SIRI_TTS_CONFIG`: alternate config file
- `HTTP_HOST`, `HTTP_PORT`: CLI bind override; invalid ports fail startup
- `CODE_SIGN_IDENTITY`: signing identity (`-` explicitly requests ad-hoc)
- `SIRI_TTS_INSTALL_DIR`: alternate app destination
- `SIRI_TTS_NO_OPEN=1`: install without launch
- `TTS_SMOKE_NO_PLAYBACK=1`: decode without audible playback

## Update and inspect

```bash
git pull --ff-only
swift test
./scripts/install.sh
TTS_SMOKE_NO_PLAYBACK=1 ./scripts/smoke-test.sh http://127.0.0.1:8787
```

After any macOS update, rerun `doctor` and real synthesis because the Apple API
is private.

```bash
ps -axo pid,ppid,state,etime,%cpu,%mem,command | grep '[s]iri-tts-server'
lsof -nP -iTCP:8787 -sTCP:LISTEN
```

Normal HTTP operation has one gateway and up to four workers. A default
audiobook adds up to eight workers; configured combined maximum is twenty.
Pools and crash circuits are independent, but hardware contention remains.

## Network and troubleshooting

The default listener is unauthenticated plain HTTP on reachable interfaces.
Use a trusted LAN or VPN/authenticated TLS proxy. Rate limiting does not provide
access control.

- **Full Disk Access:** ensure the current installed signed app—not `dist` or
  `.build`—is enabled, then quit and reopen it.
- **No voices:** wait for download completion, run `doctor`, and confirm the
  graph is 48 kHz compatible.
- **`engine_unavailable` after update:** do not weaken ABI checks; inspect the
  private bridge deliberately.
- **Device codec failure:** server decode proves the file, not the device
  WebView. Readest should probe Opus then AAC.
- **`429`:** reduce competing clients; do not raise validated safety maxima
  without measuring memory and model behavior.

## Uninstall

```bash
osascript -e 'tell application id "com.xrishox.macos-tts-server" to quit' 2>/dev/null || true
rm -rf "/Applications/Siri TTS Server.app"
rm -f "$HOME/.local/bin/siri-tts-server"
```

Optionally remove the application-support directory and stale Full Disk Access
entry. Never remove Apple voice assets as part of project cleanup.
