local World = require("../../src/shared/Voxel/World")
local Chunk = require("../../src/shared/Voxel/Chunk")
local B = require("../../src/shared/Blocks/BlockRegistry")
local SectionMesher = require("../../src/shared/Mesh/SectionMesher")
local Faces = require("../../src/shared/Mesh/Faces")

local S = SectionMesher.QUAD_STRIDE
local STONE, GLASS, WATER, FWATER, LEAVES = B.STONE * 16, B.GLASS * 16, B.WATER * 16, B.FLOWING_WATER * 16, B.LEAVES * 16

-- Source where everything not in `chunks` is air (missing = 0).
local function airSource(world)
	return {
		getChunk = function(cx, cz)
			return World.getChunk(world, cx, cz)
		end,
		missingState = function()
			return 0
		end,
	}
end

local function newWorld()
	local w = World.new(1024)
	for cx = -2, 1 do
		for cz = -2, 1 do
			World.putChunk(w, Chunk.new(cx, cz))
		end
	end
	return w
end

-- Expand quads into a set of unit faces "x,y,z,face" in world coordinates.
local function expand(mesh, cx, cz, si)
	local set, n = {}, 0
	for q = 0, mesh.quadCount - 1 do
		local o = q * S
		local face, nn, u, v, w, h = mesh.quads[o + 1], mesh.quads[o + 2], mesh.quads[o + 3], mesh.quads[o + 4], mesh.quads[o + 5], mesh.quads[o + 6]
		for du = 0, w - 1 do
			for dv = 0, h - 1 do
				local x, y, z
				if face <= 1 then
					x, z, y = nn, u + du, v + dv
				elseif face <= 3 then
					y, x, z = nn, u + du, v + dv
				else
					z, x, y = nn, u + du, v + dv
				end
				local key = string.format("%d,%d,%d,%d", cx * 16 + x, si * 16 + y, cz * 16 + z, face)
				assert(not set[key], "face covered twice: " .. key)
				set[key] = true
				n += 1
			end
		end
	end
	return set, n
end

-- Brute-force reference visibility using only World.getState + simple rules.
local function reference(w, cx, cz, si)
	local set, n = {}, 0
	for y = si * 16, si * 16 + 15 do
		for z = cz * 16, cz * 16 + 15 do
			for x = cx * 16, cx * 16 + 15 do
				local id = World.getId(w, x, y, z)
				if id ~= 0 and (B.isFullCube(id) or B.isLiquid(id)) then
					for f = 0, 5 do
						local ny = y + Faces.DY[f]
						local nid = if ny < 0 then B.BEDROCK else World.getId(w, x + Faces.DX[f], ny, z + Faces.DZ[f])
						local hidden = B.occludes(nid)
						if not hidden and nid == id and (id == B.GLASS or id == B.WATER) then
							hidden = true
						end
						if not hidden and B.isLiquid(id) and B.fluidGroup(id) == B.fluidGroup(nid) then
							hidden = true
						end
						if not hidden then
							set[string.format("%d,%d,%d,%d", x, y, z, f)] = true
							n += 1
						end
					end
				end
			end
		end
	end
	return set, n
end

return function(t)
	t.describe("SectionMesher", function()
		t.test("single block emits six unit quads", function()
			local w = newWorld()
			World.setState(w, 3, 20, 4, STONE)
			local m = SectionMesher.mesh(airSource(w), 0, 0, 1)
			t.eq(m.quadCount, 6)
			t.eq(m.visibleFaces, 6)
			for q = 0, 5 do
				t.eq(m.quads[q * S + 5], 1)
				t.eq(m.quads[q * S + 6], 1)
			end
		end)
		t.test("two adjacent blocks merge greedily", function()
			local w = newWorld()
			World.setState(w, 3, 20, 4, STONE)
			World.setState(w, 4, 20, 4, STONE)
			local m = SectionMesher.mesh(airSource(w), 0, 0, 1)
			t.eq(m.visibleFaces, 10)
			t.eq(m.quadCount, 6)
			local g = SectionMesher.mesh(airSource(w), 0, 0, 1, false)
			t.eq(g.quadCount, 10)
		end)
		t.test("filled section only shows its exposed top", function()
			local w = newWorld()
			for y = 0, 15 do
				for z = 0, 15 do
					for x = 0, 15 do
						World.setState(w, x, y, z, STONE)
					end
				end
			end
			local src = airSource(w)
			src.missingState = function()
				return STONE
			end
			-- neighbours in the world are loaded but air -> sides visible
			local m = SectionMesher.mesh(src, 0, 0, 0)
			-- top 16x16 + four sides 16x16, bottom hidden by the world floor
			t.eq(m.visibleFaces, 256 * 5)
			t.eq(m.quadCount, 5)
		end)
		t.test("3D checkerboard: no merging possible", function()
			local w = newWorld()
			for y = 16, 31 do
				for z = 0, 15 do
					for x = 0, 15 do
						if (x + y + z) % 2 == 0 then
							World.setState(w, x, y, z, STONE)
						end
					end
				end
			end
			local m = SectionMesher.mesh(airSource(w), 0, 0, 1)
			t.eq(m.visibleFaces, 2048 * 6)
			t.eq(m.quadCount, 2048 * 6)
		end)
		t.test("transparent culling rules", function()
			local w = newWorld()
			World.setState(w, 1, 1, 1, GLASS)
			World.setState(w, 2, 1, 1, GLASS)
			local m = SectionMesher.mesh(airSource(w), 0, 0, 0)
			t.eq(m.visibleFaces, 12 - 2) -- the two shared glass-glass faces are culled
			local w2 = newWorld()
			World.setState(w2, 1, 1, 1, LEAVES)
			World.setState(w2, 2, 1, 1, LEAVES)
			t.eq(SectionMesher.mesh(airSource(w2), 0, 0, 0).visibleFaces, 12) -- fancy leaves keep inner faces
			local w3 = newWorld()
			World.setState(w3, 1, 1, 1, WATER)
			World.setState(w3, 2, 1, 1, FWATER)
			t.eq(SectionMesher.mesh(airSource(w3), 0, 0, 0).visibleFaces, 10)
			local w4 = newWorld()
			World.setState(w4, 1, 1, 1, STONE)
			World.setState(w4, 2, 1, 1, GLASS)
			-- stone shows face toward glass, glass hides face toward stone
			t.eq(SectionMesher.mesh(airSource(w4), 0, 0, 0).visibleFaces, 11)
		end)
		t.test("non-cubic blocks become specials and don't occlude", function()
			local w = newWorld()
			World.setState(w, 5, 5, 5, STONE)
			World.setState(w, 5, 6, 5, B.TALLGRASS * 16)
			local m = SectionMesher.mesh(airSource(w), 0, 0, 0)
			t.eq(m.specialCount, 1)
			t.eq(m.specials[4], B.TALLGRASS * 16)
			t.eq(m.visibleFaces, 6)
		end)
		t.test("faces across chunk boundary (negative chunk) are culled", function()
			local w = newWorld()
			World.setState(w, -1, 10, 3, STONE) -- chunk -1, local x=15
			World.setState(w, 0, 10, 3, STONE) -- chunk 0, local x=0
			local a = SectionMesher.mesh(airSource(w), -1, 0, 0)
			local b = SectionMesher.mesh(airSource(w), 0, 0, 0)
			t.eq(a.visibleFaces, 5)
			t.eq(b.visibleFaces, 5)
		end)
		t.test("randomized sections match brute-force reference", function()
			local seed = 777
			local function rnd(n)
				seed = (seed * 1103515245 + 12345) % 2147483648
				return (seed // 65536) % n
			end
			local palette = { STONE, STONE, GLASS, WATER, FWATER, LEAVES, B.DIRT * 16, B.TALLGRASS * 16 }
			for trial = 1, 4 do
				local w = newWorld()
				for _ = 1, 3000 do
					local x, y, z = rnd(48) - 32, rnd(40), rnd(48) - 32
					local s = if rnd(3) == 0 then 0 else palette[rnd(#palette) + 1]
					World.setState(w, x, y, z, s)
				end
				for _, c in { { -1, -1, 0 }, { 0, 0, 1 }, { -2, 0, 2 }, { 0, -1, 0 } } do
					local m = SectionMesher.mesh(airSource(w), c[1], c[2], c[3])
					local got, gn = expand(m, c[1], c[2], c[3])
					local ref, rn = reference(w, c[1], c[2], c[3])
					t.eq(gn, rn, "trial " .. trial .. " face count")
					t.eq(m.visibleFaces, rn)
					for k in ref do
						t.truthy(got[k], "missing face " .. k)
					end
					t.truthy(m.quadCount <= gn)
				end
			end
		end)
		t.test("quads carry the per-face texture (grass top vs side)", function()
			local TextureIndex = require("../../src/shared/Mesh/TextureIndex")
			local w = newWorld()
			World.setState(w, 0, 3, 0, B.GRASS * 16)
			local m = SectionMesher.mesh(airSource(w), 0, 0, 0)
			for q = 0, m.quadCount - 1 do
				local face, tex = m.quads[q * S + 1], m.quads[q * S + 7]
				local name = TextureIndex.name(tex)
				if face == 2 then
					t.eq(name, "grass_top")
				elseif face == 3 then
					t.eq(name, "dirt")
				else
					t.eq(name, "grass_side")
				end
				t.eq(m.quads[q * S + 8], B.LAYER_OPAQUE)
			end
		end)
	end)
end
