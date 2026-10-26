local GameServer = require("../../src/shared/Sim/GameServer")
local Protocol = require("../../src/shared/Net/Protocol")
local World = require("../../src/shared/Voxel/World")
local Inventory = require("../../src/shared/Items/Inventory")
local ItemStack = require("../../src/shared/Items/ItemStack")
local Mobs = require("../../src/shared/Sim/Mobs")
local MobTypes = require("../../src/shared/Sim/MobTypes")
local B = require("../../src/shared/Blocks/BlockRegistry")

local C = Protocol.C2S

local function setup()
	local gs = GameServer.new({ seed = "beds", viewRadius = 2, genBudget = 50, sendBudget = 50, mobs = false })
	local p = GameServer.addPlayer(gs, 1, "a")
	GameServer.tick(gs)
	gs.randomTickRadius = -1
	for x = -6, 12 do
		for z = -6, 6 do
			World.setState(gs.world, x, 80, z, B.STONE * 16)
			for y = 81, 86 do
				World.setState(gs.world, x, y, z, 0)
			end
		end
	end
	GameServer.teleport(gs, 1, 0.5, 81, 0.5)
	GameServer.tick(gs)
	return gs, p
end

return function(t)
	t.describe("Beds", function()
		t.test("place, sleep through the night, respawn at the bed", function()
			local gs, p = setup()
			p.inventory.slots[1] = ItemStack.new(355, 1)
			p.inventory.selected = 1
			GameServer.handle(gs, 1, C.PLACE, { 2, 80, 0, 2 })
			t.eq(World.getId(gs.world, 2, 81, 0), 26)
			t.eq(World.getState(gs.world, 3, 81, 0), 26 * 16 + 3 + 8, "head toward +x")
			-- daytime: refused
			gs.worldTime = 6000
			GameServer.handle(gs, 1, C.PLACE, { 2, 81, 0, 2 })
			t.eq(p.sleeping, nil)
			t.truthy(p.spawn, "spawn still set")
			gs.worldTime = 14000
			GameServer.handle(gs, 1, C.PLACE, { 3, 81, 0, 2 }) -- clicking the head works too
			t.truthy(p.sleeping)
			t.eq(p.sleeping.x, 2)
			GameServer.setPlayerPosition(gs, 1, 2.5, 81.5, 0.5)
			for _ = 1, 101 do
				GameServer.tick(gs)
			end
			t.truthy(gs.worldTime < 100, "night skipped: " .. gs.worldTime)
			t.eq(p.sleeping, nil)
			-- die far away, respawn at the bed
			GameServer.teleport(gs, 1, 10.5, 81, 0.5)
			GameServer.kill(gs, p, "test")
			GameServer.handle(gs, 1, C.RESPAWN, {})
			t.truthy(math.abs(p.x - 2.5) <= 1.5 and math.abs(p.z - 0.5) <= 1.5, "respawned near the bed")
			local rec = GameServer.playerRecord(p)
			t.eq(rec.spawn[1], 2)
		end)
		t.test("monsters nearby prevent sleep; breaking one half removes the bed", function()
			local gs, p = setup()
			World.setStates(gs.world, { 2, 81, 0, 26 * 16 + 3, 3, 81, 0, 26 * 16 + 11 })
			gs.worldTime = 14000
			Mobs.spawn(gs.mobs, MobTypes.byName("zombie"), 5.5, 81, 0.5)
			GameServer.handle(gs, 1, C.PLACE, { 2, 81, 0, 2 })
			t.eq(p.sleeping, nil)
			p.gamemode = "creative"
			GameServer.handle(gs, 1, C.START_BREAK, { 3, 81, 0 })
			t.eq(World.getId(gs.world, 2, 81, 0), 0)
			t.eq(World.getId(gs.world, 3, 81, 0), 0)
		end)
		t.test("beds explode in the Nether", function()
			local gs = GameServer.new({ seed = "beds", viewRadius = 1, genBudget = 50, sendBudget = 50, mobs = false, dimension = "nether" })
			local p = GameServer.addPlayer(gs, 1, "a")
			GameServer.tick(gs)
			local x, y, z = math.floor(p.x), math.floor(p.y), math.floor(p.z)
			World.setStates(gs.world, { x + 2, y, z, 26 * 16 + 3, x + 3, y, z, 26 * 16 + 11 })
			GameServer.handle(gs, 1, C.PLACE, { x + 2, y, z, 2 })
			t.eq(gs.stats.explosions, 1)
		end)
	end)
	t.describe("Bows", function()
		t.test("a fully drawn bow shot kills a pig in a few hits and uses arrows", function()
			local gs, p = setup()
			p.inventory.slots[1] = ItemStack.new(261, 1)
			p.inventory.slots[2] = ItemStack.new(262, 5)
			p.inventory.selected = 1
			local pig = Mobs.spawn(gs.mobs, MobTypes.byName("pig"), 8.5, 81, 0.5)
			pig.wanderTicks = 100000
			GameServer.handle(gs, 1, C.USE_START, {})
			for _ = 1, 20 do
				GameServer.tick(gs)
			end
			-- aim at the pig's body from the eye (y 82.62 -> 81.45 over 8 blocks)
			local dx, dy = 8, 81.45 - 82.62 + 0.3
			local len = math.sqrt(dx * dx + dy * dy)
			GameServer.handle(gs, 1, C.USE_FINISH, { dx / len, dy / len, 0 })
			t.eq(Inventory.count(p.inventory, 262), 4, "arrow consumed")
			t.eq(gs.stats.arrowsShot, 1)
			for _ = 1, 20 do
				GameServer.tick(gs)
			end
			t.truthy(pig.health < 10 or gs.mobs.list[pig.id] == nil, "pig hit (health " .. pig.health .. ")")
			t.eq(p.inventory.slots[1].damage, 1)
		end)
		t.test("bad aim vectors and undrawn releases are rejected", function()
			local gs, p = setup()
			p.inventory.slots[1] = ItemStack.new(261, 1)
			p.inventory.slots[2] = ItemStack.new(262, 5)
			p.inventory.selected = 1
			t.eq(Protocol.decodeC2S(C.USE_FINISH, { 5, 0, 0 }), nil)
			t.eq(Protocol.decodeC2S(C.USE_FINISH, { 0 / 0, 0, 0 }), nil)
			GameServer.handle(gs, 1, C.USE_START, {})
			GameServer.handle(gs, 1, C.USE_FINISH, { 1, 0, 0 }) -- zero draw time
			t.eq(Inventory.count(p.inventory, 262), 5, "no arrow for an undrawn bow")
		end)
	end)
end
