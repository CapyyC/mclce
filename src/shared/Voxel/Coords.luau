--!strict
--!native
-- World/chunk/section coordinate math. All functions are correct for negative
-- coordinates (floor division, never truncation).
--
-- Layout: a chunk column is 16 x WORLD_HEIGHT x 16 blocks, split into 16^3
-- sections. Section-local index = x + z*16 + y*256 so a horizontal layer is
-- contiguous (good for heightmap scans and greedy meshing along X/Z).

local Coords = {}

Coords.CHUNK_SIZE = 16
Coords.CHUNK_SHIFT = 4
Coords.CHUNK_MASK = 15
Coords.WORLD_HEIGHT = 256
Coords.SECTION_COUNT = 16
Coords.SECTION_VOLUME = 4096

local KEY_OFFSET = 1048576 -- 2^20: chunk coords in [-2^20, 2^20)
local KEY_STRIDE = 2097152 -- 2^21

-- Block coordinate -> chunk coordinate.
function Coords.blockToChunk(v: number): number
	return v // 16
end

-- Block coordinate -> chunk-local coordinate in [0, 15].
function Coords.blockToLocal(v: number): number
	return v % 16
end

function Coords.chunkToBlock(c: number): number
	return c * 16
end

-- Packs a chunk column coordinate into a single exact integer key (fits in a
-- double's 53-bit mantissa) for fast table lookup without string allocation.
function Coords.chunkKey(cx: number, cz: number): number
	return (cx + KEY_OFFSET) * KEY_STRIDE + (cz + KEY_OFFSET)
end

function Coords.unpackChunkKey(key: number): (number, number)
	local cz = key % KEY_STRIDE
	local cx = (key - cz) // KEY_STRIDE
	return cx - KEY_OFFSET, cz - KEY_OFFSET
end

-- Section-local index for local coords x,y,z in [0,15].
function Coords.sectionIndex(x: number, y: number, z: number): number
	return x + z * 16 + y * 256
end

function Coords.unpackSectionIndex(i: number): (number, number, number)
	return i % 16, i // 256, (i // 16) % 16
end

function Coords.inWorldHeight(y: number): boolean
	return y >= 0 and y < Coords.WORLD_HEIGHT
end

-- Floors a world-space position (in blocks) to the containing block.
function Coords.floorBlock(x: number, y: number, z: number): (number, number, number)
	return math.floor(x), math.floor(y), math.floor(z)
end

return Coords
