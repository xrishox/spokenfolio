# Siri voice assets

This project exposes two model-qualified local backends, not Accessibility Spoken Content or `AVSpeechSynthesizer` voices:

- `siri/siri-private`: installed Siri natural, neural, and Gryphon assets on macOS 26+;
- `siri-fm/siri-expressive`: macOS-27+ FM voices reached through the Siri daemon.

Install a voice under **Apple Intelligence & Siri → Siri Voice**, wait for its
download and preview to complete, then quit and reopen the server app. The
project discovers installed assets only; it never invokes private download
services or changes Apple-owned files.

Inspect usable 48 kHz variants:

```bash
spokenfolio doctor
spokenfolio audiobook voices
curl -fsS http://localhost:8787/v1/audio/voices/all | python3 -m json.tool
```

A canonical ID resembles:

```text
com.apple.siri.tts.voice.en_US.nora.natural.premium
```

An expressive canonical ID currently resembles `en-US-F` or `en-US-G`. Use the full model-qualified ID when reproducibility matters. Short, display, and `<language>:<name>` aliases work only when they identify exactly one installed variant inside the selected model. `nora` is rejected if both Natural and Neural Nora are present, and no alias can cross from `siri-private` to `siri-expressive`.

Installed-Siri discovery supports current UAF/Trial, VoiceServices Gryphon, and known legacy layouts. It deduplicates equivalent assets, prefers system and newer versions, and rejects graphs whose output is not 48 kHz. Expressive discovery runs only in the bounded `--golden-gate-catalog` child, filters type-7 FM voices, and never downloads assets. Its worker honors the callback audio description: observed live mono 24 kHz Float32 and cached 48 kHz Opus are decoded to typed PCM and normalized to mono 48 kHz. Instrumentation must confirm the exact FM voice, presets, adapter, resource, and positive duration.

The framework, ABI, daemon behavior, and asset layout are undocumented. After a macOS update, run `doctor` and [the real smoke test](OPERATIONS.md#run-and-diagnose). A clean unavailable state is possible; macOS 26 deliberately omits the expressive model while retaining installed Siri. Future compatibility cannot be guaranteed.
