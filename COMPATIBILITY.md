# Compatibility matrix (target: Minecraft PS4 Edition 1.95)

Labels: **VT** verified against target · **RS** supported by related-version source/doc · **INF** inferred ·
**PART** partially implemented · **NI** not implemented · **UNK** unknown.

No target source/binary was available, so nothing is VT. "RS" = public documentation of Legacy
Console / classic numeric-ID Minecraft (wiki-level facts), never code.

| Area | Status | Evidence / notes |
|---|---|---|
| Numeric block IDs + 4-bit data | RS, PART | Classic pre-flattening table; LCE never adopted string IDs. ~75 blocks. |
| Block hardness, tool tiers, break-time formula | RS | Tests reproduce the published break-time table (stone 7.5/1.15/0.6/0.4/0.3/0.2 s). |
| Item ids, tool durability, sword damage (pre-1.9) | RS | Classic numeric ids. |
| Drops (ores, gravel flint 10%, leaves sapling 5%, apple 0.5%) | RS | |
| World height 0..255, sea level 63 | RS | |
| Finite world sizes (Classic 864, Small 1024, Medium 3072, Large 5120) | RS | Border enforced; default Classic. |
| Seeds: text → Java String.hashCode, numeric text → long | RS | JavaRandom bit-exact vs JDK. |
| Terrain shape / biome placement | INF | Classic structure (4x8x4 density lattice, 5x5 biome smoothing, biome depth/scale table) but approximate noise and climate-based biome choice. **Seeds do not reproduce console worlds.** |
| Caves | INF | Worm carver model, own constants; lava below y=11 like classic. |
| Ore distribution | RS | Classic counts/sizes/heights (coal 20x17 0–128, iron 20x9 0–64, gold 2x9 0–32, redstone 8x8 0–16, diamond 1x8 0–16, lapis triangular ~16). |
| Trees / plants | INF | Simplified oak/birch/spruce/jungle/acacia shapes. |
| Structures (villages, temples, strongholds, mineshafts) | NI | |
| Crafting UI model (recipe list by category, no grid) | RS, PART | LCE crafting screen behaviour; categories simplified; ~45 recipes. |
| Smelting / fuel values | RS, PART | Logic for furnace block entity NI. |
| Inventory 36 + 4 armour, stack sizes | RS | Click/quick-move semantics approximate Legacy controls. |
| Reach 4.5 / 5 creative | RS | Server adds latency tolerance. |
| Hunger/exhaustion/regen/starvation, fall damage | RS | Pre-1.9 values. Difficulty fixed at Normal. |
| Item entities (gravity 0.04, drag 0.98, pickup 10 ticks, despawn 5 min) | RS | |
| Day length 24000 ticks, tick 0 = 06:00 | RS | Weather NI. |
| Fluids, redstone, lighting, mobs, combat, Nether/End | NI | |
| Legacy UI (menus, tooltips, controller focus) | NI | Only functional HUD/crafting list. |
| Save format | n/a | Own DataStore schema (regions of 4x4 chunks); not console-save compatible by design. |
