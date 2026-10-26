--!strict
-- Item definitions. Block items share their block's numeric id (< 256 in the
-- classic table); other items use the classic numeric item ids (256+).
-- Tool tiers/speeds/durabilities are the public classic values.

local BlockRegistry = require("../Blocks/BlockRegistry")

export type ItemDef = {
	id: number,
	name: string,
	maxStack: number,
	block: number?, -- block id placed by this item
	tool: string?, -- "pickaxe" | "axe" | "shovel" | "sword" | "shears" | "hoe"
	tier: number?, -- harvest level 0 wood/gold, 1 stone, 2 iron, 3 diamond
	speed: number?, -- mining speed multiplier on matching blocks
	durability: number?,
	damage: number?, -- melee attack damage (half-hearts) incl. base 1
	food: number?, -- hunger points restored
	saturation: number?, -- saturation modifier
	armorSlot: number?, -- 37 helmet, 38 chestplate, 39 leggings, 40 boots
	armor: number?, -- defence points
}

local ItemRegistry = {}

local byId: { [number]: ItemDef } = {}
local byName: { [string]: ItemDef } = {}

local function add(def: ItemDef)
	assert(byId[def.id] == nil, "duplicate item id " .. def.id)
	byId[def.id] = def
	byName[def.name] = def
end

-- every block that has a definition is also an item (except air/liquids)
for _, b in BlockRegistry.all() do
	if b.id ~= 0 and b.shape ~= "liquid" then
		add({ id = b.id, name = b.name, maxStack = 64, block = b.id })
	end
end

type Tier = { tier: number, speed: number, durability: number, dmg: number }
local TIERS: { [string]: Tier } = {
	wooden = { tier = 0, speed = 2, durability = 59, dmg = 0 },
	stone = { tier = 1, speed = 4, durability = 131, dmg = 1 },
	iron = { tier = 2, speed = 6, durability = 250, dmg = 2 },
	diamond = { tier = 3, speed = 8, durability = 1561, dmg = 3 },
	golden = { tier = 0, speed = 12, durability = 32, dmg = 0 },
}
-- classic ids: { sword, shovel, pickaxe, axe, hoe }
local TOOL_IDS: { [string]: { number } } = {
	wooden = { 268, 269, 270, 271, 290 },
	stone = { 272, 273, 274, 275, 291 },
	iron = { 267, 256, 257, 258, 292 },
	diamond = { 276, 277, 278, 279, 293 },
	golden = { 283, 284, 285, 286, 294 },
}
-- base attack damage before tier bonus (pre-combat-update values)
local KIND_DAMAGE: { [string]: number } = { sword = 5, shovel = 2, pickaxe = 3, axe = 4, hoe = 1 }
for material, ids in TOOL_IDS do
	local t = TIERS[material]
	for i, kind in { "sword", "shovel", "pickaxe", "axe", "hoe" } do
		add({
			id = ids[i],
			name = material .. "_" .. kind,
			maxStack = 1,
			tool = kind,
			tier = t.tier,
			speed = t.speed,
			durability = t.durability,
			damage = KIND_DAMAGE[kind] + t.dmg,
		})
	end
end

-- armour (classic ids 298..317): defence points and durability
-- (durability = material factor x piece base 11/16/15/13)
type ArmorMat = { name: string, first: number, points: { number }, factor: number }
local ARMOR: { ArmorMat } = {
	{ name = "leather", first = 298, points = { 1, 3, 2, 1 }, factor = 5 },
	{ name = "chainmail", first = 302, points = { 2, 5, 4, 1 }, factor = 15 },
	{ name = "iron", first = 306, points = { 2, 6, 5, 2 }, factor = 15 },
	{ name = "diamond", first = 310, points = { 3, 8, 6, 3 }, factor = 33 },
	{ name = "golden", first = 314, points = { 2, 5, 3, 1 }, factor = 7 },
}
local PIECES = { "helmet", "chestplate", "leggings", "boots" }
local PIECE_BASE = { 11, 16, 15, 13 }
for _, m in ARMOR do
	for i, piece in PIECES do
		add({
			id = m.first + i - 1,
			name = m.name .. "_" .. piece,
			maxStack = 1,
			armorSlot = 36 + i,
			armor = m.points[i],
			durability = m.factor * PIECE_BASE[i],
		})
	end
end
add({ id = 334, name = "leather", maxStack = 64 })
add({ id = 259, name = "flint_and_steel", maxStack = 1, durability = 64 })
add({ id = 406, name = "quartz", maxStack = 64 })
add({ id = 355, name = "bed_item", maxStack = 1, block = 26 })
add({ id = 261, name = "bow", maxStack = 1, durability = 384 })
add({ id = 371, name = "gold_nugget", maxStack = 64 })

add({ id = 359, name = "shears", maxStack = 1, tool = "shears", tier = 0, speed = 15, durability = 238 })
add({ id = 260, name = "apple", maxStack = 64, food = 4, saturation = 0.3 })
add({ id = 263, name = "coal", maxStack = 64 })
add({ id = 264, name = "diamond", maxStack = 64 })
add({ id = 265, name = "iron_ingot", maxStack = 64 })
add({ id = 266, name = "gold_ingot", maxStack = 64 })
add({ id = 280, name = "stick", maxStack = 64 })
add({ id = 281, name = "bowl", maxStack = 64 })
add({ id = 282, name = "mushroom_stew", maxStack = 1, food = 6, saturation = 0.6 })
add({ id = 295, name = "wheat_seeds", maxStack = 64 })
add({ id = 296, name = "wheat", maxStack = 64 })
add({ id = 297, name = "bread", maxStack = 64, food = 5, saturation = 0.6 })
add({ id = 318, name = "flint", maxStack = 64 })
add({ id = 319, name = "porkchop", maxStack = 64, food = 3, saturation = 0.3 })
add({ id = 320, name = "cooked_porkchop", maxStack = 64, food = 8, saturation = 0.8 })
add({ id = 331, name = "redstone", maxStack = 64, block = 55 })
add({ id = 332, name = "snowball", maxStack = 16 })
add({ id = 348, name = "glowstone_dust", maxStack = 64 })
add({ id = 337, name = "clay_ball", maxStack = 64 })
add({ id = 338, name = "reeds_item", maxStack = 64, block = 83 })
add({ id = 351, name = "dye", maxStack = 64 }) -- meta 4 = lapis lazuli
add({ id = 363, name = "beef", maxStack = 64, food = 3, saturation = 0.3 })
add({ id = 364, name = "cooked_beef", maxStack = 64, food = 8, saturation = 0.8 })
add({ id = 367, name = "rotten_flesh", maxStack = 64, food = 4, saturation = 0.1 })
add({ id = 388, name = "emerald", maxStack = 64 })
add({ id = 262, name = "arrow", maxStack = 64 })
add({ id = 324, name = "wooden_door_item", maxStack = 1, block = 64 })
add({ id = 330, name = "iron_door_item", maxStack = 1, block = 71 })
add({ id = 325, name = "bucket", maxStack = 16 })
add({ id = 326, name = "water_bucket", maxStack = 1 })
add({ id = 327, name = "lava_bucket", maxStack = 1 })
add({ id = 287, name = "string", maxStack = 64 })
add({ id = 288, name = "feather", maxStack = 64 })
add({ id = 289, name = "gunpowder", maxStack = 64 })
add({ id = 352, name = "bone", maxStack = 64 })

function ItemRegistry.get(id: number): ItemDef?
	return byId[id]
end

function ItemRegistry.byName(name: string): ItemDef?
	return byName[name]
end

function ItemRegistry.idOf(name: string): number
	local d = byName[name]
	assert(d, "unknown item " .. name)
	return d.id
end

function ItemRegistry.maxStack(id: number): number
	local d = byId[id]
	return if d then d.maxStack else 64
end

return ItemRegistry
