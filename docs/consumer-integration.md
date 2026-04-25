# Consumer integration

This service speaks the [OpenAI Audio API](https://platform.openai.com/docs/api-reference/audio). Any client that targets that shape — including the official OpenAI SDKs — works with only a `baseURL` override.

## Endpoint

```
https://speech.example.com/v1/audio/speech
https://speech.example.com/v1/audio/voices
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

> Only browsers loaded from the configured `ALLOWED_ORIGIN` can call this from JS. For a different origin, ask the operator to update `ALLOWED_ORIGIN` and restart Caddy, or to switch to the multi-origin Caddyfile snippet in [operations.md](operations.md).

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
