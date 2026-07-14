# Consumer integration

This service speaks the [OpenAI Audio API](https://platform.openai.com/docs/api-reference/audio). Any client that targets that shape — including the official OpenAI SDKs — works with only a `baseURL` override.

## Endpoint

```
https://speech.example.com/v1/audio/speech           # TTS
https://speech.example.com/v1/audio/voices           # TTS voice listing
https://speech.example.com/v1/audio/transcriptions   # STT
https://speech.example.com/v1/audio/translations     # STT → English
```

Replace `speech.example.com` with the subdomain the operator chose.

## Auth

Every request (except CORS preflight `OPTIONS`) must include:

```
Authorization: Bearer <your-api-key>
```

The operator issues one key per consumer app. Treat keys like passwords — do not commit them, do not put them in client-side JS bundles without understanding the blast radius (a key in a browser bundle can be read by anyone who views the page).

## Using the OpenAI Node SDK

```ts
import OpenAI from "openai";

const client = new OpenAI({
  baseURL: "https://speech.example.com/v1",
  apiKey: process.env.SPEECH_API_KEY,
});

const audio = await client.audio.speech.create({
  model: "kokoro",
  voice: "af_bella",
  input: "Hello from a consumer app.",
  response_format: "mp3",
});

// audio is a Response; pipe audio.body to a file or play it
```

## Using `fetch()` from a browser

```ts
const res = await fetch("https://speech.example.com/v1/audio/speech", {
  method: "POST",
  headers: {
    "Authorization": `Bearer ${SPEECH_API_KEY}`,
    "Content-Type": "application/json",
  },
  body: JSON.stringify({
    model: "kokoro",
    voice: "af_bella",
    input: "Hello from the browser.",
    response_format: "mp3",
  }),
});
const blob = await res.blob();
new Audio(URL.createObjectURL(blob)).play();
```

> Only browsers loaded from an origin in the operator's `ALLOWED_ORIGINS` allowlist can call this from JS. For a different origin (e.g. a new app or a localhost dev server), ask the operator to add it to `ALLOWED_ORIGINS` and restart Caddy — see [operations.md](operations.md).

## Speech-to-text (transcription)

### Using the OpenAI Node SDK

```ts
import fs from "node:fs";

const transcript = await client.audio.transcriptions.create({
  file: fs.createReadStream("clip.wav"),
  model: "Systran/faster-distil-whisper-small.en",
});
console.log(transcript.text);
```

### Using `fetch()` from a browser

```ts
// `blob` is recorded audio, e.g. from MediaRecorder.
const form = new FormData();
form.append("file", blob, "clip.webm");
form.append("model", "Systran/faster-distil-whisper-small.en");

const res = await fetch("https://speech.example.com/v1/audio/transcriptions", {
  method: "POST",
  headers: { "Authorization": `Bearer ${SPEECH_API_KEY}` },
  body: form, // the browser sets the multipart Content-Type itself
});
const { text } = await res.json();
```

Notes:

- The `model` value is a Hugging Face repo ID — there is no `whisper-1`
  alias. It must be one of the models the operator preloaded (the default
  install ships `Systran/faster-distil-whisper-small.en`, English-only).
  Ask the operator, or see `PRELOAD_MODELS` in `docker-compose.yml`.
- `response_format` accepts `json` (default), `verbose_json`, `text`, `srt`,
  `vtt`. Pass `stream: true` to receive the transcript incrementally via
  server-sent events.
- Uploads are capped at 100 MB, and a single request should finish within
  ~100 s (Cloudflare's response timeout) — for long recordings use
  `stream=true` or split the audio client-side. Details in [stt.md](stt.md).
- `/v1/audio/translations` takes the same fields and returns English text.

## Voices

### Browse and audition

Open the voice browser at:

```
https://speech.example.com/voices
```

Paste a bearer key, type sample text, click any voice's **Play** button to hear it.
The page is auto-discovering — it lists exactly the voices installed in the running
Kokoro image.

### Naming convention

Voice IDs follow `<accent><gender>_<name>`:

| Accent | Gender | Example |
|---|---|---|
| `a` American | `f` female / `m` male | `af_bella`, `am_adam` |
| `b` British | `f` / `m` | `bf_emma`, `bm_lewis` |
| `j` Japanese | `f` / `m` | `jf_alpha` |
| `z` Mandarin | `f` / `m` | `zf_xiaobei` |
| `e` Spanish, `f` French, `h` Hindi, `i` Italian, `p` Portuguese | `f` / `m` | varies |

### Programmatic listing

```bash
curl -fsS -H "Authorization: Bearer $KEY" https://speech.example.com/v1/audio/voices | jq '.voices'
```

The set of installed voices is determined by the Kokoro-FastAPI image version,
not by this service. See the [Kokoro-FastAPI README](https://github.com/remsky/Kokoro-FastAPI)
for upstream voice details.

## Response formats

`response_format` accepts the standard OpenAI values: `mp3`, `opus`, `aac`, `flac`, `wav`, `pcm`. Kokoro-FastAPI streams the audio as HTTP chunked transfer — consumers can start playing before the synthesis is complete.

## Long inputs

Kokoro-FastAPI auto-stitches long inputs internally, but very long requests (many paragraphs) are best split by the consumer at paragraph boundaries — both for perceived latency (first audio arrives sooner) and to keep any single request short enough to resume cleanly if the tunnel hiccups.
