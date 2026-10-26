--!strict
-- Block definitions keyed by Legacy Console numeric block ID.
--
-- Legacy Console Edition kept the pre-"flattening" numeric ID + 4-bit data
-- value model throughout its life (it never adopted Java 1.13's string IDs),
-- so IDs and data values follow the classic numeric table. IDs and hardness
-- values are public game facts (see COMPATIBILITY.md for verification status).
--
-- Fields:
--   name        stable string identifier (used in saves for forward compat)
--   layer       "none" | "opaque" | "cutout" | "translucent"
--   shape       "cube" | "cross" | "liquid" | "slab" | "torch" | "flat" | "none"
--   solid       participates in entity collision
--   hardness    mining hardness (-1 = unbreakable)
--   light       emitted light level 0..15
--   opacity     light attenuation 0..15 (15 = fully blocks skylight)
--   tool        preferred tool class: "pickaxe" | "axe" | "shovel" | "shears" | "sword" | nil
--   harvest     minimum tool tier to drop (0 = wood/any, 1 stone, 2 iron, 3 diamond) when tool required
--   needsTool   true if the block drops nothing without the right tool
--   color       fallback RGB for untextured renderers
--   material    fallback Roblox material name for Part renderer
--   textures    { top, bottom, side } texture names (atlas lookup), or a single "all"
--   replaceable can be replaced directly by placement (tall grass, water ...)
--   gravity     falls like sand

export type BlockDef = {
	id: number,
	name: string,
	layer: string,
	shape: string,
	solid: boolean,
	hardness: number,
	light: number,
	opacity: number,
	tool: string?,
	harvest: number,
	needsTool: boolean,
	color: { number },
	material: string,
	textures: { [string]: string },
	replaceable: boolean,
	gravity: boolean,
	drops: number?, -- item id dropped (defaults to own id); 0 = nothing
	flammable: boolean,
	-- Transparent cubes hide faces shared with the same block (glass, water).
	-- Leaves set false (Legacy renders fancy leaves).
	cullSame: boolean?,
}

type Partial = { [string]: any }

local defs: { Partial } = {}

local function add(id: number, name: string, props: Partial)
	props.id = id
	props.name = name
	table.insert(defs, props)
end

local function cube(hardness: number, color: { number }, material: string, tex: { [string]: string }, extra: Partial?): Partial
	local p: Partial = {
		layer = "opaque", shape = "cube", solid = true, hardness = hardness,
		light = 0, opacity = 15, harvest = 0, needsTool = false,
		color = color, material = material, textures = tex,
		replaceable = false, gravity = false, flammable = false,
	}
	if extra then
		for k, v in extra do
			p[k] = v
		end
	end
	return p
end

local function plant(color: { number }, tex: string, extra: Partial?): Partial
	local p: Partial = {
		layer = "cutout", shape = "cross", solid = false, hardness = 0,
		light = 0, opacity = 0, harvest = 0, needsTool = false,
		color = color, material = "Grass", textures = { all = tex },
		replaceable = false, gravity = false, flammable = true,
	}
	if extra then
		for k, v in extra do
			p[k] = v
		end
	end
	return p
end

local PICK = { tool = "pickaxe", needsTool = true }
local function pick(tier: number): Partial
	return { tool = "pickaxe", needsTool = true, harvest = tier }
end

add(0, "air", {
	layer = "none", shape = "none", solid = false, hardness = 0, light = 0, opacity = 0,
	harvest = 0, needsTool = false, color = { 0, 0, 0 }, material = "Air", textures = {},
	replaceable = true, gravity = false, flammable = false, drops = 0,
})
add(1, "stone", cube(1.5, { 125, 125, 125 }, "Slate", { all = "stone" }, { tool = "pickaxe", needsTool = true, drops = 4 }))
add(2, "grass", cube(0.6, { 95, 159, 53 }, "Grass", { top = "grass_top", bottom = "dirt", side = "grass_side" }, { tool = "shovel", drops = 3 }))
add(3, "dirt", cube(0.5, { 134, 96, 67 }, "Ground", { all = "dirt" }, { tool = "shovel" }))
add(4, "cobblestone", cube(2.0, { 122, 122, 122 }, "Cobblestone", { all = "cobblestone" }, PICK))
add(5, "planks", cube(2.0, { 157, 128, 79 }, "WoodPlanks", { all = "planks_oak" }, { tool = "axe", flammable = true }))
add(6, "sapling", plant({ 72, 130, 40 }, "sapling_oak"))
add(7, "bedrock", cube(-1, { 60, 60, 60 }, "Basalt", { all = "bedrock" }, { drops = 0 }))
add(8, "flowing_water", { layer = "translucent", shape = "liquid", solid = false, hardness = 100, light = 0, opacity = 3, harvest = 0, needsTool = false, color = { 47, 67, 244 }, material = "Glass", textures = { all = "water_flow" }, replaceable = true, gravity = false, flammable = false, drops = 0 })
add(9, "water", { layer = "translucent", shape = "liquid", solid = false, hardness = 100, light = 0, opacity = 3, harvest = 0, needsTool = false, color = { 47, 67, 244 }, material = "Glass", textures = { all = "water_still" }, replaceable = true, gravity = false, flammable = false, drops = 0 })
add(10, "flowing_lava", { layer = "opaque", shape = "liquid", solid = false, hardness = 100, light = 15, opacity = 0, harvest = 0, needsTool = false, color = { 207, 92, 15 }, material = "Neon", textures = { all = "lava_flow" }, replaceable = true, gravity = false, flammable = false, drops = 0 })
add(11, "lava", { layer = "opaque", shape = "liquid", solid = false, hardness = 100, light = 15, opacity = 0, harvest = 0, needsTool = false, color = { 207, 92, 15 }, material = "Neon", textures = { all = "lava_still" }, replaceable = true, gravity = false, flammable = false, drops = 0 })
add(12, "sand", cube(0.5, { 219, 207, 163 }, "Sand", { all = "sand" }, { tool = "shovel", gravity = true }))
add(13, "gravel", cube(0.6, { 136, 126, 126 }, "Pebble", { all = "gravel" }, { tool = "shovel", gravity = true }))
add(14, "gold_ore", cube(3.0, { 143, 140, 125 }, "Slate", { all = "gold_ore" }, pick(2)))
add(15, "iron_ore", cube(3.0, { 136, 130, 127 }, "Slate", { all = "iron_ore" }, pick(1)))
add(16, "coal_ore", cube(3.0, { 115, 115, 115 }, "Slate", { all = "coal_ore" }, pick(0)))
add(17, "log", cube(2.0, { 102, 81, 51 }, "Wood", { top = "log_oak_top", bottom = "log_oak_top", side = "log_oak" }, { tool = "axe", flammable = true }))
add(18, "leaves", cube(0.2, { 60, 120, 30 }, "LeafyGrass", { all = "leaves_oak" }, { layer = "cutout", opacity = 1, tool = "shears", flammable = true, cullSame = false }))
add(19, "sponge", cube(0.6, { 195, 192, 74 }, "Fabric", { all = "sponge" }))
add(20, "glass", cube(0.3, { 220, 240, 255 }, "Glass", { all = "glass" }, { layer = "cutout", opacity = 0, drops = 0 }))
add(21, "lapis_ore", cube(3.0, { 102, 112, 134 }, "Slate", { all = "lapis_ore" }, pick(1)))
add(22, "lapis_block", cube(3.0, { 30, 67, 140 }, "SmoothPlastic", { all = "lapis_block" }, pick(1)))
add(24, "sandstone", cube(0.8, { 216, 203, 155 }, "Sandstone", { top = "sandstone_top", bottom = "sandstone_bottom", side = "sandstone_normal" }, PICK))
add(30, "web", plant({ 220, 220, 220 }, "web", { hardness = 4.0, tool = "sword", flammable = false }))
add(31, "tallgrass", plant({ 86, 150, 50 }, "tallgrass", { replaceable = true, drops = 0 }))
add(32, "deadbush", plant({ 123, 79, 25 }, "deadbush", { replaceable = true, drops = 0 }))
add(35, "wool", cube(0.8, { 234, 236, 237 }, "Fabric", { all = "wool_colored_white" }, { tool = "shears", flammable = true }))
add(37, "yellow_flower", plant({ 255, 236, 79 }, "flower_dandelion"))
add(38, "red_flower", plant({ 237, 48, 44 }, "flower_rose"))
add(39, "brown_mushroom", plant({ 145, 109, 85 }, "mushroom_brown", { light = 1, flammable = false }))
add(40, "red_mushroom", plant({ 226, 18, 18 }, "mushroom_red", { flammable = false }))
add(41, "gold_block", cube(3.0, { 249, 236, 79 }, "Foil", { all = "gold_block" }, pick(2)))
add(42, "iron_block", cube(5.0, { 219, 219, 219 }, "Metal", { all = "iron_block" }, pick(1)))
add(44, "stone_slab", cube(2.0, { 168, 168, 168 }, "Concrete", { top = "stone_slab_top", bottom = "stone_slab_top", side = "stone_slab_side" }, { shape = "slab", layer = "cutout", opacity = 0, tool = "pickaxe", needsTool = true }))
add(45, "brick_block", cube(2.0, { 150, 97, 83 }, "Brick", { all = "brick" }, PICK))
add(46, "tnt", cube(0.0, { 219, 68, 26 }, "SmoothPlastic", { top = "tnt_top", bottom = "tnt_bottom", side = "tnt_side" }))
add(47, "bookshelf", cube(1.5, { 117, 94, 59 }, "WoodPlanks", { top = "planks_oak", bottom = "planks_oak", side = "bookshelf" }, { tool = "axe", flammable = true }))
add(48, "mossy_cobblestone", cube(2.0, { 103, 121, 103 }, "Cobblestone", { all = "cobblestone_mossy" }, PICK))
add(49, "obsidian", cube(50.0, { 20, 18, 29 }, "Glass", { all = "obsidian" }, pick(3)))
add(50, "torch", { layer = "cutout", shape = "torch", solid = false, hardness = 0, light = 14, opacity = 0, harvest = 0, needsTool = false, color = { 255, 216, 0 }, material = "Neon", textures = { all = "torch_on" }, replaceable = false, gravity = false, flammable = false })
add(52, "mob_spawner", cube(5.0, { 26, 39, 49 }, "DiamondPlate", { all = "mob_spawner" }, { layer = "cutout", opacity = 0, tool = "pickaxe", needsTool = true, drops = 0 }))
add(54, "chest", cube(2.5, { 164, 116, 42 }, "WoodPlanks", { all = "chest" }, { tool = "axe", opacity = 0, layer = "cutout" }))
local function redstonePart(color: { number }, tex: string, shape: string, extra: Partial?): Partial
	local p: Partial = {
		layer = "cutout", shape = shape, solid = false, hardness = 0, light = 0, opacity = 0,
		harvest = 0, needsTool = false, color = color, material = "SmoothPlastic", textures = { all = tex },
		replaceable = false, gravity = false, flammable = false,
	}
	if extra then
		for k, v in extra do
			p[k] = v
		end
	end
	return p
end
add(55, "redstone_wire", redstonePart({ 170, 0, 0 }, "redstone_dust_line", "flat", { drops = 331 }))
add(64, "wooden_door", redstonePart({ 145, 110, 70 }, "door_wood_lower", "door", { hardness = 3.0, tool = "axe", drops = 324 }))
add(69, "lever", redstonePart({ 120, 100, 80 }, "lever", "torch", { hardness = 0.5 }))
add(70, "stone_pressure_plate", redstonePart({ 125, 125, 125 }, "stone", "flat", { hardness = 0.5, tool = "pickaxe", needsTool = true }))
add(71, "iron_door", redstonePart({ 200, 200, 200 }, "door_iron_lower", "door", { hardness = 5.0, tool = "pickaxe", needsTool = true, drops = 330 }))
add(72, "wooden_pressure_plate", redstonePart({ 157, 128, 79 }, "planks_oak", "flat", { hardness = 0.5, tool = "axe" }))
add(75, "unlit_redstone_torch", redstonePart({ 100, 0, 0 }, "redstone_torch_off", "torch", { drops = 76 }))
add(76, "redstone_torch", redstonePart({ 255, 40, 40 }, "redstone_torch_on", "torch", { light = 7 }))
add(77, "stone_button", redstonePart({ 125, 125, 125 }, "stone", "torch", { hardness = 0.5 }))
add(123, "redstone_lamp", cube(0.3, { 110, 70, 40 }, "Glass", { all = "redstone_lamp_off" }))
add(124, "lit_redstone_lamp", cube(0.3, { 250, 200, 120 }, "Neon", { all = "redstone_lamp_on" }, { light = 15, drops = 123 }))
add(152, "redstone_block", cube(5.0, { 170, 20, 10 }, "SmoothPlastic", { all = "redstone_block" }, { tool = "pickaxe", needsTool = true }))
add(56, "diamond_ore", cube(3.0, { 129, 140, 143 }, "Slate", { all = "diamond_ore" }, pick(2)))
add(57, "diamond_block", cube(5.0, { 98, 219, 214 }, "Ice", { all = "diamond_block" }, pick(2)))
add(58, "crafting_table", cube(2.5, { 120, 73, 42 }, "WoodPlanks", { top = "crafting_table_top", bottom = "planks_oak", side = "crafting_table_side" }, { tool = "axe", flammable = true }))
add(59, "wheat", plant({ 200, 180, 60 }, "wheat_stage_7", { flammable = false, drops = 0 }))
add(60, "farmland", cube(0.6, { 115, 74, 44 }, "Ground", { top = "farmland_dry", bottom = "dirt", side = "dirt" }, { tool = "shovel", drops = 3 }))
add(61, "furnace", cube(3.5, { 110, 110, 110 }, "Cobblestone", { top = "furnace_top", bottom = "furnace_top", side = "furnace_side", front = "furnace_front_off" }, PICK))
add(62, "lit_furnace", cube(3.5, { 110, 110, 110 }, "Cobblestone", { top = "furnace_top", bottom = "furnace_top", side = "furnace_side", front = "furnace_front_on" }, { tool = "pickaxe", needsTool = true, light = 13, drops = 61 }))
add(73, "redstone_ore", cube(3.0, { 133, 107, 107 }, "Slate", { all = "redstone_ore" }, pick(2)))
add(78, "snow_layer", { layer = "cutout", shape = "flat", solid = false, hardness = 0.1, light = 0, opacity = 0, tool = "shovel", harvest = 0, needsTool = true, color = { 249, 254, 254 }, material = "Snow", textures = { all = "snow" }, replaceable = true, gravity = false, flammable = false })
add(79, "ice", cube(0.5, { 125, 173, 255 }, "Ice", { all = "ice" }, { layer = "translucent", opacity = 3, drops = 0 }))
add(80, "snow", cube(0.2, { 249, 254, 254 }, "Snow", { all = "snow" }, { tool = "shovel", needsTool = true }))
add(81, "cactus", cube(0.4, { 13, 99, 25 }, "Grass", { top = "cactus_top", bottom = "cactus_bottom", side = "cactus_side" }, { layer = "cutout", opacity = 0 }))
add(82, "clay", cube(0.6, { 159, 164, 177 }, "Slate", { all = "clay" }, { tool = "shovel" }))
add(83, "reeds", plant({ 148, 192, 101 }, "reeds", { flammable = false }))
add(86, "pumpkin", cube(1.0, { 227, 144, 29 }, "SmoothPlastic", { top = "pumpkin_top", bottom = "pumpkin_top", side = "pumpkin_side", front = "pumpkin_face_off" }, { tool = "axe" }))
add(87, "netherrack", cube(0.4, { 111, 54, 52 }, "CrackedLava", { all = "netherrack" }, PICK))
add(88, "soul_sand", cube(0.5, { 84, 64, 51 }, "Sand", { all = "soul_sand" }, { tool = "shovel" }))
add(89, "glowstone", cube(0.3, { 249, 212, 156 }, "Neon", { all = "glowstone" }, { layer = "cutout", opacity = 0, light = 15 }))
add(98, "stonebrick", cube(1.5, { 122, 121, 122 }, "Slate", { all = "stonebrick" }, PICK))
add(103, "melon_block", cube(1.0, { 151, 153, 36 }, "SmoothPlastic", { top = "melon_top", bottom = "melon_top", side = "melon_side" }, { tool = "axe" }))
add(110, "mycelium", cube(0.6, { 111, 99, 107 }, "Grass", { top = "mycelium_top", bottom = "dirt", side = "mycelium_side" }, { tool = "shovel", drops = 3 }))
add(111, "waterlily", { layer = "cutout", shape = "flat", solid = true, hardness = 0, light = 0, opacity = 0, harvest = 0, needsTool = false, color = { 32, 128, 48 }, material = "Grass", textures = { all = "waterlily" }, replaceable = false, gravity = false, flammable = false })
add(121, "end_stone", cube(3.0, { 221, 223, 165 }, "Sandstone", { all = "end_stone" }, PICK))
add(129, "emerald_ore", cube(3.0, { 117, 136, 124 }, "Slate", { all = "emerald_ore" }, pick(2)))
add(133, "emerald_block", cube(5.0, { 81, 217, 117 }, "SmoothPlastic", { all = "emerald_block" }, pick(2)))
add(159, "stained_hardened_clay", cube(1.25, { 209, 178, 161 }, "Slate", { all = "hardened_clay_stained_white" }, PICK))
add(161, "leaves2", cube(0.2, { 60, 110, 30 }, "LeafyGrass", { all = "leaves_acacia" }, { layer = "cutout", opacity = 1, tool = "shears", flammable = true, cullSame = false }))
add(162, "log2", cube(2.0, { 103, 96, 86 }, "Wood", { top = "log_acacia_top", bottom = "log_acacia_top", side = "log_acacia" }, { tool = "axe", flammable = true }))
add(172, "hardened_clay", cube(1.25, { 150, 92, 66 }, "Slate", { all = "hardened_clay" }, PICK))
add(174, "packed_ice", cube(0.5, { 165, 195, 245 }, "Ice", { all = "ice_packed" }, { drops = 0 }))
add(175, "double_plant", plant({ 86, 150, 50 }, "double_plant_grass_bottom", { replaceable = true, drops = 0 }))

return defs
