--!strict
-- Legacy Console crafting screen model. Recipes are grouped into category
-- tabs (switched with LB/RB); within a tab the cursor moves left/right over
-- recipes. Every recipe that fits the grid is listed; ones the player cannot
-- craft right now are flagged so the UI can grey them out (Legacy shows
-- unavailable recipes dimmed rather than hiding them).

local Recipes = require("../Items/Recipes")
local Crafting = require("../Items/Crafting")
local Inventory = require("../Items/Inventory")

export type Entry = { recipe: Recipes.Recipe, craftable: boolean, count: number }
export type Model = {
	tabs: { string },
	tab: number,
	index: number,
	grid: number,
	entries: { Entry },
}

local CraftingModel = {}

-- Tab order mirrors the Legacy crafting screen's category bar.
CraftingModel.TABS = { "structures", "tools", "food", "armour", "mechanisms", "decoration", "materials" }

function CraftingModel.new(grid: number): Model
	return { tabs = CraftingModel.TABS, tab = 1, index = 1, grid = grid, entries = {} }
end

-- Rebuilds the entry list for the current tab from the inventory.
function CraftingModel.refresh(m: Model, inv: Inventory.Inventory)
	local cat = m.tabs[m.tab]
	local entries: { Entry } = {}
	for _, r in Recipes.all() do
		if r.category == cat and r.grid <= m.grid then
			local n = Crafting.maxCrafts(inv, r, m.grid)
			table.insert(entries, { recipe = r, craftable = n > 0, count = n })
		end
	end
	-- craftable first (stable within each group), like the console sorting
	table.sort(entries, function(a: Entry, b: Entry): boolean
		if a.craftable ~= b.craftable then
			return a.craftable
		end
		return a.recipe.id < b.recipe.id
	end)
	m.entries = entries
	if m.index > #entries then
		m.index = math.max(1, #entries)
	end
end

-- Input actions: "tabNext", "tabPrev", "left", "right". Returns true if the
-- selection changed.
function CraftingModel.input(m: Model, action: string, inv: Inventory.Inventory): boolean
	if action == "tabNext" or action == "tabPrev" then
		local n = #m.tabs
		m.tab = (m.tab - 1 + (if action == "tabNext" then 1 else -1)) % n + 1
		m.index = 1
		CraftingModel.refresh(m, inv)
		return true
	elseif action == "left" or action == "right" then
		local n = #m.entries
		if n == 0 then
			return false
		end
		m.index = (m.index - 1 + (if action == "right" then 1 else -1)) % n + 1
		return true
	end
	return false
end

function CraftingModel.selected(m: Model): Entry?
	return m.entries[m.index]
end

return CraftingModel
