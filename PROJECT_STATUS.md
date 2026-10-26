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
D (playable prototype) code-complete but **unverified in Studio**; E (streaming/saving) and F
(survival) partially done.

## Done and tested in the Luau CLI (149 specs passing)
- Voxel core: Coords, Chunk (lazy u16 sections, heightmap, versions), World (finite Legacy border)
- BlockRegistry (~75 classic-ID blocks), item registry (tools, food, materials)
- Meshing: culled + greedy quads (SectionMesher), greedy boxes with hidden-cell wildcards (BoxMesher)
- Deterministic world gen: bit-exact JavaRandom (JDK fixture), own Perlin (fast path bit-identical to
  reference), approximate biomes, density terrain, worm caves (seamless), ores/trees/plants with
  order-independent decoration
- Streaming: chunk scheduler (budgets, cancellation, hysteresis), remesh queue (neighbour invalidation)
- Persistence: versioned RLE chunk codec, Base64, region-batched SaveManager (retries/backoff,
  migrations, in-flight edit safety, never generates over unreadable saves)
- Server core (GameServer): validated break (timing anti-cheat)/place/craft/eat, rate limiting,
  per-player chunk + block-change replication, item entities, survival (hunger, regen, fall damage,
  death drops, respawn)
- Client replica (ClientWorld): message application, break prediction with rollback
- Protocol with strict validation of untrusted input
- Benchmarks (`scripts/bench.sh`): see ADR 0001 and bench output

## Roblox glue (written, NOT run)
`src/server/Main.server.luau`, `DataStoreBackend.luau`; `src/client/Main.client.luau`,
`ChunkRenderer.luau` (pooled greedy-box Parts), `Hud.luau`, `Input.luau`, `CraftingMenu.luau`.
Manual verification procedure: TESTING.md → "Manual Studio verification".

## Known gaps / risks
- Biome selection and terrain shaping are approximations → seeds do not match console worlds.
- Renderer has no textures/lighting (colour + material only); EditableMesh path not started.
- No mobs, fluids flow, redstone, lighting engine, block entities (chests/furnaces), Legacy UI.
- Roblox require-by-string from shared modules must be confirmed in Studio (first manual check).

## Failing tests
None.

## Next concrete tasks
1. Studio verification pass (local session with Studio/MCP) — fix glue bugs found.
2. Fluid simulation (water/lava spread, Legacy flow rules) in shared + tests.
3. Light engine (sky/block light propagation) feeding face brightness for the mesh renderer.
4. Passive/hostile mob basics (AI, spawning rules, combat) in shared + glue.
5. EditableMesh textured renderer with a licensed/original atlas; keep Part fallback.
