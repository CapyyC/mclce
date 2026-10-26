--!strict
-- D-pad focus navigation over a set of slots laid out on a grid (Legacy
-- inventory/container screens). Each slot has integer (col, row); moving
-- picks the nearest slot in the direction, preferring the same column/row,
-- and wraps horizontally within a row like the console UI.

export type Slot = { id: any, col: number, row: number }
export type Grid = { slots: { Slot }, focus: number }

local FocusGrid = {}

function FocusGrid.new(slots: { Slot }): Grid
	return { slots = slots, focus = 1 }
end

-- Standard Legacy layout: container rows (optional), 3 storage rows, hotbar.
-- Inventory slot ids: storage 10..36, hotbar 1..9; container ids "c1".."cN".
function FocusGrid.inventoryLayout(containerSlots: number?, columns: number?): { Slot }
	local cols = columns or 9
	local out: { Slot } = {}
	local row = 0
	if containerSlots and containerSlots > 0 then
		for i = 1, containerSlots do
			table.insert(out, { id = "c" .. i, col = (i - 1) % cols, row = (i - 1) // cols })
		end
		row = (containerSlots - 1) // cols + 1
	end
	for i = 10, 36 do
		table.insert(out, { id = i, col = (i - 10) % 9, row = row + (i - 10) // 9 })
	end
	for i = 1, 9 do
		table.insert(out, { id = i, col = i - 1, row = row + 3 })
	end
	return out
end

-- Player inventory screen: 4 armour slots (ids 37..40) in a column on the
-- left above the storage rows, then storage and hotbar.
function FocusGrid.playerLayout(): { Slot }
	local out: { Slot } = {}
	for i = 0, 3 do
		table.insert(out, { id = 37 + i, col = 0, row = i })
	end
	for i = 10, 36 do
		table.insert(out, { id = i, col = (i - 10) % 9, row = 4 + (i - 10) // 9 })
	end
	for i = 1, 9 do
		table.insert(out, { id = i, col = i - 1, row = 7 })
	end
	return out
end

function FocusGrid.focused(g: Grid): Slot?
	return g.slots[g.focus]
end

local DIRS = { up = { 0, -1 }, down = { 0, 1 }, left = { -1, 0 }, right = { 1, 0 } }

-- Moves focus; returns true if it changed.
function FocusGrid.move(g: Grid, dir: string): boolean
	local d = DIRS[dir]
	local cur = g.slots[g.focus]
	if d == nil or cur == nil then
		return false
	end
	local best, bestScore = nil, math.huge
	for i, s in g.slots do
		if i ~= g.focus then
			local dc, dr = s.col - cur.col, s.row - cur.row
			-- must lie in the requested direction
			local along = dc * d[1] + dr * d[2]
			if along > 0 then
				local across = math.abs(if d[1] ~= 0 then dr else dc)
				local score = along + across * 10
				if score < bestScore then
					best, bestScore = i, score
				end
			end
		end
	end
	if best == nil and d[2] == 0 then
		-- wrap within the row
		local target = nil
		for i, s in g.slots do
			if s.row == cur.row and (target == nil or (d[1] > 0 and s.col < g.slots[target].col) or (d[1] < 0 and s.col > g.slots[target].col)) then
				target = i
			end
		end
		best = target
	end
	if best and best ~= g.focus then
		g.focus = best
		return true
	end
	return false
end

-- Focus a slot by id (e.g. after opening, hotbar selection).
function FocusGrid.focusId(g: Grid, id: any): boolean
	for i, s in g.slots do
		if s.id == id then
			g.focus = i
			return true
		end
	end
	return false
end

return FocusGrid
