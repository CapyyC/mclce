local GameServer = require("../../src/shared/Sim/GameServer")
local Protocol = require("../../src/shared/Net/Protocol")
local World = require("../../src/shared/Voxel/World")
local ItemStack = require("../../src/shared/Items/ItemStack")
local B = require("../../src/shared/Blocks/BlockRegistry")
local Collision = require("../../src/shared/Physics/Collision")

local C = Protocol.C2S

local function setup()
	local gs = GameServer.new({ seed = "redstone", viewRadius = 2, genBudget = 50, sendBudget = 50, sendBytesPerSecond = 1e9, mobs = false })
	local p = GameServer.addPlayer(gs, 1, "a")
	GameServer.tick(gs)
	gs.randomTickRadius = -1
	for x = -5, 5 do
		for z = -5, 5 do
			World.setState(gs.world, x, 80, z, B.STONE * 16)
			for y = 81, 86 do
				World.setState(gs.world, x, y, z, 0)
			end
		end
	end
	GameServer.teleport(gs, 1, 0.5, 81, 0.5)
	GameServer.tick(gs)
	p.gamemode = "creative"
	return gs, p
end

local function hold(p, id, n)
	p.inventory.slots[1] = ItemStack.new(id, n or 64)
	p.inventory.selected = 1
end

return function(t)
	t.describe("GameServer redstone", function()
		t.test("player builds lever -> wire -> lamp and toggles it", function()
			local gs, p = setup()
			hold(p, 69)
			GameServer.handle(gs, 1, C.PLACE, { 2, 80, 0, 2 }) -- lever on the floor
			t.eq(World.getState(gs.world, 2, 81, 0), 69 * 16 + 5)
			hold(p, 331)
			GameServer.handle(gs, 1, C.PLACE, { 3, 80, 0, 2 })
			GameServer.handle(gs, 1, C.PLACE, { 4, 80, 0, 2 })
			t.eq(World.getId(gs.world, 3, 81, 0), 55)
			hold(p, 123)
			GameServer.handle(gs, 1, C.PLACE, { 4, 80, 1, 2 }) -- lamp beside the wire end... next to (4,81,0)
			World.setState(gs.world, 5, 81, 0, 123 * 16) -- lamp in line with the wire
			GameServer.tick(gs)
			GameServer.handle(gs, 1, C.PLACE, { 2, 81, 0, 2 }) -- use the lever
			for _ = 1, 3 do
				GameServer.tick(gs)
			end
			t.eq(World.getState(gs.world, 3, 81, 0) % 16, 15)
			t.eq(World.getId(gs.world, 5, 81, 0), 124, "lamp lit")
		end)
		t.test("doors: placing makes two halves, using toggles, breaking removes both", function()
			local gs, p = setup()
			hold(p, 324, 1)
			GameServer.handle(gs, 1, C.PLACE, { 2, 80, 0, 2 })
			t.eq(World.getId(gs.world, 2, 81, 0), 64)
			t.eq(World.getState(gs.world, 2, 82, 0), 64 * 16 + 8)
			local closed = Collision.solidHeight(World.getState(gs.world, 2, 81, 0))
			t.eq(closed, 1)
			GameServer.handle(gs, 1, C.PLACE, { 2, 82, 0, 1 }) -- use via the upper half
			t.truthy(World.getState(gs.world, 2, 81, 0) % 16 >= 4, "opened")
			t.eq(Collision.solidHeight(World.getState(gs.world, 2, 81, 0)), 0)
			GameServer.handle(gs, 1, C.START_BREAK, { 2, 81, 0 })
			t.eq(World.getId(gs.world, 2, 82, 0), 0, "upper half removed with the lower")
		end)
		t.test("standing on a pressure plate powers wire; stepping off releases", function()
			local gs, p = setup()
			World.setState(gs.world, 2, 81, 0, 70 * 16)
			World.setState(gs.world, 3, 81, 0, 55 * 16)
			GameServer.setPlayerPosition(gs, 1, 2.5, 81, 0.5)
			for _ = 1, 3 do
				GameServer.tick(gs)
			end
			t.eq(World.getState(gs.world, 3, 81, 0) % 16, 15)
			GameServer.setPlayerPosition(gs, 1, -2.5, 81, 0.5)
			for _ = 1, 3 do
				GameServer.tick(gs)
			end
			t.eq(World.getState(gs.world, 3, 81, 0) % 16, 0)
			local _ = p
		end)
		t.test("wire pops when its floor is removed", function()
			local gs = setup()
			World.setState(gs.world, 2, 81, 0, 55 * 16)
			World.setState(gs.world, 2, 80, 0, 0)
			t.eq(World.getId(gs.world, 2, 81, 0), 0)
		end)
	end)
end
