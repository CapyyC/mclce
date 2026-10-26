# Testing

## Automated (CLI, no Roblox)
```
scripts/setup-luau.sh   # once
scripts/analyze.sh      # strict type-check src/shared, tests, bench
scripts/test.sh         # all specs
scripts/bench.sh        # micro-benchmarks (Luau CLI VM timings only)
```
Last run (session 1): all specs pass; analyzer clean.

## Coverage by area
| Area | Spec |
|---|---|
| Coordinates, negative coords, chunk keys | tests/shared/Coords.spec.luau |
| Block registry, state packing | tests/shared/BlockRegistry.spec.luau |
| Chunk storage boundaries, heightmap, randomized vs reference | tests/shared/Chunk.spec.luau |
| World cross-chunk addressing, border, listeners | tests/shared/World.spec.luau |

## Manual Studio verification
(Not yet applicable — no Roblox glue yet.)
