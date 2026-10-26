local World = require("../../src/shared/Voxel/World")
local Chunk = require("../../src/shared/Voxel/Chunk")
local B = require("../../src/shared/Blocks/BlockRegistry")
local BoxMesher = require("../../src/shared/Mesh/BoxMesher")
local SectionMesher = require("../../src/shared/Mesh/SectionMesher")

local STONE, DIRT, GLASS = B.STONE * 16, B.DIRT * 16, B.GLASS * 16

local function src(w, missing)
	return {
		getChunk = function(cx, cz)
			return World.getChunk(w, cx, cz)
		end,
		missingState = function()
			return missing or 0
		end,
	}
end

local function newWorld()
	local w = World.new(1024)
	for cx = -1, 1 do
		for cz = -1, 1 do
			World.putChunk(w, Chunk.new(cx, cz))
		end
	end
	return w
end

-- Every visible cube cell must lie in exactly one box of its own state,
-- and boxes never cover a non-occluding cell of another type or air.
local function check(t, w, cx, cz, si, data)
	local cover = {}
	for b = 0, data.boxCount - 1 do
		local o = b * 7
		local x, y, z, sx, sy, sz, st = table.unpack(data.boxes, o + 1, o + 7)
		t.truthy(sx >= 1 and sy >= 1 and sz >= 1 and x + sx <= 16 and y + sy <= 16 and z + sz <= 16, "box bounds")
		for yy = y, y + sy - 1 do
			for zz = z, z + sz - 1 do
				for xx = x, x + sx - 1 do
					local ws = World.getState(w, cx * 16 + xx, si * 16 + yy, cz * 16 + zz)
					if ws == st then
						local k = xx + zz * 16 + yy * 256
						cover[k] = (cover[k] or 0) + 1
					else
						t.truthy(B.occludes(ws // 16), "box covers a visible-able foreign cell")
					end
				end
			end
		end
	end
	local need = BoxMesher._need
	local required = 0
	for i = 1, 4096 do
		if need[i] > 0 then
			required += 1
			t.truthy(cover[i - 1] ~= nil and cover[i - 1] >= 1, "visible cell not covered")
		end
	end
	t.eq(data.coveredCells, required)
end

return function(t)
	t.describe("BoxMesher", function()
		t.test("solid slab of one block becomes one box", function()
			local w = newWorld()
			for z = 0, 15 do
				for x = 0, 15 do
					for y = 0, 3 do
						World.setState(w, x, y, z, STONE)
					end
				end
			end
			local d = BoxMesher.mesh(src(w), 0, 0, 0)
			t.eq(d.boxCount, 1)
			check(t, w, 0, 0, 0, d)
		end)
		t.test("hidden interior acts as wildcard across materials", function()
			local w = newWorld()
			-- 3 layers stone, a hidden dirt pocket in the middle
			for z = 0, 15 do
				for x = 0, 15 do
					for y = 0, 2 do
						World.setState(w, x, y, z, STONE)
					end
				end
			end
			World.setState(w, 8, 1, 8, DIRT)
			local d = BoxMesher.mesh(src(w, STONE), 0, 0, 0)
			t.eq(d.boxCount, 1)
			check(t, w, 0, 0, 0, d)
		end)
		t.test("surface layer of grass over dirt", function()
			local w = World.new(1024)
			World.putChunk(w, Chunk.new(0, 0))
			for z = 0, 15 do
				for x = 0, 15 do
					for y = 0, 4 do
						World.setState(w, x, y, z, DIRT)
					end
					World.setState(w, x, 5, z, B.GRASS * 16)
				end
			end
			local d = BoxMesher.mesh(src(w, STONE), 0, 0, 0)
			t.eq(d.boxCount, 1) -- dirt fully hidden when neighbours solid
			check(t, w, 0, 0, 0, d)
			local d2 = BoxMesher.mesh(src(w, 0), 0, 0, 0) -- sides exposed: dirt needs its own box
			t.eq(d2.boxCount, 2)
			check(t, w, 0, 0, 0, d2)
			World.putChunk(w, Chunk.new(1, 0))
			t.eq(BoxMesher.mesh(src(w, 0), 1, 0, 0).boxCount, 0)
		end)
		t.test("glass is never merged with wildcards", function()
			local w = newWorld()
			World.setState(w, 1, 1, 1, GLASS)
			World.setState(w, 2, 1, 1, GLASS)
			World.setState(w, 3, 1, 1, STONE)
			local d = BoxMesher.mesh(src(w), 0, 0, 0)
			check(t, w, 0, 0, 0, d)
			t.eq(d.boxCount, 2)
		end)
		t.test("randomized coverage invariant and fewer boxes than visible cells", function()
			local seed = 4242
			local function rnd(n)
				seed = (seed * 1103515245 + 12345) % 2147483648
				return (seed // 65536) % n
			end
			for trial = 1, 3 do
				local w = newWorld()
				for z = -16, 31 do
					for x = -16, 31 do
						local h = 10 + rnd(4)
						for y = 0, h do
							World.setState(w, x, y, z, if y == h then B.GRASS * 16 elseif rnd(10) == 0 then GLASS else STONE)
						end
					end
				end
				local d = BoxMesher.mesh(src(w, STONE), 0, 0, 0)
				check(t, w, 0, 0, 0, d)
				local q = SectionMesher.mesh(src(w, STONE), 0, 0, 0)
				t.truthy(d.boxCount < d.coveredCells, "trial " .. trial .. " should merge")
				t.truthy(q.visibleFaces > 0)
			end
		end)
	end)
end
