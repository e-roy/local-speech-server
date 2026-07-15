# Speech-to-text (STT)

The service exposes OpenAI-compatible speech-to-text alongside TTS, behind
the same base URL, auth, and CORS policy.

## GPU path status: ON HOLD (rolled back to CPU)

Phase 3a moved transcriptions to [mlx-audio](https://github.com/Blaizzy/mlx-audio)
on the host (M4 GPU via MLX), but its server **crashes on real requests**:
MLX core made GPU streams thread-local (~0.31.2) and mlx-audio's server
touches them from worker threads — `libc++abi … There is no Stream(gpu, N)
in current thread`, process death, 5xx to consumers. It is an
ecosystem-wide regression (same crash class in mlx-lm's server, voicebox,
vllm-mlx; mlx-audio's own issue #744 closed without a published fix).
Pinning `mlx==0.31.1` broke the server outright (0.4.5 needs newer APIs
than its declared minimum). Until upstream ships a fix, the Caddy `@stt`
route points back at the CPU engine. Re-enabling is a one-line route swap
plus `STT_MODEL` in `.env` (instructions in the Caddyfile comment); the
measured GPU win when it works was ~1.7 s → ~0.55 s per clip.

## What runs

- **Transcriptions** (`/v1/audio/transcriptions`): Speaches (CPU,
  faster-whisper int8) — models declared in `PRELOAD_MODELS`.
- **Translations** (`/v1/audio/translations`): Speaches.
- `/v1/realtime` sessions use Speaches' internal models regardless
  ([realtime.md](realtime.md)).
- The mlx-audio host install (`scripts/setup-stt-engine.sh`,
  [operations.md](operations.md)) is kept for when upstream fixes land;
  its LaunchAgent can stay unloaded meanwhile.

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

The transcription model consumers should pass is set in `.env` as
`STT_MODEL` (read by `verify-stack.sh`; treat it as the operator's source
of truth). While the CPU engine is routed:

| Model | Languages | Notes |
|---|---|---|
| `Systran/faster-distil-whisper-small.en` | English only | Current default — must be in `PRELOAD_MODELS` |
| `Systran/faster-whisper-small` | Multilingual | Alternative; add to `PRELOAD_MODELS` first |

When the GPU engine returns, the IDs become `mlx-community/...` names
(e.g. `mlx-community/whisper-large-v3-turbo-asr-fp16`) — one more reason
consumers should keep the model name in config (env var), not code. The
two engines' model IDs are **not** interchangeable.

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
