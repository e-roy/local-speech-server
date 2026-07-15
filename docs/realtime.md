# Realtime voice sessions

`/v1/realtime` is a WebSocket endpoint implementing the OpenAI Realtime API
shape, served by Speaches. It is the stack's **composed** mode: one
connection in which Speaches orchestrates STT → LLM → TTS server-side, with
voice-activity detection deciding when the speaker has finished a turn.

It is additive. The à-la-carte HTTP endpoints (`/v1/audio/*`, `/v1/llm/*`)
are unchanged and remain the right choice when an app wants the pieces
individually — see the design principle in [CLAUDE.md](../CLAUDE.md).

## Connecting

```
wss://speech.example.com/v1/realtime?model=<pulled-ollama-model>
```

Query parameters:

| Param | Required | Meaning |
|---|---|---|
| `model` | yes | The chat model for the session — any model pulled into the host-side Ollama (e.g. `gemma3:4b`). The consumer chooses; there is no privileged default. |
| `intent` | no | `conversation` (default, full voice loop) or `transcription` (live STT streaming only — no LLM, no TTS). |
| `language` | no | Input language hint; auto-detected when unset. |
| `transcription_model` | no | Override the STT model (defaults to the preloaded `Systran/faster-distil-whisper-small.en`). |

### Auth

- **Server-side clients** (Node, Python — anything that can set headers):
  `Authorization: Bearer <key>`, same as every other endpoint.
- **Browsers** cannot set headers on a `WebSocket`, so this endpoint — and
  only this endpoint — also accepts `&api_key=<key>` in the query string.
  Caveats: URLs appear in edge/proxy logs, so prefer header auth wherever
  possible; and the OpenAI JS trick of smuggling the key in
  `Sec-WebSocket-Protocol` does **not** work here (Speaches accepts the
  socket without echoing a subprotocol, which makes browsers abort the
  handshake — don't request subprotocols at all).
- CORS does not apply to WebSockets; the API key is the gate.

```js
const ws = new WebSocket(
  `wss://speech.example.com/v1/realtime?model=gemma3:4b&api_key=${KEY}`
);
```

## Session behavior

Defaults (adjustable per-session with a standard `session.update` event):
voice `af_heart`, PCM16 audio in and out, server-side VAD turn detection
(threshold 0.9, 550 ms of silence ends a turn). The event flow follows the
[OpenAI Realtime API](https://platform.openai.com/docs/guides/realtime)
event protocol — `input_audio_buffer.append` with base64 PCM16 audio in;
`input_audio_buffer.speech_started`, transcription events, and audio
response deltas out.

## Expectations and limitations

- **Turn-based, not interruptible.** The pinned Speaches release does not
  support `response.cancel`, so there is no barge-in — let a reply finish
  (or stop playback locally and ignore the rest).
- **Latency is "walkie-talkie", not "phone call".** Upstream notes
  realtime-grade performance requires CUDA, and realtime sessions use
  Speaches' *internal* CPU speech models — they do not benefit from the
  faster host-side engine that serves `/v1/audio/transcriptions` (those
  backends are not configurable upstream). Expect a few seconds from
  end-of-speech to first reply audio; the fast path for conversation is
  the client-orchestrated cascade ([consumer-integration.md](consumer-integration.md)).
- **Echo:** there is no server-side echo cancellation. If the mic can hear
  the speakers, the assistant will transcribe itself — use headphones or
  browser echo cancellation (`getUserMedia` `echoCancellation: true`).
- **LLM dependency:** conversation sessions require the host-side Ollama.
  If it is down, the socket still connects but responses fail mid-session —
  apps that care should check `GET /v1/llm/models` (cheap, catchable 502)
  before opening a session. `intent=transcription` sessions work without
  Ollama entirely.
- **WebRTC:** Speaches also ships a WebRTC transport, but WebRTC media
  (UDP) does not traverse the Cloudflare tunnel — it is unreachable in this
  deployment and deliberately unrouted.

## Verifying

`./scripts/verify-stack.sh` checks that the realtime TTS model is installed
and that the endpoint completes a WebSocket upgrade under both auth modes.
For a live end-to-end session test, any OpenAI Realtime-compatible client
pointed at `wss://<host>/v1/realtime?...` works.
