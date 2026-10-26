# Roadmap

Milestones follow the mission brief (A–H). `[x]` done & tested, `[~]` partial, `[ ]` not started.

## A — Audit & tooling
- [x] Audit (empty repo, no source → clean-room) — see PROJECT_STATUS.md
- [x] Luau CLI build script, test runner, analyzer, bench harness, CI

## B — Core voxel primitives
- [x] Coords, chunk keys, section indexing
- [x] Block registry / state packing
- [x] Chunk storage, World container, border

## C — Meshing
- [ ] Face culling + greedy quads per section (opaque / cutout / translucent)
- [ ] Greedy box decomposition for Part renderer
- [ ] Neighbour-aware invalidation + rebuild queue

## D — Playable prototype
- [ ] Deterministic terrain (Java-compatible LCG + Perlin, approximate shaping)
- [ ] Raycast targeting, break/place with server validation
- [ ] Roblox server/client bootstrap, chunk renderer, input

## E — Streaming & saving
- [ ] Player-centred chunk scheduler with budgets & cancellation
- [ ] Chunk codec + DataStore persistence (batching, retries, schema version)

## F — Survival
- [ ] Inventory, item stacks, drops, crafting
- [ ] Mining time, tools; health/hunger; day/night; basic mobs

## G — Legacy fidelity
- [ ] Biomes, structures, fluids, lighting, redstone, Legacy UI

## H — Stability
- [ ] Regression suite, perf budgets, multiplayer validation
