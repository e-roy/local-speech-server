#!/usr/bin/env bash
# Bootstrap .env with freshly generated API keys.
# Refuses to overwrite an existing .env.
# Usage: ./scripts/init-env.sh
set -euo pipefail

cd "$(dirname "$0")/.."

if [[ -f .env ]]; then
  echo "Refusing to overwrite existing .env." >&2
  echo "Delete it first if you really want to regenerate:" >&2
  echo "  rm .env && ./scripts/init-env.sh" >&2
  exit 1
fi

if [[ ! -f .env.example ]]; then
  echo ".env.example not found — run from a clone, not a tarball." >&2
  exit 1
fi

K1=$(./scripts/generate-key.sh)
K2=$(./scripts/generate-key.sh)

read -r -p "Allowed CORS origin(s), pipe-separated for multiple (e.g. https://app.example.com|http://localhost:5173): " ORIGINS
if [[ -z "$ORIGINS" ]]; then
  echo "ALLOWED_ORIGINS cannot be empty." >&2
  exit 1
fi

# Use perl for portable in-place substitution (sed -i differs between BSD and GNU).
# Pass the origin list via env var so the literal '|' between origins is not
# misread as a perl substitution delimiter.
cp .env.example .env
perl -pi -e "s|^API_KEYS=.*|API_KEYS=${K1}\\|${K2}|" .env
ORIGINS_VAL="$ORIGINS" perl -pi -e 's|^ALLOWED_ORIGINS=.*|ALLOWED_ORIGINS=$ENV{ORIGINS_VAL}|' .env

echo
echo "Wrote .env with two fresh API keys:"
echo "  Key 1: $K1"
echo "  Key 2: $K2"
echo
echo "CLOUDFLARE_TUNNEL_TOKEN is still a placeholder — paste the real token from"
echo "the Cloudflare Zero Trust dashboard before running 'docker compose up -d'."
