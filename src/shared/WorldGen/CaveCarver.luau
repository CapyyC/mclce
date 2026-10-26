--!strict
--!native
-- Worm ("tunnel") caves. Every chunk within RADIUS of the target owns an
-- independent, seed-derived set of tunnels; the target chunk carves only the
-- parts of those tunnels that intersect it. Result is a pure function of
-- (seed, chunk), independent of generation order, and seamless across chunk
-- boundaries.
--
-- APPROXIMATION of the classic carver: same overall model (random-walk
-- tunnels with sinusoidal radius, occasional rooms and branches, lava below
-- y=11, no carving through water) with independently chosen constants.

local Chunk = require("../Voxel/Chunk")
local Hash = require("../Util/Hash")
local JavaRandom = require("../Util/JavaRandom")
local WorldSeed = require("./WorldSeed")

export type CaveCarver = { seed: WorldSeed.WorldSeed }

local CaveCarver = {}

CaveCarver.RADIUS = 5 -- chunks; tunnels never reach further than ~80 blocks
local LAVA_LEVEL = 11

local AIR, WATER, FWATER, LAVA, BEDROCK = 0, 9 * 16, 8 * 16, 11 * 16, 7 * 16
local STONE, DIRT, GRASS, SAND, GRAVEL, SANDSTONE = 16, 48, 32, 192, 208, 384
local carvable: { [number]: boolean } = {
	[STONE] = true, [DIRT] = true, [GRASS] = true, [SANDSTONE] = true,
	[GRAVEL] = true, [SAND] = true, [1296] = true, [2752] = true, -- clay, hardened clay
	[1760] = true, -- mycelium
}

function CaveCarver.new(seed: WorldSeed.WorldSeed): CaveCarver
	return { seed = seed }
end

-- Carves an ellipsoid centred at (x,y,z) with radii (rh, rv), clipped to chunk.
local function carveBlob(chunk: Chunk.Chunk, x: number, y: number, z: number, rh: number, rv: number)
	local bx, bz = chunk.cx * 16, chunk.cz * 16
	local x0, x1 = math.max(math.floor(x - rh) - bx, 0), math.min(math.floor(x + rh) - bx, 15)
	local z0, z1 = math.max(math.floor(z - rh) - bz, 0), math.min(math.floor(z + rh) - bz, 15)
	if x0 > x1 or z0 > z1 then
		return
	end
	local y0, y1 = math.max(math.floor(y - rv), 1), math.min(math.floor(y + rv), 250)
	-- refuse to breach water (classic carvers check the hull for water)
	for ly = y0 - 1, y1 + 1 do
		for lz = z0, z1 do
			for lx = x0, x1 do
				local st = Chunk.getState(chunk, lx, ly, lz)
				if st == WATER or st == FWATER then
					return
				end
			end
		end
	end
	for lz = z0, z1 do
		local dz = (lz + bz + 0.5 - z) / rh
		for lx = x0, x1 do
			local dx = (lx + bx + 0.5 - x) / rh
			if dx * dx + dz * dz >= 1 then
				continue
			end
			for ly = y1, y0, -1 do
				local dy = (ly + 0.5 - y) / rv
				if dy > -0.7 and dx * dx + dy * dy + dz * dz < 1 then
					local st = Chunk.getState(chunk, lx, ly, lz)
					if carvable[st] then
						Chunk.setState(chunk, lx, ly, lz, if ly < LAVA_LEVEL then LAVA else AIR, false)
						-- dirt exposed below carved grass becomes grass
						if st == GRASS and Chunk.getState(chunk, lx, ly - 1, lz) == DIRT then
							Chunk.setState(chunk, lx, ly - 1, lz, GRASS, false)
						end
					end
				end
			end
		end
	end
end

local function tunnel(chunk: Chunk.Chunk, rng: JavaRandom.JavaRandom, x: number, y: number, z: number, width: number, yaw: number, pitch: number, step: number, length: number, vScale: number, depth: number)
	local cxm, czm = chunk.cx * 16 + 8, chunk.cz * 16 + 8
	local yawV, pitchV = 0, 0
	local branchAt = if depth == 0 then rng:nextInt(length // 2) + length // 4 else -1
	local steep = rng:nextInt(6) == 0
	local s = step
	while s < length do
		local rh = 1.5 + math.sin(s * math.pi / length) * width
		local rv = rh * vScale
		local cp = math.cos(pitch)
		x += math.cos(yaw) * cp
		y += math.sin(pitch)
		z += math.sin(yaw) * cp
		pitch *= if steep then 0.92 else 0.7
		pitch += pitchV * 0.1
		yaw += yawV * 0.1
		pitchV = pitchV * 0.9 + (rng:nextFloat() - rng:nextFloat()) * rng:nextFloat() * 2
		yawV = yawV * 0.75 + (rng:nextFloat() - rng:nextFloat()) * rng:nextFloat() * 4
		if s == branchAt and width > 1 then
			tunnel(chunk, rng, x, y, z, rng:nextFloat() * 0.5 + 0.5, yaw - math.pi / 2, pitch / 3, s, length, 1, depth + 1)
			tunnel(chunk, rng, x, y, z, rng:nextFloat() * 0.5 + 0.5, yaw + math.pi / 2, pitch / 3, s, length, 1, depth + 1)
			return
		end
		if rng:nextInt(4) ~= 0 then
			-- quick distance cull against the target chunk
			local ddx, ddz = x - cxm, z - czm
			local remaining = length - s
			local reach = width + 2 + 16
			if ddx * ddx + ddz * ddz - remaining * remaining > reach * reach then
				return
			end
			if math.abs(x - cxm) <= 8 + rh * 2 and math.abs(z - czm) <= 8 + rh * 2 then
				carveBlob(chunk, x, y, z, rh, rv)
			end
		end
		s += 1
	end
end

function CaveCarver.carve(carver: CaveCarver, chunk: Chunk.Chunk)
	local R = CaveCarver.RADIUS
	for sz = chunk.cz - R, chunk.cz + R do
		for sx = chunk.cx - R, chunk.cx + R do
			local h = Hash.hash(carver.seed.hi, carver.seed.lo, sx, sz, 0xCA7E)
			local rng = JavaRandom.new(h * 4096 + sx % 4096)
			if rng:nextInt(7) ~= 0 then
				continue
			end
			local systems = rng:nextInt(rng:nextInt(rng:nextInt(12) + 1) + 1)
			for _ = 1, systems do
				local x = sx * 16 + rng:nextInt(16)
				local y = rng:nextInt(rng:nextInt(110) + 8)
				local z = sz * 16 + rng:nextInt(16)
				local tunnels = 1
				if rng:nextInt(4) == 0 then
					-- room: a big squashed blob plus extra tunnels
					local roomW = 1 + rng:nextFloat() * 6
					carveBlob(chunk, x, y, z, 1.5 + roomW, (1.5 + roomW) * 0.5)
					tunnels += rng:nextInt(4)
				end
				for _ = 1, tunnels do
					local yaw = rng:nextFloat() * math.pi * 2
					local pitch = (rng:nextFloat() - 0.5) * 2 / 8
					local width = rng:nextFloat() * 2 + rng:nextFloat()
					if rng:nextInt(10) == 0 then
						width *= rng:nextFloat() * rng:nextFloat() * 3 + 1
					end
					local length = 112 - rng:nextInt(28)
					tunnel(chunk, rng, x, y, z, width, yaw, pitch, 0, length, 1, 0)
				end
			end
		end
	end
	local _ = BEDROCK
end

return CaveCarver
