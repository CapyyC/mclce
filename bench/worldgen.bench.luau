local JavaRandom = require("../src/shared/Util/JavaRandom")
local PerlinNoise = require("../src/shared/Util/PerlinNoise")
local WorldGenerator = require("../src/shared/WorldGen/WorldGenerator")
local TerrainGenerator = require("../src/shared/WorldGen/TerrainGenerator")
local BiomeSource = require("../src/shared/WorldGen/BiomeSource")
local CaveCarver = require("../src/shared/WorldGen/CaveCarver")
local Chunk = require("../src/shared/Voxel/Chunk")
local WorldSeed = require("../src/shared/WorldGen/WorldSeed")

return function(Bench)
	local n = PerlinNoise.new(JavaRandom.new(1))
	Bench.run("perlin.sample 3D", 1000000, function(count)
		local acc = 0
		for i = 1, count do
			acc += PerlinNoise.sample(n, i * 0.013, i * 0.007, i * -0.011)
		end
		return { checksum = math.floor(acc * 1000) }
	end)
	local o = PerlinNoise.Octaves.new(JavaRandom.new(2), 4)
	Bench.run("octaves.fbm 4 octaves", 250000, function(count)
		local acc = 0
		for i = 1, count do
			acc += PerlinNoise.Octaves.fbm(o, i * 0.013, i * 0.007, i * -0.011)
		end
		return { checksum = math.floor(acc * 1000) }
	end)
	local seed = WorldSeed.fromNumber(20131218)
	local terrain = TerrainGenerator.new(seed)
	Bench.run("biomeSource.biomeAt", 20000, function(count)
		local acc = 0
		for i = 1, count do
			acc += BiomeSource.biomeAt(terrain.biomes, i * 4, i * -3).id
		end
		return { checksum = acc }
	end)
	Bench.run("cave carve (pre-filled stone chunk)", 50, function(count)
		local c = Chunk.new(0, 0)
		for y = 1, 100 do
			for z = 0, 15 do
				for x = 0, 15 do
					Chunk.setState(c, x, y, z, 16, false)
				end
			end
		end
		local start = Chunk.countNonAir(c)
		for i = 1, count do
			c.cx = i
			CaveCarver.carve(terrain.caves, c)
		end
		return { carved = start - Chunk.countNonAir(c) }
	end)
	Bench.run("terrain.generateBase (incl. caves)", 60, function(count)
		local blocks = 0
		for i = 1, count do
			blocks += Chunk.countNonAir(TerrainGenerator.generateBase(terrain, i, -i).chunk)
		end
		return { blocks = blocks }
	end)
	Bench.run("worldGenerator.generate (streamed 8x8)", 64, function(count)
		local g = WorldGenerator.new(seed)
		local side = math.max(1, math.floor(math.sqrt(count)))
		local made = 0
		for i = 0, count - 1 do
			WorldGenerator.generate(g, i % side, i // side)
			made += 1
		end
		return { chunks = made, base = g.stats.baseGenerated }
	end)
end
