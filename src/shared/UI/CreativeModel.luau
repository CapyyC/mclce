--!strict
-- Creative inventory palette (Legacy groups items into tabs). Pure model:
-- tabs of item ids (with variant metas), cursor index, page of the grid.
local ItemRegistry = require("../Items/ItemRegistry")
local BlockRegistry = require("../Blocks/BlockRegistry")

export type Entry = { id: number, meta: number }
export type Model = { tabs: { { name: string, items: { Entry } } }, tab: number, index: number }

local CreativeModel = {}

local HIDDEN: { [number]: boolean } = { [90] = true, [8] = true, [10] = true, [62] = true, [75] = true, [94] = true, [124] = true, [59] = true, [64] = true, [71] = true, [26] = true, [55] = true }

local function build(): { { name: string, items: { Entry } } }
	local blocks, deco, redstone, tools, food, materials = {}, {}, {}, {}, {}, {}
	for _, b in BlockRegistry.all() do
		if b.id ~= 0 and not HIDDEN[b.id] and ItemRegistry.get(b.id) then
			local variants = if b.name == "wool" or b.name == "stained_hardened_clay" then 16 elseif b.name == "log" or b.name == "planks" or b.name == "leaves" or b.name == "sapling" then 4 else 1
			for meta = 0, variants - 1 do
				local e = { id = b.id, meta = meta }
				if b.shape == "cross" or b.layer == "cutout" and b.shape ~= "cube" then
					table.insert(deco, e)
				else
					table.insert(blocks, e)
				end
			end
		end
	end
	for id = 256, 4095 do
		local d = ItemRegistry.get(id)
		if d then
			local e = { id = id, meta = 0 }
			if d.tool or d.armor or id == 261 or id == 262 or id == 259 or id == 325 or id == 326 or id == 327 then
				table.insert(tools, e)
			elseif d.food then
				table.insert(food, e)
			elseif d.block then
				table.insert(redstone, e)
			else
				table.insert(materials, e)
			end
		end
	end
	for _, id in { 69, 70, 72, 76, 77, 123, 152, 33 } do
		if ItemRegistry.get(id) then
			table.insert(redstone, { id = id, meta = 0 })
		end
	end
	return {
		{ name = "building", items = blocks },
		{ name = "decoration", items = deco },
		{ name = "redstone", items = redstone },
		{ name = "tools", items = tools },
		{ name = "food", items = food },
		{ name = "materials", items = materials },
	}
end

function CreativeModel.new(): Model
	return { tabs = build(), tab = 1, index = 1 }
end

function CreativeModel.input(m: Model, action: string): boolean
	local items = m.tabs[m.tab].items
	if action == "tabNext" or action == "tabPrev" then
		m.tab = (m.tab - 1 + (if action == "tabNext" then 1 else -1)) % #m.tabs + 1
		m.index = 1
		return true
	elseif action == "left" or action == "right" or action == "up" or action == "down" then
		local n = #items
		if n == 0 then
			return false
		end
		local step = if action == "left" then -1 elseif action == "right" then 1 elseif action == "up" then -9 else 9
		m.index = math.clamp(m.index + step, 1, n)
		return true
	end
	return false
end

function CreativeModel.selected(m: Model): Entry?
	return m.tabs[m.tab].items[m.index]
end

return CreativeModel
