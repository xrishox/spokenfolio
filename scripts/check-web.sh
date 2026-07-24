#!/bin/bash
# WebUI verification: types, tests, and a production build.
set -euo pipefail
cd "$(dirname "$0")/../webui"
if ! command -v npm >/dev/null 2>&1; then
  echo "check-web: npm not found; install Node 22 (see webui/.nvmrc)" >&2
  exit 69
fi
npm ci --no-audit --no-fund
npx vitest run
npm run build
