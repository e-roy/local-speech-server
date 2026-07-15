# LLM (chat completions)

The service exposes an OpenAI-compatible chat/LLM surface alongside TTS and
STT, behind the same base URL, auth, and CORS policy. Unlike the speech
engines, the LLM runs **natively on the host, not in Docker**: it is served
by [Ollama](https://ollama.com) on the Mac itself, which Caddy reaches at
`host.docker.internal:11434`.

## Why the LLM is host-side

Docker on macOS cannot use the GPU, and the LLM is by far the heaviest
component in a voice pipeline. Ollama on the host uses Apple Silicon's GPU
(via the MLX backend on Ollama ≥ 0.19), while the lighter CPU-friendly
speech engines stay containerized. This is the same native-engine pattern
documented as the performance path in [stt.md](stt.md) — applied to the one
component where it matters most.

Consequence: Ollama is a **host dependency**, not part of `docker compose`.
The stack is designed to degrade gracefully without it — see "Failure
behavior" below.

## Endpoint surface

Caddy maps `/v1/llm/*` to Ollama's OpenAI-compatible `/v1/*`:

```
POST /v1/llm/chat/completions   → Ollama /v1/chat/completions
GET  /v1/llm/models             → Ollama /v1/models (pulled models)
POST /v1/llm/embeddings         → Ollama /v1/embeddings
```

Point an OpenAI client at `https://<host>/v1/llm` and `chat.completions` /
`models.list()` work unmodified — see
[consumer-integration.md](consumer-integration.md). Streaming
(`stream: true`) is supported and proxied unbuffered; prefer it, both for
perceived latency and because it sidesteps Cloudflare's ~100 s response
timeout on long generations.

Ollama's native API (`/api/*` — pull, delete, create) is **not reachable**
through this mapping: the prefix rewrite only lands on `/v1/*` paths.
Model installation stays operator-only, like the speech engines.

## Models

- **Selection:** consumers pass any *pulled* model in the `model` field.
  An unknown model returns Ollama's own 404 error (same semantics as STT).
- **Discovery:** `GET /v1/llm/models`.
- **Installation (operator, on the host):** `ollama pull llama3.2:3b`.
- **Sizing on the M4 / 16 GB** (with Docker Desktop holding 6–8 GB): 3–4B
  models (`llama3.2:3b`, `qwen3:4b`, `gemma3:4b`, ~2–3 GB loaded) are the
  sweet spot — fast enough that TTS is the bottleneck. A 7–8B Q4 (~5 GB) is
  feasible if Docker's allocation is trimmed to 6 GB. For voice turns, a
  fast small model usually *feels* better than a smarter slow one.
- **Keep-alive:** Ollama unloads idle models after ~5 minutes by default;
  set `OLLAMA_KEEP_ALIVE` on the host (e.g. `1h` or `-1`) if reload latency
  on the first turn bothers you.

## Failure behavior

If Ollama is not running, Caddy fails the dial within ~2 s and returns an
OpenAI-style JSON error with status 502:

```json
{"error": {"message": "Upstream engine unavailable. If this was a /v1/llm request, check that Ollama is running on the host.", "type": "api_error", "code": "upstream_unavailable"}}
```

SDKs surface this as a normal catchable `APIError`, so consumers can degrade
(e.g. transcribe-and-store, or answer "assistant offline"). TTS and STT are
unaffected — they are separate routes to separate engines.
`verify-stack.sh` reports a non-fatal WARN for an unreachable LLM upstream:
the speech stack is still healthy without it.

Operational setup (autostart at login, pulling models, keep-alive) lives in
[operations.md](operations.md) — "LLM upstream (Ollama on the host)".

## Design notes

- **Namespaced surface (`/v1/llm`) instead of flat `/v1/chat/completions`.**
  `GET /v1/models` already belongs to the STT engine; namespacing gives the
  LLM its own complete OpenAI surface so SDK-native discovery works for both
  engines without collision. Consumers use two client instances (or one per
  capability), each just a `baseURL` string — switching either to a hosted
  provider remains a config-only change.
- **Auth and CORS are unchanged** — the same bearer keys and origin
  allowlist gate `/v1/llm/*`; Ollama's own (absent) auth is never exposed.

## Roadmap

- **Phase 2 — realtime conversation: built, ON HOLD upstream.** The
  `/v1/realtime` wiring (route, auth, WebSocket) is verified, but Speaches
  rc.3 sessions die after one turn (speaches#559, unfixed). Conversation
  UX runs on the cascade until upstream ships a fix — see
  [realtime.md](realtime.md), "Status".
- **Phase 3a — native STT: built, currently ON HOLD.** The mlx-audio
  server crashes on real requests (upstream MLX thread-local streams
  regression); transcriptions are rolled back to the CPU engine until a
  fix ships — status and re-enable steps in [stt.md](stt.md).
- **Phase 3b — native TTS: pending.** Same pattern for `/v1/audio/speech`,
  blocked on voice-list parity (the `/voices` page and consumer voice IDs
  must survive the swap). Note neither phase changes `/v1/realtime` — its
  speech engines are internal to Speaches and not configurable upstream.
