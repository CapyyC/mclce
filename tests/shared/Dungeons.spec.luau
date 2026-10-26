local WorldGenerator = require("../../src/shared/WorldGen/WorldGenerator")
local WorldSeed = require("../../src/shared/WorldGen/WorldSeed")
local Dungeons = require("../../src/shared/WorldGen/Dungeons")
local Chunk = require("../../src/shared/Voxel/Chunk")

return function(t)
	t.describe("Dungeons", function()
		local seed = WorldSeed.fromNumber(31337)
		local g = WorldGenerator.new(seed)
		local function getBase(cx, cz)
			return WorldGenerator.getBase(g, cx, cz)
		end
		-- find some rooms in a 10x10 area
		local rooms = {}
		for sx = -5, 4 do
			for sz = -5, 4 do
				for _, r in Dungeons.rooms(seed, sx, sz, getBase) do
					table.insert(rooms, { r, sx, sz })
				end
			end
		end
		t.test("rooms occur at a plausible rate", function()
			-- rooms need cave openings; our approximate caves make them rarer than classic
			t.truthy(#rooms >= 1 and #rooms <= 60, "rooms in 100 chunks: " .. #rooms)
		end)
		t.test("a generated room has a spawner entity, mossy floor and air inside", function()
			local r = rooms[1][1]
			local c = WorldGenerator.generate(g, r.x // 16, r.z // 16)
			local lx, lz = r.x % 16, r.z % 16
			t.eq(Chunk.getId(c, lx, r.y, lz), 52)
			local e = c.blockEntities[lx + lz * 16 + r.y * 256]
			t.truthy(e and string.sub(e.kind, 1, 8) == "spawner:", "spawner entity")
			local floor = Chunk.getId(c, lx, r.y - 1, lz)
			t.truthy(floor == 4 or floor == 48)
			t.eq(Chunk.getId(c, lx, r.y + 2, lz), 0)
		end)
		t.test("rooms spanning chunk borders are identical regardless of generation order", function()
			-- pick a room touching a border
			local pick
			for _, entry in rooms do
				local r = entry[1]
				if (r.x - r.rx - 1) // 16 ~= (r.x + r.rx + 1) // 16 then
					pick = r
					break
				end
			end
			t.truthy(pick, "found a border room")
			local cxa, cxb = (pick.x - pick.rx - 1) // 16, (pick.x + pick.rx + 1) // 16
			local cz = pick.z // 16
			local g1, g2 = WorldGenerator.new(seed, { cacheCapacity = 4 }), WorldGenerator.new(seed)
			local a1 = WorldGenerator.generate(g1, cxa, cz)
			local b1 = WorldGenerator.generate(g1, cxb, cz)
			local b2 = WorldGenerator.generate(g2, cxb, cz)
			local a2 = WorldGenerator.generate(g2, cxa, cz)
			for y = pick.y - 1, pick.y + 4 do
				for z = 0, 15 do
					for x = 0, 15 do
						t.eq(Chunk.getState(a1, x, y, z), Chunk.getState(a2, x, y, z))
						t.eq(Chunk.getState(b1, x, y, z), Chunk.getState(b2, x, y, z))
					end
				end
			end
		end)
		t.test("chests contain loot", function()
			local found = 0
			for _, entry in rooms do
				local r = entry[1]
				for _, c in { WorldGenerator.generate(g, (r.x - 5) // 16, r.z // 16), WorldGenerator.generate(g, (r.x + 5) // 16, r.z // 16), WorldGenerator.generate(g, r.x // 16, (r.z - 5) // 16), WorldGenerator.generate(g, r.x // 16, (r.z + 5) // 16) } do
					for _, e in c.blockEntities or {} do
						if e.kind == "chest" then
							local n = 0
							for _ in e.slots do
								n += 1
							end
							if n > 0 then
								found += 1
							end
						end
					end
				end
			end
			t.truthy(found >= 1, "loot chests " .. found)
		end)
	end)
end
