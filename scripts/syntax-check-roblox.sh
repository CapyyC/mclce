#!/usr/bin/env bash
# Parse-only check of Roblox glue (src/server, src/client). Type errors from
# Roblox globals are expected without Roblox type definitions and ignored;
# syntax errors fail.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ANALYZE="${LUAU_ANALYZE:-$ROOT/tools/bin/luau-analyze}"
cd "$ROOT"
OUT="$("$ANALYZE" --formatter=gnu $(find src/server src/client -name '*.luau') 2>&1 || true)"
if echo "$OUT" | grep -q "SyntaxError"; then
  echo "$OUT" | grep "SyntaxError"
  exit 1
fi
echo "roblox glue: no syntax errors"
