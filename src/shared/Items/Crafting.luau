--!strict
-- Legacy-style crafting: craft a listed recipe directly from inventory
-- contents. Server-authoritative: craft() re-validates everything and is
-- atomic (either all ingredients are consumed and the output added, or
-- nothing changes).

local Inventory = require("./Inventory")
local ItemStack = require("./ItemStack")
local Recipes = require("./Recipes")

local Crafting = {}

-- How many times `recipe` can be crafted from `inv` with the given grid.
function Crafting.maxCrafts(inv: Inventory.Inventory, recipe: Recipes.Recipe, grid: number): number
	if recipe.grid > grid then
		return 0
	end
	local best = math.huge
	for _, ing in recipe.inputs do
		local have = Inventory.count(inv, ing.id, ing.meta) - (if inv.cursor and inv.cursor.id == ing.id and (ing.meta == nil or inv.cursor.meta == ing.meta) then inv.cursor.count else 0)
		best = math.min(best, have // ing.count)
	end
	return if best == math.huge then 0 else best
end

-- Recipes craftable at least once, in recipe order (UI shows them grouped).
function Crafting.available(inv: Inventory.Inventory, grid: number): { Recipes.Recipe }
	local out = {}
	for _, r in Recipes.all() do
		if Crafting.maxCrafts(inv, r, grid) > 0 then
			table.insert(out, r)
		end
	end
	return out
end

local function snapshot(inv: Inventory.Inventory): { [number]: ItemStack.ItemStack? }
	local s = {}
	for i = 1, Inventory.SIZE do
		s[i] = inv.slots[i]
	end
	return s
end

-- Crafts recipe `recipeId` once. Returns true on success. Fails (no change)
-- if the recipe is unknown, needs a bigger grid, ingredients are missing or
-- the output does not fit.
function Crafting.craft(inv: Inventory.Inventory, recipeId: any, grid: number): boolean
	if type(recipeId) ~= "number" then
		return false
	end
	local r = Recipes.get(recipeId)
	if r == nil or Crafting.maxCrafts(inv, r, grid) < 1 then
		return false
	end
	local before = snapshot(inv)
	local v = inv.version
	for _, ing in r.inputs do
		local removed = Inventory.remove(inv, ing.id, ing.meta, ing.count)
		assert(removed == ing.count, "maxCrafts said ingredients were present")
	end
	local left = Inventory.add(inv, ItemStack.new(r.output.id, r.output.count, r.output.meta))
	if left > 0 then
		-- roll back atomically
		for i = 1, Inventory.SIZE do
			inv.slots[i] = before[i]
		end
		inv.version = v
		return false
	end
	return true
end

return Crafting
