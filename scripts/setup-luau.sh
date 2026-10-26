#!/usr/bin/env bash
# Builds the standalone Luau CLI (luau + luau-analyze) from the official
# luau-lang/luau source into tools/bin. Pinned for reproducibility.
set -euo pipefail
LUAU_COMMIT="${LUAU_COMMIT:-32c28089305f488f901aaf1dbf3fd1cb65fa3d11}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/tools/luau-src"
if [ -x "$ROOT/tools/bin/luau" ] && [ -x "$ROOT/tools/bin/luau-analyze" ]; then
  echo "luau already built in tools/bin"; exit 0
fi
mkdir -p "$ROOT/tools/bin"
if [ ! -d "$SRC/.git" ]; then
  git clone https://github.com/luau-lang/luau.git "$SRC"
fi
git -C "$SRC" fetch --depth 1 origin "$LUAU_COMMIT" 2>/dev/null || true
git -C "$SRC" checkout -q "$LUAU_COMMIT"
cmake -S "$SRC" -B "$SRC/build" -DCMAKE_BUILD_TYPE=Release
cmake --build "$SRC/build" --target Luau.Repl.CLI Luau.Analyze.CLI -j"$(nproc 2>/dev/null || echo 4)"
cp "$SRC/build/luau" "$SRC/build/luau-analyze" "$ROOT/tools/bin/"
echo "built: $ROOT/tools/bin/luau"
