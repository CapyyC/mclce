local WorldGenerator = require("../../src/shared/WorldGen/WorldGenerator")
local WorldSeed = require("../../src/shared/WorldGen/WorldSeed")
local Chunk = require("../../src/shared/Voxel/Chunk")

return function(t)
	t.describe("Nether generation", function()
		local seed = WorldSeed.fromNumber(666)
		local g = WorldGenerator.new(seed, { dimension = "nether" })
		t.test("bedrock floor and ceiling, nothing above y=127", function()
			local c = WorldGenerator.generate(g, 0, 0)
			for z = 0, 15 do
				for x = 0, 15 do
					t.eq(Chunk.getId(c, x, 0, z), 7)
					t.eq(Chunk.getId(c, x, 127, z), 7)
					t.eq(Chunk.height(c, x, z), 128)
				end
			end
		end)
		t.test("netherrack caverns with a lava sea, glowstone and quartz appear", function()
			local counts = {}
			for cx = -2, 1 do
				for cz = -2, 1 do
					local c = WorldGenerator.generate(g, cx, cz)
					for y = 1, 126 do
						for z = 0, 15 do
							for x = 0, 15 do
								local id = Chunk.getId(c, x, y, z)
								counts[id] = (counts[id] or 0) + 1
								if id == 0 then
									t.truthy(y > 31, "air below the lava sea at y=" .. y)
								end
							end
						end
					end
				end
			end
			t.truthy((counts[87] or 0) > (counts[0] or 0) * 0.3, "mostly netherrack")
			t.truthy((counts[0] or 0) > 10000, "open caverns")
			t.truthy((counts[11] or 0) > 500, "lava sea")
			t.truthy((counts[153] or 0) > 10, "quartz")
			t.truthy((counts[89] or 0) + (counts[88] or 0) > 0, "glowstone or soul sand")
		end)
		t.test("deterministic per seed and chunk", function()
			local g2 = WorldGenerator.new(seed, { dimension = "nether" })
			local a, b = WorldGenerator.generate(g, 3, -4), WorldGenerator.generate(g2, 3, -4)
			for y = 0, 127, 3 do
				for x = 0, 15 do
					t.eq(Chunk.getState(a, x, y, 7), Chunk.getState(b, x, y, 7))
				end
			end
		end)
	end)
end
