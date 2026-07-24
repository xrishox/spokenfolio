# SpokenFolio

An OpenAI-compatible TTS server for high-quality Siri natural, neural, and
Gryphon voices installed on an Apple Silicon Mac. It serves Readest and other
LAN clients, and can turn EPUB books into chaptered, tagged, resumable M4B
audiobooks. Production can optionally create an EPUB 3 Media Overlay
ReadAloud with stalign and deliver selected products to Storyteller.

The project uses Apple's undocumented `SiriTTSService.framework`, not
Accessibility voices or `AVSpeechSynthesizer`. macOS updates can change this
private interface; the bridge validates it and fails closed.

## Requirements

- Apple Silicon and macOS 26 or newer
- Swift 6.2 toolchain and Xcode Command Line Tools
- A Siri voice fully downloaded in System Settings
- Full Disk Access for the installed app when the shared Siri models require it

## Install

```bash
git clone https://github.com/xrishox/spokenfolio.git
cd spokenfolio
./scripts/install.sh
```

The installer builds and signs a self-contained app, installs it at
`/Applications/SpokenFolio.app`, creates
`~/.local/bin/spokenfolio`, and launches the desktop app. It stages and
verifies updates before stopping the installed service and restores the old
app if replacement fails. It refuses to update while book production,
ReadAloud creation, stalign installation, or another managed heavyweight task
is running.

Grant Full Disk Access to the installed app if requested, then quit and reopen
it. Choose **Run Connection Test** to synthesize and decode real Opus and AAC.

## Verify and use

```bash
~/.local/bin/spokenfolio doctor
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
spokenfolio audiobook chapters book.epub
spokenfolio audiobook audit ~/Books --output ~/Books-Audit
spokenfolio audiobook create book.epub
spokenfolio audiobook verify "Book - Author.m4b"
```

Ordinary hyperlink text remains prose; HTML markup, note references,
footnote/endnote apparatus, navigation furniture, and excluded front/back
matter are not narrated. Completed chapter artifacts allow an interrupted job
to resume.

Open **SpokenFolio** for durable production jobs, ReadAloud creation and quality
audits, managed stalign installation, and Storyteller connections. Production
uses visible Create, Queue, and History modes; Library is the shared local and
Storyteller inventory. Closing the window leaves the gateway and active jobs
running; reopen it from the Dock.
Storyteller authorization uses its device-approval page; bearer tokens remain
in the macOS Keychain. Production accepts multi-book batches, processes one book at
a time, and catalogs E/A/R products under `~/Books/SpokenFolio` (one folder
per book) by default. Its
Library reconciles local editions with one selected Storyteller server, without
downloading remote audiobooks.

To exercise Readest-style ordered playback from another machine:

```bash
./scripts/readest-playback-test.sh http://mac-hostname:8787
```

## Documentation

- [HTTP API](docs/API.md)
- [Architecture and design](docs/ARCHITECTURE.md)
- [Codebase map](docs/CODEBASE.md)
- [Build, installation, and operations](docs/OPERATIONS.md)
- [Siri voices](docs/VOICES.md)
- [EPUB to M4B audiobooks](docs/AUDIOBOOKS.md)
- [Siri narration quality research](docs/SIRI_NARRATION_QUALITY.md)
- [Readest integration](docs/READEST_INTEGRATION.md)
- [Durable production jobs](docs/PRODUCTION_JOBS.md)
- [Desktop app](docs/STUDIO.md)
- [ReadAloud generation](docs/READALOUD.md)
- [Storyteller delivery](docs/STORYTELLER.md)
- [Library and completeness](docs/LIBRARY.md)

Contributor constraints are maintained identically in [AGENTS.md](AGENTS.md)
and [CLAUDE.md](CLAUDE.md).
