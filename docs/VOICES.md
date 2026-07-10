# Siri voice assets

This server uses the higher-quality models installed for Siri, not voices from
`AVSpeechSynthesizer` or Accessibility Spoken Content.

## Install and authorize

In System Settings, choose **Apple Intelligence & Siri → Siri Voice**, select
the desired voice/variant, and wait for its preview/download to complete.
Apple changes the label between releases; the server never invokes private
download services itself.

On first app launch, grant Full Disk Access to:

```text
/Applications/Siri TTS Server.app
```

Use the menu-bar app's **Restart Server** after authorization or after
installing another voice.

## Inspect voices

```bash
~/.local/bin/siri-tts-server doctor
curl -s http://localhost:8787/v1/audio/voices/all | python3 -m json.tool
```

An ID resembles:

```text
com.apple.siri.tts.voice.en_US.nora.natural.premium
```

Use the full ID in API requests. Names such as `Nora` are ambiguous when both
natural and neural variants exist; the server refuses ambiguous aliases.

## Verify synthesis

```bash
TTS_SMOKE_NO_PLAYBACK=1 ./scripts/smoke-test.sh http://localhost:8787
```

To force one asset:

```bash
TTS_SMOKE_NO_PLAYBACK=1 ./scripts/smoke-test.sh \
  http://localhost:8787 \
  com.apple.siri.tts.voice.en_US.nora.natural.premium
```

The test uses real speech for Opus, AAC, and WAV and independently decodes
each result when `ffprobe` or `afinfo` is installed.

## Compatibility limitation

The synthesis framework and asset layout are undocumented Apple interfaces.
ABI and format validation turn an incompatible update into a clean unavailable
state, but no project can guarantee that this private API will survive a future
macOS release. WAV is a transport fallback, not a fallback synthesis engine.
