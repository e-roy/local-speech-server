#!/usr/bin/env bash
# Generate a single 32-character URL-safe API key.
# Usage:
#   ./scripts/generate-key.sh
# To produce a pipe-separated list for two consumers:
#   echo "$(./scripts/generate-key.sh)|$(./scripts/generate-key.sh)"
set -euo pipefail
LC_ALL=C tr -dc 'A-Za-z0-9_-' </dev/urandom | head -c 32
echo
