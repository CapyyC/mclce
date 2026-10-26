--!strict
-- Biome table. Numeric IDs, depth ("base height") and scale ("height
-- variation"), temperature and rainfall are the public classic-Minecraft
-- values Legacy Console inherited (Java 1.7–1.12 era tables). The surface
-- and decoration counts are simplified approximations (see COMPATIBILITY.md).

export type Biome = {
	id: number,
	name: string,
	depth: number,
	scale: number,
	temperature: number,
	rainfall: number,
	top: number, -- block id
	filler: number, -- block id
	trees: number, -- attempts per chunk
	treeKind: string, -- "oak" | "birch" | "spruce" | "jungle" | "acacia" | "none"
	grass: number, -- tall grass attempts per chunk
	flowers: number,
	frozen: boolean,
	ocean: boolean,
}

local GRASS, DIRT, SAND, STONE, GRAVEL, MYCELIUM, HCLAY = 2, 3, 12, 1, 13, 110, 172

local list: { Biome } = {}
local Biomes = {}

local function add(id: number, name: string, depth: number, scale: number, temp: number, rain: number, extra: { [string]: any }?)
	local b: any = {
		id = id, name = name, depth = depth, scale = scale, temperature = temp, rainfall = rain,
		top = GRASS, filler = DIRT, trees = 0, treeKind = "oak", grass = 1, flowers = 2,
		frozen = temp < 0.15, ocean = false,
	}
	if extra then
		for k, v in extra do
			b[k] = v
		end
	end
	list[#list + 1] = b
	Biomes[name] = b
	return b
end

add(0, "ocean", -1.0, 0.1, 0.5, 0.5, { ocean = true, top = GRAVEL, filler = DIRT, grass = 0, flowers = 0 })
add(1, "plains", 0.125, 0.05, 0.8, 0.4, { trees = 0, grass = 10, flowers = 4 })
add(2, "desert", 0.125, 0.05, 2.0, 0.0, { top = SAND, filler = SAND, grass = 0, flowers = 0, treeKind = "none" })
add(3, "extreme_hills", 1.0, 0.5, 0.2, 0.3, { trees = 0, treeKind = "spruce" })
add(4, "forest", 0.1, 0.2, 0.7, 0.8, { trees = 10, grass = 2 })
add(5, "taiga", 0.2, 0.2, 0.25, 0.8, { trees = 10, treeKind = "spruce", grass = 1, flowers = 0 })
add(6, "swampland", -0.2, 0.1, 0.8, 0.9, { trees = 2, grass = 5, flowers = 1 })
add(7, "river", -0.5, 0.0, 0.5, 0.5, { top = SAND, filler = DIRT, grass = 0, flowers = 0 })
add(10, "frozen_ocean", -1.0, 0.1, 0.0, 0.5, { ocean = true, top = GRAVEL, filler = DIRT, grass = 0, flowers = 0 })
add(12, "ice_plains", 0.125, 0.05, 0.0, 0.5, { trees = 0, treeKind = "spruce", grass = 0, flowers = 0 })
add(14, "mushroom_island", 0.2, 0.3, 0.9, 1.0, { top = MYCELIUM, grass = 0, flowers = 0, treeKind = "none" })
add(16, "beach", 0.0, 0.025, 0.8, 0.4, { top = SAND, filler = SAND, grass = 0, flowers = 0, treeKind = "none" })
add(21, "jungle", 0.1, 0.2, 0.95, 0.9, { trees = 50, treeKind = "jungle", grass = 25, flowers = 4 })
add(24, "deep_ocean", -1.8, 0.1, 0.5, 0.5, { ocean = true, top = GRAVEL, filler = DIRT, grass = 0, flowers = 0 })
add(27, "birch_forest", 0.1, 0.2, 0.6, 0.6, { trees = 10, treeKind = "birch", grass = 2 })
add(30, "cold_taiga", 0.2, 0.2, -0.5, 0.4, { trees = 10, treeKind = "spruce", grass = 1, flowers = 0 })
add(35, "savanna", 0.125, 0.05, 1.2, 0.0, { trees = 1, treeKind = "acacia", grass = 20, flowers = 0 })
add(37, "mesa", 0.1, 0.2, 2.0, 0.0, { top = HCLAY, filler = HCLAY, grass = 0, flowers = 0, treeKind = "none" })

local byId: { [number]: Biome } = {}
for _, b in list do
	byId[b.id] = b
end

function Biomes.get(id: number): Biome
	return byId[id] or byId[1]
end

function Biomes.all(): { Biome }
	return list
end

local _ = STONE
return Biomes
