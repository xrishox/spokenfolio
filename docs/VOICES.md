# Siri voice assets

This project uses Siri natural, neural, and Gryphon models, not Accessibility
Spoken Content or `AVSpeechSynthesizer` voices.

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

Use the full ID when reproducibility matters. Short, display, and
`<language>:<name>` aliases work only when they identify exactly one installed
variant. `nora` is rejected if both Natural and Neural Nora are present.

Discovery supports current UAF/Trial, VoiceServices Gryphon, and known legacy
layouts. It deduplicates equivalent assets, prefers system and newer versions,
and rejects graphs whose output is not 48 kHz. Runtime format validation remains
authoritative after a worker loads the model.

The framework, ABI, and asset layout are undocumented. After a macOS update,
run `doctor` and [the real smoke test](OPERATIONS.md#run-and-diagnose). A clean
unavailable state is possible; future compatibility cannot be guaranteed.
