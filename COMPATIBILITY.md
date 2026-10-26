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
| Dungeons (8 attempts/chunk, 1–5 openings, spawner, 2 loot chests) | INF, PART | Classic rules; rarer than classic because our caves are sparser. Loot table subset. |
| Mob spawners (16-block activation, 200–799 t delay, ≤4 per cycle, cap 6) | RS | No light check. |
| Structures (villages, temples, strongholds, mineshafts) | NI | |
| Crafting UI model (recipe list by category, no grid) | RS, PART | LCE crafting screen behaviour; categories simplified; ~45 recipes. |
| Smelting / fuel values | RS, PART | Logic for furnace block entity NI. |
| Inventory 36 + 4 armour, stack sizes | RS | Click/quick-move semantics approximate Legacy controls. |
| Reach 4.5 / 5 creative | RS | Server adds latency tolerance. |
| Hunger/exhaustion/regen/starvation, fall damage | RS | Pre-1.9 values. Difficulty fixed at Normal. |
| Item entities (gravity 0.04, drag 0.98, pickup 10 ticks, despawn 5 min) | RS | |
| Day length 24000 ticks, tick 0 = 06:00 | RS | Weather NI. |
| Fluids (water 5 t / lava 30 t, levels, falling, infinite water, drop-seeking, reactions) | RS, PART | Flow-direction search simplified; no flowing-fluid pushing entities. |
| Light (sky/block 0–15, opacity costs, lossless sky down) | RS | Matches classic propagation rules; verified vs brute-force fixpoint. |
| Day/night sky darkening (0 noon, 11 midnight), mob spawn light ≤ 7 | RS | |
| Mobs: pig/cow/sheep/chicken/zombie/skeleton/creeper/spider | PART | Classic HP/damage/drops; AI simplified; skeletons melee (no bows); caps 30/20 INF (LCE caps differ). |
| Combat: weapon damage, 10-tick i-frames, knockback, tool wear | RS, PART | No crits, no armour yet. |
| Creeper explosion power 3, damage formula | RS, PART | Sphere-based block destruction (not ray-based); drop chance 1/power RS. |
| Furnace: 200 ticks/item, coal = 8 items, lit swap | RS | |
| Chests 27 slots | RS | No double chests. |
| Random ticks (3/section/tick), crops, saplings, grass, leaf decay (4 blocks), cane/cactus | RS, PART | Growth probabilities simplified. |
| Falling sand/gravel | INF | Instant fall, no falling-block entity. |
| Nether: 128-high netherrack caverns, bedrock shell, lava sea ≤ 31, glowstone, quartz | INF, PART | Approximate shape; no fortresses, ghasts or magma cubes; zombie pigmen (neutral, group anger). |
| Nether size / coordinate scale | UNK | Configurable `Config.NETHER_SCALE` (default 1:3, 288-block Nether for Classic). Java uses 1:8; PS4 1.95 value not verified. |
| Portals: obsidian frames 2..21 x 3..21, flint & steel, 4 s standing, exit search 16 blocks / creation | RS, PART | Nether lava 10 t / 1 per block; water evaporates. |
| Redstone (wire, torches, levers, buttons, plates, lamps, blocks, doors, repeaters) | RS, PART | No comparators, pistons, hoppers; no quasi-connectivity, repeater locking or torch burnout. |
| Beds: sleep 12541–23458, monsters within 8 block sleep, all asleep 100 t → morning, spawn point, explode (power 5) in the Nether | RS | |
| Bows: charge f = (t²+2t)/3, speed 3f, arrow damage ceil(speed·2) | RS, PART | No crits/enchantments; arrows not recoverable. |
| Weather: rain 12000–179999 t clear / 12000–23999 t rain, thunder cycle; storms allow daytime spawns; rain hydrates farmland | RS, PART | Darkening 3/8 INF; no lightning, snow accumulation or fire. |
| End, enchanting, brewing | NI | |
| Legacy UI (menus, tooltips, controller focus) | NI | Only functional HUD/crafting list. |
| Save format | n/a | Own DataStore schema (regions of 4x4 chunks); not console-save compatible by design. |
