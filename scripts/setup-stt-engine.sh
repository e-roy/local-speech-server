#!/usr/bin/env bash
# One-command setup of the host-side STT engine (mlx-audio) on the Mac.
# Idempotent: safe to re-run over a partial or existing install (it reuses
# the venv, completes missing packages, rewrites the LaunchAgent, reloads
# the service, and re-warms the model). Also the update path: re-running
# upgrades mlx-audio and restarts the service.
#
# Usage: ./scripts/setup-stt-engine.sh
set -euo pipefail

ENGINE_DIR="$HOME/mlx-audio"
VENV="$ENGINE_DIR/.venv"
PLIST="$HOME/Library/LaunchAgents/com.local-speech.mlx-audio.plist"
LABEL="com.local-speech.mlx-audio"
PORT=8001
LOG=/tmp/mlx-audio.log

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

# The model to pre-warm: env override, then repo .env, then the default.
if [[ -z "${STT_MODEL:-}" && -f "$SCRIPT_DIR/../.env" ]]; then
  STT_MODEL=$(sed -n 's/^STT_MODEL=//p' "$SCRIPT_DIR/../.env" | head -1 | sed "s/^[\"']//; s/[\"']\$//")
fi
STT_MODEL="${STT_MODEL:-mlx-community/whisper-large-v3-turbo-asr-fp16}"

echo "Checking this is an Apple Silicon Mac..."
if [[ "$(uname -s)" != "Darwin" || "$(uname -m)" != "arm64" ]]; then
  echo "FAIL: mlx-audio requires macOS on Apple Silicon (this is $(uname -s)/$(uname -m))." >&2
  echo "      Run this script on the Mac that hosts the stack." >&2
  exit 1
fi
echo "  ok"

echo "Checking python3 >= 3.10..."
if ! command -v python3 >/dev/null || ! python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3,10) else 1)'; then
  echo "FAIL: python3 3.10+ not found. Install the Xcode Command Line Tools" >&2
  echo "      (xcode-select --install) or 'brew install python'." >&2
  exit 1
fi
echo "  ok ($(python3 --version))"

echo "Creating/reusing the venv at $VENV..."
mkdir -p "$ENGINE_DIR"
[[ -d "$VENV" ]] || python3 -m venv "$VENV"
echo "  ok"

echo "Installing mlx-audio with the server+stt extras (upgrades if present)..."
"$VENV/bin/pip" install --quiet --upgrade "mlx-audio[server,stt]"
echo "  ok"

echo "Sanity-checking the server can import..."
if ! "$VENV/bin/python" -c "import mlx_audio.server, uvicorn, fastapi" 2>/dev/null; then
  echo "FAIL: server imports failed even after install. Re-run with pip's" >&2
  echo "      output visible: $VENV/bin/pip install -U 'mlx-audio[server,stt]'" >&2
  exit 1
fi
echo "  ok"

echo "Writing the LaunchAgent ($PLIST)..."
# WorkingDirectory matters: the server creates a relative logs/ dir in its
# cwd, and launchd's default cwd is / — read-only on modern macOS.
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$VENV/bin/python</string>
        <string>-m</string><string>mlx_audio.server</string>
        <string>--host</string><string>127.0.0.1</string>
        <string>--port</string><string>$PORT</string>
    </array>
    <key>WorkingDirectory</key><string>$ENGINE_DIR</string>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>StandardOutPath</key><string>$LOG</string>
    <key>StandardErrorPath</key><string>$LOG</string>
</dict>
</plist>
EOF
echo "  ok"

echo "(Re)loading the service..."
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "  ok"

echo "Waiting for the server to answer on 127.0.0.1:$PORT..."
n=0
until code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 -X POST "http://127.0.0.1:$PORT/v1/audio/transcriptions" 2>/dev/null) && [[ "$code" != "000" ]]; do
  n=$((n+1))
  if [[ $n -gt 60 ]]; then
    echo "FAIL: the server did not come up within 120s. Check $LOG" >&2
    exit 1
  fi
  sleep 2
done
echo "  ok (answered $code)"

echo "Pre-warming $STT_MODEL (first run downloads the model — minutes; watch $LOG)..."
"$VENV/bin/python" - <<'PY'
import wave
w = wave.open("/tmp/stt-warm.wav", "w")
w.setnchannels(1); w.setsampwidth(2); w.setframerate(16000)
w.writeframes(b"\x00\x00" * 16000)
w.close()
PY
warm=$(curl -s -o /tmp/stt-warm-response.json -w '%{http_code}' --max-time 2400 \
  -F "file=@/tmp/stt-warm.wav;filename=warm.wav;type=audio/wav" \
  -F "model=$STT_MODEL" \
  "http://127.0.0.1:$PORT/v1/audio/transcriptions" || true)
if [[ "$warm" != "200" ]]; then
  echo "FAIL: pre-warm request returned ${warm:-000}." >&2
  echo "      Response: $(cat /tmp/stt-warm-response.json 2>/dev/null || echo '<none>')" >&2
  echo "      If the model ID was rejected, set STT_MODEL in the repo .env to a" >&2
  echo "      valid one and re-run. Server log: $LOG" >&2
  exit 1
fi
rm -f /tmp/stt-warm.wav /tmp/stt-warm-response.json

echo
echo "STT engine ready: mlx-audio on 127.0.0.1:$PORT (model: $STT_MODEL)."
echo "Reboot-safe via LaunchAgent $LABEL. Logs: $LOG"
echo "Next: ./scripts/verify-stack.sh"
