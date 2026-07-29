# Build, installation, and operations

Run `./scripts/check.sh` for the repeatable local verification set. Set
`CHECK_BUNDLE=1` to include an ad-hoc signed release bundle. Real Siri and
real-book smoke tests remain separate because CI cannot prove the private API.

## Requirements and fresh install

- Apple Silicon, macOS 26+, Swift 6.2, and Xcode Command Line Tools
- Git/network access for initial dependency resolution
- A completely downloaded compatible Siri voice
- macOS 27+ for optional Siri Expressive/FM voices; macOS 26 remains supported by `siri-private`

```bash
git clone https://github.com/xrishox/spokenfolio.git
cd spokenfolio
./scripts/install.sh
```

The installer first recovers any interrupted swap, then builds, embeds required
Swift compatibility libraries, removes developer-toolchain runtime paths,
signs and verifies a staged app, and stops the installed server. It detects
processes even when launched through the CLI symlink. Active audiobook or
ReadAloud production blocks installation; pause or finish it first. Replacement
is rollback-safe, and the CLI link is updated atomically.
An interrupted install backup is restored when its destination is absent. If
both exist, the installer preserves both and stops for review instead of deleting either.

An upgrade from the former Siri TTS Server identity moves owned application
support and window state transactionally, rewrites owned JSON and SQLite paths,
and requires the installed migration command itself to exit successfully before
committing the app swap. It refuses
split old/new data roots and leaves external source/output paths unchanged.
Because the bundle identity changes, grant Full Disk Access again and re-enable
Launch at Login in Settings. A saved Storyteller token is copied lazily on its
first use so macOS can show a normal Keychain prompt; the legacy token is kept
until the new copy verifies. Do not manually move either support directory.

## Siri voice and Full Disk Access

Download a voice under **Apple Intelligence & Siri → Siri Voice** and wait for
its preview to work. The project never downloads Apple assets itself.

If requested, grant Full Disk Access to:

```text
/Applications/SpokenFolio.app
```

Quit and reopen the complete app after changing privacy access; restarting only the embedded HTTP task is not sufficient. Full Disk Access applies to installed Siri assets; the Golden Gate expressive backend uses the Siri daemon and does not authorize asset changes. Then open **TTS Server**, select a model/voice, enter text, and choose **Test & Play**.

## Signing

`scripts/build-app.sh` uses an explicit `CODE_SIGN_IDENTITY`, otherwise the
first discovered Apple Development or Developer ID Application identity, and
uses ad-hoc signing only when none is found. If a selected identity cannot sign, the build fails instead
of silently changing identity and invalidating privacy grants.

Explicit ad-hoc build:

```bash
CODE_SIGN_IDENTITY=- ./scripts/install.sh
```

Inspect the installed bundle:

```bash
codesign --verify --deep --strict --verbose=2 "/Applications/SpokenFolio.app"
otool -l "/Applications/SpokenFolio.app/Contents/MacOS/spokenfolio"
codesign -d --entitlements :- "/Applications/SpokenFolio.app"
```

The app uses hardened runtime but deliberately has no App Sandbox entitlement. App Sandbox blocks the implemented `com.apple.sirittsd` expressive path; adding it is an architectural change, not a packaging hardening toggle. Private APIs remain isolated in bounded child processes.

## EPUB tools

SpokenFolio requires official EPUBCheck for imports, production, ReadAloud
verification, quality audits, and Storyteller delivery. Calibre is required
only when a legacy EPUB 2 source must be upgraded; ordinary EPUB 3 books bypass
it. On Homebrew systems:

```bash
brew install epubcheck
brew install --cask calibre
```

Settings → ReadAloud reports both tools and their versions. `EPUBCHECK_PATH`
and `CALIBRE_EBOOK_CONVERT_PATH` select explicit executables. SpokenFolio does
not implement a lightweight relabeler: Calibre performs the conversion and
EPUBCheck independently proves the output has no fatal or error-level
specification findings.

## Run and diagnose

```bash
open "/Applications/SpokenFolio.app"       # normal desktop app
spokenfolio serve                           # foreground diagnostics
spokenfolio doctor                          # assets and permissions
HTTP_HOST=127.0.0.1 HTTP_PORT=18790 swift run spokenfolio serve
```

Do not run the desktop app and foreground server on the same port. If Siri startup
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

For deliberate throughput experiments, use `scripts/bench-tts.sh` for installed Siri or `swift run -c release golden-gate-tts-bench --help` for the expressive backend. Benchmark code is not part of the installed server's public command tree.

## Configuration

Copy `config.example.json` to:

```text
~/Library/Application Support/com.xrishox.spokenfolio/config.json
```

| Field | Default | Valid values |
|---|---:|---|
| `host` | `0.0.0.0` | bind hostname/address |
| `port` | `8787` | 1–65535 |
| `defaultVoice` | automatic | legacy Siri canonical ID or unambiguous alias |
| `defaultTTS` | `null` | qualified backend/model/voice object with optional `1...5` presets |
| `maxWorkers` | `4` | 1–4 |
| `maxQueuedRequests` | `20` | 0–20 |
| `requestDeadlineSeconds` | `25` | 1–120 |

The JSON configuration file must be a regular file no larger than 1 MiB. A macOS-27+ expressive default is:

```json
"defaultTTS": {
  "backendID": "siri-fm",
  "modelID": "siri-expressive",
  "voiceID": "en-US-F",
  "pacePreset": 3,
  "expressivityPreset": 3
}
```

`defaultTTS` wins over `defaultVoice` and seeds the server plus desktop/WebUI production selectors. Configuring an unavailable expressive default on macOS 26 fails startup instead of silently changing models.

The nested `audiobook` object controls bitrate, pauses, title announcements,
worker count, voice, and work directory; see [AUDIOBOOKS.md](AUDIOBOOKS.md).

Environment overrides:

- `SPOKENFOLIO_CONFIG`: alternate config file
- `HTTP_HOST`, `HTTP_PORT`: CLI bind override; invalid ports fail startup
- `CODE_SIGN_IDENTITY`: signing identity (`-` explicitly requests ad-hoc)
- `SPOKENFOLIO_INSTALL_DIR`: alternate app destination
- `SPOKENFOLIO_NO_OPEN=1`: install without launch
- `FFMPEG_PATH`: explicit ffmpeg executable for ReadAloud work
- `TTS_SMOKE_NO_PLAYBACK=1`: decode without audible playback
- `STORYTELLER_TEST_URL`, `STORYTELLER_TEST_TOKEN`: opt into live API tests
- `STORYTELLER_TEST_READALOUD`: opt into the temporary live upload/delete test

## Update and inspect

```bash
git pull --ff-only
swift test
./scripts/install.sh
TTS_SMOKE_NO_PLAYBACK=1 ./scripts/smoke-test.sh http://127.0.0.1:8787
```

After any macOS update, rerun `doctor` and real synthesis because the Siri TTS
API is private.

```bash
ps -axo pid,ppid,state,etime,%cpu,%mem,command | grep '[s]pokenfolio'
lsof -nP -iTCP:8787 -sTCP:LISTEN
```

Normal HTTP operation has one gateway, a global four-synthesis admission limit, and up to four retained workers per initialized backend. A default installed-Siri audiobook adds up to eight workers; the measured expressive default adds one. Explicit audiobook settings may request 1–8, the measured plateau above which throughput falls. Pools and crash circuits are independent, but hardware contention remains.

## ReadAloud and Storyteller

Install or repair the pinned stalign executable from **Settings → ReadAloud**, or run:

```bash
spokenfolio readaloud tools install
spokenfolio readaloud doctor
```

ffmpeg and ffprobe must be available in Homebrew or `PATH`. The installer
verifies the stalign release checksum and signing team. **Settings → Storyteller**
starts the server’s device authorization flow and stores only connection
metadata on disk; the bearer token is in Keychain.

ReadAloud production uses exact natural-sentence synthesis timing and does not
request Speech Recognition permission or run Whisper. Independent quality
audits may use managed Whisper as a checker.

Production job state lives under the application-support directory. It is
small JSON and logs, not generated HTTP speech. ReadAloud staging and M4B
resume artifacts are deliberate durable work products. Do not delete them
while a job is running.

Production keeps editions under `~/Books/SpokenFolio` by default (chosen at
first launch), one folder per book. Changing the root under **Settings**
moves the whole library; the move is refused while jobs, quality checks, or
downloads are active. The Library catalog,
queue order, controls, and job state live under:

```text
~/Library/Application Support/com.xrishox.spokenfolio/
```

Closing the window does not stop the gateway or production. Quitting pauses
active production, suspends pending work, and waits for the child and server to
stop. Reopen SpokenFolio and choose **Production → Queue → Resume Queue** after verifying
the machine is ready.

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

## UI diagnostics

Two environment-gated hooks exist so interface behavior can be verified from a
headless session (they have no effect when the variables are unset). Running
the desktop binary with `SPOKENFOLIO_UI_AUDIT=<dir>` walks every
section/size/appearance combination, writes a PNG self-snapshot plus a
view-frame report per state into `<dir>`, and then quits; the walk only
navigates and resizes, never mutating jobs or the library. Running the test
suite with `SPOKENFOLIO_SNAPSHOT_DIR=<dir>` renders populated component
fixtures (queue rows, failed drafts) to PNGs through an off-screen window.
Sidebar vibrancy renders as a blank panel in self-snapshots; that is a capture
artifact, not an interface defect.

## Uninstall

```bash
osascript -e 'tell application id "com.xrishox.spokenfolio" to quit' 2>/dev/null || true
rm -rf "/Applications/SpokenFolio.app"
rm -f "$HOME/.local/bin/spokenfolio"
```

Optionally remove the application-support directory and stale Full Disk Access
entry. Never remove Apple voice assets as part of project cleanup.
