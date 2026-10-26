--!strict
-- Player inventory: 36 main slots (1..9 = hotbar, 10..36 = storage) plus
-- 4 armour slots (37..40) and a cursor slot used by container UIs.
-- All mutations conserve items: every operation either moves items or
-- returns what could not be placed. Indices are validated so the same code
-- can execute untrusted client requests on the server.

local ItemStack = require("./ItemStack")

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

-- Container-style click: left click picks up / places / merges / swaps the
-- whole stack; right click picks up half or places one. Returns success.
function Inventory.click(inv: Inventory, slot: number, button: string): boolean
	if not validSlot(slot) or (button ~= "left" and button ~= "right") then
		return false
	end
	local s = inv.slots[slot]
	local c = inv.cursor
	if slot > Inventory.MAIN and c then
		-- armour slots take only one item (type checking is the caller's job)
		if c.count ~= 1 and button == "left" then
			return false
		end
	end
	if c == nil then
		if s == nil then
			return false
		end
		if button == "left" then
			inv.cursor, inv.slots[slot] = s, nil
		else
			local take = (s.count + 1) // 2
			inv.cursor = ItemStack.copy(s, take)
			inv.slots[slot] = if s.count - take > 0 then ItemStack.copy(s, s.count - take) else nil
		end
	elseif s == nil then
		if button == "left" then
			inv.slots[slot], inv.cursor = c, nil
		else
			inv.slots[slot] = ItemStack.copy(c, 1)
			inv.cursor = if c.count > 1 then ItemStack.copy(c, c.count - 1) else nil
		end
	elseif ItemStack.canMerge(s, c) then
		local max = ItemStack.maxStack(s)
		local want = if button == "left" then c.count else 1
		local move = math.min(want, max - s.count)
		if move <= 0 then
			return false
		end
		inv.slots[slot] = ItemStack.copy(s, s.count + move)
		inv.cursor = if c.count - move > 0 then ItemStack.copy(c, c.count - move) else nil
	else
		inv.slots[slot], inv.cursor = c, s
	end
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
