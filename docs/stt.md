# Speech-to-text (STT)

The service exposes OpenAI-compatible speech-to-text alongside TTS, behind the
same base URL, auth, and CORS policy. STT is served by
[Speaches](https://github.com/speaches-ai/speaches) (formerly
`faster-whisper-server`), which runs Whisper-family models via faster-whisper.

## What runs

- Image: `ghcr.io/speaches-ai/speaches:0.9.0-rc.3-cpu` — pinned because the
  0.9 line introduced the config surface we rely on (`PRELOAD_MODELS`); bump
  to `0.9.0` final when released. The `-cpu` image is multi-arch and runs
  natively on Apple Silicon (linux/arm64).
- Caddy routes `/v1/audio/transcriptions*` and `/v1/audio/translations*` to
  `speaches:8000`; everything TTS-related stays on Kokoro-FastAPI.
- Models live in the `speaches_models` named volume (the Hugging Face hub
  cache, mounted at `/home/ubuntu/.cache/huggingface/hub`).

## Endpoints

```
POST /v1/audio/transcriptions   # speech → text (same language)
POST /v1/audio/translations     # speech → English text
```

Multipart form fields follow the OpenAI Whisper API: `file`, `model`, and
optionally `language`, `prompt`, `response_format`, `temperature`.
`response_format` accepts `json` (default), `verbose_json`, `text`, `srt`,
`vtt`. Passing `stream=true` returns the transcript incrementally via
server-sent events as the audio is processed — Caddy proxies this unbuffered.

See [consumer-integration.md](consumer-integration.md) for SDK and `fetch()`
examples.

## Models

Speaches loads models dynamically per request, but **only models that have
already been downloaded can be used** — a request naming an unknown model
fails; nothing downloads implicitly at request time. Downloads are declared in
`docker-compose.yml`:

```yaml
- 'PRELOAD_MODELS=["Systran/faster-distil-whisper-small.en"]'
```

Model IDs are Hugging Face repo names (there is no `whisper-1` alias — the
OpenAI SDK's `model` parameter takes the full ID). Models are downloaded at
container startup if missing, then loaded into memory on first use and
unloaded after 5 idle minutes (`STT_MODEL_TTL`, default 300 s), so the first
request after a quiet period pays a few seconds of load time.

Reasonable choices for CPU inference:

| Model | Languages | Notes |
|---|---|---|
| `Systran/faster-distil-whisper-small.en` | English only | Default here — best speed/quality trade-off on CPU |
| `Systran/faster-whisper-base.en` | English only | Lighter and faster, noticeably less accurate |
| `Systran/faster-whisper-small` | Multilingual | Use if you need non-English audio |
| `Systran/faster-distil-whisper-medium.en` | English only | More accurate; test whether CPU latency is acceptable |

Anything `large` is not a realistic fit for CPU-only inference — see
"Performance" below. To change, add, or remove models, follow
[operations.md](operations.md) — "Changing the STT model".

## Size and duration limits

- **100 MB request cap.** Caddy rejects larger uploads with 413; Cloudflare's
  edge enforces the same 100 MB limit on Free/Pro plans anyway. That is
  roughly an hour of 16 kHz WAV — far more of Opus/M4A.
- **~100 s response timeout.** Cloudflare returns 524 if the origin takes
  longer than ~100 seconds to respond. Short clips are nowhere near this;
  very long recordings on CPU can be. Mitigations, in order: use a distil
  model, pass `stream=true` (headers and partial results flow immediately, so
  the timeout never triggers), or split long recordings client-side.
  Requests over the LAN or via the smoke setup bypass Cloudflare and have no
  such limit.

## Performance

Inference is CPU-only: Docker on macOS cannot use the M-series GPU or Neural
Engine, and faster-whisper has no Metal backend regardless. Expect the
small/distil models to run a few times faster than realtime on an M-series
CPU — fine for dictation and voice notes; slow for hour-long recordings.

If long-form or heavier workloads ever matter, the upgrade path is to run a
Metal-accelerated engine natively on the Mac (e.g. an MLX-based server that
speaks the same OpenAI shape) and point the Caddy `@stt` route at
`host.docker.internal:<port>` instead of `speaches:8000`. Because consumers
only depend on the OpenAI API shape, that swap touches one line of the
Caddyfile and no client code.

## Design notes

- **Separate service, not consolidation.** Speaches can also serve TTS
  (it bundles Kokoro), so the stack could in principle collapse to one
  engine container. That would change the TTS `model`/voices API shape that
  existing consumers and the `/voices` page depend on, for no performance
  gain — the same models do the work either way. Revisit only if the
  duplicate container ever becomes a real cost.
- **`/v1/audio/voices` routes to Kokoro.** Speaches exposes its own voices
  endpoint for its TTS side; the Caddyfile deliberately shadows it because
  Kokoro is the TTS engine here.
- **Unrouted paths 404.** Both backends expose more routes than the service
  publishes (model management, docs pages, health). Caddy only forwards the
  documented `/v1/audio/*` surface; model management happens on the Docker
  network via `docker compose exec` (see operations.md).

## Related extensions

- **Realtime / speech-to-speech.** Speaches ships a WebSocket `/v1/realtime`
  API. Exposing it would need a new Caddy route (WebSocket proxying works
  through `reverse_proxy` as-is) and consumer-side session handling —
  spec it before wiring it up.
- **Multiple TTS voice engines.** If a second TTS engine (e.g. Piper) is ever
  desired, add it as a parallel service and route by URL path, mirroring how
  STT was added.
