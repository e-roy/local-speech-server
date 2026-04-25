# Adding STT (speech-to-text)

A future extension: add a `/v1/audio/transcriptions` endpoint matching the OpenAI Whisper API shape, so the service provides both TTS and STT behind the same base URL.

## Recommended engine

[Speaches](https://github.com/speaches-ai/speaches) (formerly `faster-whisper-server`) — exposes the OpenAI Whisper API surface directly and ships as a Docker image, so integration is a matter of adding a service and a Caddy route.

Alternative: [whisper-asr-webservice](https://github.com/ahmetoner/whisper-asr-webservice). Also dockerized, but uses its own API shape — less drop-in for consumers already using the OpenAI SDK.

## Steps

### 1. Add the STT service to `docker-compose.yml`

Append under `services:`:

```yaml
speaches:
  image: ghcr.io/speaches-ai/speaches:latest-cpu
  container_name: speech-speaches
  restart: unless-stopped
  expose:
    - "8000"
  volumes:
    - speaches_models:/app/models
  environment:
    - WHISPER__MODEL=Systran/faster-whisper-base.en
  networks:
    - speech
```

And add `speaches_models:` under the `volumes:` block at the bottom of the file.

### 2. Update `caddy/Caddyfile` to route by path

Replace the single `reverse_proxy kokoro:8880` block inside `handle @authed` with path-based routing:

```caddy
handle @authed {
    header Access-Control-Allow-Origin "{$ALLOWED_ORIGIN}"
    header Vary "Origin"

    # TTS
    @tts path /v1/audio/speech*
    handle @tts {
        reverse_proxy kokoro:8880 {
            flush_interval -1
        }
    }

    # STT
    @stt path /v1/audio/transcriptions* /v1/audio/translations*
    handle @stt {
        reverse_proxy speaches:8000 {
            # Whisper requests can be large (audio uploads); raise body limit
            request_body {
                max_size 100MB
            }
        }
    }

    # Voice listing — Kokoro
    @voices path /v1/audio/voices*
    handle @voices {
        reverse_proxy kokoro:8880
    }

    # Anything else under /v1/audio: 404
    respond 404
}
```

### 3. Bring it up

```bash
docker compose pull speaches
docker compose up -d
```

First run downloads the Whisper model into the `speaches_models` named volume.

### 4. Verify

```bash
curl -fsS https://speech.example.com/v1/audio/transcriptions \
  -H "Authorization: Bearer $KEY" \
  -F file=@/path/to/test.wav \
  -F model=Systran/faster-whisper-base.en
```

Expected: JSON with a `text` field containing the transcript.

### 5. Document the new endpoint

Add an OpenAI-SDK example to `docs/consumer-integration.md`:

```ts
const transcript = await client.audio.transcriptions.create({
  file: fs.createReadStream("clip.wav"),
  model: "Systran/faster-whisper-base.en",
});
```

## Related extensions

### Streaming TTS via SSE / WebSocket

Kokoro-FastAPI's HTTP chunked response handles streaming for most consumers. If a future use case needs true WebSocket streaming (e.g., a real-time voice agent), evaluate [Paroli](https://github.com/marty1885/paroli) as an alternative engine and add it as a parallel service.

### Multiple voice models

If multiple TTS engines are desired (e.g., Kokoro + Piper for different voice characters), add Piper as a parallel service and route by URL path (`/v1/audio/speech/kokoro`, `/v1/audio/speech/piper`). Routing by a JSON body field is possible in Caddy but awkward — URL paths with a thin client-side shim are cleaner.
