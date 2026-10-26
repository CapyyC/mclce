--!strict
--!native
-- Stage 2 ("decoration"): ores, trees and plants.
--
-- Order independence: features belonging to source chunk N are a pure
-- function of (seed, N, N's base terrain). To decorate target chunk C we
-- evaluate the features of every N in C's 3x3 neighbourhood in a fixed order
-- and keep only the writes that land inside C. Feature placement decisions
-- read base terrain only; each write is a per-cell rule ("replace air", "replace
-- stone"), so C's result never depends on which neighbours were generated first.
--
-- Ore counts/sizes/heights follow the public classic (pre-1.13) defaults; tree
-- shapes are simplified approximations.

local Chunk = require("../Voxel/Chunk")
local World = require("../Voxel/World")
local Biomes = require("./Biomes")
local Hash = require("../Util/Hash")
local JavaRandom = require("../Util/JavaRandom")
local TerrainGenerator = require("./TerrainGenerator")
local Dungeons = require("./Dungeons")

export type BaseChunk = TerrainGenerator.BaseChunk
export type GetBase = (cx: number, cz: number) -> BaseChunk

local Decorator = {}

local AIR, STONE, DIRT, GRASS, SAND, WATER = 0, 16, 48, 32, 192, 144
local LOG, LEAVES, LOG2, LEAVES2 = 17 * 16, 18 * 16, 162 * 16, 161 * 16
local TALLGRASS, DEADBUSH, YELLOW, RED, CACTUS, REEDS = 31 * 16 + 1, 32 * 16, 37 * 16, 38 * 16, 81 * 16, 83 * 16
local SNOW_LAYER = 78 * 16
local GRAVEL = 13 * 16

-- { state, veinsPerChunk, size, minY, maxY }
local ORES: { { number } } = {
	{ DIRT, 10, 33, 0, 256 },
	{ GRAVEL, 8, 33, 0, 256 },
	{ 16 * 16, 20, 17, 0, 128 }, -- coal
	{ 15 * 16, 20, 9, 0, 64 }, -- iron
	{ 14 * 16, 2, 9, 0, 32 }, -- gold
	{ 73 * 16, 8, 8, 0, 16 }, -- redstone
	{ 56 * 16, 1, 8, 0, 16 }, -- diamond
}
local LAPIS = 21 * 16

-- A write sink: either restricted to one target chunk (generation) or the
-- whole World (sapling growth at runtime).
type Sink = { chunk: Chunk.Chunk, bx: number, bz: number, world: World.World? }

local function allowed(cur: number, rule: string): boolean
	if rule == "stone" then
		return cur == STONE
	elseif rule == "air" or rule == "leaves" then
		return cur == AIR or cur == SNOW_LAYER or cur == TALLGRASS
	elseif rule == "log" then
		return cur == AIR or cur // 16 == 18 or cur // 16 == 161 or cur == SNOW_LAYER or cur == TALLGRASS or cur // 16 == 6
	end
	return true
end

local function put(sink: Sink, x: number, y: number, z: number, st: number, rule: string)
	if y < 1 or y > 255 then
		return
	end
	local w = sink.world
	if w then
		if allowed(World.getState(w, x, y, z), rule) then
			World.setState(w, x, y, z, st)
		end
		return
	end
	local lx, lz = x - sink.bx, z - sink.bz
	if lx < 0 or lx > 15 or lz < 0 or lz > 15 then
		return
	end
	if allowed(Chunk.getState(sink.chunk, lx, y, lz), rule) then
		Chunk.setState(sink.chunk, lx, y, lz, st, false)
	end
end

local function vein(sink: Sink, rng: JavaRandom.JavaRandom, st: number, size: number, x: number, y: number, z: number)
	local angle = rng:nextFloat() * math.pi
	local x0 = x + 8 + math.sin(angle) * size / 8
	local x1 = x + 8 - math.sin(angle) * size / 8
	local z0 = z + 8 + math.cos(angle) * size / 8
	local z1 = z + 8 - math.cos(angle) * size / 8
	local y0 = y + rng:nextInt(3) - 2
	local y1 = y + rng:nextInt(3) - 2
	for i = 0, size do
		local t = i / size
		local cx = x0 + (x1 - x0) * t
		local cy = y0 + (y1 - y0) * t
		local cz = z0 + (z1 - z0) * t
		local r = (math.sin(t * math.pi) + 1) * (rng:nextDouble() * size / 16) / 2 + 0.5
		-- clip the sphere's bounding box to the sink chunk before iterating
		local xa, xb = math.max(math.floor(cx - r), sink.bx), math.min(math.floor(cx + r), sink.bx + 15)
		local za, zb = math.max(math.floor(cz - r), sink.bz), math.min(math.floor(cz + r), sink.bz + 15)
		if xa > xb or za > zb then
			continue
		end
		local ya, yb = math.max(math.floor(cy - r), 1), math.min(math.floor(cy + r), 255)
		local chunk = sink.chunk
		for by = ya, yb do
			local dy = (by + 0.5 - cy) / r
			local sec = chunk.sections[by // 16]
			if sec == nil then
				continue
			end
			local states = sec.states
			local yoff = (by % 16) * 256
			for bz = za, zb do
				local dz = (bz + 0.5 - cz) / r
				local rem = 1 - dy * dy - dz * dz
				if rem <= 0 then
					continue
				end
				for bx = xa, xb do
					local dx = (bx + 0.5 - cx) / r
					if dx * dx < rem then
						local off = ((bx - sink.bx) + (bz - sink.bz) * 16 + yoff) * 2
						if buffer.readu16(states, off) == STONE then
							-- same block count (stone -> ore), so section bookkeeping is unchanged
							buffer.writeu16(states, off, st)
						end
					end
				end
			end
		end
	end
end

local function blobLeaves(sink: Sink, rng: JavaRandom.JavaRandom, leaves: number, x: number, topY: number, z: number)
	for y = topY - 3, topY do
		local rel = y - topY
		local radius = 1 - rel // 2
		for dx = -radius, radius do
			for dz = -radius, radius do
				local corner = math.abs(dx) == radius and math.abs(dz) == radius
				-- corners: always skip on the top layer, random elsewhere
				if corner and (rel == 0 or rng:nextInt(2) == 0) then
					continue
				end
				put(sink, x + dx, y, z + dz, leaves, "leaves")
			end
		end
	end
end

local function oak(sink: Sink, rng: JavaRandom.JavaRandom, x: number, y: number, z: number, log: number, leaves: number, minH: number)
	local h = minH + rng:nextInt(3)
	blobLeaves(sink, rng, leaves, x, y + h, z)
	for i = 0, h - 1 do
		put(sink, x, y + i, z, log, "log")
	end
end

local function spruce(sink: Sink, rng: JavaRandom.JavaRandom, x: number, y: number, z: number)
	local h = 6 + rng:nextInt(4)
	local leafStart = 1 + rng:nextInt(2)
	local radius, maxR = 0, 2 + rng:nextInt(2)
	for i = h, leafStart, -1 do
		for dx = -radius, radius do
			for dz = -radius, radius do
				if radius > 0 and math.abs(dx) == radius and math.abs(dz) == radius then
					continue
				end
				put(sink, x + dx, y + i, z + dz, LEAVES + 1, "leaves")
			end
		end
		if radius >= maxR then
			radius = 1
		else
			radius += 1
		end
	end
	put(sink, x, y + h + 1, z, LEAVES + 1, "leaves")
	for i = 0, h - 1 do
		put(sink, x, y + i, z, LOG + 1, "log")
	end
end

-- Surface y (first non-air) of a column in a base chunk, plus its state.
local function surface(base: BaseChunk, lx: number, lz: number): (number, number)
	local y = Chunk.height(base.chunk, lx, lz) - 1
	while y > 0 do
		local st = Chunk.getState(base.chunk, lx, y, lz)
		if st ~= SNOW_LAYER and st ~= AIR then
			return y, st
		end
		y -= 1
	end
	return 0, 0
end

local function featureRng(seed: { hi: number, lo: number }, cx: number, cz: number, salt: number): JavaRandom.JavaRandom
	return JavaRandom.new(Hash.hash(seed.hi, seed.lo, cx, cz, salt) * 65536 + Hash.hash(cx, cz, salt) % 65536)
end

-- Features owned by source chunk (sx, sz), written into `sink`.
local function sourceFeatures(seed: { hi: number, lo: number }, src: BaseChunk, sx: number, sz: number, sink: Sink, isSelf: boolean)
	local bx, bz = sx * 16, sz * 16
	-- ores. Each vein has its own RNG stream so veins that cannot reach the
	-- target chunk are skipped without perturbing any other feature.
	local rng = featureRng(seed, sx, sz, 1)
	for oi, ore in ORES do
		local size = ore[3]
		local reach = size / 8 + size / 16 + 2
		for vi = 1, ore[2] do
			local x = bx + rng:nextInt(16)
			local y = rng:nextInt(ore[5] - ore[4]) + ore[4]
			local z = bz + rng:nextInt(16)
			if x + reach < sink.bx or x - reach > sink.bx + 15 or z + reach < sink.bz or z - reach > sink.bz + 15 then
				continue
			end
			vein(sink, featureRng(seed, sx * 64 + oi, sz * 64 + vi, 11), ore[1], size, x - 8, y, z - 8)
		end
	end
	-- lapis: centred distribution around y=16
	local ly = rng:nextInt(16) + rng:nextInt(16)
	local lx0, lz0 = bx + rng:nextInt(16), bz + rng:nextInt(16)
	vein(sink, featureRng(seed, sx, sz, 12), LAPIS, 7, lx0 - 8, ly, lz0 - 8)

	-- trees
	local trng = featureRng(seed, sx, sz, 2)
	local centre = Biomes.get(buffer.readu8(src.biomeIds, 8 + 8 * 16))
	local attempts = centre.trees
	if trng:nextInt(10) == 0 then
		attempts += 1
	end
	for _ = 1, attempts do
		local lx, lz = trng:nextInt(16), trng:nextInt(16)
		local biome = Biomes.get(buffer.readu8(src.biomeIds, lx + lz * 16))
		local y, st = surface(src, lx, lz)
		if (st ~= GRASS and st ~= DIRT) or y < 62 or y > 240 or biome.treeKind == "none" then
			continue
		end
		local x, z = bx + lx, bz + lz
		if x + 3 < sink.bx or x - 3 > sink.bx + 15 or z + 3 < sink.bz or z - 3 > sink.bz + 15 then
			continue
		end
		local kind = biome.treeKind
		local outer = trng
		trng = featureRng(seed, x, z, 21)
		if kind == "spruce" then
			spruce(sink, trng, x, y + 1, z)
		elseif kind == "birch" or (kind == "oak" and trng:nextInt(5) == 0 and biome.name == "forest") then
			oak(sink, trng, x, y + 1, z, LOG + 2, LEAVES + 2, 5)
		elseif kind == "jungle" then
			oak(sink, trng, x, y + 1, z, LOG + 3, LEAVES + 3, 4 + trng:nextInt(7))
		elseif kind == "acacia" then
			oak(sink, trng, x, y + 1, z, LOG2, LEAVES2, 5)
		else
			oak(sink, trng, x, y + 1, z, LOG, LEAVES, 4)
		end
		trng = outer
		if sink.chunk.cx == sx and sink.chunk.cz == sz then
			-- the block under a trunk becomes dirt
			local cur = Chunk.getState(sink.chunk, lx, y, lz)
			if cur == GRASS then
				Chunk.setState(sink.chunk, lx, y, lz, DIRT, false)
			end
		end
	end

	-- plants: single-block, confined to their own chunk
	if isSelf then
		local prng = featureRng(seed, sx, sz, 3)
		local biome = centre
		local function scatter(count: number, place: (lx: number, y: number, lz: number, ground: number) -> ())
			for _ = 1, count do
				local lx, lz = prng:nextInt(16), prng:nextInt(16)
				local y, st = surface(src, lx, lz)
				if y >= 1 and y < 254 and Chunk.getState(sink.chunk, lx, y + 1, lz) == AIR then
					place(lx, y + 1, lz, st)
				end
			end
		end
		scatter(biome.grass, function(lx, y, lz, ground)
			if ground == GRASS then
				Chunk.setState(sink.chunk, lx, y, lz, TALLGRASS, false)
			end
		end)
		scatter(biome.flowers, function(lx, y, lz, ground)
			if ground == GRASS then
				Chunk.setState(sink.chunk, lx, y, lz, if prng:nextInt(3) == 0 then RED else YELLOW, false)
			end
		end)
		if biome.name == "desert" then
			scatter(3, function(lx, y, lz, ground)
				if ground ~= SAND then
					return
				end
				-- cactus needs no horizontal neighbours
				for _, d in { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } } do
					local nx, nz = lx + d[1], lz + d[2]
					if nx >= 0 and nx <= 15 and nz >= 0 and nz <= 15 and Chunk.getState(sink.chunk, nx, y, nz) ~= AIR then
						return
					end
				end
				for i = 0, prng:nextInt(3) do
					Chunk.setState(sink.chunk, lx, y + i, lz, CACTUS, false)
				end
			end)
			scatter(2, function(lx, y, lz, ground)
				if ground == SAND then
					Chunk.setState(sink.chunk, lx, y, lz, DEADBUSH, false)
				end
			end)
		end
		-- sugar cane beside water
		scatter(10, function(lx, y, lz, ground)
			if ground ~= GRASS and ground ~= SAND and ground ~= DIRT then
				return
			end
			local wet = false
			for _, d in { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } } do
				local nx, nz = lx + d[1], lz + d[2]
				if nx >= 0 and nx <= 15 and nz >= 0 and nz <= 15 and Chunk.getState(sink.chunk, nx, y - 1, nz) == WATER then
					wet = true
				end
			end
			if wet then
				for i = 0, 1 + prng:nextInt(2) do
					Chunk.setState(sink.chunk, lx, y + i, lz, REEDS, false)
				end
			end
		end)
	end
end

-- Grows a tree into a live World (sapling growth). kind: "oak" | "birch" |
-- "spruce" | "jungle" | "acacia". Trunk replaces the sapling.
function Decorator.growTree(world: World.World, kind: string, rng: JavaRandom.JavaRandom, x: number, y: number, z: number)
	local sink: Sink = { chunk = nil :: any, bx = 0, bz = 0, world = world }
	if kind == "spruce" then
		spruce(sink, rng, x, y, z)
	elseif kind == "birch" then
		oak(sink, rng, x, y, z, LOG + 2, LEAVES + 2, 5)
	elseif kind == "jungle" then
		oak(sink, rng, x, y, z, LOG + 3, LEAVES + 3, 4 + rng:nextInt(7))
	elseif kind == "acacia" then
		oak(sink, rng, x, y, z, LOG2, LEAVES2, 5)
	else
		oak(sink, rng, x, y, z, LOG, LEAVES, 4)
	end
end

-- Decorates `target` (a copy of its base terrain) using the 3x3 neighbourhood.
function Decorator.decorate(seed: { hi: number, lo: number }, target: Chunk.Chunk, getBase: GetBase)
	local sink: Sink = { chunk = target, bx = target.cx * 16, bz = target.cz * 16 }
	-- dungeons first (underground), then ores/trees/plants per source chunk.
	-- Room validity needs base terrain up to 1 chunk around the source, so
	-- rooms are evaluated with the caching getBase.
	for dz = -1, 1 do
		for dx = -1, 1 do
			for _, room in Dungeons.rooms(seed, target.cx + dx, target.cz + dz, getBase) do
				Dungeons.apply(room, target, getBase)
			end
		end
	end
	for dz = -1, 1 do
		for dx = -1, 1 do
			local sx, sz = target.cx + dx, target.cz + dz
			sourceFeatures(seed, getBase(sx, sz), sx, sz, sink, dx == 0 and dz == 0)
		end
	end
	target.dirty = false
end

return Decorator
