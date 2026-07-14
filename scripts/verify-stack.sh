#!/usr/bin/env bash
# Post-bringup health check.
# Usage:
#   ./scripts/verify-stack.sh                  # against the tunnel URL
#   ./scripts/verify-stack.sh smoke            # against http://localhost:8080
set -euo pipefail

cd "$(dirname "$0")/.."

MODE="${1:-prod}"

if [[ ! -f .env ]]; then
  echo "FAIL: .env not found. Run ./scripts/init-env.sh first." >&2
  exit 1
fi

# Read values verbatim rather than sourcing: API_KEYS and ALLOWED_ORIGINS
# legitimately contain '|', which 'source' would parse as a shell pipeline
# (and try to execute the second key as a command). Tolerate optional
# surrounding quotes, which compose and bash would both strip.
env_val() {
  sed -n "s/^${1}=//p" .env | head -1 | sed "s/^[\"']//; s/[\"']\$//"
}
API_KEYS=$(env_val API_KEYS)
ALLOWED_ORIGINS=$(env_val ALLOWED_ORIGINS)
SPEECH_BASE="${SPEECH_BASE:-$(env_val SPEECH_BASE)}"

KEY="${API_KEYS%%|*}"  # take first key from pipe-separated list
if [[ -z "$KEY" || "$KEY" == CHANGEME_* ]]; then
  echo "FAIL: API_KEYS is unset or still a CHANGEME_ placeholder." >&2
  exit 1
fi

if [[ "$MODE" == "smoke" ]]; then
  BASE="http://localhost:8080"
else
  # Fall back to the first origin in ALLOWED_ORIGINS if SPEECH_BASE is unset.
  # That fallback only works when an allowlisted origin happens to also be
  # the speech URL — multi-origin operators should set SPEECH_BASE explicitly.
  FIRST_ORIGIN="${ALLOWED_ORIGINS%%|*}"
  BASE="${SPEECH_BASE:-${FIRST_ORIGIN:-}}"
  if [[ -z "$BASE" || "$BASE" == CHANGEME_* ]]; then
    echo "FAIL: set SPEECH_BASE=https://speech.example.com and re-run." >&2
    exit 1
  fi
fi

echo "Checking containers are up..."
for svc in caddy kokoro speaches; do
  state=$(docker compose ps --format json "$svc" 2>/dev/null | grep -o '"State":"[^"]*"' | head -1 | cut -d'"' -f4 || true)
  if [[ "$state" != "running" ]]; then
    echo "FAIL: container '$svc' is not running (state: ${state:-missing})." >&2
    exit 1
  fi
done
echo "  ok"

echo "Checking Kokoro model files exist in the volume..."
if ! docker compose exec -T kokoro sh -c 'ls /app/api/src/models 2>/dev/null | grep -q .' ; then
  echo "FAIL: /app/api/src/models is empty. Either the first-run download is" >&2
  echo "      still in progress, or the upstream image moved the model dir." >&2
  echo "      Check 'docker compose logs kokoro' and the Kokoro-FastAPI README." >&2
  exit 1
fi
echo "  ok"

echo "Checking Speaches (STT) model cache..."
if ! docker compose exec -T speaches sh -c 'ls /home/ubuntu/.cache/huggingface/hub 2>/dev/null | grep -q .' ; then
  echo "FAIL: the Speaches model cache is empty. Either the startup download" >&2
  echo "      (PRELOAD_MODELS in docker-compose.yml) is still in progress, or" >&2
  echo "      it failed. Check 'docker compose logs speaches'." >&2
  exit 1
fi
echo "  ok"

echo "Checking $BASE is reachable and is this service..."
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$BASE/voices" || true)
if [[ "$code" == "000" ]]; then
  echo "FAIL: cannot connect to $BASE at all (DNS or TLS failed before any" >&2
  echo "      request reached the service). Check that the domain's" >&2
  echo "      nameservers still point at Cloudflare and the tunnel's public" >&2
  echo "      hostname exists: 'nslookup <host>' should return Cloudflare" >&2
  echo "      IPs, and the tunnel should show Healthy in the dashboard." >&2
  exit 1
elif [[ "$code" != "200" ]]; then
  echo "FAIL: $BASE answered, but /voices returned $code instead of 200 —" >&2
  echo "      that URL may not be this speech service (wrong SPEECH_BASE," >&2
  echo "      or DNS for the hostname points somewhere else)." >&2
  exit 1
fi
echo "  ok"

echo "Checking auth rejects an unknown key..."
code=$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer not-a-real-key" "$BASE/v1/audio/voices" || true)
if [[ "$code" != "401" ]]; then
  echo "FAIL: expected 401 for bogus key, got $code." >&2
  exit 1
fi
echo "  ok"

echo "Checking /v1/audio/voices with a real key..."
n=$(curl -fsS -H "Authorization: Bearer $KEY" "$BASE/v1/audio/voices" | grep -oE '"[a-z]{2}_[a-z]+"' | wc -l)
if [[ "$n" -lt 1 ]]; then
  echo "FAIL: voices endpoint returned no voices." >&2
  exit 1
fi
echo "  ok ($n voices installed)"

# Use the first preloaded model from docker-compose.yml unless overridden.
STT_MODEL="${STT_MODEL:-$(docker compose config 2>/dev/null | sed -n 's/.*PRELOAD_MODELS[=:][^[]*\["\([^"]*\)".*/\1/p' | head -1)}"
STT_MODEL="${STT_MODEL:-Systran/faster-distil-whisper-small.en}"

echo "Checking /v1/models lists the STT model..."
if ! curl -fsS -H "Authorization: Bearer $KEY" "$BASE/v1/models" | grep -q "$STT_MODEL"; then
  echo "FAIL: /v1/models did not include $STT_MODEL. Either the model" >&2
  echo "      download failed (check 'docker compose logs speaches') or the" >&2
  echo "      Caddy models route is missing." >&2
  exit 1
fi
echo "  ok"

echo "Checking TTS -> STT round-trip (synthesize a clip, then transcribe it)..."
clip=$(mktemp)
trap 'rm -f "$clip"' EXIT
if ! curl -fsS -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
  -d '{"model":"kokoro","voice":"af_bella","input":"stack verification test","response_format":"wav"}' \
  -o "$clip" "$BASE/v1/audio/speech"; then
  echo "FAIL: TTS synthesis request failed. Check 'docker compose logs kokoro'." >&2
  exit 1
fi
transcript=$(curl -fsS -H "Authorization: Bearer $KEY" \
  -F "file=@$clip;filename=check.wav;type=audio/wav" \
  -F "model=$STT_MODEL" \
  "$BASE/v1/audio/transcriptions" || true)
if ! grep -qi "verification" <<<"$transcript"; then
  echo "FAIL: transcription of a synthesized clip did not contain 'verification'." >&2
  echo "      Response: ${transcript:-<empty>}" >&2
  echo "      If the model is still loading (first request after a restart is" >&2
  echo "      slow), re-run. Otherwise check 'docker compose logs speaches'." >&2
  exit 1
fi
echo "  ok (model: $STT_MODEL)"

echo
echo "Stack healthy."
