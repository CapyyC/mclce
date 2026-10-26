#!/usr/bin/env bash
# Runs all *.spec.luau files under tests/ with the standalone Luau CLI.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LUAU="${LUAU:-$ROOT/tools/bin/luau}"
cd "$ROOT/tests"
mapfile -t SPECS < <(find . -name '*.spec.luau' | sort | sed 's/\.luau$//')
"$LUAU" run.luau -a "${SPECS[@]}" "$@"
