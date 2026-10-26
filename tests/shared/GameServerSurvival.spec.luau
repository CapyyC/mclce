local GameServer = require("../../src/shared/Sim/GameServer")
local Protocol = require("../../src/shared/Net/Protocol")
local World = require("../../src/shared/Voxel/World")
local Inventory = require("../../src/shared/Items/Inventory")
local ItemStack = require("../../src/shared/Items/ItemStack")
local B = require("../../src/shared/Blocks/BlockRegistry")

local C, S = Protocol.C2S, Protocol.S2C

local function setup()
	local gs = GameServer.new({ seed = "survival", viewRadius = 1, genBudget = 50, sendBudget = 50, mobs = false })
	local p = GameServer.addPlayer(gs, 1, "a")
	GameServer.tick(gs)
	-- platform at y=80 around origin, clear sky above
	for x = -3, 3 do
		for z = -3, 3 do
			World.setState(gs.world, x, 80, z, B.STONE * 16)
			for y = 81, 120 do
				World.setState(gs.world, x, y, z, 0)
			end
		end
	end
	GameServer.teleport(gs, 1, 0.5, 81, 0.5)
	GameServer.tick(gs)
	GameServer.takeOutbox(gs, 1)
	return gs, p
end

local function has(box, kind)
	for _, m in box do
		if m.kind == kind then
			return m
		end
	end
	return nil
end

return function(t)
	t.describe("GameServer survival", function()
		t.test("falling 10 blocks deals 7 damage on landing", function()
			local gs, p = setup()
			for y = 91, 81, -1 do
				GameServer.setPlayerPosition(gs, 1, 0.5, y, 0.5)
				GameServer.tick(gs)
			end
			t.eq(p.vitals.health, 13)
			local m = has(GameServer.takeOutbox(gs, 1), S.PLAYER)
			t.truthy(m); t.eq(m.args[1].health, 13)
		end)
		t.test("creative players take no damage", function()
			local gs, p = setup()
			p.gamemode = "creative"
			for y = 111, 81, -1 do
				GameServer.setPlayerPosition(gs, 1, 0.5, y, 0.5)
				GameServer.tick(gs)
			end
			t.eq(p.vitals.health, 20)
		end)
		t.test("death drops the inventory; actions refused until respawn", function()
			local gs, p = setup()
			Inventory.add(p.inventory, ItemStack.new(B.COBBLESTONE, 10))
			Inventory.add(p.inventory, ItemStack.new(257, 1))
			for y = 120, 81, -1 do
				GameServer.setPlayerPosition(gs, 1, 0.5, y, 0.5)
				GameServer.tick(gs)
			end
			t.truthy(p.vitals.dead)
			t.eq(Inventory.totalItems(p.inventory), 0)
			t.eq(gs.items.count, 2)
			t.truthy(has(GameServer.takeOutbox(gs, 1), S.DIED))
			local before = p.rejected
			GameServer.handle(gs, 1, C.START_BREAK, { 0, 80, 0 })
			t.eq(p.rejected, before + 1)
			GameServer.handle(gs, 1, C.RESPAWN, {})
			t.falsy(p.vitals.dead); t.eq(p.vitals.health, 20)
			t.truthy(has(GameServer.takeOutbox(gs, 1), S.RESPAWNED))
		end)
		t.test("eating requires the use duration and restores food", function()
			local gs, p = setup()
			p.vitals.food, p.vitals.saturation = 10, 0
			Inventory.add(p.inventory, ItemStack.new(297, 2)) -- bread
			GameServer.handle(gs, 1, C.USE_START, {})
			GameServer.handle(gs, 1, C.USE_FINISH, {})
			t.eq(p.vitals.food, 10, "instant eat rejected")
			GameServer.handle(gs, 1, C.USE_START, {})
			for _ = 1, 32 do
				GameServer.tick(gs)
			end
			GameServer.handle(gs, 1, C.USE_FINISH, {})
			t.eq(p.vitals.food, 15)
			t.eq(Inventory.count(p.inventory, 297), 1)
		end)
		t.test("breaking a block beside water lets it flow in", function()
			local gs, p = setup()
			p.gamemode = "creative"
			World.setState(gs.world, 2, 81, 0, B.STONE * 16)
			World.setState(gs.world, 3, 81, 0, 9 * 16) -- water source behind the stone
			for _ = 1, 10 do
				GameServer.tick(gs)
			end
			GameServer.handle(gs, 1, C.START_BREAK, { 2, 81, 0 })
			for _ = 1, 20 do
				GameServer.tick(gs)
			end
			t.eq(World.getId(gs.world, 2, 81, 0), 8, "flowing water filled the gap")
		end)
		t.test("walking costs exhaustion, eventually hunger", function()
			local gs, p = setup()
			p.vitals.saturation = 0
			local x = 0.5
			for i = 1, 4000 do
				x = 0.5 + (i % 2) * 0.2 -- pace back and forth on the platform
				GameServer.setPlayerPosition(gs, 1, x, 81, 0.5)
				GameServer.tick(gs)
			end
			t.truthy(p.vitals.food < 20, "food " .. p.vitals.food)
		end)
	end)
end
