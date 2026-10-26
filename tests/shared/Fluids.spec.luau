local Fluids = require("../../src/shared/Sim/Fluids")
local World = require("../../src/shared/Voxel/World")
local Chunk = require("../../src/shared/Voxel/Chunk")

local STONE, WATER, LAVA = 16, 9 * 16, 11 * 16

-- flat stone floor at y=10 over a 3x3 chunk area
local function setup()
	local w = World.new(1024)
	for cx = -1, 1 do
		for cz = -1, 1 do
			World.putChunk(w, Chunk.new(cx, cz))
		end
	end
	for x = -16, 31 do
		for z = -16, 31 do
			World.setState(w, x, 10, z, STONE)
		end
	end
	local f = Fluids.new(w)
	return w, f
end

local function run(f, ticks)
	for _ = 1, ticks do
		Fluids.step(f)
	end
end

local function waterCells(w, y)
	local n = 0
	for x = -16, 31 do
		for z = -16, 31 do
			if Fluids.kindOf(World.getId(w, x, y, z)) == "water" then
				n += 1
			end
		end
	end
	return n
end

return function(t)
	t.describe("Fluids", function()
		t.test("water source spreads 7 blocks on a flat floor (diamond shape)", function()
			local w, f = setup()
			World.setState(w, 8, 11, 8, WATER)
			run(f, 200)
			-- level k at Manhattan distance k: 1 + 4*(1+..+7) = 113 cells
			t.eq(waterCells(w, 11), 113)
			t.eq(World.getState(w, 8 + 3, 11, 8), 8 * 16 + 3)
			t.eq(World.getId(w, 8 + 8, 11, 8), 0)
			t.eq(World.getState(w, 8 + 7, 11, 8), 8 * 16 + 7)
			t.eq(Fluids.pending(f), 0, "settles")
		end)
		t.test("removing the source drains the flow", function()
			local w, f = setup()
			World.setState(w, 8, 11, 8, WATER)
			run(f, 200)
			World.setState(w, 8, 11, 8, 0)
			run(f, 400)
			t.eq(waterCells(w, 11), 0)
		end)
		t.test("water falls first and then spreads at the bottom", function()
			local w, f = setup()
			World.setState(w, 8, 20, 8, STONE)
			World.setState(w, 8, 21, 8, WATER)
			run(f, 300)
			-- falls off the pillar edges: column of falling water down to y=11
			local falling = 0
			for y = 11, 20 do
				local s = World.getState(w, 9, y, 8)
				if Fluids.kindOf(s // 16) == "water" and s % 16 >= 8 then
					falling += 1
				end
			end
			t.truthy(falling >= 8, "falling column " .. falling)
			t.truthy(waterCells(w, 11) > 20)
		end)
		t.test("infinite water: a 2x1 pool between sources refills", function()
			local w, f = setup()
			-- trench walls
			for x = 0, 4 do
				World.setState(w, x, 11, -1, STONE)
				World.setState(w, x, 11, 1, STONE)
			end
			World.setState(w, -1, 11, 0, STONE)
			World.setState(w, 3, 11, 0, STONE)
			World.setState(w, 0, 11, 0, WATER)
			World.setState(w, 2, 11, 0, WATER)
			run(f, 50)
			t.eq(World.getState(w, 1, 11, 0), WATER, "middle became a source")
		end)
		t.test("lava spreads ~3 blocks and slower", function()
			local w, f = setup()
			World.setState(w, 8, 11, 8, LAVA)
			run(f, 29)
			t.eq(World.getId(w, 9, 11, 8), 0, "lava waits 30 ticks")
			run(f, 400)
			t.eq(World.getState(w, 9, 11, 8), 10 * 16 + 2)
			t.eq(World.getState(w, 11, 11, 8), 10 * 16 + 6)
			t.eq(World.getId(w, 12, 11, 8), 0)
		end)
		t.test("water meeting lava makes obsidian / cobblestone", function()
			local w, f = setup()
			World.setState(w, 0, 11, 0, LAVA)
			World.setState(w, 4, 11, 0, WATER)
			run(f, 400)
			local obs, cob = 0, 0
			for x = -10, 15 do
				for z = -10, 10 do
					local id = World.getId(w, x, 11, z)
					if id == 49 then
						obs += 1
					elseif id == 4 then
						cob += 1
					end
				end
			end
			t.truthy(obs + cob >= 1, "obsidian " .. obs .. " cobble " .. cob)
		end)
		t.test("flow prefers the direction of a nearby hole", function()
			local w, f = setup()
			World.setState(w, 10, 10, 8, 0) -- hole 2 blocks east of the source
			World.setState(w, 8, 11, 8, WATER)
			run(f, 10)
			t.truthy(Fluids.kindOf(World.getId(w, 9, 11, 8)) == "water", "flows east")
			t.eq(World.getId(w, 7, 11, 8), 0, "not west")
		end)
		t.test("deterministic across identical runs", function()
			local function sim(budget)
				local w = World.new(1024)
				for cx = -1, 1 do
					for cz = -1, 1 do
						World.putChunk(w, Chunk.new(cx, cz))
					end
				end
				for x = -16, 31 do
					for z = -16, 31 do
						World.setState(w, x, 10, z, STONE)
					end
				end
				local f = Fluids.new(w, budget)
				World.setState(w, 0, 11, 0, WATER)
				World.setState(w, 6, 11, 3, WATER)
				World.setState(w, 3, 10, 9, 0)
				run(f, 600)
				local h = 0
				for x = -16, 31 do
					for z = -16, 31 do
						for y = 9, 11 do
							h = (h * 31 + World.getState(w, x, y, z)) % 2147483647
						end
					end
				end
				return h
			end
			t.eq(sim(1024), sim(1024))
		end)
	end)
end
