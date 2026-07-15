# local-speech-server

A self-hostable voice-services appliance that exposes **OpenAI-compatible HTTP endpoints** for text-to-speech and speech-to-text on your own hardware, reachable from anywhere via a Cloudflare Tunnel. It is designed to run on a single always-on machine (target: Apple Silicon Mac Mini) on a personal LAN, and be consumed by your own client applications by simply pointing `OPENAI_BASE_URL` at it with a bearer-token API key.

TTS is backed by [Kokoro-FastAPI](https://github.com/remsky/Kokoro-FastAPI); STT by [Speaches](https://github.com/speaches-ai/speaches) running faster-whisper — see [docs/stt.md](docs/stt.md) for models, limits, and design notes.

## Architecture

```
                   ┌─────────────────────────────────────────┐
                   │  Consumer app (browser or server-side)  │
                   │  configured with:                       │
                   │   - OPENAI_BASE_URL=https://speech.…    │
                   │   - Authorization: Bearer <api-key>     │
                   └─────────────────┬───────────────────────┘
                                     │ HTTPS
                                     ▼
                   ┌─────────────────────────────────────────┐
                   │       Cloudflare edge (worldwide)       │
                   │  Terminates TLS for speech.example.com  │
                   └─────────────────┬───────────────────────┘
                                     │ encrypted tunnel
                                     ▼
   ┌─────────────────────────────────────────────────────────────────┐
   │                   Mac Mini (LAN, always on)                     │
   │                                                                 │
   │  ┌────────────────┐    ┌────────────┐    ┌──────────────────┐   │
   │  │ cloudflared    │───►│   Caddy    │───►│  Kokoro-FastAPI  │   │
   │  │ (Docker)       │    │ (Docker)   │TTS │  (Docker) :8880  │   │
   │  │ listens for    │    │ :8080      │    │  /v1/audio/      │   │
   │  │ tunnel traffic │    │ - auth     │    │    speech,voices │   │
   │  │                │    │ - CORS     │    └────────┬─────────┘   │
   │  │                │    │ - path     │             ▼             │
   │  │                │    │   routing  │    ┌──────────────────┐   │
   │  └────────────────┘    │            │    │ volume:          │   │
   │                        │            │    │ kokoro_models    │   │
   │                        │            │    └──────────────────┘   │
   │                        │            │    ┌──────────────────┐   │
   │                        │            │───►│  Speaches        │   │
   │                        └────────────┘    │  (Docker) :8000  │   │
   │                                          │  /v1/audio/      │   │
   │                                          │    translations  │   │
   │                                          │ /v1/realtime (WS)│   │
   │                                          └────────┬─────────┘   │
   │                                                   ▼             │
   │                                          ┌──────────────────┐   │
   │                                          │ volume:          │   │
   │                                          │ speaches_models  │   │
   │                                          └──────────────────┘   │
   │                                                                 │
   │  ┌───────────────────────────────────────────────────────────┐  │
   │  │ host-native (no Docker, GPU via host.docker.internal):    │  │
   │  │  Ollama    :11434 - LLM   - /v1/llm/*                     │  │
   │  │  mlx-audio :8001  - STT   - /v1/audio/transcriptions      │  │
   │  └───────────────────────────────────────────────────────────┘  │
   └─────────────────────────────────────────────────────────────────┘
```

Cloudflare's edge terminates TLS with a browser-trusted cert; traffic flows through a persistent tunnel to `cloudflared` on the Mac Mini, which forwards to Caddy over the Docker network. Caddy enforces bearer-token auth and CORS, then routes by path: speech synthesis and voice listing to Kokoro-FastAPI, transcription to mlx-audio running natively on the host (the GPU path — Docker on macOS is CPU-only), translation and realtime sessions to Speaches, and `/v1/llm/*` to Ollama, also host-native. A host engine that is down fails fast with a JSON 502; the containers run regardless.

## Prerequisites

| Prerequisite | Why |
|---|---|
| Apple Silicon Mac Mini (M1 or newer) running macOS Sonoma or later | Host machine |
| Docker Desktop for Mac (latest stable) | Runtime for all services |
| A Cloudflare account | Tunnel + DNS for HTTPS |
| A domain managed by Cloudflare (DNS in Cloudflare's nameservers) | Stable HTTPS subdomain |
| A subdomain to use for the service (e.g. `speech.example.com`) | The endpoint URL |

## Operator setup

Follow these in order. The phases mirror the implementation plan — each ends in a verifiable state.

### 1. Clone and configure

```bash
git clone <this-repo>
cd local-speech-server
./scripts/init-env.sh
```

The script will prompt for your CORS origin(s) and generate two keys. For multiple origins (dev + prod, multiple apps), pipe-separate them at the prompt: `https://app.example.com|http://localhost:5173`. Then open `.env` and paste the Cloudflare tunnel token from step 3 below.

### 2. Smoke-test locally (no tunnel yet)

Bring everything up except the tunnel, with Caddy exposed on `127.0.0.1:8080`:

```bash
docker compose -f docker-compose.yml -f docker-compose.smoke.yml up -d
docker compose logs -f kokoro speaches
# Wait for the models to load (first run downloads both — several minutes).
```

Smoke-test:

```bash
KEY=<one of your generated keys>
curl -fsS -H "Authorization: Bearer $KEY" http://localhost:8080/v1/audio/voices | jq '.voices | length'
```

Tear down before moving to step 3:

```bash
docker compose -f docker-compose.yml -f docker-compose.smoke.yml down
```

### 3. Create the Cloudflare Tunnel

In the [Cloudflare Zero Trust dashboard](https://one.dash.cloudflare.com):

1. Sidebar → **Networks** → **Tunnels** → **Create a tunnel**.
2. Connector type: **Cloudflared**.
3. Tunnel name: `local-speech-server` (any name).
4. After creation, the dashboard shows installation instructions for several platforms. **Ignore the install instructions** — copy the tunnel **token** only (a long opaque string starting with `eyJ…`).
5. **Public Hostnames** tab → **Add a public hostname**:
   - **Subdomain:** `speech` (or your choice)
   - **Domain:** select your Cloudflare-managed domain
   - **Path:** leave blank
   - **Service Type:** `HTTP`
   - **URL:** `caddy:8080` — important: not `localhost`, not `host.docker.internal`. This is the Docker service name and resolves over the internal Docker network because `cloudflared` runs in the same compose project.
6. Save. Cloudflare automatically creates the DNS CNAME record for the subdomain.

Paste the token into `.env` as `CLOUDFLARE_TUNNEL_TOKEN`, then bring the full stack up (without the smoke override) so `cloudflared` is included:

```bash
docker compose up -d --force-recreate
docker compose logs -f cloudflared
# Wait for "Registered tunnel connection" lines.
```

Verify end-to-end:

```bash
curl -fsS -H "Authorization: Bearer $KEY" https://speech.example.com/v1/audio/voices | jq '.voices | length'
```

### 4. Mac Mini persistence

See [docs/operations.md](docs/operations.md) — "First-time Mac Mini setup" — for the handful of system-settings toggles that make the stack survive reboots and power blips.

### 5. Verify

```bash
./scripts/verify-stack.sh smoke    # if you smoke-tested without the tunnel
./scripts/verify-stack.sh          # against the production URL (set SPEECH_BASE=https://speech.example.com)
```

## Consuming the service

See [docs/consumer-integration.md](docs/consumer-integration.md) for OpenAI-SDK and `fetch()` examples covering both speech synthesis and transcription. Visit `https://speech.example.com/voices` to audition installed voices.

## Further reading

- [docs/consumer-integration.md](docs/consumer-integration.md) — how to call the service from client apps
- [docs/operations.md](docs/operations.md) — key rotation, CORS origins, updates, backups
- [docs/stt.md](docs/stt.md) — the speech-to-text subsystem: models, limits, design notes
- [docs/llm.md](docs/llm.md) — the LLM subsystem (host-side Ollama): endpoint surface, models, failure behavior
- [docs/realtime.md](docs/realtime.md) — realtime voice sessions over WebSocket: connection, auth, session defaults, limitations

## Troubleshooting

When something looks off, start with `./scripts/verify-stack.sh smoke` (or `./scripts/verify-stack.sh` against the tunnel URL) — it prints a specific failure for the first broken check.

- **DNS does not resolve.** Cloudflare creates the CNAME automatically when you add a public hostname to the tunnel. Check the DNS tab for your zone; the record should point at `<tunnel-id>.cfargotunnel.com`. If missing, re-add the public hostname.
- **502 from Cloudflare.** The tunnel is up but cannot reach Caddy. Check that the public hostname's URL is `caddy:8080` (not `localhost:8080`) and that all three containers are `Up` (`docker compose ps`).
- **401 from Caddy.** Either the bearer token is wrong, or the `API_KEYS` env var did not get substituted into the Caddyfile. Check `docker compose config` to confirm the env var expanded, and `docker compose logs caddy` for auth-related log lines.
- **Model not loading / Kokoro keeps restarting.** Check `docker compose logs kokoro`. First-run model download is slow; subsequent runs reuse the `kokoro_models` named volume. If the image's internal model directory has moved between versions, update the `kokoro_models` mount path in `docker-compose.yml` per the upstream Kokoro-FastAPI README.
- **Transcription fails with a model error.** The request's `model` field must name a model listed in `PRELOAD_MODELS` in `docker-compose.yml` — models are not downloaded on demand. Edit the list and `docker compose up -d --force-recreate speaches`. See [docs/stt.md](docs/stt.md).
- **First transcription after a quiet period is slow.** The STT model unloads after 5 idle minutes and reloads on the next request (a few seconds). This is expected; see [docs/stt.md](docs/stt.md) to tune it.
