# Project status

_Last updated: 2026-10-26 (cloud session 1). Resume by reading this file, ROADMAP.md, then `git log`._

## Source & environment audit (session 1)
- Repository `CapyyC/mclce` was **empty** (no commits, no branches). **No decompilation or community
  source is present**, so no PS4 1.95 algorithms could be inspected.
- The port is therefore a **clean-room reimplementation** from public knowledge of Legacy Console /
  classic numeric-ID Minecraft behaviour. No leaked/proprietary code or game assets are used; keep it
  that way. Every behaviour carries an evidence label in COMPATIBILITY.md; nothing is "Verified
  against target".
- Tooling: Luau CLI + analyzer built from official luau-lang source (`scripts/setup-luau.sh`); JDK
  available in the cloud box (used only to generate `java.util.Random` golden fixtures).
  No Roblox Studio, Rojo or live servers in the cloud session → `src/server`, `src/client` are
  **unexecuted** (parse-checked only).

## Current milestone
D/E/F code-complete in shared code and exercised end-to-end in the Roblox mock; **unverified in
real Studio**. G (Legacy fidelity) started (fluids, light, mobs, block entities, farming).

## Done and tested in the Luau CLI (264 specs passing + Roblox mock sessions PASS in both renderers)
- Voxel core: Coords, Chunk (lazy u16 sections, heightmap, versions, block entities), World (finite
  Legacy border, batched setStates)
- BlockRegistry (~95 classic-ID blocks), ItemRegistry (tools, armour, food, buckets, mechanisms)
- Meshing: culled + greedy quads, greedy boxes, MeshBuilder (shaded triangle batches for EditableMesh)
- World gen: bit-exact JavaRandom, own Perlin, approximate biomes/terrain, seamless caves,
  order-independent ores/trees/plants/dungeons; Nether generator
- Streaming, persistence (codec v2 with block entities, region-batched SaveManager)
- Simulation: validated break/place/craft/eat/attack/containers/use; survival; fluids; light; mobs
  (9 types incl. neutral pigmen, arrows); chests/furnaces/spawners; block updates and random ticks;
  farming; buckets; armour; redstone subset; Nether dimension with portals (Dimensions orchestrator)
- UI models: Legacy category-tab crafting, D-pad focus grid, menu stack (pause/death), creative palette
- Client replica with prediction/rollback; Roblox mock harness runs the real glue end to end
  (boot, stream, render, mine, place, attack, chest UI, Legacy crafting, pause, portal to Nether,
  autosave, shutdown save)

## Roblox glue (written, run only in the mock)
`src/server`: Main.server, DataStoreBackend. `src/client`: Main.client, ChunkRenderer (pooled greedy
Parts), MeshRenderer (opt-in EditableMesh), MobRenderer, Hud, Input, LegacyMenus, ContainerMenu.
Debug handles: `_G.mclceServer.gs` / `.dims` / `.nether` (server), `_G.mclceClient.cw` / `.renderer`
(client) for the Studio command bar / MCP.

## Known gaps / risks
- Terrain/biomes approximate → seeds do not match console worlds.
- Renderer: colours + materials only, no textures; EditableMesh path not started. ~22k Parts at
  radius 6 in the mock — real FPS unknown.
- Missing: beds, player bows, villages/strongholds/fortresses, the End, weather, enchanting,
  brewing, pistons/repeaters, Legacy UI art (functional placeholder panels only), audio.
- Nether scale for PS4 1.95 unknown (configurable, default 1:3).
- Roblox require-by-string in shared modules must be confirmed in Studio (first manual check).

## Failing tests
None.

## Next concrete tasks
1. Studio verification pass (local session) using TESTING.md; fix what the real engine rejects.
2. Beds (sleep/skip night, spawn point) and player bows.
3. Parallel-Luau (Actor) world generation on the server; measure tick cost in Studio.
4. Legacy UI art pass: inventory/furnace screens on FocusGrid, controller focus visuals.
5. Pistons and repeaters; villages.
