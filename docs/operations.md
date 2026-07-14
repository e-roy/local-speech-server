# Operations

Day-to-day and one-time operator procedures.

## First-time Mac Mini setup

These system settings make the stack survive reboots, power blips, and being left alone for weeks without operator intervention.

1. **Auto-login.** System Settings → Users & Groups → "Automatically log in as" → set to a dedicated user account. (Docker Desktop runs in the user session; auto-login lets it come up after reboot without manual login.)
2. **Disable sleep.** System Settings → Energy → "Prevent automatic sleeping when display is off" → on. Headless sleep can sever the tunnel.
3. **Wake for network access.** System Settings → Energy → "Wake for network access" → on.
4. **Auto-restart after power failure.** System Settings → Energy → "Start up automatically after a power failure" → on.
5. **Docker Desktop autostart.** Docker Desktop → Settings → General → "Start Docker Desktop when you log in" → on. Also turn off "Open Docker Dashboard at startup" (no need for the GUI).
6. **Docker Desktop resources.** Docker Desktop → Settings → Resources → CPUs ≥ 4, Memory ≥ 6 GB. Kokoro-CPU is light; the STT model adds roughly a gigabyte while loaded — headroom helps.
7. **Container restart policy.** Already set to `restart: unless-stopped` in `docker-compose.yml`. Containers come back automatically when Docker Desktop comes back.
8. **Ollama autostart (only if using the LLM features).** Ollama menu-bar icon → Settings → "Start at login" → on. See [llm.md](llm.md).

Verify: reboot, wait ~60 seconds, and from a different machine run

```bash
curl -H "Authorization: Bearer $KEY" https://speech.example.com/v1/audio/voices
```

It should return 200 without any intervention on the Mac Mini.

## Key rotation

Rotate a compromised or stale key without downtime:

1. Generate a new key:
   ```bash
   ./scripts/generate-key.sh
   ```
2. Update `API_KEYS` in `.env` to include **both** the old and new key, pipe-separated:
   ```
   API_KEYS=old-key|new-key
   ```
3. Re-create Caddy so it picks up the new env — note this must be `up -d`,
   not `restart`; a plain restart reuses the container's original
   environment and would silently keep the old keys:
   ```bash
   docker compose up -d caddy
   ```
4. Roll the new key out to consumers.
5. Once all consumers are migrated, remove the old key from `.env` and run `docker compose up -d caddy` again.

## CORS origins

`ALLOWED_ORIGINS` in `.env` is a pipe-separated allowlist. Add or remove origins to support dev/prod splits, multiple consumer apps, or local development:

```
ALLOWED_ORIGINS=https://app.example.com|https://staging.example.com|http://localhost:5173
```

The Caddyfile inlines the value directly into a regex matcher (`^({$ALLOWED_ORIGINS})$`). When the request's `Origin` header matches, Caddy echoes it back as `Access-Control-Allow-Origin`; when it doesn't, no CORS header is set and the browser blocks the call.

After editing:

```bash
docker compose up -d caddy
```

(`up -d` re-creates the container because its environment changed. A plain
`docker compose restart` does **not** re-read `.env` — the container keeps
the environment it was created with.)

Notes:

- The pipe is the regex alternation operator — entries are independent regex alternatives, not literal strings. A literal `.` in an origin matches any character, so `app.example.com` would also match `appXexample.com`. For typical subdomain allowlists this is fine; if you need exact matching, escape dots as `\.`.
- Server-side callers (no `Origin` header) are unaffected — only bearer-token auth gates them.

## Updating Kokoro

```bash
docker compose pull kokoro
docker compose up -d --force-recreate kokoro
```

The model cache survives because of the named `kokoro_models` volume. If the new image changes the internal model directory path, update the volume mount in `docker-compose.yml` accordingly.

## Updating Speaches

Unlike the other images, Speaches is version-pinned in `docker-compose.yml`
(the 0.9 line is required for `PRELOAD_MODELS`; bump the `0.9.0-rc.3-cpu` tag
to `0.9.0` final when released). Edit the tag, then:

```bash
docker compose pull speaches
docker compose up -d --force-recreate speaches
```

The model cache survives in the `speaches_models` named volume.

## Changing the STT model

1. Edit `PRELOAD_MODELS` in `docker-compose.yml` — a JSON array of Hugging
   Face repo IDs; see [stt.md](stt.md) for sensible choices. Only listed
   models can be used; nothing downloads at request time. Keep the
   `speaches-ai/Kokoro-82M-v1.0-ONNX` entry — it is the TTS voice of
   `/v1/realtime` sessions ([realtime.md](realtime.md)).
2. Recreate the service; missing models download on startup:
   ```bash
   docker compose up -d --force-recreate speaches
   docker compose logs -f speaches   # watch the download
   ```
3. Roll the new model ID out to consumers (it is their `model` parameter).

Old models stay on disk until removed. Consumers can list installed models
via `GET /v1/models` (read-only, routed through Caddy), but installing and
deleting stay operator-only — run those on the Docker network:

```bash
docker compose exec speaches curl -s http://localhost:8000/v1/models
docker compose exec speaches curl -s -X DELETE "http://localhost:8000/v1/models/<model-id>"
```

## LLM upstream (Ollama on the host)

The LLM behind `/v1/llm/*` is **not part of the compose stack** — it is
Ollama running natively on the Mac (for GPU access; see
[llm.md](llm.md)). That makes it a host dependency with its own lifecycle:

- **Install / run:** the Ollama macOS app. For reboot-survival, enable
  "Start at login" (menu-bar icon → Settings), mirroring the Docker Desktop
  autostart in the first-time setup list above.
- **Models:** `ollama pull llama3.2:3b` (operator-only; consumers can list
  pulled models via `GET /v1/llm/models` but cannot install or delete).
- **Idle unload:** Ollama frees a model after ~5 idle minutes; set
  `OLLAMA_KEEP_ALIVE=1h` (or `-1` for never) in Ollama's environment if
  first-turn reload latency matters.
- **When it's down:** `/v1/llm/*` requests fail fast with an OpenAI-style
  JSON 502; TTS/STT are unaffected and `verify-stack.sh` reports a
  non-fatal WARN. Check with `ollama ps` on the host.

## Updating cloudflared

```bash
docker compose pull cloudflared
docker compose up -d --force-recreate cloudflared
```

## Backups

The only stateful things are the two model caches. To back them up:

```bash
docker run --rm \
  -v local-speech-server_kokoro_models:/data \
  -v "$(pwd)":/backup \
  alpine tar czf /backup/kokoro_models.tar.gz -C /data .

docker run --rm \
  -v local-speech-server_speaches_models:/data \
  -v "$(pwd)":/backup \
  alpine tar czf /backup/speaches_models.tar.gz -C /data .
```

(Both caches are also re-downloadable — a backup only saves bandwidth and
first-start time.)

(The volume name is `<compose-project>_<volume>`; `local-speech-server` is the compose project name, taken from the directory name.)

The only other secret is the Cloudflare Tunnel token in `.env`. The tunnel configuration itself lives in the Cloudflare dashboard, which is its own source of truth.

## Log inspection

```bash
docker compose logs -f              # all services
docker compose logs caddy           # auth / reverse proxy
docker compose logs kokoro          # synthesis / model loading
docker compose logs speaches        # transcription / STT model downloads
docker compose logs cloudflared     # tunnel registration / disconnects
```

## Tunnel diagnostics

- Cloudflare dashboard → **Networks** → **Tunnels** → click the tunnel → **Connectors** tab. The connector should show "Healthy."
- `docker compose logs cloudflared` shows registration and disconnect events in real time.
- If the tunnel is healthy but requests 502, check that Caddy is `Up` and that the public hostname's URL in the dashboard is `caddy:8080`.

## Wiping the model cache

Rarely needed — only if a model download is corrupted:

```bash
docker compose down
docker volume rm local-speech-server_kokoro_models
docker compose up -d
# Next start will re-download the model.
```

Same procedure for the STT cache with
`docker volume rm local-speech-server_speaches_models` — preloaded models
re-download on the next start.
