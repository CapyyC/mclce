--!strict
--!native
-- The Nether: a 128-high netherrack cavern world. Bedrock floor (y 0..4) and
-- ceiling (y 123..127) with ragged edges, a lava sea filling open space at
-- y <= 31, soul sand / gravel patches near the sea, glowstone clusters
-- hanging from the ceiling and quartz ore veins.
-- Shape is an APPROXIMATION (3D density with vertical falloff toward the
-- floor and ceiling, like the classic Nether's lattice approach).

local Chunk = require("../Voxel/Chunk")
local Hash = require("../Util/Hash")
local JavaRandom = require("../Util/JavaRandom")
local PerlinNoise = require("../Util/PerlinNoise")
local WorldSeed = require("./WorldSeed")

local Octaves = PerlinNoise.Octaves

export type NetherGen = { seed: WorldSeed.WorldSeed, density: PerlinNoise.Octaves, patches: PerlinNoise.Octaves }

local NetherGenerator = {}

NetherGenerator.HEIGHT = 128
NetherGenerator.LAVA_LEVEL = 31

local NETHERRACK, LAVA, BEDROCK, SOUL_SAND, GRAVEL, GLOWSTONE, QUARTZ = 87 * 16, 11 * 16, 7 * 16, 88 * 16, 13 * 16, 89 * 16, 153 * 16

function NetherGenerator.new(seed: WorldSeed.WorldSeed): NetherGen
	local rng = JavaRandom.new(Hash.hash(seed.hi, seed.lo, 0x4E7) * 65536 + 7)
	return { seed = seed, density = Octaves.new(rng, 4), patches = Octaves.new(rng, 2) }
end

local GRID_Y = 17 -- y = 0, 8, ..., 128

function NetherGenerator.generate(gen: NetherGen, cx: number, cz: number): Chunk.Chunk
	local chunk = Chunk.new(cx, cz)
	local bx, bz = cx * 16, cz * 16
	local dens: { number } = table.create(5 * GRID_Y * 5, 0)
	for sz = 0, 4 do
		for sx = 0, 4 do
			local wx, wz = bx + sx * 4, bz + sz * 4
			for sy = 0, GRID_Y - 1 do
				local y = sy * 8
				local n = Octaves.fbm(gen.density, wx / 60, y / 40, wz / 60)
				-- solid near floor/ceiling, open caverns in between
				local edge = math.min(y, 128 - y)
				local falloff = if edge < 24 then (24 - edge) / 24 * 1.5 else 0
				dens[sx + sz * 5 + sy * 25 + 1] = n + 0.12 + falloff
			end
		end
	end
	for sy = 0, GRID_Y - 2 do
		for sz = 0, 3 do
			for sx = 0, 3 do
				local i = sx + sz * 5 + sy * 25 + 1
				local d000, d100, d010, d110 = dens[i], dens[i + 1], dens[i + 5], dens[i + 6]
				local d001, d101, d011, d111 = dens[i + 25], dens[i + 26], dens[i + 30], dens[i + 31]
				for ly = 0, 7 do
					local y = sy * 8 + ly
					local ty = ly / 8
					local a00 = d000 + (d001 - d000) * ty
					local a10 = d100 + (d101 - d100) * ty
					local a01 = d010 + (d011 - d010) * ty
					local a11 = d110 + (d111 - d110) * ty
					for lz = 0, 3 do
						local tz = lz / 4
						local b0 = a00 + (a01 - a00) * tz
						local b1 = a10 + (a11 - a10) * tz
						for lx = 0, 3 do
							local d = b0 + (b1 - b0) * (lx / 4)
							local st = 0
							if d > 0 then
								st = NETHERRACK
							elseif y <= NetherGenerator.LAVA_LEVEL then
								st = LAVA
							end
							if st ~= 0 then
								Chunk.setState(chunk, sx * 4 + lx, y, sz * 4 + lz, st, false)
							end
						end
					end
				end
			end
		end
	end
	-- bedrock shell, sand/gravel patches by the lava sea
	for z = 0, 15 do
		for x = 0, 15 do
			local wx, wz = bx + x, bz + z
			local h = Hash.hash(gen.seed.lo, wx, wz, 0x4E7)
			Chunk.setState(chunk, x, 0, z, BEDROCK, false)
			Chunk.setState(chunk, x, 127, z, BEDROCK, false)
			for k = 1, 4 do
				if k <= bit32.extract(h, (k - 1) * 4, 4) % 5 then
					Chunk.setState(chunk, x, k, z, BEDROCK, false)
				end
				if k <= bit32.extract(h, 16 + (k - 1) * 4, 4) % 5 then
					Chunk.setState(chunk, x, 127 - k, z, BEDROCK, false)
				end
			end
			local p = Octaves.fbm(gen.patches, wx / 24, 0, wz / 24)
			if math.abs(p) > 0.25 then
				local cover = if p > 0 then SOUL_SAND else GRAVEL
				for y = NetherGenerator.LAVA_LEVEL - 2, NetherGenerator.LAVA_LEVEL + 3 do
					if Chunk.getState(chunk, x, y, z) == NETHERRACK and Chunk.getState(chunk, x, y + 1, z) // 16 ~= 87 then
						Chunk.setState(chunk, x, y, z, cover, false)
					end
				end
			end
		end
	end
	-- glowstone clusters under the ceiling and quartz veins (inside this chunk)
	local rng = JavaRandom.new(Hash.hash(gen.seed.hi, cx, cz, 0x6105) * 64 + 3)
	for _ = 1, rng:nextInt(rng:nextInt(10) + 1) + 1 do
		local x, z = rng:nextInt(16), rng:nextInt(16)
		local y = 120 - rng:nextInt(30)
		if Chunk.getState(chunk, x, y, z) == 0 and Chunk.getState(chunk, x, y + 1, z) == NETHERRACK then
			for _ = 1, 40 do
				local gx, gy, gz = x + rng:nextInt(5) - 2, y - rng:nextInt(4), z + rng:nextInt(5) - 2
				if gx >= 0 and gx <= 15 and gz >= 0 and gz <= 15 and Chunk.getState(chunk, gx, gy, gz) == 0 then
					Chunk.setState(chunk, gx, gy, gz, GLOWSTONE, false)
				end
			end
		end
	end
	for _ = 1, 16 do
		local x, y, z = rng:nextInt(16), rng:nextInt(108) + 10, rng:nextInt(16)
		for _ = 1, 6 do
			if Chunk.getState(chunk, x, y, z) == NETHERRACK then
				Chunk.setState(chunk, x, y, z, QUARTZ, false)
			end
			x = math.clamp(x + rng:nextInt(3) - 1, 0, 15)
			y = math.clamp(y + rng:nextInt(3) - 1, 1, 126)
			z = math.clamp(z + rng:nextInt(3) - 1, 0, 15)
		end
	end
	chunk.generated = true
	chunk.dirty = false
	return chunk
end

return NetherGenerator
