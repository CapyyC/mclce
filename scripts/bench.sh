#!/usr/bin/env bash
# Runs pure-Luau micro-benchmarks. Numbers are Luau CLI VM timings on this
# machine, NOT Roblox client/server timings.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LUAU="${LUAU:-$ROOT/tools/bin/luau}"
cd "$ROOT/bench"
"$LUAU" --codegen -O2 run.luau -a "$@"
