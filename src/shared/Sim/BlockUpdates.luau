--!strict
-- Neighbour-triggered block rules and random ticks.
--
-- Neighbour updates (after any block change, for the cell and its 6
-- neighbours): unsupported plants/torches/snow pop off as items; sand and
-- gravel fall to the lowest free cell (APPROXIMATION: instant, no falling
-- entity). Random ticks (classic randomTickSpeed = 3 per 16^3 section per
-- tick): grass spread/decay, crops, sugar cane and cactus growth, saplings
-- growing into trees, leaf decay, farmland hydration, ice/snow melting.

local World = require("../Voxel/World")
local BlockRegistry = require("../Blocks/BlockRegistry")
local JavaRandom = require("../Util/JavaRandom")
local Decorator = require("../WorldGen/Decorator")

export type Hooks = {
	-- break a block and drop its items (server decides drops)
	popBlock: (x: number, y: number, z: number) -> (),
	skyLight: (x: number, y: number, z: number) -> number,
	blockLight: (x: number, y: number, z: number) -> number,
	skyDarken: () -> number,
}

export type BlockUpdates = {
	world: World.World,
	hooks: Hooks,
	rng: JavaRandom.JavaRandom,
	pending: { number }, -- flat x, y, z neighbour checks queued during a change
	busy: boolean,
	stats: { pops: number, falls: number, grows: number },
}

local BlockUpdates = {}

BlockUpdates.RANDOM_TICKS_PER_SECTION = 3

local AIR, GRASS, DIRT, SAPLING, SAND, GRAVEL, LOG, LEAVES, TORCH = 0, 2, 3, 6, 12, 13, 17, 18, 50
local WHEAT, FARMLAND, SNOW_LAYER, ICE, CACTUS, REEDS, LOG2, LEAVES2, WATER, FWATER = 59, 60, 78, 79, 81, 83, 162, 161, 9, 8
local TALLGRASS, DEADBUSH, YELLOW, RED, BROWN_MUSH, RED_MUSH, DOUBLE_PLANT = 31, 32, 37, 38, 39, 40, 175

local plantOnSoil: { [number]: boolean } = { [SAPLING] = true, [TALLGRASS] = true, [YELLOW] = true, [RED] = true, [DOUBLE_PLANT] = true }

function BlockUpdates.new(world: World.World, hooks: Hooks, seed: number): BlockUpdates
	return { world = world, hooks = hooks, rng = JavaRandom.new(seed), pending = {}, busy = false, stats = { pops = 0, falls = 0, grows = 0 } }
end

local function idAt(bu: BlockUpdates, x: number, y: number, z: number): number
	return World.getId(bu.world, x, y, z)
end

local function solidTop(id: number): boolean
	return BlockRegistry.isSolid(id) and BlockRegistry.isFullCube(id)
end

-- Is the block at (x,y,z) still supported?
local function supported(bu: BlockUpdates, x: number, y: number, z: number, state: number): boolean
	local id = state // 16
	local below = idAt(bu, x, y - 1, z)
	if plantOnSoil[id] then
		return below == GRASS or below == DIRT or below == FARMLAND
	elseif id == DEADBUSH then
		return below == SAND or below == 159 or below == 172 or below == DIRT
	elseif id == BROWN_MUSH or id == RED_MUSH then
		return solidTop(below)
	elseif id == WHEAT then
		return below == FARMLAND
	elseif id == REEDS then
		if below == REEDS then
			return true
		end
		if below ~= GRASS and below ~= DIRT and below ~= SAND then
			return false
		end
		for _, d in { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } } do
			local n = idAt(bu, x + d[1], y - 1, z + d[2])
			if n == WATER or n == FWATER then
				return true
			end
		end
		return false
	elseif id == CACTUS then
		if below ~= SAND and below ~= CACTUS then
			return false
		end
		for _, d in { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } } do
			if BlockRegistry.isSolid(idAt(bu, x + d[1], y, z + d[2])) then
				return false
			end
		end
		return true
	elseif id == SNOW_LAYER then
		return solidTop(below) or below == LEAVES or below == LEAVES2
	elseif id == 55 or id == 70 or id == 72 then -- wire, pressure plates
		return solidTop(below)
	elseif id == 64 or id == 71 then -- doors: lower on solid ground, upper on its lower half
		if state % 16 >= 8 then
			return below == id
		end
		return solidTop(below)
	elseif id == TORCH or id == 75 or id == 76 or id == 69 or id == 77 then
		-- meta 1..4 = attached to a wall (east, west, south, north side), 5/0 = floor
		local meta = state % 16
		if meta == 1 then
			return solidTop(idAt(bu, x - 1, y, z))
		elseif meta == 2 then
			return solidTop(idAt(bu, x + 1, y, z))
		elseif meta == 3 then
			return solidTop(idAt(bu, x, y, z - 1))
		elseif meta == 4 then
			return solidTop(idAt(bu, x, y, z + 1))
		end
		return solidTop(below)
	end
	return true
end
BlockUpdates.supported = supported

local function checkCell(bu: BlockUpdates, x: number, y: number, z: number)
	if y < 0 or y > 255 or not World.isLoaded(bu.world, x, z) then
		return
	end
	local st = World.getState(bu.world, x, y, z)
	local id = st // 16
	if id == AIR then
		return
	end
	if id == SAND or id == GRAVEL then
		local below = idAt(bu, x, y - 1, z)
		if y > 0 and (below == AIR or BlockRegistry.isLiquid(below) or (BlockRegistry.isReplaceable(below) and not BlockRegistry.isSolid(below))) then
			local ty = y - 1
			while ty > 0 do
				local b = idAt(bu, x, ty - 1, z)
				if not (b == AIR or BlockRegistry.isLiquid(b) or (BlockRegistry.isReplaceable(b) and not BlockRegistry.isSolid(b))) then
					break
				end
				ty -= 1
			end
			World.setState(bu.world, x, y, z, 0)
			World.setState(bu.world, x, ty, z, st)
			bu.stats.falls += 1
		end
		return
	end
	if not supported(bu, x, y, z, st) then
		bu.hooks.popBlock(x, y, z)
		bu.stats.pops += 1
	end
end

-- Called from the World listener. Re-entrant changes (pops/falls triggering
-- further changes) are queued and drained iteratively, bounded per call.
function BlockUpdates.onChange(bu: BlockUpdates, x: number, y: number, z: number)
	local q = bu.pending
	local n = #q
	q[n + 1], q[n + 2], q[n + 3] = x, y, z
	if bu.busy then
		return
	end
	bu.busy = true
	local head = 1
	local guard = 0
	while head <= #q and guard < 4096 do
		local cx, cy, cz = q[head], q[head + 1], q[head + 2]
		head += 3
		guard += 1
		checkCell(bu, cx, cy, cz)
		checkCell(bu, cx, cy + 1, cz)
		checkCell(bu, cx, cy - 1, cz)
		checkCell(bu, cx + 1, cy, cz)
		checkCell(bu, cx - 1, cy, cz)
		checkCell(bu, cx, cy, cz + 1)
		checkCell(bu, cx, cy, cz - 1)
	end
	table.clear(q)
	bu.busy = false
end

-- Random ticks -------------------------------------------------------------

local function lightAbove(bu: BlockUpdates, x: number, y: number, z: number): number
	return math.max(bu.hooks.blockLight(x, y + 1, z), bu.hooks.skyLight(x, y + 1, z) - bu.hooks.skyDarken())
end

local function hydrated(bu: BlockUpdates, x: number, y: number, z: number): boolean
	for dy = 0, 1 do
		for dz = -4, 4 do
			for dx = -4, 4 do
				local id = idAt(bu, x + dx, y + dy, z + dz)
				if id == WATER or id == FWATER then
					return true
				end
			end
		end
	end
	return false
end

local function hasLogNearby(bu: BlockUpdates, x: number, y: number, z: number): boolean
	for dy = -4, 4 do
		for dz = -4, 4 do
			for dx = -4, 4 do
				local id = idAt(bu, x + dx, y + dy, z + dz)
				if id == LOG or id == LOG2 then
					return true
				end
			end
		end
	end
	return false
end

local SAPLING_TREES = { [0] = "oak", "spruce", "birch", "jungle", "acacia", "acacia" }

function BlockUpdates.randomTick(bu: BlockUpdates, x: number, y: number, z: number)
	local w = bu.world
	local st = World.getState(w, x, y, z)
	local id, meta = st // 16, st % 16
	local rng = bu.rng
	if id == GRASS then
		local above = idAt(bu, x, y + 1, z)
		if lightAbove(bu, x, y, z) < 4 and BlockRegistry.opacity(above) > 2 then
			World.setState(w, x, y, z, DIRT * 16)
		elseif lightAbove(bu, x, y, z) >= 9 then
			for _ = 1, 4 do
				local tx, ty, tz = x + rng:nextInt(3) - 1, y + rng:nextInt(5) - 3, z + rng:nextInt(3) - 1
				if World.getState(w, tx, ty, tz) == DIRT * 16 and lightAbove(bu, tx, ty, tz) >= 4 and BlockRegistry.opacity(idAt(bu, tx, ty + 1, tz)) <= 2 then
					World.setState(w, tx, ty, tz, GRASS * 16)
				end
			end
		end
	elseif id == SAPLING then
		if lightAbove(bu, x, y, z) >= 9 and rng:nextInt(7) == 0 then
			if meta < 8 then
				World.setState(w, x, y, z, st + 8) -- stage 2
			else
				World.setState(w, x, y, z, 0)
				Decorator.growTree(w, SAPLING_TREES[meta % 8] or "oak", rng, x, y, z)
				if idAt(bu, x, y, z) == 0 then
					World.setState(w, x, y, z, st) -- no room: stays a sapling
				else
					bu.stats.grows += 1
				end
			end
		end
	elseif id == WHEAT then
		if meta < 7 and lightAbove(bu, x, y, z) >= 9 then
			local below = World.getState(w, x, y - 1, z)
			local wet = below // 16 == FARMLAND and below % 16 > 0
			if rng:nextInt(if wet then 9 else 25) == 0 then
				World.setState(w, x, y, z, st + 1)
				bu.stats.grows += 1
			end
		end
	elseif id == FARMLAND then
		if hydrated(bu, x, y, z) then
			if meta < 7 then
				World.setState(w, x, y, z, FARMLAND * 16 + 7)
			end
		elseif meta > 0 then
			World.setState(w, x, y, z, st - 1)
		elseif idAt(bu, x, y + 1, z) ~= WHEAT then
			World.setState(w, x, y, z, DIRT * 16)
		end
	elseif id == REEDS or id == CACTUS then
		-- support can be lost diagonally (water removed), so re-check here
		if not supported(bu, x, y, z, st) then
			bu.hooks.popBlock(x, y, z)
			return
		end
		if idAt(bu, x, y + 1, z) == AIR then
			local height = 1
			while idAt(bu, x, y - height, z) == id do
				height += 1
			end
			if height < 3 then
				if meta >= 15 then
					World.setState(w, x, y, z, id * 16)
					World.setState(w, x, y + 1, z, id * 16)
					bu.stats.grows += 1
				else
					World.setState(w, x, y, z, st + 1)
				end
			end
		end
	elseif id == LEAVES or id == LEAVES2 then
		-- meta bit 4 = placed by a player (never decays)
		if meta < 4 and not hasLogNearby(bu, x, y, z) then
			bu.hooks.popBlock(x, y, z)
		end
	elseif id == ICE then
		if bu.hooks.blockLight(x, y + 1, z) > 11 then
			World.setState(w, x, y, z, WATER * 16)
		end
	elseif id == SNOW_LAYER then
		if bu.hooks.blockLight(x, y, z) > 11 then
			World.setState(w, x, y, z, 0)
		end
	end
end

-- Runs random ticks over every non-empty section of the given chunks.
function BlockUpdates.tickChunks(bu: BlockUpdates, chunks: { [number]: any })
	local rng = bu.rng
	for _, c in chunks do
		local bx, bz = c.cx * 16, c.cz * 16
		for si, _ in c.sections do
			for _ = 1, BlockUpdates.RANDOM_TICKS_PER_SECTION do
				local x, y, z = rng:nextInt(16), rng:nextInt(16), rng:nextInt(16)
				BlockUpdates.randomTick(bu, bx + x, si * 16 + y, bz + z)
			end
		end
	end
end

return BlockUpdates
