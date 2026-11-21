#!/bin/bash
# Runs test/e2e.mjs against `wrangler dev` with a throwaway local D1 (test/.state). From Services/accounts:
#   test/run.sh            (uses the website's wrangler, or WRANGLER=/path/to/wrangler)
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$(git rev-parse --show-toplevel)
COMMON=$(cd "$(git rev-parse --git-common-dir)/.." && pwd)
for candidate in "${WRANGLER:-}" "$ROOT/website/node_modules/.bin/wrangler" "$COMMON/website/node_modules/.bin/wrangler"; do
  [ -n "$candidate" ] && [ -x "$candidate" ] && { export WRANGLER=$candidate; break; }
done
[ -n "${WRANGLER:-}" ] || { echo "no wrangler: run npm ci in website/ or set WRANGLER" >&2; exit 1; }
node test/e2e.mjs
