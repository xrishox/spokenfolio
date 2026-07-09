# Architecture

```text
Readest (iOS, Android, Linux, Windows, macOS)       macOS speech server
┌──────────────────────────────────────────┐       ┌──────────────────────────────┐
│ OpenAI-compatible TTS client             │       │ OpenAI-compatible HTTP API   │
│                                          │       │                              │
│ local AudioContext capability probe      │       │ installed Siri voice assets │
│   Ogg Opus → AAC/M4A → WAV               │       │          ↓                   │
│          ↓                               │ POST  │ private SiriTTSService       │
│ ordered window: current + 9 sentences ───┼──────▶│          ↓ 48 kHz mono PCM   │
│          ↓                               │       │ Opus / AAC / WAV encoder     │
│ decode and play strictly in book order ◀─┼───────│                              │
└──────────────────────────────────────────┘       └──────────────────────────────┘
```

The Mac performs synthesis and encoding. Readest only downloads, decodes, and
plays sentence audio. This keeps Apple-private code off every client platform
and keeps the Readest patch limited to its existing custom OpenAI TTS client.

## Wire contract

| Endpoint | Purpose |
|---|---|
| `POST /v1/audio/speech` | OpenAI-shaped `{model,input,voice,response_format,speed}` request. `opus` returns 48 kHz mono Ogg Opus at a 48 kbps constrained-VBR target; `aac` returns 48 kHz mono AAC-LC at 64 kbps in M4A/MP4; `wav` returns 48 kHz mono PCM16 WAV. The legacy raw `pcm` response remains available. |
| `GET /v1/audio/voices` | `{"voices":["<asset-id>", ...]}` flat identifier list. |
| `GET /v1/audio/voices/all` | `{"voices":[{"id","name","lang","quality"}, ...]}` installed and usable Siri voice assets. |
| `GET /v1/models` | Static OpenAI-style model list used as a health check. |
| `POST /v1/audio/transcriptions` | Returns 503 in the supplied TTS-only configuration. |

Compressed responses are completed before their HTTP headers are sent. That
allows synthesis or encoding errors to remain ordinary JSON errors instead of
leaving clients with a successful status and a truncated audio container.

## Codec negotiation

There is no single compressed browser audio format that can be assumed on
every WebView version Readest supports. Readest therefore decodes tiny valid
fixtures through the same `AudioContext.decodeAudioData` path used for book
audio and selects the first working rung:

1. Ogg Opus — best speech quality per byte and the normal default.
2. AAC-LC in M4A/MP4 — the broad compressed fallback, especially for older
   Apple WebKit versions.
3. PCM16 WAV — large, but the universal final fallback.

The result is pinned per endpoint for the current app session. A server
unsupported-format response or a real audio decode failure downgrades and
retries the same sentence. Authentication failures, rate limits, and transient
network errors do not poison the pinned codec.

The server MIME types are authoritative and are retained in Readest's cache:

- `audio/ogg; codecs=opus`
- `audio/mp4; codecs=mp4a.40.2`
- `audio/wav`

## Latency, ordering, and limits

Readest maintains one ordered sliding window of at most ten network jobs: the
current sentence and nine ahead. Fetches may finish out of order, but decoding,
highlighting, and playback remain in book order. Preload requests share the
same ten-job priority pool instead of starting an unbounded detached loop. A
generation token and abort signal make skipped or stopped text ineligible for
later playback.

The Siri engine itself is expensive (hundreds of megabytes per loaded voice)
and serializes requests for a single voice. The server therefore:

- lazily creates and permanently retains one serial lane per used voice;
- caps the process at four resident voice lanes and four active syntheses;
- caps queued HTTP synthesis requests at twenty;
- rejects a fifth distinct resident voice with a restart-required capacity
  error instead of risking multi-gigabyte growth.

## Private API boundary

`SiriTTSService.framework` is an undocumented Apple private framework. The
server dynamically loads it, validates the required classes, selectors, and
Objective-C method encodings, and fails closed when the ABI does not match.
It only scans already-installed voice assets and never downloads or modifies
Apple assets. A macOS update can still change or remove this API; this project
cannot provide the compatibility guarantee of a public framework.

The network service is deliberately ordinary HTTP. Put authentication,
encryption, or VPN access in front of it when the network is not trusted.
