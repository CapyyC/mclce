local GameServer = require("../../src/shared/Sim/GameServer")
local Protocol = require("../../src/shared/Net/Protocol")
local World = require("../../src/shared/Voxel/World")
local Inventory = require("../../src/shared/Items/Inventory")
local ItemStack = require("../../src/shared/Items/ItemStack")
local Mobs = require("../../src/shared/Sim/Mobs")
local MobTypes = require("../../src/shared/Sim/MobTypes")
local B = require("../../src/shared/Blocks/BlockRegistry")

local C, S = Protocol.C2S, Protocol.S2C

local function setup()
	local gs = GameServer.new({ seed = "mobs", viewRadius = 2, genBudget = 50, sendBudget = 50, sendBytesPerSecond = 1e9, mobs = false })
	local p = GameServer.addPlayer(gs, 1, "a")
	GameServer.tick(gs)
	for x = -8, 8 do
		for z = -8, 8 do
			World.setState(gs.world, x, 80, z, B.STONE * 16)
			for y = 81, 90 do
				World.setState(gs.world, x, y, z, 0)
			end
		end
	end
	GameServer.teleport(gs, 1, 0.5, 81, 0.5)
	for _ = 1, 3 do
		GameServer.tick(gs)
	end
	GameServer.takeOutbox(gs, 1)
	return gs, p
end

local function find(box, kind)
	local out = {}
	for _, m in box do
		if m.kind == kind then
			table.insert(out, m)
		end
	end
	return out
end

return function(t)
	t.describe("GameServer mobs", function()
		t.test("players see mobs spawn/move/despawn via MOBS messages", function()
			local gs = setup()
			local pig = Mobs.spawn(gs.mobs, MobTypes.byName("pig"), 3.5, 81, 0.5)
			GameServer.tick(gs)
			local msgs = find(GameServer.takeOutbox(gs, 1), S.MOBS)
			t.eq(#msgs, 1)
			t.eq(msgs[1].args[1].spawned[1][1], pig.id)
			t.eq(msgs[1].args[1].spawned[1][2], 90)
			Mobs.remove(gs.mobs, pig.id)
			GameServer.tick(gs)
			local m2 = find(GameServer.takeOutbox(gs, 1), S.MOBS)
			t.eq(m2[1].args[1].removed[1], pig.id)
		end)
		t.test("attacking with a sword kills a pig in 2 hits and drops pork", function()
			local gs, p = setup()
			Inventory.add(p.inventory, ItemStack.new(267, 1)) -- iron sword (7)
			local pig = Mobs.spawn(gs.mobs, MobTypes.byName("pig"), 2.0, 81, 0.5)
			GameServer.tick(gs)
			GameServer.handle(gs, 1, C.ATTACK, { pig.id })
			t.eq(pig.health, 3)
			GameServer.handle(gs, 1, C.ATTACK, { pig.id }) -- invulnerable
			t.eq(pig.health, 3)
			for _ = 1, 10 do
				GameServer.tick(gs)
			end
			GameServer.handle(gs, 1, C.ATTACK, { pig.id })
			t.eq(gs.mobs.list[pig.id], nil)
			t.eq(p.inventory.slots[1].damage, 2, "sword wear")
			-- walk to where it died and pick up the drop
			local dropX, dropZ
			for _, e in gs.items.list do
				if e.stack.id == 319 then
					dropX, dropZ = e.x, e.z
				end
			end
			t.truthy(dropX ~= nil, "porkchop dropped")
			for _ = 1, 30 do
				GameServer.setPlayerPosition(gs, 1, dropX, 81, dropZ)
				GameServer.tick(gs)
			end
			t.truthy(Inventory.count(p.inventory, 319) >= 1, "porkchop picked up")
		end)
		t.test("out-of-reach attacks are rejected", function()
			local gs, p = setup()
			local pig = Mobs.spawn(gs.mobs, MobTypes.byName("pig"), 7.5, 81, 0.5)
			GameServer.tick(gs)
			GameServer.handle(gs, 1, C.ATTACK, { pig.id })
			t.eq(pig.health, 10)
			GameServer.handle(gs, 1, C.ATTACK, { 99999 })
			t.truthy(p.rejected >= 2)
		end)
		t.test("zombies hurt survival players", function()
			local gs, p = setup()
			gs.worldTime = 18000 -- midnight: no burning
			Mobs.spawn(gs.mobs, MobTypes.byName("zombie"), 3.5, 81, 0.5)
			for _ = 1, 100 do
				GameServer.tick(gs)
			end
			t.truthy(p.vitals.health < 20, "health " .. p.vitals.health)
		end)
		t.test("full diamond armour reduces melee damage by 80%, not fall damage", function()
			local gs, p = setup()
			for i, id in { 310, 311, 312, 313 } do
				p.inventory.slots[36 + i] = ItemStack.new(id, 1)
			end
			local total = 0
			for _ = 1, 20 do
				p.vitals.health = 20
				p.vitals.dead = false
				GameServer.damage(gs, p, 10, "zombie")
				total += 20 - p.vitals.health
			end
			t.eq(total, 40, "10 * 0.2 = exactly 2 per hit")
			t.truthy(p.inventory.slots[38].damage > 0, "armour wore")
			p.vitals.health = 20
			GameServer.damage(gs, p, 5, "fell")
			t.eq(p.vitals.health, 15)
		end)
		t.test("creeper explosion craters the floor and hurts the player", function()
			local gs, p = setup()
			gs.worldTime = 18000
			Mobs.spawn(gs.mobs, MobTypes.byName("creeper"), 2.5, 81, 0.5)
			for _ = 1, 60 do
				GameServer.tick(gs)
			end
			t.eq(gs.stats.explosions, 1)
			local holes = 0
			for x = -4, 6 do
				for z = -4, 4 do
					if World.getId(gs.world, x, 80, z) == 0 then
						holes += 1
					end
				end
			end
			t.truthy(holes >= 5, "crater " .. holes)
			t.truthy(p.vitals.health < 20)
			t.eq(World.getId(gs.world, 0, 0, 0), B.BEDROCK)
		end)
		t.test("a dungeon spawner spawns its mob near players", function()
			local gs = setup()
			local BlockEntities = require("../../src/shared/Sim/BlockEntities")
			World.setState(gs.world, 3, 81, 3, 52 * 16)
			local e = BlockEntities.get(gs.world, 3, 81, 3)
			e.kind = "spawner:skeleton"
			e.cook = 5
			for _ = 1, 10 do
				GameServer.tick(gs)
			end
			local skeletons = 0
			for _, m in gs.mobs.list do
				if m.kind.name == "skeleton" then
					skeletons += 1
				end
			end
			t.truthy(skeletons >= 1, "spawned " .. skeletons)
			t.truthy(e.cook >= 190, "delay reset")
		end)
		t.test("hostiles spawn in the dark around players when enabled", function()
			local gs = GameServer.new({ seed = "mobs", viewRadius = 3, genBudget = 50, sendBudget = 50, sendBytesPerSecond = 1e9 })
			GameServer.addPlayer(gs, 1, "a")
			gs.worldTime = 17000
			for _ = 1, 400 do
				GameServer.tick(gs)
			end
			t.truthy(gs.mobs.hostileCount > 0, "hostiles " .. gs.mobs.hostileCount)
		end)
	end)
end
