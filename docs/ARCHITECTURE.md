# Architecture

```
KDE Plasma Linux                     any network path        Mac
┌───────────────────────────┐                               ┌──────────────────────────────┐
│ Readest — our fork,        │──POST /v1/audio/speech (WAV)─▶│ macos-speech-server + patches│
│ AppImage:                  │◀──WAV per sentence, prefetched│  engine: avspeech            │
│  OpenAI-compat TTSClient   │──GET /v1/audio/voices/all───▶│  (Apple system voices)       │
│  via @tauri-apps/plugin-   │                               │  LaunchAgent, plain HTTP     │
│  http (no CORS/CSP issues) │                               │  on 0.0.0.0:8787             │
└───────────────────────────┘                               └──────────────────────────────┘
```

## Wire contract

| Endpoint | Purpose |
|---|---|
| `POST /v1/audio/speech` | `{model, input, voice, response_format:"wav", speed}` → streamed `audio/wav` (22050 Hz, 16-bit mono). `voice` accepts display names ("Samantha", case-insensitive) or full identifiers (`com.apple.voice.premium.en-US.Zoe`). |
| `GET /v1/audio/voices` | `{"voices": ["<id>", ...]}` — flat identifier list (Kokoro-FastAPI-compatible shape). |
| `GET /v1/audio/voices/all` | `{"voices": [{"id","name","lang","quality"}, ...]}` — quality is `default`/`enhanced`/`premium`. |
| `GET /v1/models` | Static OpenAI-style model list; used as a health check. |
| `POST /v1/audio/transcriptions` | Returns 503 (STT disabled via `stt: engine: none`). |

## Design notes

- **WAV, not MP3/Opus.** The server has no MP3 encoder; WAV decodes bulletproof in
  WebKitGTK's `decodeAudioData` (AppImage GStreamer setups are fragile); ~353 kbps mono
  is trivial bandwidth. `response_format` stays in the client config + cache key so a
  compressed format could be added later.
- **Rate is client-side.** Readest always requests `speed: 1.0` and time-stretches during
  playback (WSOLA, same as its Edge TTS path) — rate changes are instant and cached audio
  survives them.
- **Latency model.** Cold start (play/skip) ≈ one network round trip + synthesis of one
  sentence (~10× realtime on Apple Silicon) + transfer. Steady state is gapless: Readest's
  controller prefetches upcoming sentences while the current one plays.
- **Why a Readest fork at all:** on Linux desktop Readest only has Edge TTS (Microsoft
  cloud) and the Web Speech API (voiceless on stock WebKitGTK). There is no custom-endpoint
  support upstream; draft PR readest#1858 was the reference for ours.
- **Server fork diff** (`server/patches/`): voice discovery endpoints, `resolveVoice` so
  full identifiers pass validation (required to disambiguate enhanced/premium tiers), and
  `stt: engine: none` (skips a ~500 MB ASR model download for TTS-only use).
- **No upstream submissions** — both forks are personal, by explicit policy.
- The server binds `0.0.0.0:8787` (8080 is taken by whisper-server on the Mac). It's an
  ordinary self-hosted HTTP service; network reachability (VPN etc.) is out of scope.
