--!strict
--!native
-- Authoritative block container: a sparse map of chunk columns plus the
-- Legacy Console finite world border. Pure data; no Roblox dependencies.

local Coords = require("./Coords")
local Chunk = require("./Chunk")

export type Chunk = Chunk.Chunk

export type BlockChange = (wx: number, wy: number, wz: number, old: number, new: number) -> ()

export type World = {
	chunks: { [number]: Chunk },
	chunkCount: number,
	-- Inclusive block-coordinate border. Legacy worlds are finite squares
	-- centred on the origin.
	minX: number,
	maxX: number,
	minZ: number,
	maxZ: number,
	listeners: { BlockChange },
}

local World = {}

-- Legacy Console world sizes (edge length in blocks). PS4 offered Classic,
-- Small, Medium and Large after the world-size expansion update.
World.SIZES = {
	classic = 864,
	small = 1024,
	medium = 3072,
	large = 5120,
}

function World.new(edgeBlocks: number?): World
	local edge = edgeBlocks or World.SIZES.classic
	assert(edge % 16 == 0, "world edge must be a multiple of 16")
	local half = edge // 2
	return {
		chunks = {},
		chunkCount = 0,
		minX = -half,
		maxX = half - 1,
		minZ = -half,
		maxZ = half - 1,
		listeners = {},
	}
end

function World.inBorder(world: World, wx: number, wz: number): boolean
	return wx >= world.minX and wx <= world.maxX and wz >= world.minZ and wz <= world.maxZ
end

function World.chunkInBorder(world: World, cx: number, cz: number): boolean
	return cx * 16 >= world.minX and cx * 16 + 15 <= world.maxX and cz * 16 >= world.minZ and cz * 16 + 15 <= world.maxZ
end

function World.getChunk(world: World, cx: number, cz: number): Chunk?
	return world.chunks[Coords.chunkKey(cx, cz)]
end

function World.putChunk(world: World, chunk: Chunk)
	local k = Coords.chunkKey(chunk.cx, chunk.cz)
	if world.chunks[k] == nil then
		world.chunkCount += 1
	end
	world.chunks[k] = chunk
end

function World.removeChunk(world: World, cx: number, cz: number): Chunk?
	local k = Coords.chunkKey(cx, cz)
	local c = world.chunks[k]
	if c then
		world.chunks[k] = nil
		world.chunkCount -= 1
	end
	return c
end

function World.getState(world: World, wx: number, wy: number, wz: number): number
	if wy < 0 or wy >= 256 then
		return 0
	end
	local c = world.chunks[Coords.chunkKey(wx // 16, wz // 16)]
	if c == nil then
		return 0
	end
	return Chunk.getState(c, wx % 16, wy, wz % 16)
end

function World.getId(world: World, wx: number, wy: number, wz: number): number
	return World.getState(world, wx, wy, wz) // 16
end

function World.isLoaded(world: World, wx: number, wz: number): boolean
	return world.chunks[Coords.chunkKey(wx // 16, wz // 16)] ~= nil
end

-- Sets a block. Returns false if the target is outside the world height,
-- outside the border, or in an unloaded chunk (writes never auto-create chunks).
function World.setState(world: World, wx: number, wy: number, wz: number, state: number): boolean
	if wy < 0 or wy >= 256 or not World.inBorder(world, wx, wz) then
		return false
	end
	local c = world.chunks[Coords.chunkKey(wx // 16, wz // 16)]
	if c == nil then
		return false
	end
	local old = Chunk.setState(c, wx % 16, wy, wz % 16, state)
	if old ~= state then
		for _, fn in world.listeners do
			fn(wx, wy, wz, old, state)
		end
	end
	return true
end

function World.addListener(world: World, fn: BlockChange): () -> ()
	table.insert(world.listeners, fn)
	return function()
		local i = table.find(world.listeners, fn)
		if i then
			table.remove(world.listeners, i)
		end
	end
end

function World.height(world: World, wx: number, wz: number): number
	local c = world.chunks[Coords.chunkKey(wx // 16, wz // 16)]
	if c == nil then
		return 0
	end
	return Chunk.height(c, wx % 16, wz % 16)
end

return World
