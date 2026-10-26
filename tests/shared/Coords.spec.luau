local Coords = require("../../src/shared/Voxel/Coords")

return function(t)
	t.describe("Coords", function()
		t.test("blockToChunk floors negatives", function()
			t.eq(Coords.blockToChunk(0), 0)
			t.eq(Coords.blockToChunk(15), 0)
			t.eq(Coords.blockToChunk(16), 1)
			t.eq(Coords.blockToChunk(-1), -1)
			t.eq(Coords.blockToChunk(-16), -1)
			t.eq(Coords.blockToChunk(-17), -2)
		end)
		t.test("blockToLocal wraps into [0,15]", function()
			t.eq(Coords.blockToLocal(-1), 15)
			t.eq(Coords.blockToLocal(-16), 0)
			t.eq(Coords.blockToLocal(-17), 15)
			t.eq(Coords.blockToLocal(31), 15)
		end)
		t.test("chunk*16 + local reconstructs block coordinate", function()
			for v = -300, 300 do
				t.eq(Coords.chunkToBlock(Coords.blockToChunk(v)) + Coords.blockToLocal(v), v)
			end
		end)
		t.test("chunkKey round-trips and is unique", function()
			local seen = {}
			for cx = -40, 40, 3 do
				for cz = -40, 40, 3 do
					local k = Coords.chunkKey(cx, cz)
					t.falsy(seen[k], "duplicate key")
					seen[k] = true
					local a, b = Coords.unpackChunkKey(k)
					t.eq(a, cx)
					t.eq(b, cz)
				end
			end
			local a, b = Coords.unpackChunkKey(Coords.chunkKey(-1048576, 1048575))
			t.eq(a, -1048576)
			t.eq(b, 1048575)
		end)
		t.test("section index round-trips over full section", function()
			local seen = {}
			for y = 0, 15 do
				for z = 0, 15 do
					for x = 0, 15 do
						local i = Coords.sectionIndex(x, y, z)
						t.truthy(i >= 0 and i < 4096)
						t.falsy(seen[i])
						seen[i] = true
						local a, b, c = Coords.unpackSectionIndex(i)
						t.eq(a, x); t.eq(b, y); t.eq(c, z)
					end
				end
			end
		end)
		t.test("floorBlock handles negative fractional positions", function()
			local x, y, z = Coords.floorBlock(-0.5, 64.99, -16.0001)
			t.eq(x, -1); t.eq(y, 64); t.eq(z, -17)
		end)
	end)
end
