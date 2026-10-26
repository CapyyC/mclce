# Roadmap

`[x]` done & CLI-tested, `[~]` partial / unverified in Roblox, `[ ]` not started.

## A — Audit & tooling
- [x] Audit (empty repo, no source → clean-room) — PROJECT_STATUS.md
- [x] Luau CLI build script, test runner, analyzer, bench harness, CI

## B — Core voxel primitives
- [x] Coords, chunk keys, section indexing, block registry/state packing, chunk storage, world border

## C — Meshing
- [x] Face culling + greedy quads per section (opaque / cutout / translucent)
- [x] Greedy box decomposition for Part renderer
- [x] Neighbour-aware invalidation + bounded rebuild queue
- [ ] Faster quad mesher (precomputed face masks) — ~1 ms/section today

## D — Playable prototype
- [x] Deterministic terrain, caves, ores, trees (approximate shaping)
- [x] Raycast targeting, validated break/place, item drops
- [~] Roblox server/client bootstrap, Part renderer, HUD, input (unverified in Studio)

## E — Streaming & saving
- [x] Scheduler, codec, SaveManager, failure recovery tests
- [~] DataStore adapter, autosave, BindToClose (unverified)

## F — Survival
- [x] Inventory, drops, crafting (Legacy list UI model), smelting tables, mining times, tools
- [x] Health/hunger/fall damage/death/respawn, eating
- [~] Day/night (time sync + Lighting.ClockTime; no mob-spawn coupling yet)
- [ ] Furnace block entity, chests, armour, combat, mobs

## G — Legacy fidelity
- [ ] Fluids, lighting, redstone, structures, Nether/End, Legacy UI screens, tutorial/minigames

## H — Stability
- [ ] Studio perf measurements, multiplayer soak, Roblox mock harness for glue
