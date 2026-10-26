--!strict
-- Pure container slot-click semantics shared by the player inventory and
-- block-entity containers. Given a slot's stack and the cursor stack, returns
-- the new (slot, cursor) pair, or ok = false when the click does nothing.
--   left  click: pick up / place / merge all / swap
--   right click: pick up half / place one
-- Rules: takeOnly (e.g. furnace output), canPlace(stack) filter (fuel slot),
-- maxPlace limits how many items may sit in the slot (armour = 1).

local ItemStack = require("./ItemStack")

export type Rules = {
	takeOnly: boolean?,
	canPlace: ((ItemStack.ItemStack) -> boolean)?,
	maxPlace: number?,
}

local SlotClick = {}

function SlotClick.click(slot: ItemStack.ItemStack?, cursor: ItemStack.ItemStack?, button: string, rules: Rules?): (boolean, ItemStack.ItemStack?, ItemStack.ItemStack?)
	if button ~= "left" and button ~= "right" then
		return false, slot, cursor
	end
	local r: Rules = rules or {}
	local s, c = slot, cursor
	if c == nil then
		if s == nil then
			return false, s, c
		end
		if button == "left" or r.takeOnly then
			return true, nil, s
		end
		local take = (s.count + 1) // 2
		return true, if s.count - take > 0 then ItemStack.copy(s, s.count - take) else nil, ItemStack.copy(s, take)
	end
	-- placing requires permission
	local placeable = not r.takeOnly and (r.canPlace == nil or r.canPlace(c))
	local maxHere = math.min(ItemStack.maxStack(c), r.maxPlace or math.huge)
	if s == nil then
		if not placeable then
			return false, s, c
		end
		local n = if button == "left" then math.min(c.count, maxHere) else 1
		local rest = c.count - n
		return true, ItemStack.copy(c, n), if rest > 0 then ItemStack.copy(c, rest) else nil
	end
	if ItemStack.canMerge(s, c) then
		if r.takeOnly then
			-- taking from an output slot onto a matching cursor stack
			local max = ItemStack.maxStack(c)
			local move = math.min(s.count, max - c.count)
			if move <= 0 then
				return false, s, c
			end
			return true, if s.count - move > 0 then ItemStack.copy(s, s.count - move) else nil, ItemStack.copy(c, c.count + move)
		end
		if not placeable then
			return false, s, c
		end
		local max = math.min(ItemStack.maxStack(s), r.maxPlace or math.huge)
		local want = if button == "left" then c.count else 1
		local move = math.min(want, max - s.count)
		if move <= 0 then
			return false, s, c
		end
		return true, ItemStack.copy(s, s.count + move), if c.count - move > 0 then ItemStack.copy(c, c.count - move) else nil
	end
	-- different items: swap (only if the cursor may go here and fits)
	if not placeable or c.count > maxHere then
		return false, s, c
	end
	return true, c, s
end

return SlotClick
