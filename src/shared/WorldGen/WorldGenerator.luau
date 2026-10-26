--!strict
-- Public generation entry point: generate(cx, cz) -> fully decorated chunk.
-- Base terrain of neighbours is memoised in a bounded cache so streaming a
-- region costs ~1 base generation per chunk. Output is a pure function of
-- (seed, cx, cz): independent of call order and cache state.

local Coords = require("../Voxel/Coords")
local Chunk = require("../Voxel/Chunk")
local TerrainGenerator = require("./TerrainGenerator")
local Decorator = require("./Decorator")
local WorldSeed = require("./WorldSeed")
local NetherGenerator = require("./NetherGenerator")

export type BaseChunk = TerrainGenerator.BaseChunk

export type WorldGenerator = {
	seed: WorldSeed.WorldSeed,
	terrain: TerrainGenerator.Terrain,
	cache: { [number]: BaseChunk },
	cacheOrder: { number },
	cacheHead: number,
	capacity: number,
	stats: { baseGenerated: number, cacheHits: number, decorated: number },
	dimension: string, -- "overworld" | "nether"
	nether: NetherGenerator.NetherGen?,
}

local WorldGenerator = {}

type Options = { cacheCapacity: number?, biomeScale: number?, dimension: string? }

function WorldGenerator.new(seed: WorldSeed.WorldSeed, opts: Options?): WorldGenerator
	local o: Options = opts or {} :: Options
	return {
		seed = seed,
		terrain = TerrainGenerator.new(seed, o.biomeScale),
		cache = {},
		cacheOrder = {},
		cacheHead = 1,
		capacity = o.cacheCapacity or 128,
		stats = { baseGenerated = 0, cacheHits = 0, decorated = 0 },
		dimension = o.dimension or "overworld",
		nether = if o.dimension == "nether" then NetherGenerator.new(seed) else nil,
	}
end

function WorldGenerator.getBase(gen: WorldGenerator, cx: number, cz: number): BaseChunk
	local k = Coords.chunkKey(cx, cz)
	local b = gen.cache[k]
	if b then
		gen.stats.cacheHits += 1
		return b
	end
	b = TerrainGenerator.generateBase(gen.terrain, cx, cz)
	gen.stats.baseGenerated += 1
	-- FIFO ring eviction
	local order = gen.cacheOrder
	if #order >= gen.capacity then
		local old = order[gen.cacheHead]
		gen.cache[old] = nil
		order[gen.cacheHead] = k
		gen.cacheHead = gen.cacheHead % gen.capacity + 1
	else
		table.insert(order, k)
	end
	gen.cache[k] = b
	return b :: BaseChunk
end

function WorldGenerator.generate(gen: WorldGenerator, cx: number, cz: number): Chunk.Chunk
	if gen.nether then
		gen.stats.decorated += 1
		return NetherGenerator.generate(gen.nether, cx, cz)
	end
	local base = WorldGenerator.getBase(gen, cx, cz)
	local c = Chunk.clone(base.chunk)
	Decorator.decorate(gen.seed, c, function(x, z)
		return WorldGenerator.getBase(gen, x, z)
	end)
	c.generated = true
	c.dirty = false
	gen.stats.decorated += 1
	return c
end

-- Biome id at a block column (from the base terrain of its chunk).
function WorldGenerator.biomeAt(gen: WorldGenerator, wx: number, wz: number): number
	local b = WorldGenerator.getBase(gen, wx // 16, wz // 16)
	return buffer.readu8(b.biomeIds, wx % 16 + (wz % 16) * 16)
end

function WorldGenerator.clearCache(gen: WorldGenerator)
	gen.cache = {}
	gen.cacheOrder = {}
	gen.cacheHead = 1
end

return WorldGenerator
