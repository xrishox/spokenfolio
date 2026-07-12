# macos-tts-server

An OpenAI-compatible TTS server for high-quality Siri natural, neural, and
Gryphon voices installed on an Apple Silicon Mac. It serves Readest and other
LAN clients, and can turn EPUB books into chaptered, tagged, resumable M4B
audiobooks with an embedded cover when the book supplies one.

The project uses Apple's undocumented `SiriTTSService.framework`, not
Accessibility voices or `AVSpeechSynthesizer`. macOS updates can change this
private interface; the bridge validates it and fails closed.

## Requirements

- Apple Silicon and macOS 15 or newer
- Swift 6.2 toolchain and Xcode Command Line Tools
- A Siri voice fully downloaded in System Settings
- Full Disk Access for the installed app when the shared Siri models require it

## Install

```bash
git clone https://github.com/xrishox/macos-tts-server.git
cd macos-tts-server
./scripts/install.sh
```

The installer builds and signs a self-contained app, installs it at
`/Applications/Siri TTS Server.app`, creates
`~/.local/bin/siri-tts-server`, and launches the menu-bar app. It stages and
verifies updates before stopping the installed service and restores the old
app if replacement fails. It refuses to update while an audiobook job is
running.

Grant Full Disk Access to the installed app if requested, then quit and reopen
it. Choose **Run Connection Test** to synthesize and decode real Opus and AAC.

## Verify and use

```bash
~/.local/bin/siri-tts-server doctor
TTS_SMOKE_NO_PLAYBACK=1 ./scripts/smoke-test.sh http://127.0.0.1:8787
```

The default trusted-LAN endpoint is `http://<mac-name>:8787`. It has no
authentication, TLS, or broad browser CORS policy; do not expose it directly to
the public Internet.

Example speech request:

```bash
curl -fsS http://localhost:8787/v1/audio/speech \
  -H 'Content-Type: application/json' \
  -d '{"model":"tts-1","input":"The story begins.","response_format":"opus"}' \
  -o speech.ogg
```

Create an audiobook:

```bash
siri-tts-server audiobook chapters book.epub
siri-tts-server audiobook create book.epub
siri-tts-server audiobook verify "Book - Author.m4b"
```

Ordinary hyperlink text remains prose; HTML markup, note references,
footnote/endnote apparatus, navigation furniture, and excluded front/back
matter are not narrated. Completed chapter artifacts allow an interrupted job
to resume.

To exercise Readest-style ordered playback from another machine:

```bash
./test.sh http://mac-hostname:8787
```

## Documentation

- [HTTP API](docs/API.md)
- [Architecture and design](docs/ARCHITECTURE.md)
- [Codebase map](docs/CODEBASE.md)
- [Build, installation, and operations](docs/OPERATIONS.md)
- [Siri voices](docs/VOICES.md)
- [EPUB to M4B audiobooks](docs/AUDIOBOOKS.md)
- [Readest integration](docs/READEST_INTEGRATION.md)

Contributor constraints are maintained identically in [AGENTS.md](AGENTS.md)
and [CLAUDE.md](CLAUDE.md).
