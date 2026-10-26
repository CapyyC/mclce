--!strict
-- Crafting and smelting recipes.
--
-- Legacy Console Edition does not use a free-form crafting grid: the
-- crafting screen lists recipes (grouped into category tabs) and the player
-- crafts directly from inventory contents. A recipe therefore needs only its
-- ingredient multiset, its output and the grid size it requires (2x2 in the
-- inventory, 3x3 at a crafting table). Recipe contents are the classic ones.

export type Ingredient = { id: number, meta: number?, count: number }
export type Recipe = {
	id: number, -- stable index
	name: string,
	category: string, -- "structures" | "tools" | "food" | "decoration" | "materials"
	grid: number, -- 2 or 3
	output: { id: number, meta: number, count: number },
	inputs: { Ingredient },
}
export type Smelt = { input: number, inputMeta: number?, output: number, outputMeta: number, xp: number }

local Recipes = {}

local list: { Recipe } = {}

local PLANKS, LOG, LOG2, STICK, COBBLE, COAL, IRON, GOLD, DIAMOND = 5, 17, 162, 280, 4, 263, 265, 266, 264

local function add(name: string, category: string, grid: number, out: { number }, inputs: { Ingredient })
	table.insert(list, {
		id = #list + 1,
		name = name,
		category = category,
		grid = grid,
		output = { id = out[1], meta = out[3] or 0, count = out[2] },
		inputs = inputs,
	})
end

-- planks from each log variant (meta 0..3) and acacia/dark oak logs
for meta = 0, 3 do
	add("planks_" .. meta, "materials", 2, { PLANKS, 4, meta }, { { id = LOG, meta = meta, count = 1 } })
end
for meta = 0, 1 do
	add("planks_" .. (4 + meta), "materials", 2, { PLANKS, 4, 4 + meta }, { { id = LOG2, meta = meta, count = 1 } })
end
add("stick", "materials", 2, { STICK, 4 }, { { id = PLANKS, count = 2 } })
add("crafting_table", "structures", 2, { 58, 1 }, { { id = PLANKS, count = 4 } })
add("torch", "decoration", 2, { 50, 4 }, { { id = COAL, count = 1 }, { id = STICK, count = 1 } })
add("furnace", "structures", 3, { 61, 1 }, { { id = COBBLE, count = 8 } })
add("chest", "structures", 3, { 54, 1 }, { { id = PLANKS, count = 8 } })
add("stonebrick", "structures", 2, { 98, 4 }, { { id = 1, meta = 0, count = 4 } })
add("sandstone", "structures", 2, { 24, 1 }, { { id = 12, count = 4 } })
add("glowstone", "decoration", 2, { 89, 1 }, { { id = 348, count = 4 } })
add("snow", "structures", 2, { 80, 1 }, { { id = 332, count = 4 } })
add("clay", "structures", 2, { 82, 1 }, { { id = 337, count = 4 } })
add("bowl", "food", 3, { 281, 4 }, { { id = PLANKS, count = 3 } })
add("bread", "food", 3, { 297, 1 }, { { id = 296, count = 3 } })
add("mushroom_stew", "food", 3, { 282, 1 }, { { id = 39, count = 1 }, { id = 40, count = 1 }, { id = 281, count = 1 } })

type ToolMat = { name: string, mat: number, ids: { number } }
local TOOL_MATS: { ToolMat } = {
	{ name = "wooden", mat = PLANKS, ids = { 268, 269, 270, 271, 290 } },
	{ name = "stone", mat = COBBLE, ids = { 272, 273, 274, 275, 291 } },
	{ name = "iron", mat = IRON, ids = { 267, 256, 257, 258, 292 } },
	{ name = "golden", mat = GOLD, ids = { 283, 284, 285, 286, 294 } },
	{ name = "diamond", mat = DIAMOND, ids = { 276, 277, 278, 279, 293 } },
}
-- material count and stick count for sword, shovel, pickaxe, axe, hoe
type ToolShape = { kind: string, mats: number, sticks: number }
local TOOL_SHAPES: { ToolShape } = {
	{ kind = "sword", mats = 2, sticks = 1 },
	{ kind = "shovel", mats = 1, sticks = 2 },
	{ kind = "pickaxe", mats = 3, sticks = 2 },
	{ kind = "axe", mats = 3, sticks = 2 },
	{ kind = "hoe", mats = 2, sticks = 2 },
}
for _, m in TOOL_MATS do
	for i, shape in TOOL_SHAPES do
		add(m.name .. "_" .. shape.kind, "tools", 3, { m.ids[i], 1 }, { { id = m.mat, count = shape.mats }, { id = STICK, count = shape.sticks } })
	end
end

-- storage blocks and back
type Storage = { name: string, block: number, item: number, meta: number }
local STORAGE: { Storage } = {
	{ name = "iron_block", block = 42, item = IRON, meta = 0 },
	{ name = "gold_block", block = 41, item = GOLD, meta = 0 },
	{ name = "diamond_block", block = 57, item = DIAMOND, meta = 0 },
	{ name = "emerald_block", block = 133, item = 388, meta = 0 },
	{ name = "lapis_block", block = 22, item = 351, meta = 4 },
}
for _, s in STORAGE do
	add(s.name, "materials", 3, { s.block, 1 }, { { id = s.item, meta = s.meta, count = 9 } })
	add(s.name .. "_unpack", "materials", 2, { s.item, 9, s.meta }, { { id = s.block, count = 1 } })
end

local smelts: { Smelt } = {
	{ input = 15, output = IRON, outputMeta = 0, xp = 0.7 },
	{ input = 14, output = GOLD, outputMeta = 0, xp = 1.0 },
	{ input = 12, output = 20, outputMeta = 0, xp = 0.1 },
	{ input = COBBLE, output = 1, outputMeta = 0, xp = 0.1 },
	{ input = LOG, output = COAL, outputMeta = 1, xp = 0.15 }, -- charcoal
	{ input = LOG2, output = COAL, outputMeta = 1, xp = 0.15 },
	{ input = 319, output = 320, outputMeta = 0, xp = 0.35 },
	{ input = 363, output = 364, outputMeta = 0, xp = 0.35 },
	{ input = 81, output = 351, outputMeta = 2, xp = 1.0 }, -- cactus green
	{ input = 56, output = DIAMOND, outputMeta = 0, xp = 1.0 },
	{ input = 16, output = COAL, outputMeta = 0, xp = 0.1 },
}

-- furnace fuel burn time in ticks (classic values)
local FUEL: { [number]: number } = {
	[COAL] = 1600, [PLANKS] = 300, [LOG] = 300, [LOG2] = 300, [STICK] = 100,
	[58] = 300, [54] = 300, [6] = 100, [327] = 20000, [173] = 16000,
	[268] = 200, [269] = 200, [270] = 200, [271] = 200, [290] = 200,
}

function Recipes.all(): { Recipe }
	return list
end

function Recipes.get(id: number): Recipe?
	return list[id]
end

function Recipes.byName(name: string): Recipe?
	for _, r in list do
		if r.name == name then
			return r
		end
	end
	return nil
end

function Recipes.smeltResult(id: number, meta: number): Smelt?
	for _, s in smelts do
		if s.input == id and (s.inputMeta == nil or s.inputMeta == meta) then
			return s
		end
	end
	return nil
end

function Recipes.fuelTicks(id: number): number
	return FUEL[id] or 0
end

return Recipes
