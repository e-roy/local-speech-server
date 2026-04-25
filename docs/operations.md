# Operations

Day-to-day and one-time operator procedures.

## First-time Mac Mini setup

These system settings make the stack survive reboots, power blips, and being left alone for weeks without operator intervention.

1. **Auto-login.** System Settings → Users & Groups → "Automatically log in as" → set to a dedicated user account. (Docker Desktop runs in the user session; auto-login lets it come up after reboot without manual login.)
2. **Disable sleep.** System Settings → Energy → "Prevent automatic sleeping when display is off" → on. Headless sleep can sever the tunnel.
3. **Wake for network access.** System Settings → Energy → "Wake for network access" → on.
4. **Auto-restart after power failure.** System Settings → Energy → "Start up automatically after a power failure" → on.
5. **Docker Desktop autostart.** Docker Desktop → Settings → General → "Start Docker Desktop when you log in" → on. Also turn off "Open Docker Dashboard at startup" (no need for the GUI).
6. **Docker Desktop resources.** Docker Desktop → Settings → Resources → CPUs ≥ 4, Memory ≥ 4 GB. Kokoro-CPU is light, but headroom helps.
7. **Container restart policy.** Already set to `restart: unless-stopped` in `docker-compose.yml`. Containers come back automatically when Docker Desktop comes back.

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
3. Restart Caddy so it picks up the new env:
   ```bash
   docker compose restart caddy
   ```
4. Roll the new key out to consumers.
5. Once all consumers are migrated, remove the old key from `.env` and restart Caddy again.

## Multi-origin CORS

The default `ALLOWED_ORIGIN` is a single origin. To allow multiple origins, replace the static CORS header lines in `caddy/Caddyfile` with a regex matcher that echoes the request's `Origin` back when it matches an allowlist:

```caddy
@allowedOrigin header_regexp Origin "^(https://app1\.example\.com|https://app2\.example\.com)$"
header @allowedOrigin Access-Control-Allow-Origin "{header.Origin}"
header @allowedOrigin Vary "Origin"
```

Apply this in both the `@preflight` and `@authed` handlers, replacing the `header Access-Control-Allow-Origin "{$ALLOWED_ORIGIN}"` lines. Then:

```bash
docker compose restart caddy
```

## Updating Kokoro

```bash
docker compose pull kokoro
docker compose up -d --force-recreate kokoro
```

The model cache survives because of the named `kokoro_models` volume. If the new image changes the internal model directory path, update the volume mount in `docker-compose.yml` accordingly.

## Updating cloudflared

```bash
docker compose pull cloudflared
docker compose up -d --force-recreate cloudflared
```

## Backups

The only stateful thing is the model cache. To back it up:

```bash
docker run --rm \
  -v local-speech-server_kokoro_models:/data \
  -v "$(pwd)":/backup \
  alpine tar czf /backup/kokoro_models.tar.gz -C /data .
```

(The volume name is `<compose-project>_<volume>`; `local-speech-server` is the compose project name, taken from the directory name.)

The only other secret is the Cloudflare Tunnel token in `.env`. The tunnel configuration itself lives in the Cloudflare dashboard, which is its own source of truth.

## Log inspection

```bash
docker compose logs -f              # all services
docker compose logs caddy           # auth / reverse proxy
docker compose logs kokoro          # synthesis / model loading
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
