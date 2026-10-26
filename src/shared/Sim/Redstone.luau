--!strict
-- Redstone (subset): wire, levers, stone buttons, pressure plates, redstone
-- torches, lamps, redstone blocks and doors.
--
-- Model (classic semantics, clean-room implementation):
--  * Sources: lever (on), pressed button/plate, lit torch, redstone block
--    emit 15 into adjacent wires/components.
--  * A solid block is STRONGLY powered by a lever/button attached to it, a
--    lit torch directly below it or a pressed plate on top of it; strongly
--    powered blocks drive adjacent wires at 15. A solid block is WEAKLY powered
--    by a wire on top of it or a wire pointing into it; weak power only
--    drives components (torches, lamps, doors), not wires.
--  * Wire power = max(15 from sources/strong blocks, neighbour wire - 1);
--    wires connect horizontally and step up/down one block (step-up blocked
--    by a solid block above the lower wire).
--  * Torches turn off when the block they are attached to is powered
--    (2-tick delay); lamps light when powered (turn-off delay 4 ticks);
--    doors open while powered.
-- Wire networks are recomputed by flood fill on change, so results do not
-- depend on update order.

local World = require("../Voxel/World")
local BlockRegistry = require("../Blocks/BlockRegistry")

export type Redstone = {
	world: World.World,
	scheduled: { [number]: { x: number, y: number, z: number, at: number } },
	tick: number,
	busy: boolean,
	pending: { number },
	stats: { networks: number, toggles: number },
}

local Redstone = {}

local WIRE, LEVER, STONE_PLATE, WOOD_PLATE, TORCH_OFF, TORCH_ON, BUTTON = 55, 69, 70, 72, 75, 76, 77
local LAMP, LAMP_ON, RS_BLOCK, WOOD_DOOR, IRON_DOOR = 123, 124, 152, 64, 71
local REPEATER, REPEATER_ON = 93, 94

-- Repeater output direction by meta % 4: 0 north (-z), 1 east (+x), 2 south (+z), 3 west (-x).
-- meta // 4 = extra delay (delay = 1..4 redstone ticks = 2..8 game ticks).
local REP_DX = { [0] = 0, 1, 0, -1 }
local REP_DZ = { [0] = -1, 0, 1, 0 }

local function repeaterFacesInto(st: number, rx: number, rz: number, tx: number, tz: number): boolean
	local d = st % 4
	return rx + REP_DX[d] == tx and rz + REP_DZ[d] == tz
end

local HX = { 1, -1, 0, 0 }
local HZ = { 0, 0, 1, -1 }
local DX = { 1, -1, 0, 0, 0, 0 }
local DY = { 0, 0, 1, -1, 0, 0 }
local DZ = { 0, 0, 0, 0, 1, -1 }

Redstone.BUTTON_TICKS = 20
Redstone.TORCH_DELAY = 2
Redstone.LAMP_OFF_DELAY = 4

local function key(x: number, y: number, z: number): number
	return ((x + 2097152) * 4194304 + (z + 2097152)) * 256 + y
end

function Redstone.new(world: World.World): Redstone
	return { world = world, scheduled = {}, tick = 0, busy = false, pending = {}, stats = { networks = 0, toggles = 0 } }
end

local function idAt(rs: Redstone, x: number, y: number, z: number): number
	return World.getId(rs.world, x, y, z)
end

local function isSolidBlock(id: number): boolean
	return BlockRegistry.occludes(id)
end

-- attachment offset for torch-like metas: 1 -x, 2 +x, 3 -z, 4 +z, 5 floor (-y), 0/6/7 ceiling (+y)
local function attachedTo(x: number, y: number, z: number, meta: number): (number, number, number)
	local m = meta % 8
	if m == 1 then
		return x - 1, y, z
	elseif m == 2 then
		return x + 1, y, z
	elseif m == 3 then
		return x, y, z - 1
	elseif m == 4 then
		return x, y, z + 1
	elseif m == 5 then
		return x, y - 1, z
	end
	return x, y + 1, z
end
Redstone.attachedTo = attachedTo

local function isSourceOn(st: number): boolean
	local id, meta = st // 16, st % 16
	if id == LEVER or id == BUTTON then
		return meta >= 8
	elseif id == STONE_PLATE or id == WOOD_PLATE then
		return meta >= 1
	end
	return id == TORCH_ON or id == RS_BLOCK
end

-- Is solid block (x,y,z) strongly powered (by an attached lever/button,
-- a lit torch below, or a pressed plate on top)?
local function stronglyPowered(rs: Redstone, x: number, y: number, z: number): boolean
	if not isSolidBlock(idAt(rs, x, y, z)) then
		return false
	end
	for d = 1, 6 do
		local nx, ny, nz = x + DX[d], y + DY[d], z + DZ[d]
		local st = World.getState(rs.world, nx, ny, nz)
		local id = st // 16
		if (id == LEVER or id == BUTTON) and st % 16 >= 8 then
			local ax, ay, az = attachedTo(nx, ny, nz, st % 8)
			if ax == x and ay == y and az == z then
				return true
			end
		elseif id == TORCH_ON and d == 4 then
			-- torch directly below powers the block above it
			return true
		elseif (id == STONE_PLATE or id == WOOD_PLATE) and d == 3 and st % 16 >= 1 then
			return true
		elseif id == REPEATER_ON and ny == y and repeaterFacesInto(st % 16, nx, nz, x, z) then
			return true
		end
	end
	return false
end
Redstone.stronglyPowered = stronglyPowered

-- Does the wire at (wx,wy,wz) point into horizontal neighbour direction i?
-- A wire points in every direction it connects to; an isolated dot points all ways.
local function wireConnects(rs: Redstone, x: number, y: number, z: number, i: number): boolean
	local nx, nz = x + HX[i], z + HZ[i]
	local n = idAt(rs, nx, y, nz)
	if n == WIRE or n == LEVER or n == BUTTON or n == TORCH_ON or n == TORCH_OFF or n == RS_BLOCK or n == STONE_PLATE or n == WOOD_PLATE then
		return true
	end
	if n == REPEATER or n == REPEATER_ON then
		-- repeaters connect along their axis only
		local d = World.getState(rs.world, nx, y, nz) % 4
		return (REP_DX[d] ~= 0) == (HX[i] ~= 0)
	end
	-- step down / up
	if not isSolidBlock(n) and idAt(rs, nx, y - 1, nz) == WIRE then
		return true
	end
	if isSolidBlock(n) and not isSolidBlock(idAt(rs, x, y + 1, z)) and idAt(rs, nx, y + 1, nz) == WIRE then
		return true
	end
	return false
end

local OPP = { 2, 1, 4, 3 }

-- Directions a wire points: every direction it connects to; a wire with a
-- single connection also points straight ahead (line end); an isolated dot
-- points all four ways.
local function wirePointsInto(rs: Redstone, x: number, y: number, z: number, i: number): boolean
	local n, only = 0, 0
	for j = 1, 4 do
		if wireConnects(rs, x, y, z, j) then
			n += 1
			only = j
			if j == i then
				return true
			end
		end
	end
	if n == 0 then
		return true
	end
	return n == 1 and OPP[only] == i
end

-- Is solid block weakly powered by wires (on top, or pointing into it)?
local function weaklyPowered(rs: Redstone, x: number, y: number, z: number): boolean
	if not isSolidBlock(idAt(rs, x, y, z)) then
		return false
	end
	local above = World.getState(rs.world, x, y + 1, z)
	if above // 16 == WIRE and above % 16 > 0 then
		return true
	end
	for i = 1, 4 do
		local wx, wz = x - HX[i], z - HZ[i] -- wire to the side, pointing toward +i into this block
		local st = World.getState(rs.world, wx, y, wz)
		if st // 16 == WIRE and st % 16 > 0 and wirePointsInto(rs, wx, y, wz, i) then
			return true
		end
	end
	return false
end

local function blockPowered(rs: Redstone, x: number, y: number, z: number): boolean
	return stronglyPowered(rs, x, y, z) or weaklyPowered(rs, x, y, z)
end
Redstone.blockPowered = blockPowered

-- Power arriving at a component cell (lamp, door): adjacent sources,
-- powered solid blocks, or wires pointing at it.
local function componentPowered(rs: Redstone, x: number, y: number, z: number): boolean
	for d = 1, 6 do
		local nx, ny, nz = x + DX[d], y + DY[d], z + DZ[d]
		local st = World.getState(rs.world, nx, ny, nz)
		local id = st // 16
		if isSourceOn(st) then
			return true
		end
		if id == REPEATER_ON and ny == y and repeaterFacesInto(st % 16, nx, nz, x, z) then
			return true
		end
		if id == WIRE and st % 16 > 0 then
			if d == 4 then
				-- wire below does not power upward
			elseif d == 3 then
				return true -- wire on top
			else
				-- horizontal: wire must point toward us; direction from wire to us is opposite of d
				local back = if d == 1 then 2 elseif d == 2 then 1 elseif d == 5 then 4 else 3
				if wirePointsInto(rs, nx, ny, nz, back) then
					return true
				end
			end
		end
		if isSolidBlock(id) and blockPowered(rs, nx, ny, nz) then
			return true
		end
	end
	return false
end
Redstone.componentPowered = componentPowered

-- Source power delivered into the wire cell from non-wire neighbours.
local function wireInput(rs: Redstone, x: number, y: number, z: number): number
	for d = 1, 6 do
		local nx, ny, nz = x + DX[d], y + DY[d], z + DZ[d]
		local st = World.getState(rs.world, nx, ny, nz)
		if isSourceOn(st) then
			return 15
		end
		if st // 16 == REPEATER_ON and ny == y and repeaterFacesInto(st % 16, nx, nz, x, z) then
			return 15
		end
		if isSolidBlock(st // 16) and stronglyPowered(rs, nx, ny, nz) then
			return 15
		end
	end
	return 0
end

-- Wire neighbours (horizontal, step up, step down).
local function wireNeighbours(rs: Redstone, x: number, y: number, z: number): { number }
	local out = {}
	for i = 1, 4 do
		local nx, nz = x + HX[i], z + HZ[i]
		local n = idAt(rs, nx, y, nz)
		if n == WIRE then
			table.insert(out, nx)
			table.insert(out, y)
			table.insert(out, nz)
		elseif isSolidBlock(n) then
			if not isSolidBlock(idAt(rs, x, y + 1, z)) and idAt(rs, nx, y + 1, nz) == WIRE then
				table.insert(out, nx)
				table.insert(out, y + 1)
				table.insert(out, nz)
			end
		elseif idAt(rs, nx, y - 1, nz) == WIRE then
			table.insert(out, nx)
			table.insert(out, y - 1)
			table.insert(out, nz)
		end
	end
	return out
end

local function notifyAround(rs: Redstone, x: number, y: number, z: number)
	local q = rs.pending
	for dy = -1, 1 do
		for dz = -1, 1 do
			for dx = -1, 1 do
				local n = #q
				q[n + 1], q[n + 2], q[n + 3] = x + dx, y + dy, z + dz
			end
		end
	end
end

-- Recomputes the whole wire network containing (x,y,z). `netDone` marks
-- cells already recomputed in this pass so each network is solved once.
local function recomputeNetwork(rs: Redstone, x: number, y: number, z: number, netDone: { [number]: boolean })
	if idAt(rs, x, y, z) ~= WIRE or netDone[key(x, y, z)] then
		return
	end
	rs.stats.networks += 1
	local cells: { number } = {}
	local seen: { [number]: boolean } = {}
	local stack = { x, y, z }
	while #stack > 0 do
		local cz, cy, cx = table.remove(stack), table.remove(stack), table.remove(stack)
		local k = key(cx :: number, cy :: number, cz :: number)
		if seen[k] then
			continue
		end
		seen[k] = true
		netDone[k] = true
		table.insert(cells, cx :: number)
		table.insert(cells, cy :: number)
		table.insert(cells, cz :: number)
		if #cells > 3 * 4096 then
			break -- bound pathological networks
		end
		for _, v in wireNeighbours(rs, cx :: number, cy :: number, cz :: number) do
			table.insert(stack, v)
		end
	end
	-- BFS from inputs (Dijkstra with integer levels via buckets)
	local power: { [number]: number } = {}
	local buckets: { { number } } = {}
	for l = 1, 15 do
		buckets[l] = {}
	end
	for i = 1, #cells, 3 do
		local cx, cy, cz = cells[i], cells[i + 1], cells[i + 2]
		local p = wireInput(rs, cx, cy, cz)
		if p > 0 then
			power[key(cx, cy, cz)] = p
			table.insert(buckets[p], cx)
			table.insert(buckets[p], cy)
			table.insert(buckets[p], cz)
		end
	end
	for l = 15, 2, -1 do
		local b = buckets[l]
		local i = 1
		while i <= #b do
			local cx, cy, cz = b[i], b[i + 1], b[i + 2]
			i += 3
			if power[key(cx, cy, cz)] ~= l then
				continue
			end
			local ns = wireNeighbours(rs, cx, cy, cz)
			for j = 1, #ns, 3 do
				local nk = key(ns[j], ns[j + 1], ns[j + 2])
				if (power[nk] or 0) < l - 1 then
					power[nk] = l - 1
					local nb = buckets[l - 1]
					table.insert(nb, ns[j])
					table.insert(nb, ns[j + 1])
					table.insert(nb, ns[j + 2])
				end
			end
		end
	end
	-- write back changed wires and wake components around them
	for i = 1, #cells, 3 do
		local cx, cy, cz = cells[i], cells[i + 1], cells[i + 2]
		local p = power[key(cx, cy, cz)] or 0
		local st = World.getState(rs.world, cx, cy, cz)
		if st % 16 ~= p then
			rs.busy = true
			World.setState(rs.world, cx, cy, cz, WIRE * 16 + p)
			rs.busy = false
			notifyAround(rs, cx, cy, cz)
		end
	end
end

local function schedule(rs: Redstone, x: number, y: number, z: number, delay: number)
	local k = key(x, y, z)
	if rs.scheduled[k] == nil then
		rs.scheduled[k] = { x = x, y = y, z = z, at = rs.tick + delay }
	end
end

-- Is the repeater at (x,y,z) receiving power at its back?
local function repeaterInput(rs: Redstone, x: number, y: number, z: number, meta: number): boolean
	local d = meta % 4
	local bx, bz = x - REP_DX[d], z - REP_DZ[d]
	local st = World.getState(rs.world, bx, y, bz)
	local id = st // 16
	if id == WIRE then
		return st % 16 > 0
	end
	if isSourceOn(st) then
		return true
	end
	if id == REPEATER_ON and repeaterFacesInto(st % 16, bx, bz, x, z) then
		return true
	end
	return isSolidBlock(id) and blockPowered(rs, bx, y, bz)
end

local function repeaterDelay(meta: number): number
	return (meta // 4 + 1) * 2
end

-- Re-evaluates a single non-wire component.
local function evaluate(rs: Redstone, x: number, y: number, z: number, netDone: { [number]: boolean })
	local st = World.getState(rs.world, x, y, z)
	local id, meta = st // 16, st % 16
	if id == WIRE then
		recomputeNetwork(rs, x, y, z, netDone)
	elseif id == TORCH_ON or id == TORCH_OFF then
		local ax, ay, az = attachedTo(x, y, z, meta)
		local shouldBeOn = not blockPowered(rs, ax, ay, az)
		if shouldBeOn ~= (id == TORCH_ON) then
			schedule(rs, x, y, z, Redstone.TORCH_DELAY)
		end
	elseif id == REPEATER or id == REPEATER_ON then
		if repeaterInput(rs, x, y, z, meta) ~= (id == REPEATER_ON) then
			schedule(rs, x, y, z, repeaterDelay(meta))
		end
	elseif id == LAMP or id == LAMP_ON then
		local on = componentPowered(rs, x, y, z)
		if on and id == LAMP then
			World.setState(rs.world, x, y, z, LAMP_ON * 16)
			rs.stats.toggles += 1
		elseif not on and id == LAMP_ON then
			schedule(rs, x, y, z, Redstone.LAMP_OFF_DELAY)
		end
	elseif id == WOOD_DOOR or id == IRON_DOOR then
		local lowerY = if meta >= 8 then y - 1 else y
		local lower = World.getState(rs.world, x, lowerY, z)
		if lower // 16 ~= id then
			return
		end
		local powered = componentPowered(rs, x, lowerY, z) or componentPowered(rs, x, lowerY + 1, z)
		local open = lower % 16 >= 4
		if powered ~= open then
			local lm = lower % 4 + (if powered then 4 else 0)
			World.setState(rs.world, x, lowerY, z, id * 16 + lm)
			rs.stats.toggles += 1
		end
	end
end

local RELEVANT: { [number]: boolean } = {
	[REPEATER] = true, [REPEATER_ON] = true,
	[WIRE] = true, [LEVER] = true, [STONE_PLATE] = true, [WOOD_PLATE] = true, [TORCH_OFF] = true,
	[TORCH_ON] = true, [BUTTON] = true, [LAMP] = true, [LAMP_ON] = true, [RS_BLOCK] = true,
	[WOOD_DOOR] = true, [IRON_DOOR] = true,
}

-- World listener hook: any change may affect redstone within 2 blocks
-- (attached-block power reaches components 2 cells away).
function Redstone.onChange(rs: Redstone, x: number, y: number, z: number, oldId: number, newId: number)
	if rs.busy then
		return
	end
	if not (RELEVANT[oldId] or RELEVANT[newId] or isSolidBlock(oldId) ~= isSolidBlock(newId)) then
		return
	end
	local q = rs.pending
	for dy = -2, 2 do
		for dz = -2, 2 do
			for dx = -2, 2 do
				if math.abs(dx) + math.abs(dy) + math.abs(dz) <= 2 then
					local n = #q
					q[n + 1], q[n + 2], q[n + 3] = x + dx, y + dy, z + dz
				end
			end
		end
	end
end

-- Processes queued evaluations (bounded) and due scheduled toggles.
function Redstone.step(rs: Redstone)
	rs.tick += 1
	-- scheduled toggles
	local due: { number } = {}
	for k: number, s in rs.scheduled do
		if s.at <= rs.tick then
			table.insert(due, k)
		end
	end
	table.sort(due)
	for _, k in due do
		local s = rs.scheduled[k]
		rs.scheduled[k] = nil
		local st = World.getState(rs.world, s.x, s.y, s.z)
		local id, meta = st // 16, st % 16
		if id == TORCH_ON or id == TORCH_OFF then
			local ax, ay, az = attachedTo(s.x, s.y, s.z, meta)
			local on = not blockPowered(rs, ax, ay, az)
			local want = if on then TORCH_ON else TORCH_OFF
			if want ~= id then
				World.setState(rs.world, s.x, s.y, s.z, want * 16 + meta)
				rs.stats.toggles += 1
			end
		elseif id == REPEATER or id == REPEATER_ON then
			local want = if repeaterInput(rs, s.x, s.y, s.z, meta) then REPEATER_ON else REPEATER
			if want ~= id then
				World.setState(rs.world, s.x, s.y, s.z, want * 16 + meta)
				rs.stats.toggles += 1
			end
		elseif id == LAMP_ON then
			if not componentPowered(rs, s.x, s.y, s.z) then
				World.setState(rs.world, s.x, s.y, s.z, LAMP * 16)
				rs.stats.toggles += 1
			end
		elseif id == BUTTON and meta >= 8 then
			World.setState(rs.world, s.x, s.y, s.z, BUTTON * 16 + meta - 8)
		end
	end
	-- queued evaluations (networks solved once per pass; bounded)
	local q = rs.pending
	local guard = 0
	local netDone: { [number]: boolean } = {}
	local head = 1
	while head <= #q and guard < 16384 do
		local x, y, z = q[head], q[head + 1], q[head + 2]
		head += 3
		guard += 1
		if y >= 0 and y <= 255 and World.isLoaded(rs.world, x, z) and RELEVANT[idAt(rs, x, y, z)] then
			evaluate(rs, x, y, z, netDone)
		end
	end
	table.clear(q)
end

-- Player interaction: toggles a lever / presses a button. Returns true if handled.
function Redstone.use(rs: Redstone, x: number, y: number, z: number): boolean
	local st = World.getState(rs.world, x, y, z)
	local id, meta = st // 16, st % 16
	if id == LEVER then
		World.setState(rs.world, x, y, z, LEVER * 16 + (meta + 8) % 16)
		return true
	elseif id == BUTTON then
		if meta < 8 then
			World.setState(rs.world, x, y, z, BUTTON * 16 + meta + 8)
			schedule(rs, x, y, z, Redstone.BUTTON_TICKS)
		end
		return true
	elseif id == REPEATER or id == REPEATER_ON then
		-- cycle the delay 1 -> 4 ticks
		World.setState(rs.world, x, y, z, id * 16 + (meta + 4) % 16)
		return true
	elseif id == WOOD_DOOR then
		local lowerY = if meta >= 8 then y - 1 else y
		local lower = World.getState(rs.world, x, lowerY, z)
		if lower // 16 == WOOD_DOOR then
			World.setState(rs.world, x, lowerY, z, WOOD_DOOR * 16 + (lower % 16 + 4) % 8)
		end
		return true
	end
	return false
end

-- Pressure plates: set pressed state from whether an entity stands on it.
function Redstone.setPlate(rs: Redstone, x: number, y: number, z: number, pressed: boolean)
	local st = World.getState(rs.world, x, y, z)
	local id = st // 16
	if (id == STONE_PLATE or id == WOOD_PLATE) and (st % 16 >= 1) ~= pressed then
		World.setState(rs.world, x, y, z, id * 16 + (if pressed then 1 else 0))
	end
end

Redstone.IDS = { REPEATER = REPEATER, REPEATER_ON = REPEATER_ON, WIRE = WIRE, LEVER = LEVER, STONE_PLATE = STONE_PLATE, WOOD_PLATE = WOOD_PLATE, TORCH_OFF = TORCH_OFF, TORCH_ON = TORCH_ON, BUTTON = BUTTON, LAMP = LAMP, LAMP_ON = LAMP_ON, RS_BLOCK = RS_BLOCK, WOOD_DOOR = WOOD_DOOR, IRON_DOOR = IRON_DOOR }

return Redstone
