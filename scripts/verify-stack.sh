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

# shellcheck disable=SC1091
set -a; source .env; set +a

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
for svc in caddy kokoro; do
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

echo
echo "Stack healthy."
