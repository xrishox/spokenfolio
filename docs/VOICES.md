# Siri voice assets

This server uses the higher-quality voice assets installed for Siri, not the
voices exposed by `AVSpeechSynthesizer` or Accessibility Spoken Content.
Natural and neural premium assets are listed separately when both are present.

## Install a voice

Choose a Siri voice in System Settings and let macOS finish downloading it:

- newer macOS: **Apple Intelligence & Siri → Siri Voice**;
- macOS 14: **Siri & Spotlight → Siri Voice**.

Apple changes these labels between macOS releases. The important part is to
select and preview the desired Siri voice so its local asset download
completes. The server deliberately does not invoke Apple's private download
services and cannot synthesize from a cloud-only voice.

Restart the server after installing a new voice so the catalog is rescanned:

```bash
launchctl kickstart -k gui/$(id -u)/com.local.speech-server
```

## Inspect installed voices

```bash
curl -s http://localhost:8787/v1/audio/voices/all | python3 -m json.tool
```

A selectable id resembles:

```text
com.apple.siri.tts.voice.en_US.nora.natural.premium
```

Always configure Readest with the full `id`. Display names can collide across
languages and natural/neural variants. The server accepts a unique display
name as a convenience, but the id is stable and unambiguous within the current
asset catalog.

The server scans Apple's installed Siri TTS asset locations, including current
UAF and Trial asset roots and older local Siri/Gryphon locations. It only
publishes entries containing a usable `AssetData` directory. Asset metadata is
used for the language, quality tier, and narration-style capability; the
natural narration prompt is enabled only when the asset advertises it.

## Verify real synthesis

The repository smoke test selects an installed natural voice when possible,
synthesizes all three fallback formats, validates their containers, and uses
`ffprobe` or `afinfo` as an independent decoder when available:

```bash
scripts/smoke-test.sh http://localhost:8787
```

To test a specific asset:

```bash
scripts/smoke-test.sh \
  http://localhost:8787 \
  com.apple.siri.tts.voice.en_US.nora.natural.premium
```

## Important limitation

Siri synthesis is reached through an undocumented private framework. The
server checks the private Objective-C ABI before using it and fails safely when
the installed macOS no longer matches, but Apple can change that framework or
its asset layout in any OS update. Keep WAV enabled as a client codec fallback;
it does not, however, provide a fallback synthesis engine when the private Siri
API itself is unavailable.
