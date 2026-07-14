# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

An ops/config repo, not an application. There is no compiled code, no test suite, and no linter. The artifacts are:

- A 4-service `docker-compose.yml` (Kokoro-FastAPI + Speaches + Caddy + cloudflared)
- A Caddyfile that does auth + CORS + path-based reverse proxying
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
./scripts/init-env.sh                  # one-time: prompts for ALLOWED_ORIGINS, generates two API keys, writes .env
./scripts/generate-key.sh              # print a fresh 32-char URL-safe key
./scripts/verify-stack.sh smoke        # post-bringup checks against http://localhost:8080
./scripts/verify-stack.sh              # post-bringup checks against $SPEECH_BASE (or first entry in ALLOWED_ORIGINS)
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

Request path: **client → Cloudflare edge (TLS) → cloudflared (tunnel) → Caddy (auth/CORS/path routing) → Kokoro-FastAPI (`:8880`, `/v1/audio/speech` + `/v1/audio/voices`) or Speaches (`:8000`, `/v1/audio/transcriptions` + `/v1/audio/translations`)**. Authenticated requests to any other path get 404 — the published surface is deliberately smaller than what the backends expose.

All four containers share the `speech` bridge network. The Cloudflare tunnel's public hostname must point at `caddy:8080` (the Docker service name) — not `localhost` or `host.docker.internal` — because cloudflared resolves it over the internal Docker network. This is the most common operator misconfiguration; preserve it when editing tunnel docs.

Caddy is the only piece doing policy. Authentication is a regex match on a pipe-separated `${API_KEYS}` env var inlined into the Caddyfile (`^Bearer ({$API_KEYS})$`). CORS uses the same pattern: `${ALLOWED_ORIGINS}` is a pipe-separated allowlist inlined into a `header_regexp` matcher (`^({$ALLOWED_ORIGINS})$`); when the request's `Origin` matches, Caddy echoes it back as `Access-Control-Allow-Origin`. Note that pipes are regex alternation, so a literal `.` in an origin is technically a wildcard — fine for typical subdomain allowlists; document `\.` escaping if a stricter setup ever matters.

Kokoro-FastAPI and Speaches are upstream code we do not touch — both speak the OpenAI Audio API. Speaches is version-pinned (`0.9.0-rc.3-cpu`; the 0.9 line is required for `PRELOAD_MODELS`) and only serves models named in `PRELOAD_MODELS` — nothing downloads at request time. Models persist in the `kokoro_models` and `speaches_models` named volumes; first-run downloads are slow (minutes) and operators frequently mistake them for a hang.

State: the only stateful things in the stack are the two model volumes. The Cloudflare tunnel config lives in the Cloudflare dashboard, not in this repo. The tunnel token in `.env` is the only secret that needs backing up alongside the volumes.

## Conventions worth preserving

- **Placeholder rejection.** The Caddyfile explicitly 401s any `Bearer CHANGEME_*` token so a default-config boot cannot serve real traffic. Keep this matcher when editing auth logic — it is the safety net for `init-env.sh` not having been run.
- **Two-key rotation pattern.** `API_KEYS` is pipe-separated specifically to support zero-downtime rotation: add new key, restart Caddy, migrate consumers, remove old key. `init-env.sh` generates two keys for this reason.
- **`verify-stack.sh` is the troubleshooting entry point.** When something breaks, the README and this file both point operators to run it first. New checks belong there, in the same "fail with a specific message" style.
- **LF line endings everywhere.** `.gitattributes` enforces `eol=lf` for shell scripts, YAML, Caddyfile, HTML, Markdown, and `.env.example`. Editing on Windows (this repo's primary dev host) without respecting that will break the scripts on the Mac Mini target.
- **Named-volume naming.** Backup commands and `docker volume rm` invocations in `docs/operations.md` assume the compose project name is `local-speech-server` (taken from the directory name). If the directory is ever renamed, those commands need updating in lockstep.

## Extending the stack

STT is implemented — [docs/stt.md](docs/stt.md) documents the subsystem (model management, size/timeout limits, design rationale) and the remaining extension paths: Speaches' `/v1/realtime` WebSocket API, swapping the STT upstream for a native Metal engine on the host (`host.docker.internal`), or additional TTS engines routed by path. When touching the routing surface, preserve the auth/CORS layering in Caddy and the OpenAI-SDK compatibility the consumer integration depends on; consumers depend on the API shape, never on which engine serves it.
