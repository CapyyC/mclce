local CaveCarver = require("../../src/shared/WorldGen/CaveCarver")
local WorldSeed = require("../../src/shared/WorldGen/WorldSeed")
local Chunk = require("../../src/shared/Voxel/Chunk")

local function stoneChunk(cx, cz)
	local c = Chunk.new(cx, cz)
	for y = 1, 120 do
		for z = 0, 15 do
			for x = 0, 15 do
				Chunk.setState(c, x, y, z, 16, false)
			end
		end
	end
	return c
end

return function(t)
	t.describe("CaveCarver", function()
		local seed = WorldSeed.fromNumber(424242)
		t.test("blob lists are pure functions of (seed, source chunk)", function()
			local a, b = CaveCarver.new(seed, 4), CaveCarver.new(seed)
			for sx = -3, 3 do
				CaveCarver.blobsFor(b, sx, 0)
			end
			for sx = 3, -3, -1 do
				t.deepEq(CaveCarver.blobsFor(a, sx, 0), CaveCarver.blobsFor(b, sx, 0))
			end
		end)
		t.test("carving matches a brute-force union of all blobs (seamless)", function()
			local carver = CaveCarver.new(seed)
			local carvedTotal = 0
			for cx = -1, 0 do
				for cz = 0, 0 do
					local c = stoneChunk(cx, cz)
					CaveCarver.carve(carver, c)
					-- collect blobs from all sources in range
					local blobs = {}
					for sz = cz - CaveCarver.RADIUS, cz + CaveCarver.RADIUS do
						for sx = cx - CaveCarver.RADIUS, cx + CaveCarver.RADIUS do
							for _, v in CaveCarver.blobsFor(carver, sx, sz) do
								table.insert(blobs, v)
							end
						end
					end
					for y = 1, 120 do
						for z = 0, 15 do
							for x = 0, 15 do
								local wx, wz = cx * 16 + x + 0.5, cz * 16 + z + 0.5
								local inside = false
								for i = 1, #blobs, 5 do
									local bx, by, bz, rh, rv = blobs[i], blobs[i + 1], blobs[i + 2], blobs[i + 3], blobs[i + 4]
									local dx, dy, dz = (wx - bx) / rh, (y + 0.5 - by) / rv, (wz - bz) / rh
									if dy > -0.7 and dx * dx + dy * dy + dz * dz < 1 and y <= 250 and y >= 1 then
										inside = true
										break
									end
								end
								local st = Chunk.getState(c, x, y, z)
								local carved = st ~= 16
								if carved then
									carvedTotal += 1
								end
								t.eq(carved, inside, string.format("cell %d,%d,%d", cx * 16 + x, y, cz * 16 + z))
								if carved then
									t.eq(st, if y < 11 then 176 else 0)
								end
							end
						end
					end
				end
			end
			t.truthy(carvedTotal > 0, "seed should produce some caves in a 2x2 area")
		end)
	end)
end
