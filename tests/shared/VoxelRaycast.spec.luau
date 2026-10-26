local Raycast = require("../../src/shared/Physics/VoxelRaycast")

local function world(blocks)
	return function(x, y, z)
		return blocks[x .. "," .. y .. "," .. z] or 0
	end
end
local function solid(s)
	return s ~= 0
end

return function(t)
	t.describe("VoxelRaycast", function()
		t.test("hits along +X and reports entry face", function()
			local g = world({ ["5,0,0"] = 16 })
			local h = Raycast.cast(g, 0.5, 0.5, 0.5, 1, 0, 0, 10, solid)
			t.truthy(h)
			t.eq(h.x, 5); t.eq(h.face, 1); t.near(h.distance, 4.5, 1e-9)
		end)
		t.test("negative directions and negative coordinates", function()
			local g = world({ ["-3,-1,-7"] = 16 })
			local h = Raycast.cast(g, -1.5, -0.5, -6.5, 1, 0, 0, 10, solid)
			t.eq(h, nil) -- pointing away
			local h2 = Raycast.cast(g, -2.5, 3.5, -6.5, -0.5, -4, -0.5, 10, solid)
			t.truthy(h2)
			t.eq(h2.x, -3); t.eq(h2.y, -1); t.eq(h2.z, -7); t.eq(h2.face, 2)
		end)
		t.test("respects max distance", function()
			local g = world({ ["0,0,6"] = 16 })
			t.eq(Raycast.cast(g, 0.5, 0.5, 0.5, 0, 0, 1, 5, solid), nil)
			t.truthy(Raycast.cast(g, 0.5, 0.5, 0.5, 0, 0, 1, 5.6, solid))
		end)
		t.test("traversal visits every voxel the segment crosses (vs dense sampling)", function()
			local seed = 99
			local function rnd()
				seed = (seed * 1103515245 + 12345) % 2147483648
				return seed / 2147483648
			end
			for _ = 1, 200 do
				local ox, oy, oz = rnd() * 20 - 10, rnd() * 20 - 10, rnd() * 20 - 10
				local dx, dy, dz = rnd() - 0.5, rnd() - 0.5, rnd() - 0.5
				local visited = {}
				Raycast.cast(function(x, y, z)
					visited[x .. "," .. y .. "," .. z] = true
					return 0
				end, ox, oy, oz, dx, dy, dz, 8, solid)
				local l = math.sqrt(dx * dx + dy * dy + dz * dz)
				for i = 0, 7900 do
					local s = i / 1000
					-- skip samples within epsilon of a voxel boundary
					local px, py, pz = ox + dx / l * s, oy + dy / l * s, oz + dz / l * s
					local fx, fy, fz = px - math.floor(px), py - math.floor(py), pz - math.floor(pz)
					if fx > 1e-6 and fx < 1 - 1e-6 and fy > 1e-6 and fy < 1 - 1e-6 and fz > 1e-6 and fz < 1 - 1e-6 then
						t.truthy(visited[math.floor(px) .. "," .. math.floor(py) .. "," .. math.floor(pz)], "missed voxel")
					end
				end
			end
		end)
		t.test("origin inside a block hits it with face -1", function()
			local g = world({ ["0,0,0"] = 16 })
			local h = Raycast.cast(g, 0.5, 0.5, 0.5, 0, 1, 0, 5, solid)
			t.eq(h.face, -1)
		end)
	end)
end
