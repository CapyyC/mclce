local World = require("../../src/shared/Voxel/World")
local Chunk = require("../../src/shared/Voxel/Chunk")

local function withChunks(w, r)
	for cx = -r, r - 1 do
		for cz = -r, r - 1 do
			World.putChunk(w, Chunk.new(cx, cz))
		end
	end
end

return function(t)
	t.describe("World", function()
		t.test("classic border is -432..431", function()
			local w = World.new()
			t.eq(w.minX, -432); t.eq(w.maxX, 431)
			t.truthy(World.inBorder(w, -432, 431)); t.falsy(World.inBorder(w, 432, 0)); t.falsy(World.inBorder(w, 0, -433))
			t.truthy(World.chunkInBorder(w, -27, 26)); t.falsy(World.chunkInBorder(w, 27, 0))
		end)
		t.test("cross-chunk addressing with negatives", function()
			local w = World.new()
			withChunks(w, 2)
			t.eq(w.chunkCount, 16)
			local pts = { { -1, 5, -1 }, { 0, 5, 0 }, { -16, 5, 15 }, { -17, 5, -32 }, { 31, 255, 31 } }
			for i, p in pts do
				t.truthy(World.setState(w, p[1], p[2], p[3], i * 16))
			end
			for i, p in pts do
				t.eq(World.getId(w, p[1], p[2], p[3]), i)
			end
			local c = World.getChunk(w, -2, -2)
			t.truthy(c)
			t.eq(Chunk.getId(c :: any, 15, 5, 0), 4) -- (-17,-32) -> chunk (-2,-2) local (15,0)
		end)
		t.test("writes to unloaded chunks or outside border fail", function()
			local w = World.new(64)
			withChunks(w, 2)
			t.falsy(World.setState(w, 100, 5, 0, 16))
			t.falsy(World.setState(w, 0, 300, 0, 16))
			World.removeChunk(w, 0, 0)
			t.falsy(World.setState(w, 1, 1, 1, 16))
			t.eq(w.chunkCount, 15)
		end)
		t.test("listeners receive changes only when state changes", function()
			local w = World.new()
			withChunks(w, 1)
			local log = {}
			local unsub = World.addListener(w, function(x, y, z, o, n)
				table.insert(log, { x, y, z, o, n })
			end)
			World.setState(w, -1, 2, -1, 32)
			World.setState(w, -1, 2, -1, 32)
			World.setState(w, -1, 2, -1, 0)
			t.eq(#log, 2)
			t.deepEq(log[1], { -1, 2, -1, 0, 32 })
			t.deepEq(log[2], { -1, 2, -1, 32, 0 })
			unsub()
			World.setState(w, -1, 3, -1, 32)
			t.eq(#log, 2)
		end)
	end)
end
