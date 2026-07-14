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

> Only browsers loaded from an origin in the operator's `ALLOWED_ORIGINS` allowlist can call this from JS. For a different origin (e.g. a new app or a localhost dev server), ask the operator to add it to `ALLOWED_ORIGINS` and re-apply the config — see [operations.md](operations.md).

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

## Discovering models

`GET /v1/models` (and `GET /v1/models/{id}`) returns the installed STT models
in the standard OpenAI list shape — useful for agents and SDKs that discover
models instead of hardcoding IDs:

```ts
const models = await client.models.list();
// -> data: [{ id: "Systran/faster-distil-whisper-small.en", ... }]
```

Two caveats:

- The list covers **STT models only**. TTS does not appear in it — the TTS
  model is always `"kokoro"`, and voices are discovered via
  `/v1/audio/voices`. LLM models have their own listing (next section).
- The endpoint is read-only through this service; installing or removing
  models is an operator action (see [operations.md](operations.md)).

## LLM (chat completions)

The service also fronts an LLM (Ollama running on the host). It has its own
OpenAI surface under `/v1/llm` — use a client instance with that base URL
and everything is SDK-standard, same API key:

```ts
const llm = new OpenAI({
  baseURL: "https://speech.example.com/v1/llm",
  apiKey: process.env.SPEECH_API_KEY,
});

const models = await llm.models.list();          // discover pulled models
const stream = await llm.chat.completions.create({
  model: "llama3.2:3b",                          // any pulled model
  messages: [{ role: "user", content: transcript.text }],
  stream: true,                                  // prefer streaming
});
```

Notes:

- **Treat the model name as config** (env var next to the API key), like the
  STT model. Unknown/unpulled models return a 404 from the engine; pulling
  models is an operator action.
- **Prefer `stream: true`** — better perceived latency for voice UX, and
  long generations stay clear of Cloudflare's ~100 s response timeout.
- **Handle the LLM being offline.** It runs on the host, outside the Docker
  stack, and may be down independently of TTS/STT. In that case requests
  fail fast (~2 s) with a 502 and an OpenAI-style JSON error
  (`code: "upstream_unavailable"`) — catch it and degrade gracefully:

```ts
try {
  const reply = await llm.chat.completions.create({ ... });
} catch (err) {
  if (err instanceof OpenAI.APIError && err.status === 502) {
    // LLM offline — transcription/TTS still work; degrade accordingly.
  } else throw err;
}
```

- For a voice loop (hear → think → speak), chain the three calls:
  `/v1/audio/transcriptions` → `/v1/llm/chat/completions` →
  `/v1/audio/speech`. Stream the LLM tokens and start TTS on the first
  sentence boundary for the snappiest feel. Details and roadmap in
  [llm.md](llm.md).

## Realtime voice sessions (WebSocket)

For hands-free conversation, `wss://speech.example.com/v1/realtime` runs the
whole hear → think → speak loop server-side over one WebSocket, with
voice-activity detection handling turn-taking (OpenAI Realtime API event
protocol). The chat model is chosen per session
(`?model=<pulled-ollama-model>`), and browsers authenticate with
`&api_key=<key>` since they cannot set WebSocket headers. Connection
details, session defaults, and honest limitations (turn-based, no barge-in,
seconds-per-turn latency) are in [realtime.md](realtime.md). The HTTP
endpoints above remain the right choice for everything that isn't a live
conversation.

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
