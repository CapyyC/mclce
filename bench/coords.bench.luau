local Coords = require("../src/shared/Voxel/Coords")
local World = require("../src/shared/Voxel/World")
local Chunk = require("../src/shared/Voxel/Chunk")

return function(Bench)
	Bench.run("coords.chunkKey+unpack", 1000000, function(n)
		local acc = 0
		for i = 1, n do
			local k = Coords.chunkKey(i % 97 - 48, i % 89 - 44)
			local a, b = Coords.unpackChunkKey(k)
			acc += a + b
		end
		return { checksum = acc }
	end)
	local w = World.new()
	for cx = -4, 3 do
		for cz = -4, 3 do
			World.putChunk(w, Chunk.new(cx, cz))
		end
	end
	Bench.run("world.setState (random, 8x8 chunks)", 500000, function(n)
		local s = 1
		for _ = 1, n do
			s = (s * 1103515245 + 12345) % 2147483648
			World.setState(w, s % 128 - 64, s % 256, (s // 256) % 128 - 64, 16)
		end
		return nil
	end)
	Bench.run("world.getState (random, 8x8 chunks)", 1000000, function(n)
		local s, acc = 1, 0
		for _ = 1, n do
			s = (s * 1103515245 + 12345) % 2147483648
			acc += World.getState(w, s % 128 - 64, s % 256, (s // 256) % 128 - 64)
		end
		return { checksum = acc }
	end)
end
