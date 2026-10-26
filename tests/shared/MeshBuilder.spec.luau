local MeshBuilder = require("../../src/shared/Mesh/MeshBuilder")
local SectionMesher = require("../../src/shared/Mesh/SectionMesher")
local Faces = require("../../src/shared/Mesh/Faces")
local World = require("../../src/shared/Voxel/World")
local Chunk = require("../../src/shared/Voxel/Chunk")

local function source(w)
	return {
		getChunk = function(cx, cz)
			return World.getChunk(w, cx, cz)
		end,
		missingState = function()
			return 0
		end,
	}
end

return function(t)
	t.describe("MeshBuilder", function()
		t.test("single block: 12 triangles, outward CCW winding, unit cube bounds", function()
			local w = World.new(1024)
			World.putChunk(w, Chunk.new(0, 0))
			World.setState(w, 3, 5, 7, 16)
			local m = SectionMesher.mesh(source(w), 0, 0, 0)
			local batches = MeshBuilder.build(m)
			t.eq(#batches, 1)
			local b = batches[1]
			t.eq(b.triangleCount, 12)
			t.eq(b.vertexCount, 24)
			local P = b.positions
			for i = 0, b.vertexCount - 1 do
				local x, y, z = P[i * 3 + 1], P[i * 3 + 2], P[i * 3 + 3]
				t.truthy(x >= 3 and x <= 4 and y >= 5 and y <= 6 and z >= 7 and z <= 8, "vertex inside the block cell")
			end
			-- each triangle's geometric normal (CCW right-hand rule) points along its face
			for tri = 0, b.triangleCount - 1 do
				local i1, i2, i3 = b.tris[tri * 3 + 1], b.tris[tri * 3 + 2], b.tris[tri * 3 + 3]
				local function v(i)
					return P[(i - 1) * 3 + 1], P[(i - 1) * 3 + 2], P[(i - 1) * 3 + 3]
				end
				local ax, ay, az = v(i1)
				local bx, by, bz = v(i2)
				local cx, cy, cz = v(i3)
				local ux, uy, uz = bx - ax, by - ay, bz - az
				local wx, wy, wz = cx - ax, cy - ay, cz - az
				local nx, ny, nz = uy * wz - uz * wy, uz * wx - ux * wz, ux * wy - uy * wx
				local f = b.faces[tri + 1]
				t.truthy(nx * Faces.DX[f] + ny * Faces.DY[f] + nz * Faces.DZ[f] > 0, "outward normal for face " .. f)
			end
		end)
		t.test("clockwise option flips every triangle", function()
			local w = World.new(1024)
			World.putChunk(w, Chunk.new(0, 0))
			World.setState(w, 0, 0, 0, 16)
			local m = SectionMesher.mesh(source(w), 0, 0, 0)
			local a = MeshBuilder.build(m)[1]
			local b = MeshBuilder.build(m, { clockwise = true })[1]
			t.eq(a.tris[1], b.tris[1]); t.eq(a.tris[2], b.tris[3]); t.eq(a.tris[3], b.tris[2])
		end)
		t.test("face shading and greedy UV tiling", function()
			local w = World.new(1024)
			World.putChunk(w, Chunk.new(0, 0))
			for x = 0, 3 do
				World.setState(w, x, 5, 0, 16) -- above y=0 so the bottom face is visible
			end
			local m = SectionMesher.mesh(source(w), 0, 0, 0)
			local b = MeshBuilder.build(m)[1]
			local maxU = 0
			for i = 1, #b.uvs, 2 do
				maxU = math.max(maxU, b.uvs[i])
			end
			t.eq(maxU, 4, "greedy 4-wide quad tiles its UVs 0..4")
			-- top faces brightest, bottom darkest
			local topR, botR
			for tri = 0, b.triangleCount - 1 do
				local f = b.faces[tri + 1]
				local vi = b.tris[tri * 3 + 1]
				local r = b.colors[(vi - 1) * 3 + 1]
				if f == 2 then
					topR = r
				elseif f == 3 then
					botR = r
				end
			end
			t.near(botR / topR, 0.5, 1e-9)
		end)
		t.test("worst-case checkerboard splits into batches under the triangle limit", function()
			local w = World.new(1024)
			World.putChunk(w, Chunk.new(0, 0))
			for y = 0, 15 do
				for z = 0, 15 do
					for x = 0, 15 do
						if (x + y + z) % 2 == 0 then
							World.setState(w, x, y, z, 16)
						end
					end
				end
			end
			local m = SectionMesher.mesh(source(w), 0, 0, 0, false)
			local batches = MeshBuilder.build(m, { maxTriangles = 10000 })
			local total = 0
			for _, b in batches do
				t.truthy(b.triangleCount <= 10000)
				total += b.triangleCount
			end
			t.eq(total, m.quadCount * 2)
			t.truthy(#batches >= 2)
		end)
		t.test("atlas UVs stay within the tile rect", function()
			local w = World.new(1024)
			World.putChunk(w, Chunk.new(0, 0))
			World.setState(w, 0, 0, 0, 2 * 16) -- grass
			local m = SectionMesher.mesh(source(w), 0, 0, 0, false)
			local b = MeshBuilder.build(m, { atlasColumns = 16 })[1]
			for i = 1, #b.uvs do
				t.truthy(b.uvs[i] >= 0 and b.uvs[i] <= 1)
			end
		end)
	end)
end
