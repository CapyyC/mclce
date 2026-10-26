--!strict
--!native
-- Stage 1 ("base terrain"): a pure function of (seed, chunk coordinates)
-- producing stone/water/air shaped by a coarse 3D density grid, biome
-- surface layers, bedrock and worm caves.
--
-- Structure follows the classic approach (density sampled on a 4x8x4 lattice
-- and trilinearly interpolated; biome depth/scale smoothed over a 5x5
-- kernel; sea level 63) but the exact noise composition is an
-- APPROXIMATION, not the console algorithm.

local Chunk = require("../Voxel/Chunk")
local Biomes = require("./Biomes")
local BiomeSource = require("./BiomeSource")
local CaveCarver = require("./CaveCarver")
local Hash = require("../Util/Hash")
local JavaRandom = require("../Util/JavaRandom")
local PerlinNoise = require("../Util/PerlinNoise")
local WorldSeed = require("./WorldSeed")

local Octaves = PerlinNoise.Octaves

local TerrainGenerator = {}

TerrainGenerator.SEA_LEVEL = 63 -- water fills y <= 62

local STONE, WATER, AIR, BEDROCK = 1 * 16, 9 * 16, 0, 7 * 16
local SANDSTONE, SAND, ICE, SNOW_LAYER, GRAVEL, DIRT, GRASS = 24 * 16, 12 * 16, 79 * 16, 78 * 16, 13 * 16, 3 * 16, 2 * 16

export type Terrain = {
	seed: WorldSeed.WorldSeed,
	biomes: BiomeSource.BiomeSource,
	density: PerlinNoise.Octaves,
	detail: PerlinNoise.Octaves,
	beach: PerlinNoise.Octaves,
	caves: CaveCarver.CaveCarver,
}

export type BaseChunk = {
	chunk: Chunk.Chunk,
	biomeIds: buffer, -- 256 x u8, index x + z*16
}

function TerrainGenerator.new(seed: WorldSeed.WorldSeed, biomeScale: number?): Terrain
	local rng = WorldSeed.newRandom(seed)
	return {
		seed = seed,
		biomes = BiomeSource.new(seed, biomeScale),
		density = Octaves.new(rng, 4),
		detail = Octaves.new(rng, 2),
		beach = Octaves.new(rng, 2),
		caves = CaveCarver.new(seed),
	}
end

local KERNEL: { number } = table.create(25, 0)
do
	local i = 1
	for dz = -2, 2 do
		for dx = -2, 2 do
			KERNEL[i] = 10 / math.sqrt(dx * dx + dz * dz + 0.2)
			i += 1
		end
	end
end

local GRID_Y = 33 -- y = 0, 8, ..., 256

function TerrainGenerator.generateBase(gen: Terrain, cx: number, cz: number): BaseChunk
	local chunk = Chunk.new(cx, cz)
	local bx, bz = cx * 16, cz * 16
	-- 9x9 biome lattice at 4-block spacing, covering -8..+24 around the chunk
	local gridBiome: { Biomes.Biome } = {}
	for gz = 0, 8 do
		for gx = 0, 8 do
			gridBiome[gx + gz * 9 + 1] = BiomeSource.biomeAt(gen.biomes, bx + (gx - 2) * 4 + 2, bz + (gz - 2) * 4 + 2)
		end
	end
	local biomeIds = buffer.create(256)
	for z = 0, 15 do
		for x = 0, 15 do
			buffer.writeu8(biomeIds, x + z * 16, gridBiome[(x // 4 + 2) + (z // 4 + 2) * 9 + 1].id)
		end
	end

	-- density lattice 5 x 33 x 5
	local dens: { number } = table.create(5 * GRID_Y * 5, 0)
	for sz = 0, 4 do
		for sx = 0, 4 do
			local dsum, ssum, wsum = 0, 0, 0
			local k = 1
			for dz = -2, 2 do
				for dx = -2, 2 do
					local gxi, gzi = sx + dx + 2, sz + dz + 2
					if gxi > 8 then
						gxi = 8
					end
					if gzi > 8 then
						gzi = 8
					end
					local b = gridBiome[gxi + gzi * 9 + 1]
					local w = KERNEL[k]
					dsum += b.depth * w
					ssum += b.scale * w
					wsum += w
					k += 1
				end
			end
			local depth, scale = dsum / wsum, ssum / wsum
			local wx, wz = bx + sx * 4, bz + sz * 4
			local hillNoise = Octaves.fbm(gen.detail, wx / 200, 0, wz / 200)
			local height = 64 + depth * 17 + hillNoise * 3
			local amp = 3 + scale * 64
			local top, bottom = height + amp * 1.3 + 6, height - amp * 1.3 - 6
			for sy = 0, GRID_Y - 1 do
				local y = sy * 8
				local d
				if y > top then
					d = -1
				elseif y < bottom then
					d = 1
				else
					local n = Octaves.fbm(gen.density, wx / 84, y / 56, wz / 84)
					d = (height - y) + n * amp * 1.25
				end
				dens[sx + sz * 5 + sy * 25 + 1] = d
			end
		end
	end

	-- trilinear fill, written straight into section buffers (the chunk is not
	-- yet visible to anyone, so per-block bookkeeping is done once at the end)
	local sections = chunk.sections
	for sy = 0, GRID_Y - 2 do
		for sz = 0, 3 do
			for sx = 0, 3 do
				local i000 = sx + sz * 5 + sy * 25 + 1
				local d000, d100 = dens[i000], dens[i000 + 1]
				local d010, d110 = dens[i000 + 5], dens[i000 + 6]
				local d001, d101 = dens[i000 + 25], dens[i000 + 26]
				local d011, d111 = dens[i000 + 30], dens[i000 + 31]
				-- fast reject: whole cell air above sea level
				if d000 <= 0 and d100 <= 0 and d010 <= 0 and d110 <= 0 and d001 <= 0 and d101 <= 0 and d011 <= 0 and d111 <= 0 and sy * 8 >= 63 then
					continue
				end
				for ly = 0, 7 do
					local y = sy * 8 + ly
					local si = y // 16
					local sec = sections[si]
					if sec == nil then
						sec = { states = buffer.create(8192), nonAir = 0 }
						sections[si] = sec
					end
					assert(sec)
					local states = sec.states
					local placed = 0
					local ty = ly / 8
					local a00 = d000 + (d001 - d000) * ty
					local a10 = d100 + (d101 - d100) * ty
					local a01 = d010 + (d011 - d010) * ty
					local a11 = d110 + (d111 - d110) * ty
					local rowBase = (y % 16) * 256 + sx * 4
					for lz = 0, 3 do
						local tz = lz / 4
						local b0 = a00 + (a01 - a00) * tz
						local b1 = a10 + (a11 - a10) * tz
						local off = (rowBase + (sz * 4 + lz) * 16) * 2
						for lx = 0, 3 do
							local d = b0 + (b1 - b0) * (lx / 4)
							if d > 0 then
								buffer.writeu16(states, off + lx * 2, STONE)
								placed += 1
							elseif y < 63 then
								buffer.writeu16(states, off + lx * 2, WATER)
								placed += 1
							end
						end
					end
					sec.nonAir += placed
				end
			end
		end
	end
	for si = 0, 15 do
		local sec = sections[si]
		if sec and sec.nonAir == 0 then
			sections[si] = nil
		end
	end
	Chunk.rebuildHeightmap(chunk)

	-- surface + bedrock
	for z = 0, 15 do
		for x = 0, 15 do
			local wx, wz = bx + x, bz + z
			local biome = Biomes.get(buffer.readu8(biomeIds, x + z * 16))
			local colHash = Hash.hash(gen.seed.lo, wx, wz, 7)
			local fillerDepth = 3 + colHash % 3
			local beachy = Octaves.fbm(gen.beach, wx / 40, 0, wz / 40) > 0.05
			local top, filler = biome.top * 16, biome.filler * 16
			local run = -1
			local sandstoneLeft = 0
			local y = Chunk.height(chunk, x, z) - 1
			local colOff = (x + z * 16) * 2
			while y >= 0 do
				local sec = chunk.sections[y // 16]
				local st = if sec then buffer.readu16(sec.states, colOff + (y % 16) * 512) else AIR
				if st == STONE and run == -2 then
					y -= 1
					continue
				end
				if st == STONE then
					if run == -1 then
						run = fillerDepth
						local t = top
						local f = filler
						if y < 62 then
							if biome.ocean then
								t = GRAVEL
							elseif beachy then
								t, f = SAND, SAND
							else
								t = DIRT
							end
						elseif y <= 64 and beachy and not biome.ocean and biome.top == 2 and biome.scale < 0.3 then
							t, f = SAND, SAND
						end
						filler = f
						Chunk.setState(chunk, x, y, z, t, false)
						if filler == SAND then
							sandstoneLeft = 1 + colHash // 7 % 3
						end
						if biome.frozen and y >= 62 and Chunk.getState(chunk, x, y + 1, z) == AIR and t == GRASS then
							Chunk.setState(chunk, x, y + 1, z, SNOW_LAYER, false)
						end
					elseif run > 0 then
						run -= 1
						Chunk.setState(chunk, x, y, z, filler, false)
					elseif run == 0 and sandstoneLeft > 0 then
						sandstoneLeft -= 1
						Chunk.setState(chunk, x, y, z, SANDSTONE, false)
					end
					if run == 0 and sandstoneLeft == 0 then
						-- deeper stone: skip quickly to the next air pocket
						run = -2
					end
				elseif st == AIR or st == WATER then
					run = -1
					filler = biome.filler * 16
					if st == WATER and y == 62 and biome.frozen then
						Chunk.setState(chunk, x, y, z, ICE, false)
					end
				end
				y -= 1
			end
			-- bedrock: y=0 always, y=1..4 with decreasing probability
			Chunk.setState(chunk, x, 0, z, BEDROCK, false)
			local bh = Hash.hash(gen.seed.hi, wx, wz, 3)
			for by = 1, 4 do
				if by <= bit32.extract(bh, (by - 1) * 8, 8) % 5 then
					Chunk.setState(chunk, x, by, z, BEDROCK, false)
				end
			end
		end
	end

	CaveCarver.carve(gen.caves, chunk)
	chunk.generated = true
	chunk.dirty = false
	return { chunk = chunk, biomeIds = biomeIds }
end

local _ = JavaRandom
return TerrainGenerator
