--!strict
-- Player inventory: 36 main slots (1..9 = hotbar, 10..36 = storage) plus
-- 4 armour slots (37..40) and a cursor slot used by container UIs.
-- All mutations conserve items: every operation either moves items or
-- returns what could not be placed. Indices are validated so the same code
-- can execute untrusted client requests on the server.

local ItemStack = require("./ItemStack")
local SlotClick = require("./SlotClick")

local ItemRegistry = require("./ItemRegistry")

-- armour slots 37..40 accept only the matching piece
local ARMOUR_RULES: { [number]: SlotClick.Rules } = {}
for slot = 37, 40 do
	ARMOUR_RULES[slot] = {
		maxPlace = 1,
		canPlace = function(s: ItemStack.ItemStack): boolean
			local d = ItemRegistry.get(s.id)
			return d ~= nil and d.armorSlot == slot
		end,
	}
end

export type ItemStack = ItemStack.ItemStack
export type Inventory = {
	slots: { [number]: ItemStack? }, -- 1..40
	cursor: ItemStack?,
	selected: number, -- hotbar index 1..9
	version: number,
}

local Inventory = {}

Inventory.MAIN = 36
Inventory.HOTBAR = 9
Inventory.SIZE = 40

function Inventory.new(): Inventory
	return { slots = {}, cursor = nil, selected = 1, version = 0 }
end

local function validSlot(i: any): boolean
	return type(i) == "number" and i == math.floor(i) and i >= 1 and i <= Inventory.SIZE
end
Inventory.validSlot = validSlot

local function touch(inv: Inventory)
	inv.version += 1
end

-- Adds a stack: merges into matching stacks (hotbar first, then storage),
-- then fills empty slots in the same order. Returns the leftover count.
function Inventory.add(inv: Inventory, stack: ItemStack): number
	local left = stack.count
	local max = ItemStack.maxStack(stack)
	if max > 1 then
		for i = 1, Inventory.MAIN do
			local s = inv.slots[i]
			if s and ItemStack.canMerge(s, stack) and s.count < max then
				local move = math.min(max - s.count, left)
				inv.slots[i] = ItemStack.copy(s, s.count + move)
				left -= move
				if left == 0 then
					touch(inv)
					return 0
				end
			end
		end
	end
	for i = 1, Inventory.MAIN do
		if inv.slots[i] == nil then
			local move = math.min(max, left)
			inv.slots[i] = ItemStack.copy(stack, move)
			left -= move
			if left == 0 then
				break
			end
		end
	end
	if left ~= stack.count then
		touch(inv)
	end
	return left
end

-- Removes up to `count` of (id, meta). Returns how many were removed.
function Inventory.remove(inv: Inventory, id: number, meta: number?, count: number): number
	local removed = 0
	for i = 1, Inventory.MAIN do
		local s = inv.slots[i]
		if s and s.id == id and (meta == nil or s.meta == meta) then
			local take = math.min(s.count, count - removed)
			inv.slots[i] = if s.count - take > 0 then ItemStack.copy(s, s.count - take) else nil
			removed += take
			if removed == count then
				break
			end
		end
	end
	if removed > 0 then
		touch(inv)
	end
	return removed
end

function Inventory.count(inv: Inventory, id: number, meta: number?): number
	local n = 0
	for i = 1, Inventory.SIZE do
		local s = inv.slots[i]
		if s and s.id == id and (meta == nil or s.meta == meta) then
			n += s.count
		end
	end
	if inv.cursor and inv.cursor.id == id and (meta == nil or inv.cursor.meta == meta) then
		n += inv.cursor.count
	end
	return n
end

function Inventory.totalItems(inv: Inventory): number
	local n = if inv.cursor then inv.cursor.count else 0
	for i = 1, Inventory.SIZE do
		local s = inv.slots[i]
		if s then
			n += s.count
		end
	end
	return n
end

function Inventory.held(inv: Inventory): ItemStack?
	return inv.slots[inv.selected]
end

function Inventory.select(inv: Inventory, index: number): boolean
	if type(index) ~= "number" or index ~= math.floor(index) or index < 1 or index > 9 then
		return false
	end
	inv.selected = index
	touch(inv)
	return true
end

-- Consumes `n` items from the selected hotbar slot. Returns success.
function Inventory.consumeHeld(inv: Inventory, n: number): boolean
	local s = inv.slots[inv.selected]
	if s == nil or s.count < n then
		return false
	end
	inv.slots[inv.selected] = if s.count > n then ItemStack.copy(s, s.count - n) else nil
	touch(inv)
	return true
end

-- Container-style click (see SlotClick): left picks up / places / merges /
-- swaps; right picks up half / places one. Armour slots hold one item.
function Inventory.click(inv: Inventory, slot: number, button: string): boolean
	if not validSlot(slot) then
		return false
	end
	local rules = if slot > Inventory.MAIN then ARMOUR_RULES[slot] else nil
	local ok, ns, nc = SlotClick.click(inv.slots[slot], inv.cursor, button, rules)
	if not ok then
		return false
	end
	inv.slots[slot], inv.cursor = ns, nc
	touch(inv)
	return true
end

-- Moves a whole stack between storage and hotbar (Legacy "quick move").
function Inventory.quickMove(inv: Inventory, slot: number): boolean
	if not validSlot(slot) or slot > Inventory.MAIN then
		return false
	end
	local s = inv.slots[slot]
	if s == nil then
		return false
	end
	local lo, hi = 10, 36
	if slot >= 10 then
		lo, hi = 1, 9
	end
	inv.slots[slot] = nil
	local left = s.count
	local max = ItemStack.maxStack(s)
	for pass = 1, 2 do
		for i = lo, hi do
			local t = inv.slots[i]
			if pass == 1 and t and ItemStack.canMerge(t, s) and t.count < max then
				local move = math.min(max - t.count, left)
				inv.slots[i] = ItemStack.copy(t, t.count + move)
				left -= move
			elseif pass == 2 and t == nil and left > 0 then
				inv.slots[i] = ItemStack.copy(s, math.min(max, left))
				left -= math.min(max, left)
			end
			if left == 0 then
				break
			end
		end
		if left == 0 then
			break
		end
	end
	if left > 0 then
		inv.slots[slot] = ItemStack.copy(s, left)
	end
	touch(inv)
	return left < s.count
end

-- Total defence points of worn armour (0..20).
function Inventory.armorPoints(inv: Inventory): number
	local n = 0
	for slot = 37, 40 do
		local s = inv.slots[slot]
		if s then
			local d = ItemRegistry.get(s.id)
			n += if d and d.armor then d.armor else 0
		end
	end
	return n
end

-- Wears each armour piece by max(1, damage // 4); broken pieces vanish.
function Inventory.wearArmor(inv: Inventory, damage: number)
	local wear = math.max(1, damage // 4)
	for slot = 37, 40 do
		local s = inv.slots[slot]
		if s then
			local d = ItemRegistry.get(s.id)
			if d and d.durability then
				local nd = s.damage + wear
				inv.slots[slot] = if nd >= d.durability then nil else ItemStack.new(s.id, 1, s.meta, nd)
			end
		end
	end
	touch(inv)
end

-- Drops the cursor stack back into the inventory (closing a UI); returns leftover count.
function Inventory.returnCursor(inv: Inventory): number
	local c = inv.cursor
	if c == nil then
		return 0
	end
	inv.cursor = nil
	local left = Inventory.add(inv, c)
	if left > 0 then
		inv.cursor = ItemStack.copy(c, left)
	end
	return left
end

return Inventory
