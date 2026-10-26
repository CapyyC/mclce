--!strict
--!native
-- Climate-noise biome selection.
--
-- APPROXIMATION: classic Minecraft (and Legacy Console) choose biomes with a
-- stack of zoom/fuzz layers ("GenLayer"). That algorithm is not reproduced
-- here; instead temperature / humidity / continentalness / river noises pick
-- from the same biome table. Seeds therefore do NOT match console worlds.
-- The module boundary (biomeAt) lets a faithful layer stack replace it.

local Biomes = require("./Biomes")
local Hash = require("../Util/Hash")
local JavaRandom = require("../Util/JavaRandom")
local PerlinNoise = require("../Util/PerlinNoise")
local WorldSeed = require("./WorldSeed")

local Octaves = PerlinNoise.Octaves

export type BiomeSource = {
	temp: PerlinNoise.Octaves,
	humid: PerlinNoise.Octaves,
	cont: PerlinNoise.Octaves,
	river: PerlinNoise.Octaves,
	hills: PerlinNoise.Octaves,
	special: PerlinNoise.Octaves,
	scale: number,
}

local BiomeSource = {}

local B = Biomes :: any

function BiomeSource.new(seed: WorldSeed.WorldSeed, biomeScale: number?): BiomeSource
	local function stream(salt: number)
		return JavaRandom.new(Hash.hash(seed.hi, seed.lo, salt) * 65536 + Hash.hash(seed.lo, seed.hi, salt) % 65536)
	end
	return {
		temp = Octaves.new(stream(101), 3),
		humid = Octaves.new(stream(102), 3),
		cont = Octaves.new(stream(103), 4),
		river = Octaves.new(stream(104), 3),
		hills = Octaves.new(stream(105), 2),
		special = Octaves.new(stream(106), 2),
		scale = biomeScale or 1,
	}
end

-- Returns the climate values used by biomeAt (exposed for debugging/tests).
function BiomeSource.climate(src: BiomeSource, x: number, z: number): (number, number, number, number, number)
	local s = src.scale
	local t = Octaves.fbm(src.temp, x / (420 * s), 0, z / (420 * s)) * 1.6
	local h = Octaves.fbm(src.humid, x / (380 * s), 0, z / (380 * s)) * 1.6
	local c = Octaves.fbm(src.cont, x / (520 * s), 0, z / (520 * s)) * 1.5 + 0.12
	local r = Octaves.fbm(src.river, x / (300 * s), 0, z / (300 * s))
	local hl = Octaves.fbm(src.hills, x / (260 * s), 0, z / (260 * s))
	return t, h, c, r, hl
end

function BiomeSource.biomeAt(src: BiomeSource, x: number, z: number): Biomes.Biome
	local t, h, c, r, hl = BiomeSource.climate(src, x, z)
	if c < -0.32 then
		if c < -0.62 then
			return B.deep_ocean
		end
		if c < -0.5 and Octaves.fbm(src.special, x / 90, 0, z / 90) > 0.55 then
			return B.mushroom_island
		end
		return if t < -0.4 then B.frozen_ocean else B.ocean
	end
	if c < -0.27 and t > -0.4 and hl < 0.4 then
		return B.beach
	end
	if math.abs(r) < 0.022 and hl < 0.5 then
		return B.river
	end
	if hl > 0.42 then
		return B.extreme_hills
	end
	if t < -0.42 then
		return if h > 0 then B.cold_taiga else B.ice_plains
	elseif t < -0.15 then
		return if h > -0.15 then B.taiga else B.plains
	elseif t < 0.3 then
		if h < -0.25 then
			return B.plains
		elseif h < 0.12 then
			return B.forest
		elseif h < 0.38 then
			return B.birch_forest
		end
		return B.swampland
	elseif t < 0.6 then
		if h < -0.2 then
			return B.plains
		elseif h < 0.25 then
			return B.forest
		elseif h < 0.45 then
			return B.jungle
		end
		return B.swampland
	end
	if h < -0.38 then
		return if t > 0.85 then B.mesa else B.desert
	elseif h < -0.12 then
		return B.desert
	elseif h < 0.1 then
		return B.savanna
	elseif h < 0.3 then
		return B.plains
	end
	return B.jungle
end

return BiomeSource
