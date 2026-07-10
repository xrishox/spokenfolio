# Architecture

```text
Readest OpenAI TTS client                     Siri TTS Server (macOS)
┌────────────────────────────┐                ┌───────────────────────────┐
│ rolling buffer ≤ 120 s/50  │  HTTP          │ Vapor gateway             │
│ Opus 64k → AAC 64k         ├───────────────▶│ queue ≤ 20                │
│ decode/play in book order  │                │ worker pool ≤ 4 processes │
└────────────────────────────┘                └─────────────┬─────────────┘
                                                           │ framed IPC
                                               ┌───────────▼───────────┐
                                               │ private Siri engine   │
                                               │ one model per worker  │
                                               └───────────────────────┘
```

## Process isolation

The undocumented Siri engine is loaded only in child worker processes. The
HTTP gateway discovers metadata but never loads a model. A worker serves one
request at a time and is killed on cancellation, timeout, malformed IPC, or
unexpected exit; the pool retries one crash within the original 25-second
deadline. Three unexpected crashes in 60 seconds open a circuit instead of
creating a restart storm.

Workers are created lazily, reused for the same voice, and replaced by the
least-recently-used idle worker when another voice is requested. Four workers
and twenty queued requests are hard configuration maxima. This bounds
server-side memory and request amplification while Readest maintains its
rolling client buffer.

IPC is length-prefixed JSON plus raw PCM with explicit 64 KiB header and
128 MiB payload limits. Worker EOF and mismatched request IDs are protocol
failures, not partial successes.

## Private framework boundary

`SiriTTSService.framework` is loaded dynamically. The bridge verifies its
classes, selectors, Objective-C method encodings, returned audio format, and
engine initialization before publishing readiness. The expected output is
mono signed packed PCM16 at 48 kHz. Workers use `_exit` after unrecoverable
private-engine failures so unsafe Objective-C/C++ teardown cannot crash the
gateway.

Only installed natural, neural, and Gryphon assets with a verified 48 kHz
graph are listed. The project never downloads or changes Apple assets.

## Codec strategy

There is no compressed format that decodes in every historical WebView.
Readest probes valid files through its real `AudioContext.decodeAudioData`
path and tries:

1. Ogg Opus at 64 kbps constrained VBR;
2. AAC-LC at 64 kbps in M4A/MP4;

The selected format is pinned for that endpoint session. A real decode failure
evicts the cached bytes and retries the same sentence on the next rung. Auth,
rate-limit, timeout, and ordinary network failures do not downgrade the codec.
If neither compressed format decodes, Readest reports that the device is
unsupported; WAV remains available only through an explicit API request. Each
HTTP response is a complete file with an exact content length and `no-store`
cache policy.

## Readest isolation

The fork adds an `OpenAITTSClient` beside existing clients. Its rolling
120-second/50-sentence buffer and ten-task priority pool are private to that
client: upstream `TTSController.preloadNextSSML` retains its default and other
engines are unchanged. At most nine background requests run at once, reserving
capacity for the audible sentence. Network requests may complete out of order,
while decoding, highlight dispatch, and playback remain ordered and
generation-cancellable. Compressed audio lives only in a bounded volatile
memory cache (64 entries/64 MiB, ten-minute TTL); consumed history retains the
previous ten sentences for replay.

The settings connection test performs `/models` and voice discovery, then
synthesizes a short sentence and decodes it through the same codec ladder.

## Network boundary

The default `0.0.0.0:8787` service is intentionally plain unauthenticated HTTP
for a trusted LAN. Per-client token/outstanding limits and the bounded worker
queue protect resources, but they are not authentication or encryption.
