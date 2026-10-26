# ADR 0001 — Own Perlin noise in Luau; generate on the server

## Context
Roblox's built-in `math.noise` is a single fixed-permutation 3D Perlin with no seed parameter,
inconsistent value distribution and per-call overhead; seeds would have to be faked by coordinate
offsets. It also cannot be bit-reproduced outside Roblox, which breaks CLI golden tests.

## Decision
- Use our own Improved-Perlin (`src/shared/Util/PerlinNoise.luau`), permutation shuffled from a
  bit-exact `java.util.Random` (`JavaRandom.luau`). `--!native`, u8 permutation buffer,
  branch-free table gradients. A reference implementation is kept and the fast path is tested
  bit-identical against it.
- Never call `math.noise` anywhere in generation.
- Sample density on a coarse 4x8x4 lattice and trilinearly interpolate (classic approach), so noise
  calls per chunk are ~1–2 thousand rather than 65k.
- World generation runs on the server (authoritative; Native Luau codegen is available there).
  Clients receive generated/modified chunk data, they don't generate.
- Generation is a pure function of (seed, chunk); features from neighbouring chunks are evaluated
  with per-feature RNG streams so bounding-box culling never perturbs other features.

## Consequences
- CLI benchmarks (`scripts/bench.sh`) are meaningful relative measures for this code; Roblox server
  timings still need measuring in Studio (see TESTING.md).
- Measured in the Luau CLI with `--codegen` (session 1): Perlin 3D sample ~86 ns; full decorated chunk
  ~3.4 ms when streaming (base terrain incl. caves ~1.9 ms). Interpreted (no codegen) is ~3–4x slower.
