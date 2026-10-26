# mclce — Minecraft PS4 Legacy Console Edition (1.95) behaviour port to Roblox

Read `PROJECT_STATUS.md` first, then `ROADMAP.md`. `COMPATIBILITY.md` tracks fidelity,
`TESTING.md` tracks how things are verified.

## Toolchain
- `scripts/setup-luau.sh` — builds `luau` + `luau-analyze` from the official
  luau-lang/luau source (pinned commit) into `tools/bin/` (gitignored). Needs git, cmake, a C++17 compiler.
- `scripts/test.sh` — runs every `tests/**/*.spec.luau` (pure Luau, no Roblox). `--filter=<substr>` narrows.
- `scripts/analyze.sh` — strict type-check of `src/shared`, `tests`, `bench`.
- `scripts/bench.sh` — runs micro-benchmarks in `bench/` (work counts + CPU time of the CLI VM, not Roblox frame time).
- Rojo mapping is `default.project.json` (`rojo serve` / `rojo build -o mclce.rbxlx`).

## Layout / rules
- `src/shared` → `ReplicatedStorage.Shared`. Engine-independent Luau ONLY: no `game`, `Instance`,
  `Vector3`, `task`, etc. Everything here must be unit-testable in the CLI.
- `src/server` → `ServerScriptService.Server`, `src/client` → `StarterPlayer.StarterPlayerScripts.Client`.
  These are thin Roblox glue (services, remotes, Instances) and cannot run in the CLI.
- Shared modules require each other with relative string requires (`require("./Chunk")`,
  `require("../Voxel/Coords")`) — valid both in the Luau CLI and in Roblox require-by-string.
  Roblox glue requires shared code via instances (`require(ReplicatedStorage.Shared.Voxel.World)`).
- No proprietary assets or decompiled/leaked code in the repo. Behaviour is reimplemented clean-room
  from public documentation; record every fidelity claim's evidence level in COMPATIBILITY.md.
- Block state = `id * 16 + meta` (u16). Chunk = 16x256x16, sections of 16^3, index `x + z*16 + y*256`.

## Handoff to a local session (Roblox Studio / Studio MCP)
What the cloud sessions could NOT do: run Roblox Studio, Rojo, live multiplayer, or measure frame time.
A local session with Studio (and optionally the Roblox Studio MCP server) should:
1. `scripts/setup-luau.sh && scripts/test.sh && scripts/analyze.sh` — must be green.
2. `rojo serve` and connect the Studio Rojo plugin (or `rojo build -o mclce.rbxlx` and open it).
3. Follow `TESTING.md` → "Manual Studio verification" step by step; record results there.
4. Via Studio MCP you can run Luau in the edit/play DataModel: e.g. require
   `ReplicatedStorage.Shared...` modules and call them, inspect `workspace.World` chunk models,
   and read the `[mclce]` diagnostic output printed by the server/client bootstraps.
5. Fix any Roblox-only failures in `src/server` / `src/client`; keep `src/shared` CLI-testable.
