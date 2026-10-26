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

## Done and tested in the Luau CLI (205 specs passing + Roblox mock session PASS)
- Voxel core: Coords, Chunk (lazy u16 sections, heightmap, versions, block entities), World (finite
  Legacy border)
- BlockRegistry (~77 classic-ID blocks), ItemRegistry (tools, food, buckets, mob drops)
- Meshing: culled + greedy quads (SectionMesher), greedy boxes with hidden-cell wildcards (BoxMesher)
- World gen: bit-exact JavaRandom (JDK fixture), own Perlin (bit-identical fast path), approximate
  biomes, density terrain, seamless worm caves, order-independent ores/trees/plants
- Streaming: chunk scheduler, remesh queue (no leaks toward unloaded neighbours)
- Persistence: chunk codec v2 (RLE + block entities, v1 readable), Base64, region-batched SaveManager
  (retries/backoff, migrations, in-flight edit safety, never generates over unreadable saves)
- Simulation (GameServer): validated break/place/craft/eat/attack/container clicks, rate limiting,
  JOIN handshake, per-player chunk/block/mob/item replication, survival (hunger, regen, fall damage,
  death drops, respawn), fluids (water/lava, infinite water, reactions), light engine (verified vs
  brute force), mobs (8 types, AI, light-based spawning, creeper explosions), chests/furnaces,
  block updates (support pops, falling sand), random ticks (grass, crops, saplings, cane, cactus,
  leaf decay), hoe/seeds/buckets/torch attachment
- Client replica (ClientWorld): prediction + rollback, mobs, containers, targeting
- Roblox mock harness runs the real glue (boot, join, stream, render, mine, place, attack, chest UI,
  crafting menu, autosave, shutdown save)

## Roblox glue (written, run only in the mock)
`src/server`: Main.server, DataStoreBackend. `src/client`: Main.client, ChunkRenderer (pooled greedy
Parts), MobRenderer, Hud, Input, CraftingMenu, ContainerMenu. Debug handles: `_G.mclceServer.gs`
(server), `_G.mclceClient.cw` / `.renderer` (client) for the Studio command bar / MCP.

## Known gaps / risks
- Terrain/biomes approximate → seeds do not match console worlds.
- Renderer: colours + materials only, no textures; EditableMesh path not started. ~22k Parts at
  radius 6 in the mock — real FPS unknown.
- No armour, bows/arrows (skeletons melee), redstone, structures, Nether/End, weather, Legacy UI art.
- Roblox require-by-string in shared modules must be confirmed in Studio (first manual check).

## Failing tests
None.

## Next concrete tasks
1. Studio verification pass (local session) using TESTING.md; fix what the real engine rejects.
2. Armour (items, slots, damage reduction) + skeleton arrows (projectile entity).
3. EditableMesh textured renderer behind a feature flag, Part renderer as fallback.
4. Legacy Console UI screens (inventory/crafting/furnace layouts, controller focus).
5. Structures (villages/dungeons) and the Nether (portal, 1/8 scale).
