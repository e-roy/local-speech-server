# Speech-to-text (STT)

The service exposes OpenAI-compatible speech-to-text alongside TTS, behind
the same base URL, auth, and CORS policy. Since phase 3a, transcription is
served by [mlx-audio](https://github.com/Blaizzy/mlx-audio) running
**natively on the host** — the M4's GPU via Apple's MLX framework — the
same host-engine pattern as the LLM ([llm.md](llm.md)).

## What runs

- **Transcriptions** (`/v1/audio/transcriptions`): mlx-audio on the host at
  `host.docker.internal:8001`, GPU-accelerated. Installed and operated per
  [operations.md](operations.md) — "STT engine (mlx-audio on the host)".
- **Translations** (`/v1/audio/translations`): still served by the Speaches
  container (mlx-audio does not expose the endpoint). CPU-bound; fine for
  its low traffic.
- Speaches also keeps its own internal Whisper for `/v1/realtime` sessions
  (realtime does not use the mlx-audio engine — its speech models are
  internal to Speaches; see [realtime.md](realtime.md)). Its models remain
  declared in `PRELOAD_MODELS` in `docker-compose.yml`.

Rollback at any time: point the Caddyfile `@stt` route back at
`speaches:8000`, restart Caddy, and consumers switch models back to
`Systran/faster-distil-whisper-small.en` — the CPU path never left.

## Endpoints

```
POST /v1/audio/transcriptions   # speech → text (same language) — GPU
POST /v1/audio/translations     # speech → English text — CPU (Speaches)
```

Multipart form fields follow the OpenAI Whisper API: `file`, `model`, and
optionally `language`, `prompt`, `response_format`, `temperature`. See
[consumer-integration.md](consumer-integration.md) for SDK and `fetch()`
examples.

## Models

The default transcription model is set in `.env` as `STT_MODEL` (read by
`verify-stack.sh` and documented for consumers; the engine itself loads
whatever model a request names):

| Model | Languages | Notes |
|---|---|---|
| `mlx-community/whisper-large-v3-turbo-asr-fp16` | Multilingual | Default — large-v3-turbo accuracy at GPU speed; CPU could never afford this model |
| `mlx-community/parakeet-tdt-0.6b-v3` | English | Fastest option if English-only and every millisecond counts |

Models download from Hugging Face into the host user's cache on first use
and load into GPU memory on demand. The operations runbook pre-warms the
default model so no consumer pays the first-download cost.

The old CPU model IDs (`Systran/faster-whisper-*`) are **not** valid on the
mlx-audio engine — consumers must use the `mlx-community/...` IDs. Keep the
model name in consumer config (env var), not code.

`GET /v1/models` still lists the *Speaches* registry (used by realtime and
translations), not the mlx-audio engine's models — treat `STT_MODEL` as the
source of truth for transcription.

## Size and duration limits

- **100 MB request cap** (Caddy 413; Cloudflare enforces the same on
  Free/Pro plans). Roughly an hour of 16 kHz WAV; far more as Opus/M4A.
- **~100 s Cloudflare response timeout.** With GPU transcription this now
  takes truly long recordings to hit — and LAN/smoke requests bypass it
  entirely. Split extremely long recordings client-side if needed.

## Performance

Measured on the Mac Mini M4 (through the tunnel, warm): the CPU engine
transcribed a ~2 s clip in ~1.7 s; the GPU engine is expected around
0.3–0.5 s for the same clip with a *larger, more accurate* model —
verify-stack's round-trip and the timing snippets in the git history are
the measurement tools. If the engine is down, requests fail fast with the
same OpenAI-style JSON 502 used by the LLM route, and `verify-stack.sh`
fails with a pointed message.

## Design notes

- **À la carte holds.** Transcription is one route to one engine;
  translations and realtime are separate routes to a different engine.
  Consumers depend on the API shape, never on which engine serves it —
  which is exactly what made this swap a one-line Caddy change.
- **Host engines are the performance tier.** Docker on macOS cannot reach
  the GPU, so the heavy engines (LLM, now STT) live on the host behind
  Caddy's auth, while the light/orchestration pieces stay containerized.
- **Phase 3b (TTS) is scoped but not built**: same pattern for
  `/v1/audio/speech`, pending voice-list parity between Kokoro-FastAPI's
  110 voices and mlx-audio's Kokoro set — the `/voices` page and consumer
  voice IDs must keep working. See [llm.md](llm.md) roadmap.
