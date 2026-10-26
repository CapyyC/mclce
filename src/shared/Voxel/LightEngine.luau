--!strict
--!native
-- Sky light and block light (0..15 each) with incremental updates.
--
-- Rules (classic): sky light enters at the top at 15 and travels straight
-- down without loss through blocks of opacity 0; every other step (any
-- direction) costs max(1, opacity of the block entered). Block light starts
-- at each emitter's emission and spreads the same way. Fully opaque blocks
-- (opacity 15) hold no light of their own except their emission.
--
-- Storage: one 64 KB buffer per loaded chunk, byte = sky << 4 | block, index
-- x + z*16 + y*256. Light only propagates between loaded chunks; when a chunk
-- loads, its borders with loaded neighbours are re-stitched.

local World = require("./World")
local Coords = require("./Coords")
local BlockRegistry = require("../Blocks/BlockRegistry")

export type LightEngine = {
	world: World.World,
	data: { [number]: buffer },
	-- BFS work queues (flat x, y, z triples), reused between calls
	addQ: { number },
	remQ: { number },
	remLevel: { number },
	stats: { visits: number },
	-- one-entry chunk cache for the hot get/set paths
	lcx: number,
	lcz: number,
	lbuf: buffer?,
}

local LightEngine = {}

local opacityArr = BlockRegistry._opacity
local emissionArr: { number } = table.create(4096, 0)
for id = 0, 4095 do
	emissionArr[id + 1] = BlockRegistry.emission(id)
end

local DX = { 1, -1, 0, 0, 0, 0 }
local DY = { 0, 0, 1, -1, 0, 0 }
local DZ = { 0, 0, 0, 0, 1, -1 }

function LightEngine.new(world: World.World): LightEngine
	return { world = world, data = {}, addQ = {}, remQ = {}, remLevel = {}, stats = { visits = 0 }, lcx = math.huge, lcz = math.huge, lbuf = nil }
end

local function opacityAt(le: LightEngine, x: number, y: number, z: number): number
	local id = World.getId(le.world, x, y, z)
	return opacityArr[id + 1] or 0
end

-- channel 1 = sky (high nibble), 0 = block (low nibble)
local function getL(le: LightEngine, x: number, y: number, z: number, sky: boolean): number
	if y > 255 then
		return if sky then 15 else 0
	end
	if y < 0 then
		return 0
	end
	local cx, cz = x // 16, z // 16
	local b
	if cx == le.lcx and cz == le.lcz then
		b = le.lbuf
	else
		b = le.data[Coords.chunkKey(cx, cz)]
		le.lcx, le.lcz, le.lbuf = cx, cz, b
	end
	if b == nil then
		return -1 -- unloaded
	end
	local v = buffer.readu8(b, (x % 16) + (z % 16) * 16 + y * 256)
	return if sky then v // 16 else v % 16
end

local function setL(le: LightEngine, x: number, y: number, z: number, sky: boolean, level: number)
	local cx, cz = x // 16, z // 16
	local b
	if cx == le.lcx and cz == le.lcz then
		b = le.lbuf
	else
		b = le.data[Coords.chunkKey(cx, cz)]
		le.lcx, le.lcz, le.lbuf = cx, cz, b
	end
	if b == nil or y < 0 or y > 255 then
		return
	end
	local i = (x % 16) + (z % 16) * 16 + y * 256
	local v = buffer.readu8(b, i)
	if sky then
		buffer.writeu8(b, i, level * 16 + v % 16)
	else
		buffer.writeu8(b, i, (v // 16) * 16 + level)
	end
end

function LightEngine.sky(le: LightEngine, x: number, y: number, z: number): number
	local l = getL(le, x, y, z, true)
	return if l < 0 then 15 else l
end

function LightEngine.block(le: LightEngine, x: number, y: number, z: number): number
	local l = getL(le, x, y, z, false)
	return if l < 0 then 0 else l
end

-- Effective light with the sky dimmed by `skyDarken` (0 at noon, 11 at night).
function LightEngine.light(le: LightEngine, x: number, y: number, z: number, skyDarken: number): number
	return math.max(LightEngine.block(le, x, y, z), LightEngine.sky(le, x, y, z) - skyDarken)
end

local function push(q: { number }, x: number, y: number, z: number)
	local n = #q
	q[n + 1], q[n + 2], q[n + 3] = x, y, z
end

-- Spreads light from every queued cell (its current level) to neighbours.
local function propagate(le: LightEngine, sky: boolean)
	local q = le.addQ
	local head = 1
	while head <= #q do
		local x, y, z = q[head], q[head + 1], q[head + 2]
		head += 3
		local L = getL(le, x, y, z, sky)
		if L <= 0 then
			continue
		end
		for d = 1, 6 do
			local nx, ny, nz = x + DX[d], y + DY[d], z + DZ[d]
			if ny < 0 or ny > 255 then
				continue
			end
			local cur = getL(le, nx, ny, nz, sky)
			if cur < 0 then
				continue
			end
			local op = opacityAt(le, nx, ny, nz)
			local nl
			if sky and d == 4 and L == 15 and op == 0 then
				nl = 15
			else
				nl = L - math.max(1, op)
			end
			if nl > cur then
				setL(le, nx, ny, nz, sky, nl)
				push(q, nx, ny, nz)
				le.stats.visits += 1
			end
		end
	end
	table.clear(q)
end

-- Removes light that depended on the cells queued in remQ (with their old
-- levels), then re-propagates from the remaining brighter frontier.
local function unpropagate(le: LightEngine, sky: boolean)
	local q, lv = le.remQ, le.remLevel
	local head, li = 1, 1
	while head <= #q do
		local x, y, z = q[head], q[head + 1], q[head + 2]
		local old = lv[li]
		head += 3
		li += 1
		for d = 1, 6 do
			local nx, ny, nz = x + DX[d], y + DY[d], z + DZ[d]
			if ny < 0 or ny > 255 then
				continue
			end
			local l = getL(le, nx, ny, nz, sky)
			if l <= 0 then
				continue
			end
			local dependent = l < old or (sky and d == 4 and old == 15 and l == 15)
			if dependent then
				-- keep emitters' own light
				local emit = if sky then 0 else emissionArr[World.getId(le.world, nx, ny, nz) + 1]
				setL(le, nx, ny, nz, sky, emit)
				push(q, nx, ny, nz)
				lv[#lv + 1] = l
				if emit > 0 then
					push(le.addQ, nx, ny, nz)
				end
				le.stats.visits += 1
			else
				push(le.addQ, nx, ny, nz)
			end
		end
	end
	table.clear(q)
	table.clear(lv)
	propagate(le, sky)
end

-- Computes light for a freshly loaded chunk and stitches it to loaded
-- neighbours. Call after World.putChunk.
function LightEngine.addChunk(le: LightEngine, cx: number, cz: number)
	local chunk = World.getChunk(le.world, cx, cz)
	if chunk == nil then
		return
	end
	local b = buffer.create(65536)
	le.data[Coords.chunkKey(cx, cz)] = b
	le.lcx, le.lcz, le.lbuf = math.huge, math.huge, nil
	local bx, bz = cx * 16, cz * 16
	local world = le.world
	local q = le.addQ
	local lowest = table.create(256, 0)
	-- 1. direct sky light down each column
	for z = 0, 15 do
		for x = 0, 15 do
			local level = 15
			local y
			local top = World.height(world, bx + x, bz + z)
			-- everything above the column's top block is open sky
			for yy = 255, top, -1 do
				buffer.writeu8(b, x + z * 16 + yy * 256, 240)
			end
			y = top - 1
			while y >= 0 do
				local op = opacityArr[World.getId(world, bx + x, y, bz + z) + 1] or 0
				-- lossless only while still at full strength
				if op > 0 or level < 15 then
					level -= math.max(1, op)
					if level <= 0 then
						break
					end
				end
				buffer.writeu8(b, x + z * 16 + y * 256, level * 16)
				y -= 1
			end
			lowest[x + z * 16 + 1] = y + 1
		end
	end
	-- 2. queue the band where horizontal spread can matter: from the lowest
	-- directly-lit cell up to the highest neighbouring column top
	for z = 0, 15 do
		for x = 0, 15 do
			local wx, wz = bx + x, bz + z
			local maxH = World.height(world, wx, wz)
			maxH = math.max(maxH, World.height(world, wx + 1, wz), World.height(world, wx - 1, wz), World.height(world, wx, wz + 1), World.height(world, wx, wz - 1))
			for y = lowest[x + z * 16 + 1], math.min(maxH, 255) do
				push(q, wx, y, wz)
			end
		end
	end
	propagate(le, true)
	-- 3. emitters
	for si, s in chunk.sections do
		local states = s.states
		for i = 0, 4095 do
			local id = buffer.readu16(states, i * 2) // 16
			local e = emissionArr[id + 1]
			if e > 0 then
				local x, z, y = i % 16, (i // 16) % 16, si * 16 + i // 256
				local idx = x + z * 16 + y * 256
				local v = buffer.readu8(b, idx)
				buffer.writeu8(b, idx, (v // 16) * 16 + e)
				push(q, bx + x, y, bz + z)
			end
		end
	end
	propagate(le, false)
	-- 4. stitch borders with loaded neighbours, both directions. Above the
	-- highest column top on either side of a border all cells are sky 15, so
	-- sky stitching only needs the band below that.
	local hmax = 0
	for i = 0, 15 do
		hmax = math.max(hmax,
			World.height(world, bx + i, bz - 1), World.height(world, bx + i, bz + 16),
			World.height(world, bx - 1, bz + i), World.height(world, bx + 16, bz + i),
			World.height(world, bx + i, bz), World.height(world, bx + i, bz + 15),
			World.height(world, bx, bz + i), World.height(world, bx + 15, bz + i))
	end
	local cells = table.create(16, 0)
	for pass = 1, 2 do
		local sky = pass == 1
		local yTop = if sky then math.min(hmax + 1, 255) else 255
		for i = 0, 15 do
			cells[1], cells[2], cells[3], cells[4] = bx + i, bz - 1, bx + i, bz + 16
			cells[5], cells[6], cells[7], cells[8] = bx - 1, bz + i, bx + 16, bz + i
			cells[9], cells[10], cells[11], cells[12] = bx + i, bz, bx + i, bz + 15
			cells[13], cells[14], cells[15], cells[16] = bx, bz + i, bx + 15, bz + i
			for c = 1, 16, 2 do
				local cxw, czw = cells[c], cells[c + 1]
				local nb = le.data[Coords.chunkKey(cxw // 16, czw // 16)]
				if nb == nil then
					continue
				end
				local col = (cxw % 16) + (czw % 16) * 16
				for y = 0, yTop do
					local v = buffer.readu8(nb, col + y * 256)
					local l = if sky then v // 16 else v % 16
					if l > 1 then
						push(q, cxw, y, czw)
					end
				end
			end
		end
		propagate(le, sky)
	end
end

function LightEngine.removeChunk(le: LightEngine, cx: number, cz: number)
	le.data[Coords.chunkKey(cx, cz)] = nil
	le.lcx, le.lcz, le.lbuf = math.huge, math.huge, nil
end

-- Incremental update after a block at (x,y,z) changed from oldId to newId.
function LightEngine.onBlockChanged(le: LightEngine, x: number, y: number, z: number, oldId: number, newId: number)
	if le.data[Coords.chunkKey(x // 16, z // 16)] == nil then
		return
	end
	local opOld, opNew = opacityArr[oldId + 1] or 0, opacityArr[newId + 1] or 0
	local emOld, emNew = emissionArr[oldId + 1], emissionArr[newId + 1]
	if opOld == opNew and emOld == emNew then
		return
	end
	for _, sky in { true, false } do
		local cur = getL(le, x, y, z, sky)
		local target = if sky then 0 else emNew
		-- remove this cell's light (and what depended on it), then refill
		if cur > 0 then
			setL(le, x, y, z, sky, 0)
			push(le.remQ, x, y, z)
			le.remLevel[#le.remLevel + 1] = cur
		end
		if target > 0 then
			setL(le, x, y, z, sky, target)
		end
		-- neighbours may now shine into the cell
		push(le.addQ, x, y, z)
		for d = 1, 6 do
			local nx, ny, nz = x + DX[d], y + DY[d], z + DZ[d]
			if ny >= 0 and ny <= 255 and getL(le, nx, ny, nz, sky) > 0 then
				push(le.addQ, nx, ny, nz)
			end
		end
		unpropagate(le, sky)
	end
end

LightEngine._get = getL

return LightEngine
