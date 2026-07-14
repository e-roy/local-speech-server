#!/usr/bin/env bash
# Generate a single 32-character URL-safe API key.
# Usage:
#   ./scripts/generate-key.sh
# To produce a pipe-separated list for two consumers:
#   echo "$(./scripts/generate-key.sh)|$(./scripts/generate-key.sh)"
set -euo pipefail
# Read a finite chunk first: piping endless /dev/urandom into a closing
# 'head' gets tr killed by SIGPIPE, which pipefail turns into exit 141.
# 1024 random bytes yield ~256 filtered chars — far more than 32.
head -c 1024 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9_-' | head -c 32
echo
