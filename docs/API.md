# HTTP API

This document is the normative public HTTP and audio contract for SpokenFolio. The API resembles the OpenAI speech API where useful, while exposing the installed Siri voice catalog needed by Readest.

## Base URL

The default listener is:

```text
http://0.0.0.0:8787
```

From another machine, replace the host with the Mac's hostname or LAN address, for example `http://nac:8787`.

The service is plain HTTP with no built-in authentication or TLS. Use it only on a trusted network or behind a VPN/authenticated reverse proxy. Rate limiting protects resources; it does not protect access or confidentiality.

The speech, voice, and model routes are registered both with and without the `/v1` prefix. New clients should use `/v1`.

## Endpoints

| Method | Preferred path | Compatibility alias | Purpose |
|---|---|---|---|
| `POST` | `/v1/audio/speech` | `/audio/speech` | Synthesize one text input |
| `GET` | `/v1/audio/voices` | `/audio/voices` | List canonical voice IDs |
| `GET` | `/v1/audio/voices/all` | `/audio/voices/all` | List voice metadata |
| `GET` | `/v1/models` | `/models` | List compatible model names |
| `GET` | `/health/live` | none | Confirm the HTTP process is alive |
| `GET` | `/health/ready` | none | Confirm the Siri engine passed startup synthesis |

## Synthesize speech

```http
POST /v1/audio/speech
Content-Type: application/json
```

### Request body

```json
{
  "model": "tts-1",
  "input": "The first chapter begins on a quiet winter morning.",
  "voice": "com.apple.siri.tts.voice.en_US.nora.natural.premium",
  "response_format": "opus",
  "speed": 1.0
}
```

| Field | Type | Required | Rules |
|---|---|---|---|
| `model` | string | yes | `tts-1` / `tts-1-hd` select `siri/siri-private`; available macOS-27+ servers also expose `siri-expressive` for `siri-fm/siri-expressive` |
| `input` | string | yes | Non-blank and no more than 4,096 Swift characters |
| `voice` | string | no | Canonical ID or unambiguous alias within the selected model; defaults to that model's configured/preferred voice |
| `response_format` | string | no | `opus`, `aac`, `wav`, or `pcm`; defaults to `wav` |
| `speed` | number | no | Must be exactly `1.0`; defaults to `1.0` |
| `pace` | integer | no | `1...5`, default `3`; supported only by `siri-expressive` |
| `expressivity` | integer | no | `1...5`, default `3`; supported only by `siri-expressive` |

Speed is fixed because Readest caches rate-independent audio and applies playback speed locally with time stretching. Pace is a separate expressive-model preset. Legacy Siri rejects either expressive field instead of silently ignoring it.

### Voice resolution

Canonical IDs are the safest choice. Resolution is scoped to the selected model; a voice from another backend is never substituted. The server also accepts a short name, display name, or `<language>:<name>` alias only when it identifies exactly one installed variant in that model. If both Nora Natural and Nora Neural are installed, `nora` is deliberately rejected rather than guessed.

### Successful response

The response body is one complete audio object. The server synthesizes all sentences, collects PCM, finalizes the requested container in memory, and only then sends status `200`.

Every successful response contains:

- the exact `Content-Length`;
- the format-specific `Content-Type`;
- `Cache-Control: no-store`.

| Format | MIME type | Container and codec | Nominal bitrate |
|---|---|---|---|
| `opus` | `audio/ogg; codecs=opus` | RFC 7845 Ogg Opus, mono 48 kHz | 64 kbps constrained VBR |
| `aac` | `audio/mp4; codecs=mp4a.40.2` | AAC-LC in audio-only M4A/MP4, mono 48 kHz | 64 kbps constant |
| `wav` | `audio/wav` | RIFF/WAVE PCM16-LE, mono 48 kHz | 768 kbps payload before headers |
| `pcm` | `audio/pcm` | Headerless signed PCM16-LE, mono 48 kHz | 768 kbps |

Container overhead means the measured file bitrate may differ slightly from the encoder target.

### Example requests

Opus:

```bash
curl -fsS http://nac:8787/v1/audio/speech \
  -H 'Content-Type: application/json' \
  -d '{
    "model":"tts-1",
    "input":"This sentence is encoded as Opus.",
    "voice":"com.apple.siri.tts.voice.en_US.nora.natural.premium",
    "response_format":"opus",
    "speed":1.0
  }' \
  -o speech.ogg
```

AAC/M4A:

```bash
curl -fsS http://nac:8787/v1/audio/speech \
  -H 'Content-Type: application/json' \
  -d '{
    "model":"tts-1",
    "input":"This sentence is encoded as AAC.",
    "voice":"com.apple.siri.tts.voice.en_US.nora.natural.premium",
    "response_format":"aac"
  }' \
  -o speech.m4a
```

Siri Expressive on macOS 27+:

```bash
curl -fsS http://nac:8787/v1/audio/speech \
  -H 'Content-Type: application/json' \
  -d '{
    "model":"siri-expressive",
    "input":"The storm passed, and the whole valley seemed to breathe again.",
    "voice":"en-US-F",
    "pace":3,
    "expressivity":4,
    "response_format":"aac"
  }' \
  -o expressive.m4a
```

Discover the first installed legacy Siri voice and synthesize without hard-coding an ID:

```bash
voice="$(curl -fsS http://nac:8787/v1/audio/voices | python3 -c 'import json,sys; print(json.load(sys.stdin)["voices"][0])')"
curl -fsS http://nac:8787/v1/audio/speech \
  -H 'Content-Type: application/json' \
  -d "$(VOICE="$voice" python3 -c 'import json,os; print(json.dumps({"model":"tts-1","input":"Voice discovery succeeded.","voice":os.environ["VOICE"],"response_format":"opus","speed":1.0}))')" \
  -o speech.ogg
```

## List voice IDs

```http
GET /v1/audio/voices
```

Example response:

```json
{
  "voices": [
    "com.apple.siri.tts.voice.en_US.nora.natural.premium",
    "com.apple.siri.tts.voice.en_US.nora.neural.premium"
  ]
}
```

This compatibility route returns only installed `siri/siri-private` assets that pass metadata and 48 kHz graph validation. Use `/v1/audio/voices/all` for every available backend.

## List voice metadata

```http
GET /v1/audio/voices/all
```

Example response:

```json
{
  "voices": [
    {
      "id": "com.apple.siri.tts.voice.en_US.nora.natural.premium",
      "name": "Nora (Natural)",
      "lang": "en-US",
      "quality": "premium",
      "backend": "siri",
      "model": "siri-private",
      "supportsPace": false,
      "supportsExpressivity": false
    }
  ]
}
```

`quality` is `premium` when the Apple asset footprint begins with `premium`; otherwise it is reported as `enhanced`. Technology remains visible in the display name and canonical ID. On macOS 27+, available FM voices appear with backend `siri-fm`, model `siri-expressive`, and both capability flags true.

## List models

```http
GET /v1/models
```

This endpoint succeeds when the configured default TTS model is ready. It lists only models whose backend initialized successfully.

```json
{
  "object": "list",
  "data": [
    {
      "id": "tts-1",
      "object": "model",
      "created": 0,
      "owned_by": "spokenfolio"
    },
    {
      "id": "tts-1-hd",
      "object": "model",
      "created": 0,
      "owned_by": "spokenfolio"
    },
    {
      "id": "siri-expressive",
      "object": "model",
      "created": 0,
      "owned_by": "spokenfolio"
    }
  ]
}
```

`tts-1` and `tts-1-hd` exist for client compatibility and select the same installed-Siri model. `siri-expressive` appears only when the macOS-27+ FM backend is available; it is omitted honestly on macOS 26 or when its private daemon path fails.

## Health checks

`GET /health/live` confirms only that the HTTP process is responding:

```json
{"status":"live"}
```

`GET /health/ready` confirms startup initialization prepared the configured default model, synthesized its preheat sentence, and received valid non-empty PCM:

```json
{"status":"ready"}
```

A readiness check does not prove that every container works on a particular client. Use `scripts/smoke-test.sh` for end-to-end synthesis and decode validation.

If the configured default model's discovery, private engine, daemon connection, or required access fails, the gateway continues listening in degraded mode. `/health/live` still succeeds; readiness, models, and otherwise-valid speech requests return the specific structured 503. A non-default backend may fail independently: it is omitted from model/catalog responses while the healthy default remains usable. Voice endpoints return any catalog that could be discovered. Recovery requires restarting the app after fixing the underlying problem.

## Errors

Errors use an OpenAI-shaped envelope:

```json
{
  "error": {
    "message": "Voice 'nora' is not installed or usable.",
    "type": "invalid_request_error",
    "param": null,
    "code": "voice_not_found"
  }
}
```

| HTTP status | Code | Meaning |
|---|---|---|
| `400` | `invalid_input` or a field-specific code | Invalid JSON field, blank/long input, unsupported model, speed, or format |
| `400` | `model_not_found` | Model is not an available `tts-1`, `tts-1-hd`, or `siri-expressive` route |
| `400` | `unsupported_speed` | Speed is not `1.0` |
| `400` | `unsupported_controls` | Pace/expressivity was supplied to a model that does not support it |
| `400` | `invalid_controls` | Pace or expressivity is outside integer presets `1...5` |
| `400` | `unsupported_format` | Format is not Opus, AAC, WAV, or PCM |
| `400` | `voice_not_found` | Voice is missing, incompatible with the selected model, or alias is ambiguous |
| `422` | `synthesis_failed` | The selected backend accepted the request path but produced no usable speech |
| `429` | `rate_limited` | Per-client token/outstanding limit was reached |
| `429` | `queue_full` | Global worker wait queue reached its configured limit |
| `503` | `siri_permission_required` | Full Disk Access is required for shared Siri models |
| `503` | `engine_unavailable` | Private framework, assets, circuit, or initialization is unavailable |
| `503` | `worker_crashed` | Worker failed twice within the request's original deadline |
| `504` | `synthesis_timeout` | Synthesis exceeded the configured deadline |
| `500` | `internal_error` | Unclassified server failure |

Malformed requests rejected by Vapor use the same envelope with code `invalid_request`.

## Resource limits

The default and maximum safety boundaries are:

- HTTP request body: 64 KiB;
- speech input: 4,096 characters;
- token bucket per client IP: burst 20, refill 2 requests/second;
- outstanding speech requests per client IP: 12;
- tracked client buckets: 4,096 maximum, ten-minute idle expiry;
- globally active HTTP syntheses across all backends: configurable 1–4, default 4;
- worker children: one pool shared by every backend, so the limit above is the
  total across installed Siri and Siri Expressive, not a per-backend budget;
- globally queued HTTP requests: configurable 0–20, default 20;
- synthesis deadline: configurable 1–120 seconds, default 25;
- IPC JSON header: 64 KiB maximum;
- IPC PCM payload: 128 MiB maximum.

One HTTP input can contain multiple sentences. Legacy Siri synthesizes them sequentially in source order; Siri Expressive receives the complete input as one utterance for continuous prosody.

## Browser considerations

The server does not install a permissive CORS middleware and normally runs on plain LAN HTTP. Native Readest shells use their platform HTTP transport. A browser-hosted HTTPS Readest session may be blocked by CORS or mixed-content policy; deploy an appropriate authenticated HTTPS proxy if browser access is required.
