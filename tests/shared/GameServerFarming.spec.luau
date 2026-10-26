local GameServer = require("../../src/shared/Sim/GameServer")
local Protocol = require("../../src/shared/Net/Protocol")
local World = require("../../src/shared/Voxel/World")
local Inventory = require("../../src/shared/Items/Inventory")
local ItemStack = require("../../src/shared/Items/ItemStack")
local B = require("../../src/shared/Blocks/BlockRegistry")

local C = Protocol.C2S

local function setup()
	local gs = GameServer.new({ seed = "farm", viewRadius = 2, genBudget = 50, sendBudget = 50, sendBytesPerSecond = 1e9, mobs = false })
	local p = GameServer.addPlayer(gs, 1, "a")
	GameServer.tick(gs)
	gs.randomTickRadius = -1 -- deterministic: no random ticks during these tests
	for x = -4, 4 do
		for z = -4, 4 do
			World.setState(gs.world, x, 79, z, B.STONE * 16)
			World.setState(gs.world, x, 80, z, B.DIRT * 16)
			for y = 81, 86 do
				World.setState(gs.world, x, y, z, 0)
			end
		end
	end
	GameServer.teleport(gs, 1, 0.5, 81, 0.5)
	GameServer.tick(gs)
	return gs, p
end

local function hold(p, id, count, meta)
	p.inventory.slots[1] = ItemStack.new(id, count or 1, meta)
	p.inventory.selected = 1
end

return function(t)
	t.describe("GameServer farming & items", function()
		t.test("hoe tills, seeds plant, mature wheat drops wheat", function()
			local gs, p = setup()
			hold(p, 290) -- wooden hoe
			GameServer.handle(gs, 1, C.PLACE, { 2, 80, 0, 2 })
			t.eq(World.getId(gs.world, 2, 80, 0), 60)
			t.eq(p.inventory.slots[1].damage, 1)
			hold(p, 295, 3)
			GameServer.handle(gs, 1, C.PLACE, { 2, 80, 0, 2 })
			t.eq(World.getId(gs.world, 2, 81, 0), 59)
			t.eq(p.inventory.slots[1].count, 2)
			GameServer.handle(gs, 1, C.PLACE, { 1, 80, 0, 2 }) -- seeds on plain dirt: rejected
			t.eq(World.getId(gs.world, 1, 81, 0), 0)
			World.setState(gs.world, 2, 81, 0, 59 * 16 + 7)
			p.gamemode = "creative"
			p.gamemode = "survival"
			GameServer.handle(gs, 1, C.START_BREAK, { 2, 81, 0 }) -- crops break instantly
			local wheat = 0
			for _, e in gs.items.list do
				if e.stack.id == 296 then
					wheat += e.stack.count
				end
			end
			t.eq(wheat, 1)
		end)
		t.test("removing farmland's support pops the crop", function()
			local gs, p = setup()
			World.setState(gs.world, 2, 80, 0, 60 * 16)
			World.setState(gs.world, 2, 81, 0, 59 * 16)
			p.gamemode = "creative"
			GameServer.handle(gs, 1, C.START_BREAK, { 2, 80, 0 })
			t.eq(World.getId(gs.world, 2, 81, 0), 0)
		end)
		t.test("buckets scoop and place water", function()
			local gs, p = setup()
			World.setState(gs.world, 2, 81, 0, 9 * 16)
			hold(p, 325)
			GameServer.handle(gs, 1, C.PLACE, { 2, 81, 0, 2 })
			t.eq(World.getId(gs.world, 2, 81, 0), 0)
			t.eq(p.inventory.slots[1].id, 326)
			GameServer.handle(gs, 1, C.PLACE, { -2, 80, 0, 2 })
			t.eq(World.getState(gs.world, -2, 81, 0), 9 * 16)
			t.eq(p.inventory.slots[1].id, 325)
			for _ = 1, 20 do
				GameServer.tick(gs)
			end
			t.eq(World.getId(gs.world, -3, 81, 0), 8, "placed water flows")
		end)
		t.test("torches attach to the clicked face; bottom faces are rejected", function()
			local gs, p = setup()
			World.setState(gs.world, 2, 81, 0, B.STONE * 16)
			hold(p, 50, 4)
			GameServer.handle(gs, 1, C.PLACE, { 2, 81, 0, 1 }) -- west face -> torch at x=1 attached to +x
			t.eq(World.getState(gs.world, 1, 81, 0), 50 * 16 + 2)
			GameServer.handle(gs, 1, C.PLACE, { 2, 81, 0, 2 }) -- top face -> floor torch
			t.eq(World.getState(gs.world, 2, 82, 0), 50 * 16 + 5)
			World.setState(gs.world, 0, 84, 2, B.STONE * 16)
			GameServer.handle(gs, 1, C.PLACE, { 0, 84, 2, 3 })
			t.eq(World.getId(gs.world, 0, 83, 2), 0)
			-- breaking the wall drops the wall torch
			p.gamemode = "creative"
			GameServer.handle(gs, 1, C.START_BREAK, { 2, 81, 0 })
			t.eq(World.getId(gs.world, 1, 81, 0), 0)
			t.eq(World.getId(gs.world, 2, 82, 0), 0, "floor torch on top popped too")
		end)
		t.test("player-placed leaves never decay", function()
			local gs, p = setup()
			hold(p, 18, 1, 0)
			GameServer.handle(gs, 1, C.PLACE, { 2, 80, 0, 2 })
			t.eq(World.getState(gs.world, 2, 81, 0), 18 * 16 + 4)
			local BlockUpdates = require("../../src/shared/Sim/BlockUpdates")
			for _ = 1, 10 do
				BlockUpdates.randomTick(gs.updates, 2, 81, 0)
			end
			t.eq(World.getId(gs.world, 2, 81, 0), 18)
			local _ = Inventory
		end)
	end)
end
