# Testing

## Automated (CLI, no Roblox)
```
scripts/setup-luau.sh          # once: builds luau + luau-analyze from official source
scripts/analyze.sh             # strict type-check of src/shared, tests, bench
scripts/syntax-check-roblox.sh # parse-check of src/server + src/client (Roblox globals unchecked)
scripts/test.sh                # all specs (add --filter=<substring>)
scripts/bench.sh               # micro-benchmarks (Luau CLI VM timings only; --quick in CI)
```
Last run (session 1): **136 passed, 0 failed**; analyzer clean; Roblox glue parses.

## Coverage by area
| Area | Spec | Independent oracle |
|---|---|---|
| Coordinates, negative coords, chunk keys | Coords.spec | exhaustive round-trips |
| Block registry, state packing | BlockRegistry.spec | classic ID/hardness table |
| Chunk storage, heightmap | Chunk.spec | randomized vs reference table + brute-force heights |
| World addressing, border, listeners | World.spec | hand-computed |
| Face culling + greedy quads | SectionMesher.spec | brute-force face set from World.getState |
| Box meshing | BoxMesher.spec | coverage invariant over every visible cell |
| java.util.Random | JavaRandom.spec | **JDK-generated golden fixture** (tools/fixtures) |
| Perlin noise | Noise.spec | fast path bit-identical to reference impl |
| World generation | WorldGen.spec | determinism, order independence, seams, ore depth |
| Caves | CaveCarver.spec | brute-force union of blobs (seamless across chunks) |
| Raycast | VoxelRaycast.spec | dense segment sampling |
| Collision | Collision.spec | hand-computed contacts |
| Codec/Base64/varints | Codec.spec | RFC 4648 vectors, fuzz + truncation |
| Streaming/remesh | Streaming.spec | hand-computed sets |
| Items, mining, inventory | Items.spec | **published classic break-time table**; randomized conservation |
| Crafting | Crafting.spec | recipe facts; atomic rollback |
| Protocol validation | Protocol.spec | malformed-input table |
| Persistence | SaveManager.spec | fault injection, migrations, in-flight edits |
| Server core | GameServer.spec | break timing, reach, rate limit, restart persistence, failed reads |
| Client/server | ClientServer.spec | replica convergence, prediction rollback, mobs, eating |
| Survival | Survival.spec, GameServerSurvival.spec | classic constants (fall = ceil(d-3), regen 80 t) |
| Fluids | Fluids.spec | 7-block diamond = 113 cells; lava 30 t / 2 per block |
| Light | LightEngine.spec | brute-force relaxation fixpoint after random edits |
| Mobs | Mobs.spec, GameServerMobs.spec | jump apex 1.2522, i-frames, fuse 30 t |
| Time | Time.spec | noon 0 / midnight 11 darkness |
| Block entities | BlockEntities.spec, GameServerContainers.spec | coal smelts exactly 8; persistence |
| Block updates/farming | BlockUpdates.spec, GameServerFarming.spec | support rules, growth, buckets |

## Manual Studio verification (cannot be run in the cloud sessions)
Prereq: Rojo 7.x, `rojo serve` + Studio plugin (or `rojo build -o mclce.rbxlx`). Enable
*Game Settings → Security → Enable Studio Access to API Services* to test real DataStores; without it
the server warns and uses a NON-persistent memory backend.

0. **Tools for testing**: press T to chat; in Studio every player is host, so commands work:
   `/gamemode creative`, `/time set night`, `/weather thunder`, `/give diamond_pickaxe`,
   `/give 49 14` (obsidian), `/give flint_and_steel`, `/tp x y z`, `/heal`, `/kill`.
   Keys: LMB mine/attack, RMB place/use, 1–9/wheel hotbar, C or E crafting (Q/R tabs, arrows,
   Enter), I inventory (creative palette in creative: Q/R tabs, arrows, Enter/click), P pause, T chat. Gamepad: RT/LT, LB/RB, X crafting, Y inventory, Start.
1. **Boot**: Play Solo. Output shows `[mclce] world ready seed=mclce persistent=...` with no errors.
   Require-by-string inside `ReplicatedStorage.Shared` must resolve (`require("../Config")` etc.);
   if Studio rejects relative string requires, that is the first thing to fix.
2. **Streaming**: terrain appears around spawn within a few seconds; HUD debug line shows chunks
   rising to ~113 (radius 6) and `dirty` draining to 0. Character is anchored until the ground is
   meshed, then falls onto it (does not fall through).
3. **Mining**: hold LMB on dirt by hand ≈ 0.75 s, stone by hand ≈ 7.5 s and drops nothing; tall
   grass breaks instantly. Bedrock never breaks. Drops appear as small cubes and are picked up.
4. **Placing**: RMB places the selected hotbar block on the clicked face; cannot place into yourself.
5. **Crafting**: E opens the list; with logs: planks → sticks → crafting table; near a table the
   pickaxe recipe appears.
6. **Multiplayer**: Test → Start with 2 players: edits by one appear for the other; both stream.
7. **Persistence** (API access on): place a block far from spawn, stop, play again: block is still
   there. Kill Studio mid-session after an autosave (30 s) — reload keeps edits up to that save.
8. **Parallel generation**: Output must not show "no GenWorker template". In the Developer Console
   (server) `_G.mclceServer.gs.stats.asyncRequested` grows while streaming; the MicroProfiler should
   show generation on worker threads. Set `Config.GEN_WORKERS = 0` to compare main-thread cost.
9. **Measure & record here**: Parts count (HUD), section build ms, server tick time
   (`GameServer.tick` duration), client FPS at radius 6, memory (Developer Console).

## Unverified Roblox-specific performance questions
- Part count/FPS of the box renderer at radius 6 on low-end mobile.
- Server cost of `GameServer.tick` with 8+ players (generation runs at 2 chunks/tick).
- RemoteEvent bandwidth for chunk payloads (typ. 2–15 KB each, ~13/s per joining player).
- DataStore write budget under heavy editing (regions batch 16 chunks per write).
- Whether Native codegen (`--!native`) is active for these modules on the server.
