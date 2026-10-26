local Chunk = require("../../src/shared/Voxel/Chunk")

return function(t)
	t.describe("Chunk", function()
		t.test("new chunk is all air with no sections", function()
			local c = Chunk.new(3, -2)
			t.eq(Chunk.getState(c, 0, 0, 0), 0)
			t.eq(Chunk.getState(c, 15, 255, 15), 0)
			t.eq(Chunk.highestSection(c), -1)
			t.eq(Chunk.memoryBytes(c), 512)
		end)
		t.test("set/get at every corner and section boundary", function()
			local c = Chunk.new(0, 0)
			local pts = { { 0, 0, 0 }, { 15, 0, 15 }, { 0, 15, 0 }, { 0, 16, 0 }, { 15, 255, 15 }, { 7, 127, 9 }, { 7, 128, 9 } }
			for i, p in pts do
				Chunk.setState(c, p[1], p[2], p[3], i * 16 + 3)
			end
			for i, p in pts do
				t.eq(Chunk.getState(c, p[1], p[2], p[3]), i * 16 + 3)
				t.eq(Chunk.getId(c, p[1], p[2], p[3]), i)
			end
			t.eq(Chunk.countNonAir(c), #pts)
		end)
		t.test("out of height range is air and ignored", function()
			local c = Chunk.new(0, 0)
			t.eq(Chunk.setState(c, 0, -1, 0, 16), 0)
			t.eq(Chunk.setState(c, 0, 256, 0, 16), 0)
			t.eq(Chunk.getState(c, 0, -1, 0), 0)
			t.eq(Chunk.highestSection(c), -1)
		end)
		t.test("sections are freed when emptied", function()
			local c = Chunk.new(0, 0)
			Chunk.setState(c, 1, 40, 1, 16)
			t.truthy(Chunk.getSection(c, 2))
			Chunk.setState(c, 1, 40, 1, 0)
			t.eq(Chunk.getSection(c, 2), nil)
		end)
		t.test("setState returns previous state and bumps version", function()
			local c = Chunk.new(0, 0)
			t.eq(Chunk.setState(c, 2, 3, 4, 32), 0)
			local v = c.sectionVersion[1]
			t.eq(Chunk.setState(c, 2, 3, 4, 48), 32)
			t.eq(c.sectionVersion[1], v + 1)
			-- same value is a no-op
			Chunk.setState(c, 2, 3, 4, 48)
			t.eq(c.sectionVersion[1], v + 1)
		end)
		t.test("heightmap tracks additions and removals", function()
			local c = Chunk.new(0, 0)
			t.eq(Chunk.height(c, 5, 5), 0)
			Chunk.setState(c, 5, 10, 5, 16)
			Chunk.setState(c, 5, 70, 5, 16)
			t.eq(Chunk.height(c, 5, 5), 71)
			Chunk.setState(c, 5, 70, 5, 0)
			t.eq(Chunk.height(c, 5, 5), 11)
			Chunk.setState(c, 5, 10, 5, 0)
			t.eq(Chunk.height(c, 5, 5), 0)
			t.eq(Chunk.height(c, 4, 5), 0)
		end)
		t.test("dirty flag respects markDirty=false", function()
			local c = Chunk.new(0, 0)
			Chunk.setState(c, 0, 0, 0, 16, false)
			t.falsy(c.dirty)
			Chunk.setState(c, 0, 1, 0, 16)
			t.truthy(c.dirty)
		end)
		t.test("randomized set/get against reference table", function()
			local c = Chunk.new(0, 0)
			local ref = {}
			local seed = 12345
			local function rnd(n)
				seed = (seed * 1103515245 + 12345) % 2147483648
				return seed % n
			end
			for _ = 1, 5000 do
				local x, y, z, s = rnd(16), rnd(256), rnd(16), rnd(4) == 0 and 0 or rnd(65536)
				Chunk.setState(c, x, y, z, s)
				ref[x + z * 16 + y * 256] = s
			end
			for k, v in ref do
				t.eq(Chunk.getState(c, k % 16, k // 256, (k // 16) % 16), v)
			end
			-- heightmap consistent with brute force
			for z = 0, 15 do
				for x = 0, 15 do
					local h = 0
					for y = 255, 0, -1 do
						if Chunk.getState(c, x, y, z) ~= 0 then
							h = y + 1
							break
						end
					end
					t.eq(Chunk.height(c, x, z), h)
				end
			end
		end)
	end)
end
