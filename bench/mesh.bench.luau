local World = require("../src/shared/Voxel/World")
local Chunk = require("../src/shared/Voxel/Chunk")
local SectionMesher = require("../src/shared/Mesh/SectionMesher")
local BoxMesher = require("../src/shared/Mesh/BoxMesher")
local WorldSource = require("../src/shared/Mesh/WorldSource")
local WorldGenerator = require("../src/shared/WorldGen/WorldGenerator")
local WorldSeed = require("../src/shared/WorldGen/WorldSeed")
local ChunkCodec = require("../src/shared/Persistence/ChunkCodec")
local Base64 = require("../src/shared/Util/Base64")
local RemeshQueue = require("../src/shared/Streaming/RemeshQueue")

local function fixtureWorlds()
	local worlds = {}
	-- generated terrain 3x3
	local w = World.new(1024)
	local g = WorldGenerator.new(WorldSeed.fromNumber(20131218))
	for cx = -1, 1 do
		for cz = -1, 1 do
			World.putChunk(w, WorldGenerator.generate(g, cx, cz))
		end
	end
	worlds.terrain = w
	-- 3D checkerboard (worst case)
	local c = World.new(1024)
	for cx = -1, 1 do
		for cz = -1, 1 do
			World.putChunk(c, Chunk.new(cx, cz))
		end
	end
	for y = 64, 79 do
		for z = 0, 15 do
			for x = 0, 15 do
				if (x + y + z) % 2 == 0 then
					World.setState(c, x, y, z, 16)
				end
			end
		end
	end
	worlds.checker = c
	-- foliage/transparent mix
	local f = World.new(1024)
	for cx = -1, 1 do
		for cz = -1, 1 do
			World.putChunk(f, Chunk.new(cx, cz))
		end
	end
	local s = 3
	for y = 64, 79 do
		for z = 0, 15 do
			for x = 0, 15 do
				s = (s * 1103515245 + 12345) % 2147483648
				local r = s % 5
				World.setState(f, x, y, z, if r == 0 then 18 * 16 elseif r == 1 then 20 * 16 elseif r == 2 then 9 * 16 elseif r == 3 then 31 * 16 else 0)
			end
		end
	end
	worlds.foliage = f
	return worlds
end

return function(Bench)
	local worlds = fixtureWorlds()
	local function surfaceSection(w)
		-- the section containing the surface at the chunk centre
		return math.clamp((World.height(w, 8, 8) - 1) // 16, 0, 15)
	end
	for _, name in { "terrain", "checker", "foliage" } do
		local w = worlds[name]
		local src = WorldSource.new(w)
		local si = if name == "terrain" then surfaceSection(w) else 4
		Bench.run("mesh.quads greedy [" .. name .. "]", 200, function(n)
			local m
			for _ = 1, n do
				m = SectionMesher.mesh(src, 0, 0, si)
			end
			return { quads = m.quadCount, faces = m.visibleFaces, specials = m.specialCount }
		end)
		Bench.run("mesh.boxes [" .. name .. "]", 200, function(n)
			local d
			for _ = 1, n do
				d = BoxMesher.mesh(src, 0, 0, si)
			end
			return { boxes = d.boxCount, covered = d.coveredCells }
		end)
	end
	local chunk = World.getChunk(worlds.terrain, 0, 0) :: any
	local encoded = ChunkCodec.encode(chunk)
	Bench.run("codec.encode terrain chunk", 300, function(n)
		local b
		for _ = 1, n do
			b = ChunkCodec.encode(chunk)
		end
		return { bytes = buffer.len(b) }
	end)
	Bench.run("codec.decode terrain chunk", 300, function(n)
		for _ = 1, n do
			ChunkCodec.decode(encoded)
		end
		return nil
	end)
	Bench.run("base64.encode terrain chunk", 300, function(n)
		local s
		for _ = 1, n do
			s = Base64.encode(encoded)
		end
		return { chars = #s }
	end)
	Bench.run("remesh.markBlock + pop (dense edits)", 20000, function(n)
		local q = RemeshQueue.new()
		local s = 1
		for _ = 1, n do
			s = (s * 1103515245 + 12345) % 2147483648
			RemeshQueue.markBlock(q, s % 64 - 32, s % 256, (s // 256) % 64 - 32)
		end
		local marked = q.count
		local popped = #RemeshQueue.pop(q, 64, 0, 0, 4)
		return { dirtySections = marked, popped = popped }
	end)
	Bench.run("memory: 9 generated chunks (KB)", 1, function()
		local bytes = 0
		for _, c in worlds.terrain.chunks do
			bytes += Chunk.memoryBytes(c)
		end
		return { kb = bytes // 1024 }
	end)
end
