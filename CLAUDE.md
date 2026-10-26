# mclce — Minecraft PS4 Legacy Console Edition (1.95) behaviour port to Roblox

Start every session by reading `PROJECT_STATUS.md` (state, gaps, next tasks), then `ROADMAP.md`.
`COMPATIBILITY.md` = fidelity evidence per feature; `TESTING.md` = how things are verified and the
manual Studio checklist; `docs/adr/` = lasting decisions.

## Toolchain
- `scripts/setup-luau.sh` — builds `luau` + `luau-analyze` from official luau-lang/luau source
  (pinned commit) into `tools/bin/` (gitignored). Needs git, cmake, C++17 compiler.
- `scripts/test.sh` — all `tests/**/*.spec.luau` (pure Luau). `--filter=<substring>` narrows.
- `scripts/analyze.sh` — strict type-check of `src/shared`, `tests/shared`, `bench`.
- `scripts/syntax-check-roblox.sh` — parse check of the Roblox glue.
- `scripts/test-roblox-mock.sh [parts|mesh]` — runs the REAL `src/server` + `src/client` glue in a
  mock DataModel (`tests/roblox/`), both renderer modes by default.
- `scripts/bench.sh [--quick]` — benchmarks (Luau CLI VM timings, not Roblox frame times).
- Rojo: `rokit install` (or aftman) then `rojo serve` / `rojo build -o mclce.rbxlx`; mapping in
  `default.project.json`. JDK is only needed to regenerate `tests/fixtures/JavaRandomFixture.luau`.
- All of the above must stay green before committing (CI runs them: `.github/workflows/ci.yml`).

## Layout / rules
- `src/shared` → `ReplicatedStorage.Shared`: engine-independent Luau ONLY (no `game`, `Instance`,
  `Vector3`, `task`...). All game rules live here and are CLI-tested.
- `src/server` → `ServerScriptService.Server`, `src/client` → `StarterPlayer.StarterPlayerScripts.Client`:
  thin Roblox glue. Keep logic out of it; if you add logic, put it in shared and test it.
- Shared modules use relative string requires (`require("./Chunk")`); glue requires shared code via
  instances (`require(ReplicatedStorage.Shared.Sim.GameServer)`).
- Block state = `id * 16 + meta` (u16, classic numeric ids). Chunk 16x256x16, sections 16^3,
  index `x + z*16 + y*256`. Positions in shared code are in blocks; `Config.BLOCK_SIZE` studs/block.
- Network: one RemoteEvent each way (`mclceC2S`, `mclceS2C`); every client message is validated in
  `Shared/Net/Protocol.luau` and re-validated by `GameServer`. Client sends JOIN before anything is sent.
- No proprietary assets or decompiled/leaked code. Clean-room behaviour from public documentation;
  record evidence level for every fidelity claim in COMPATIBILITY.md. Never claim Studio-verified
  unless it was run in Studio.

## Handoff to a local session with Roblox Studio (and optionally an MCP server for Studio)
The cloud sessions could NOT run Studio, Rojo, real multiplayer or measure FPS. A local session should:
1. `scripts/setup-luau.sh && scripts/test.sh && scripts/analyze.sh && scripts/test-roblox-mock.sh`.
2. `rokit install && rojo serve`, connect the Rojo Studio plugin (or `rojo build -o mclce.rbxlx`).
3. Work through TESTING.md → "Manual Studio verification" in order; record results there and in
   PROJECT_STATUS.md. First risk to check: relative string `require` inside ReplicatedStorage.Shared.
4. If an MCP server for Roblox Studio is connected (e.g. Roblox's open-source Studio MCP server), use it
   to run Luau in Studio and inspect state through the debug handles:
   - server: `_G.mclceServer.gs` (GameServer: `.world`, `.players`, `.mobs`, `.stats`, `.light`)
   - client: `_G.mclceClient.cw` (ClientWorld) and `_G.mclceClient.renderer` (`.stats`)
   - renderer switch: `workspace:SetAttribute("mclceRenderer", "mesh")` before the client starts.
5. Fix Roblox-only failures in `src/server`/`src/client`; if the fix reveals a rules bug, fix it in
   shared code with a CLI test. Update the mock (`tests/roblox/MockRoblox.luau`) when the real engine
   behaves differently from it, so the mock keeps catching that class of bug.
