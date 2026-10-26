# Project status

_Last updated: 2026-10-26 (cloud session 1)_

## Source & environment audit (session 1)
- Repository `CapyyC/mclce` was **empty** (no commits, no branches). **No decompilation or community
  source is present.** Nothing could be inspected for PS4 1.95 algorithms.
- Consequence: the port is a **clean-room reimplementation** from public knowledge of Legacy Console
  behaviour (numeric block IDs, hardness, world sizes, recipes, etc.). No leaked/proprietary code or
  assets are used or should be added. Every behaviour carries an evidence label in COMPATIBILITY.md;
  nothing is labelled "Verified against target" because no target binary/source was available.
- Tooling: Luau CLI + analyzer built from official source (`scripts/setup-luau.sh`). No Roblox Studio,
  no Rojo, no live servers. Roblox glue (`src/server`, `src/client`) is unexecuted until a Studio session.

## Current milestone
B/C — core voxel primitives done; mesher in progress.

## Done (tested in Luau CLI)
- Coords (negative-safe floor math, packed chunk keys, section indexing)
- BlockRegistry + BlockData (~75 classic-ID blocks, layers, hardness, light, tool tier)
- Chunk (lazy 16^3 sections in u16 buffers, heightmap, versions, dirty flag)
- World (sparse chunk map, finite Legacy border, change listeners)
- Test harness, analyzer script, benchmark harness, CI workflow

## Failing tests
None.

## Next
See ROADMAP.md.
