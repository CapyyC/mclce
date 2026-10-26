--!strict
-- Item stacks are small immutable-by-convention records. `damage` is tool wear.
local ItemRegistry = require("./ItemRegistry")

export type ItemStack = { id: number, meta: number, count: number, damage: number }

local ItemStack = {}

function ItemStack.new(id: number, count: number?, meta: number?, damage: number?): ItemStack
	return { id = id, meta = meta or 0, count = count or 1, damage = damage or 0 }
end

function ItemStack.copy(s: ItemStack, count: number?): ItemStack
	return { id = s.id, meta = s.meta, count = count or s.count, damage = s.damage }
end

-- Stacks merge only if id, meta and damage match and the item stacks.
function ItemStack.canMerge(a: ItemStack, b: ItemStack): boolean
	return a.id == b.id and a.meta == b.meta and a.damage == b.damage and ItemRegistry.maxStack(a.id) > 1
end

function ItemStack.maxStack(s: ItemStack): number
	return ItemRegistry.maxStack(s.id)
end

-- Validates an untrusted stack (e.g. from the network or a save).
function ItemStack.isValid(s: any): boolean
	if type(s) ~= "table" then
		return false
	end
	for _, k in { "id", "meta", "count", "damage" } do
		local v = s[k]
		if type(v) ~= "number" or v ~= math.floor(v) or v < 0 then
			return false
		end
	end
	if ItemRegistry.get(s.id) == nil then
		return false
	end
	return s.count >= 1 and s.count <= ItemRegistry.maxStack(s.id) and s.meta <= 15
end

return ItemStack
