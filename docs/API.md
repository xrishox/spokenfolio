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
| `model` | string | yes | `tts-1` or `tts-1-hd`; both map to the same local Siri path |
| `input` | string | yes | Non-blank and no more than 4,096 Swift characters |
| `voice` | string | no | Canonical asset ID or an unambiguous alias; defaults to the configured/preferred voice |
| `response_format` | string | no | `opus`, `aac`, `wav`, or `pcm`; defaults to `wav` |
| `speed` | number | no | Must be exactly `1.0`; defaults to `1.0` |

Speed is fixed because Readest caches rate-independent audio and applies playback speed locally with time stretching.

### Voice resolution

Canonical Siri asset IDs are the safest choice. The server also accepts a short name, display name, or `<language>:<name>` alias only when it identifies exactly one installed variant. If both Nora Natural and Nora Neural are installed, `nora` is deliberately rejected rather than guessed.

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

Discover the first installed voice and synthesize without hard-coding an ID:

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

Only installed assets that pass metadata and 48 kHz graph validation are returned.

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
      "quality": "premium"
    }
  ]
}
```

`quality` is `premium` when the Apple asset footprint begins with `premium`; otherwise it is reported as `enhanced`. Technology remains visible in the display name and canonical ID.

## List models

```http
GET /v1/models
```

This endpoint succeeds only when the Siri service is ready.

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
    }
  ]
}
```

The two names exist for client compatibility; they do not select different Apple models.

## Health checks

`GET /health/live` confirms only that the HTTP process is responding:

```json
{"status":"live"}
```

`GET /health/ready` confirms startup initialization discovered a voice, loaded a worker, synthesized the preheat sentence, and received non-empty PCM:

```json
{"status":"ready"}
```

A readiness check does not prove that every container works on a particular client. Use `scripts/smoke-test.sh` for end-to-end synthesis and decode validation.

If voice discovery, the private engine, or Full Disk Access fails, the gateway
continues listening in degraded mode. `/health/live` still succeeds; readiness,
models, and otherwise-valid speech requests return the specific structured 503.
Voice endpoints return any catalog that could be discovered. Recovery requires
restarting the app after fixing the underlying problem.

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
| `400` | `model_not_found` | Model is not `tts-1` or `tts-1-hd` |
| `400` | `unsupported_speed` | Speed is not `1.0` |
| `400` | `unsupported_format` | Format is not Opus, AAC, WAV, or PCM |
| `400` | `voice_not_found` | Voice is missing, incompatible, or alias is ambiguous |
| `422` | `synthesis_failed` | Siri accepted the request path but produced no usable speech |
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
- worker processes: configurable 1–4, default 4;
- globally queued worker requests: configurable 0–20, default 20;
- synthesis deadline: configurable 1–120 seconds, default 25;
- IPC JSON header: 64 KiB maximum;
- IPC PCM payload: 128 MiB maximum.

One HTTP input can contain multiple sentences. They are synthesized sequentially in source order within that request.

## Browser considerations

The server does not install a permissive CORS middleware and normally runs on plain LAN HTTP. Native Readest shells use their platform HTTP transport. A browser-hosted HTTPS Readest session may be blocked by CORS or mixed-content policy; deploy an appropriate authenticated HTTPS proxy if browser access is required.
