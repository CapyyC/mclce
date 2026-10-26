--!strict
--!native
-- Read-only block property tables built once from BlockData.
--
-- A block *state* is packed as id * 16 + meta (meta = 4-bit Legacy data value)
-- and stored as a u16, so ids range 0..4095. Hot-path property lookups are
-- flat arrays indexed by id + 1 to stay in the table array part.

local BlockData = require("./BlockData")

export type BlockDef = BlockData.BlockDef

local LAYER_CODES = { none = 0, opaque = 1, cutout = 2, translucent = 3 }

local BlockRegistry = {}

BlockRegistry.MAX_ID = 4095
BlockRegistry.LAYER_NONE = 0
BlockRegistry.LAYER_OPAQUE = 1
BlockRegistry.LAYER_CUTOUT = 2
BlockRegistry.LAYER_TRANSLUCENT = 3

local byId: { [number]: BlockDef } = {}
local byName: { [string]: BlockDef } = {}
-- Flat arrays (index = id + 1). Unknown ids behave like air but are kept on
-- save so data from newer schema versions is not destroyed.
local layer: { number } = table.create(4096, 0)
local fullCube: { boolean } = table.create(4096, false)
local solid: { boolean } = table.create(4096, false)
local opacity: { number } = table.create(4096, 0)
local emission: { number } = table.create(4096, 0)
local hardness: { number } = table.create(4096, 0)
local replaceable: { boolean } = table.create(4096, true)

for _, raw in BlockData do
	local def = raw :: any
	assert(def.id >= 0 and def.id <= BlockRegistry.MAX_ID, "block id out of range: " .. tostring(def.id))
	assert(byId[def.id] == nil, "duplicate block id " .. tostring(def.id))
	assert(byName[def.name] == nil, "duplicate block name " .. def.name)
	local code = LAYER_CODES[def.layer]
	assert(code ~= nil, "bad layer for " .. def.name)
	byId[def.id] = def
	byName[def.name] = def
	local i = def.id + 1
	layer[i] = code
	fullCube[i] = def.shape == "cube"
	solid[i] = def.solid
	opacity[i] = def.opacity
	emission[i] = def.light
	hardness[i] = def.hardness
	replaceable[i] = def.replaceable
end

-- Frequently used ids, resolved by name so data edits stay consistent.
local function idOf(name: string): number
	local d = byName[name]
	assert(d, "unknown block " .. name)
	return d.id
end
BlockRegistry.idOf = idOf

BlockRegistry.AIR = 0
BlockRegistry.STONE = idOf("stone")
BlockRegistry.GRASS = idOf("grass")
BlockRegistry.DIRT = idOf("dirt")
BlockRegistry.COBBLESTONE = idOf("cobblestone")
BlockRegistry.BEDROCK = idOf("bedrock")
BlockRegistry.WATER = idOf("water")
BlockRegistry.FLOWING_WATER = idOf("flowing_water")
BlockRegistry.LAVA = idOf("lava")
BlockRegistry.FLOWING_LAVA = idOf("flowing_lava")
BlockRegistry.SAND = idOf("sand")
BlockRegistry.GRAVEL = idOf("gravel")
BlockRegistry.LOG = idOf("log")
BlockRegistry.LEAVES = idOf("leaves")
BlockRegistry.GLASS = idOf("glass")
BlockRegistry.SANDSTONE = idOf("sandstone")
BlockRegistry.TALLGRASS = idOf("tallgrass")
BlockRegistry.SNOW_LAYER = idOf("snow_layer")
BlockRegistry.ICE = idOf("ice")
BlockRegistry.CLAY = idOf("clay")
BlockRegistry.COAL_ORE = idOf("coal_ore")
BlockRegistry.IRON_ORE = idOf("iron_ore")
BlockRegistry.GOLD_ORE = idOf("gold_ore")
BlockRegistry.DIAMOND_ORE = idOf("diamond_ore")
BlockRegistry.REDSTONE_ORE = idOf("redstone_ore")
BlockRegistry.LAPIS_ORE = idOf("lapis_ore")
BlockRegistry.TORCH = idOf("torch")

function BlockRegistry.get(id: number): BlockDef?
	return byId[id]
end

function BlockRegistry.byName(name: string): BlockDef?
	return byName[name]
end

function BlockRegistry.isKnown(id: number): boolean
	return byId[id] ~= nil
end

function BlockRegistry.state(id: number, meta: number?): number
	return id * 16 + (meta or 0)
end

function BlockRegistry.stateId(state: number): number
	return state // 16
end

function BlockRegistry.stateMeta(state: number): number
	return state % 16
end

function BlockRegistry.layer(id: number): number
	return layer[id + 1] or 0
end

-- True if this block is a full opaque cube that hides neighbouring faces.
function BlockRegistry.occludes(id: number): boolean
	return layer[id + 1] == 1 and fullCube[id + 1] == true
end

function BlockRegistry.isFullCube(id: number): boolean
	return fullCube[id + 1] == true
end

function BlockRegistry.isSolid(id: number): boolean
	return solid[id + 1] == true
end

function BlockRegistry.opacity(id: number): number
	return opacity[id + 1] or 0
end

function BlockRegistry.emission(id: number): number
	return emission[id + 1] or 0
end

function BlockRegistry.hardness(id: number): number
	return hardness[id + 1] or 0
end

function BlockRegistry.isReplaceable(id: number): boolean
	local r = replaceable[id + 1]
	return r == nil or r == true
end

function BlockRegistry.isLiquid(id: number): boolean
	local d = byId[id]
	return d ~= nil and d.shape == "liquid"
end

function BlockRegistry.all(): { BlockDef }
	local out: { BlockDef } = {}
	for _, d in byId do
		table.insert(out, d)
	end
	table.sort(out, function(a: BlockDef, b: BlockDef): boolean
		return a.id < b.id
	end)
	return out
end

-- Raw arrays for hot loops (mesher, lighting). Treat as read-only.
BlockRegistry._layer = layer
BlockRegistry._fullCube = fullCube
BlockRegistry._opacity = opacity

return BlockRegistry
