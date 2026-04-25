# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

An ops/config repo, not an application. There is no compiled code, no test suite, and no linter. The artifacts are:

- A 3-service `docker-compose.yml` (Kokoro-FastAPI + Caddy + cloudflared)
- A Caddyfile that does auth + CORS + reverse proxy
- Bash scripts under `scripts/` for setup and verification
- Operator documentation under `docs/`

Changes here are almost always edits to the Caddyfile, the compose file, or the docs. Treat doc accuracy as load-bearing — operators follow the README literally.

## Common commands

Bring-up modes (run from repo root, `.env` must exist):

```bash
# Smoke test — Caddy on 127.0.0.1:8080, no tunnel
docker compose -f docker-compose.yml -f docker-compose.smoke.yml up -d

# Full stack including the Cloudflare tunnel
docker compose up -d --force-recreate
```

Setup and verification:

```bash
./scripts/init-env.sh                  # one-time: prompts for ALLOWED_ORIGIN, generates two API keys, writes .env
./scripts/generate-key.sh              # print a fresh 32-char URL-safe key
./scripts/verify-stack.sh smoke        # post-bringup checks against http://localhost:8080
./scripts/verify-stack.sh              # post-bringup checks against $SPEECH_BASE (or ALLOWED_ORIGIN)
```

After editing the Caddyfile or `.env`:

```bash
docker compose restart caddy
```

After editing `docker-compose.yml` for an existing service:

```bash
docker compose up -d --force-recreate <service>
```

## Architecture

Request path: **client → Cloudflare edge (TLS) → cloudflared (tunnel) → Caddy (auth/CORS/proxy) → Kokoro-FastAPI (`:8880`)**.

All three containers share the `speech` bridge network. The Cloudflare tunnel's public hostname must point at `caddy:8080` (the Docker service name) — not `localhost` or `host.docker.internal` — because cloudflared resolves it over the internal Docker network. This is the most common operator misconfiguration; preserve it when editing tunnel docs.

Caddy is the only piece doing policy. Authentication is a regex match on a pipe-separated `${API_KEYS}` env var inlined into the Caddyfile (`^Bearer ({$API_KEYS})$`). CORS is a single `${ALLOWED_ORIGIN}`; multi-origin support requires swapping the static header for a regex matcher (see [docs/operations.md](docs/operations.md)).

Kokoro-FastAPI is upstream code we do not touch — it already speaks the OpenAI Audio API (`/v1/audio/speech`, `/v1/audio/voices`). Models persist in the `kokoro_models` named volume; first-run download is slow (minutes) and operators frequently mistake it for a hang.

State: the only stateful thing in the stack is `kokoro_models` (and a future `speaches_models` if STT is added). The Cloudflare tunnel config lives in the Cloudflare dashboard, not in this repo. The tunnel token in `.env` is the only secret that needs backing up alongside the volume.

## Conventions worth preserving

- **Placeholder rejection.** The Caddyfile explicitly 401s any `Bearer CHANGEME_*` token so a default-config boot cannot serve real traffic. Keep this matcher when editing auth logic — it is the safety net for `init-env.sh` not having been run.
- **Two-key rotation pattern.** `API_KEYS` is pipe-separated specifically to support zero-downtime rotation: add new key, restart Caddy, migrate consumers, remove old key. `init-env.sh` generates two keys for this reason.
- **`verify-stack.sh` is the troubleshooting entry point.** When something breaks, the README and this file both point operators to run it first. New checks belong there, in the same "fail with a specific message" style.
- **LF line endings everywhere.** `.gitattributes` enforces `eol=lf` for shell scripts, YAML, Caddyfile, HTML, Markdown, and `.env.example`. Editing on Windows (this repo's primary dev host) without respecting that will break the scripts on the Mac Mini target.
- **Named-volume naming.** Backup commands and `docker volume rm` invocations in `docs/operations.md` assume the compose project name is `local-speech-server` (taken from the directory name). If the directory is ever renamed, those commands need updating in lockstep.

## Extending the stack

The STT extension path is fully spec'd in [docs/adding-stt.md](docs/adding-stt.md): add a Speaches service, replace the single `reverse_proxy kokoro:8880` in the Caddyfile's `@authed` block with path-based routing for `/v1/audio/speech*`, `/v1/audio/transcriptions*`, and `/v1/audio/voices*`. Follow that doc rather than improvising — it preserves the auth/CORS surface and the OpenAI-SDK compatibility the consumer integration depends on.
