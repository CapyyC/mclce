--!strict
-- Scheduled-tick fluid simulation (water and lava), classic rules:
--  * source blocks use the still id (9 water / 11 lava) with meta 0;
--    flowing blocks use 8 / 10 with meta = level 1..7, +8 when falling.
--  * water spreads every 5 ticks and loses 1 level per block (7 blocks);
--    lava every 30 ticks and loses 2 levels per block (overworld, ~4 blocks).
--  * fluid falls first; spreads sideways only when it cannot fall, and prefers
--    the direction(s) with the shortest path to a drop (within 4 water / 2 lava).
--  * flowing water next to >= 2 sources, above solid ground or a source,
--    becomes a source (infinite water).
--  * reactions: lava source touched by water -> obsidian, flowing lava ->
--    cobblestone; lava flowing down into water -> stone.
-- Deterministic: due updates are processed in (tick, position) order.

local World = require("../Voxel/World")
local BlockRegistry = require("../Blocks/BlockRegistry")

export type Fluids = {
	world: World.World,
	queue: { [number]: number }, -- position key -> due tick
	buckets: { [number]: { number } }, -- due tick -> keys (may hold stale entries)
	count: number,
	tick: number,
	budget: number,
	stats: { updates: number, scheduled: number },
	suppress: boolean,
}

local Fluids = {}

local WATER_FLOW, WATER_STILL, LAVA_FLOW, LAVA_STILL = 8, 9, 10, 11
local OBSIDIAN, COBBLE, STONE = 49, 4, 1

local RATE: { [string]: number } = { water = 5, lava = 30 }
local DROP: { [string]: number } = { water = 1, lava = 2 }
local SEARCH: { [string]: number } = { water = 4, lava = 2 }

local HX = { 1, -1, 0, 0 }
local HZ = { 0, 0, 1, -1 }
local OPPOSITE = { 2, 1, 4, 3 }

-- position key: exact integer for x,z in [-2^21, 2^21), y in [0, 256)
local function pkey(x: number, y: number, z: number): number
	return ((x + 2097152) * 4194304 + (z + 2097152)) * 256 + y
end
local function unpackKey(k: number): (number, number, number)
	local y = k % 256
	local rest = (k - y) / 256
	local z = rest % 4194304
	local x = (rest - z) / 4194304
	return x - 2097152, y, z - 2097152
end
Fluids.key = pkey

local function kindOf(id: number): string?
	if id == WATER_FLOW or id == WATER_STILL then
		return "water"
	elseif id == LAVA_FLOW or id == LAVA_STILL then
		return "lava"
	end
	return nil
end
Fluids.kindOf = kindOf

local function flowId(kind: string): number
	return if kind == "water" then WATER_FLOW else LAVA_FLOW
end
local function stillId(kind: string): number
	return if kind == "water" then WATER_STILL else LAVA_STILL
end

-- Effective level: 0 for sources and falling fluid, else 1..7.
local function level(state: number): number
	local id, meta = state // 16, state % 16
	if id == WATER_STILL or id == LAVA_STILL then
		return 0
	end
	if meta >= 8 then
		return 0
	end
	return meta
end
local function isSource(state: number): boolean
	local id = state // 16
	return (id == WATER_STILL or id == LAVA_STILL) and state % 16 == 0
end

function Fluids.new(world: World.World, budget: number?): Fluids
	local f: Fluids = { world = world, queue = {}, buckets = {}, count = 0, tick = 0, budget = budget or 1024, stats = { updates = 0, scheduled = 0 }, suppress = false }
	World.addListener(world, function(x, y, z, old, new)
		if f.suppress then
			return
		end
		Fluids.notify(f, x, y, z, old, new)
	end)
	return f
end

function Fluids.schedule(f: Fluids, x: number, y: number, z: number, delay: number)
	if y < 0 or y > 255 then
		return
	end
	local k = pkey(x, y, z)
	local due = f.tick + delay
	local cur = f.queue[k]
	if cur ~= nil and cur <= due then
		return
	end
	if cur == nil then
		f.count += 1
		f.stats.scheduled += 1
	end
	f.queue[k] = due
	local b = f.buckets[due]
	if b == nil then
		b = {}
		f.buckets[due] = b
	end
	table.insert(b :: { number }, k)
end

-- Called for every block change: wakes the changed cell and its neighbours.
function Fluids.notify(f: Fluids, x: number, y: number, z: number, _old: number, new: number)
	local w = f.world
	local function wake(ax: number, ay: number, az: number)
		local k = kindOf(World.getId(w, ax, ay, az))
		if k then
			Fluids.schedule(f, ax, ay, az, RATE[k])
		end
	end
	local nk = kindOf(new // 16)
	if nk then
		Fluids.schedule(f, x, y, z, RATE[nk])
	end
	wake(x, y + 1, z)
	wake(x, y - 1, z)
	for i = 1, 4 do
		wake(x + HX[i], y, z + HZ[i])
	end
end

local function set(f: Fluids, x: number, y: number, z: number, state: number)
	World.setState(f.world, x, y, z, state)
end

-- Can fluid of `kind` move into this state (air, replaceable non-fluid
-- blocks, or the same fluid at a weaker level)?
local function canFlowInto(kind: string, state: number, newLevel: number): boolean
	local id = state // 16
	if id == 0 then
		return true
	end
	local k = kindOf(id)
	if k then
		if k ~= kind then
			return true -- handled as a reaction
		end
		if isSource(state) then
			return false
		end
		local meta = state % 16
		if meta >= 8 then
			return false
		end
		return meta > newLevel
	end
	return BlockRegistry.isReplaceable(id) and not BlockRegistry.isSolid(id)
end

local function blocksFlow(state: number): boolean
	local id = state // 16
	if id == 0 or kindOf(id) then
		return false
	end
	return not (BlockRegistry.isReplaceable(id) and not BlockRegistry.isSolid(id))
end

-- Writes fluid into (x,y,z), applying reactions with the other fluid.
local function flowInto(f: Fluids, kind: string, x: number, y: number, z: number, state: number, falling: boolean)
	local w = f.world
	local cur = World.getState(w, x, y, z)
	local ck = kindOf(cur // 16)
	if ck and ck ~= kind then
		if kind == "water" then
			set(f, x, y, z, (if isSource(cur) then OBSIDIAN else COBBLE) * 16)
		else
			set(f, x, y, z, (if falling then STONE else COBBLE) * 16)
		end
		return
	end
	set(f, x, y, z, state)
end

-- Cost (steps) to the nearest drop from (x,y,z) moving horizontally, up to `limit`.
local function dropDistance(f: Fluids, kind: string, x: number, y: number, z: number, fromDir: number, depth: number, limit: number): number
	local w = f.world
	local best = 1000
	for i = 1, 4 do
		if fromDir ~= 0 and i == OPPOSITE[fromDir] then
			continue
		end
		local nx, nz = x + HX[i], z + HZ[i]
		local st = World.getState(w, nx, y, nz)
		if blocksFlow(st) or isSource(st) and kindOf(st // 16) == kind then
			continue
		end
		if not blocksFlow(World.getState(w, nx, y - 1, nz)) then
			return depth
		end
		if depth < limit then
			local d = dropDistance(f, kind, nx, y, nz, i, depth + 1, limit)
			if d < best then
				best = d
			end
		end
	end
	return best
end

local function update(f: Fluids, x: number, y: number, z: number)
	local w = f.world
	if not World.isLoaded(w, x, z) then
		return
	end
	local state = World.getState(w, x, y, z)
	local kind = kindOf(state // 16)
	if kind == nil then
		return
	end
	f.stats.updates += 1
	local drop = DROP[kind]
	local rate = RATE[kind]
	-- lava touching water hardens
	if kind == "lava" then
		local touching = kindOf(World.getId(w, x, y + 1, z)) == "water"
		for i = 1, 4 do
			if kindOf(World.getId(w, x + HX[i], y, z + HZ[i])) == "water" then
				touching = true
			end
		end
		if touching then
			set(f, x, y, z, (if isSource(state) then OBSIDIAN else COBBLE) * 16)
			return
		end
	end
	-- recompute level of non-source blocks from their feeders
	if not isSource(state) then
		local above = World.getState(w, x, y + 1, z)
		local newState: number
		if kindOf(above // 16) == kind then
			newState = flowId(kind) * 16 + 8
		else
			local minLevel = 100
			local sources = 0
			for i = 1, 4 do
				local ns = World.getState(w, x + HX[i], y, z + HZ[i])
				if kindOf(ns // 16) == kind then
					local l = level(ns)
					if l < minLevel then
						minLevel = l
					end
					if isSource(ns) then
						sources += 1
					end
				end
			end
			local below = World.getState(w, x, y - 1, z)
			if kind == "water" and sources >= 2 and (blocksFlow(below) or isSource(below)) then
				newState = stillId(kind) * 16
			elseif minLevel + drop > 7 then
				newState = 0
			else
				newState = flowId(kind) * 16 + minLevel + drop
			end
		end
		if newState ~= state then
			set(f, x, y, z, newState)
			if newState == 0 then
				return
			end
			state = newState
			Fluids.schedule(f, x, y, z, rate)
		end
	end
	-- spread
	local below = World.getState(w, x, y - 1, z)
	if y > 0 and canFlowInto(kind, below, 0) and not (kindOf(below // 16) == kind and below % 16 >= 8) then
		flowInto(f, kind, x, y - 1, z, flowId(kind) * 16 + 8, true)
		return
	end
	if y > 0 and kindOf(below // 16) == kind and not isSource(below) and below % 16 >= 8 then
		return -- already falling below
	end
	local myLevel = level(state)
	local newLevel = myLevel + drop
	if newLevel > 7 then
		return
	end
	if not (isSource(state) or blocksFlow(below) or isSource(below)) then
		return
	end
	-- choose directions with the shortest path to a drop
	local costs = table.create(4, 1000)
	local best = 1000
	for i = 1, 4 do
		local nx, nz = x + HX[i], z + HZ[i]
		local st = World.getState(w, nx, y, nz)
		if canFlowInto(kind, st, newLevel) then
			local c
			if not blocksFlow(World.getState(w, nx, y - 1, nz)) then
				c = 0
			else
				c = dropDistance(f, kind, nx, y, nz, i, 1, SEARCH[kind])
			end
			costs[i] = c
			if c < best then
				best = c
			end
		else
			costs[i] = -1
		end
	end
	for i = 1, 4 do
		if costs[i] >= 0 and costs[i] == best then
			flowInto(f, kind, x + HX[i], y, z + HZ[i], flowId(kind) * 16 + newLevel, false)
		end
	end
end

-- Advances one tick and processes due updates (bounded by budget).
function Fluids.step(f: Fluids): number
	f.tick += 1
	local bucket = f.buckets[f.tick]
	if bucket == nil then
		return 0
	end
	f.buckets[f.tick] = nil
	local due: { number } = {}
	for _, k in bucket do
		if f.queue[k] == f.tick then
			table.insert(due, k)
		end
	end
	table.sort(due)
	local n = math.min(#due, f.budget)
	-- over budget: postpone the rest by one tick (keeps order deterministic)
	for i = n + 1, #due do
		local k = due[i]
		f.queue[k] = nil
		f.count -= 1
		local x, y, z = unpackKey(k)
		Fluids.schedule(f, x, y, z, 1)
	end
	for i = 1, n do
		local k = due[i]
		f.queue[k] = nil
		f.count -= 1
	end
	for i = 1, n do
		local x, y, z = unpackKey(due[i])
		update(f, x, y, z)
	end
	return n
end

function Fluids.pending(f: Fluids): number
	return f.count
end

return Fluids
