#!/usr/bin/env bash
# Static type-check of engine-independent code (src/shared + tests).
# src/server and src/client use Roblox globals and must be checked in Studio.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ANALYZE="${LUAU_ANALYZE:-$ROOT/tools/bin/luau-analyze}"
cd "$ROOT"
mapfile -t FILES < <(find src/shared tests bench -name '*.luau' -not -path 'tests/roblox/*' -not -path 'bench/scratch/*' 2>/dev/null | sort)
"$ANALYZE" --formatter=gnu "${FILES[@]}"
