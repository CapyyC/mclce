-- Integration: server outbox -> client replica -> client requests -> server.
local GameServer = require("../../src/shared/Sim/GameServer")
local ClientWorld = require("../../src/shared/Sim/ClientWorld")
local World = require("../../src/shared/Voxel/World")
local Inventory = require("../../src/shared/Items/Inventory")
local ItemStack = require("../../src/shared/Items/ItemStack")
local RemeshQueue = require("../../src/shared/Streaming/RemeshQueue")
local B = require("../../src/shared/Blocks/BlockRegistry")

local function pump(gs, clients)
	GameServer.tick(gs)
	for pid, cw in clients do
		for _, m in GameServer.takeOutbox(gs, pid) do
			ClientWorld.apply(cw, m.kind, m.args)
		end
		for _, o in ClientWorld.takeOutgoing(cw) do
			GameServer.handle(gs, pid, o[1], { table.unpack(o, 2) })
		end
	end
end

return function(t)
	t.describe("Client/Server integration", function()
		t.test("client replica converges with the server and predicts breaks", function()
			local gs = GameServer.new({ seed = "integration", viewRadius = 2, genBudget = 50, sendBudget = 50 })
			local p = GameServer.addPlayer(gs, 1, "a")
			local cw = ClientWorld.new()
			local clients = { [1] = cw }
			for _ = 1, 4 do
				pump(gs, clients)
			end
			t.eq(cw.stats.chunks, 13)
			t.truthy(cw.remesh.count > 0)
			-- every dirty section belongs to a loaded chunk (no leak toward unloaded neighbours)
			for k in cw.remesh.dirty do
				local cx, cz = RemeshQueue.unpack(k)
				t.truthy(World.getChunk(cw.world, cx, cz) ~= nil, "dirty section in unloaded chunk")
			end
			-- replica equals server for the spawn chunk
			for y = 0, 255, 7 do
				for x = 0, 15 do
					t.eq(World.getState(cw.world, x, y, 3), World.getState(gs.world, x, y, 3))
				end
			end
			-- server-side edit replicates
			World.setState(gs.world, 2, 90, 2, B.GLASS * 16)
			pump(gs, clients)
			t.eq(World.getId(cw.world, 2, 90, 2), B.GLASS)
			-- break flow: dirt at foot level next to the player
			World.setState(gs.world, 1, 90, 0, B.STONE * 16)
			World.setState(gs.world, 1, 91, 0, B.DIRT * 16)
			GameServer.setPlayerPosition(gs, 1, 0.5, 91, 0.5)
			pump(gs, clients)
			local dt = 1 / 20
			for _ = 1, 30 do
				ClientWorld.updateBreaking(cw, 1, 91, 0, dt, true, false)
				pump(gs, clients)
			end
			t.eq(World.getId(gs.world, 1, 91, 0), 0, "server broke it")
			t.eq(World.getId(cw.world, 1, 91, 0), 0, "client agrees")
			t.eq(cw.stats.rollbacks or 0, 0)
			for _ = 1, 30 do
				pump(gs, clients)
			end
			t.eq(Inventory.count(p.inventory, B.DIRT), 1)
			local slotCount = 0
			for _, s in cw.inventory.slots do
				slotCount += s.count
			end
			t.eq(slotCount, 1, "client inventory mirrors server")
		end)
		t.test("rejected prediction is rolled back", function()
			local gs = GameServer.new({ seed = "integration", viewRadius = 1, genBudget = 50, sendBudget = 50 })
			GameServer.addPlayer(gs, 1, "a")
			local cw = ClientWorld.new()
			local clients = { [1] = cw }
			for _ = 1, 3 do
				pump(gs, clients)
			end
			World.setState(gs.world, 1, 91, 0, B.STONE * 16)
			GameServer.setPlayerPosition(gs, 1, 0.5, 91, 0.5)
			pump(gs, clients)
			-- a cheating client that pretends stone breaks instantly
			cw.gamemode = "creative"
			ClientWorld.updateBreaking(cw, 1, 91, 0, 0, true, false)
			t.eq(World.getId(cw.world, 1, 91, 0), 0, "predicted")
			pump(gs, clients)
			t.eq(World.getId(gs.world, 1, 91, 0), B.STONE)
			-- server never sent FINISH_BREAK acceptance; start-break leaves state as is.
			-- Simulate the client then finishing immediately (too fast) -> rejection -> rollback
			GameServer.handle(gs, 1, 3, { 1, 91, 0 })
			pump(gs, clients)
			t.eq(World.getId(cw.world, 1, 91, 0), B.STONE, "rolled back")
			t.truthy((cw.stats.rollbacks or 0) >= 1)
		end)
		t.test("death, respawn and eating round-trip", function()
			local gs = GameServer.new({ seed = "integration", viewRadius = 1, genBudget = 50, sendBudget = 50 })
			local p = GameServer.addPlayer(gs, 1, "a")
			local cw = ClientWorld.new()
			local clients = { [1] = cw }
			pump(gs, clients)
			GameServer.kill(gs, p, "test")
			pump(gs, clients)
			t.truthy(cw.vitals.dead); t.eq(cw.deathCause, "test")
			ClientWorld.requestRespawn(cw)
			pump(gs, clients)
			pump(gs, clients)
			t.falsy(cw.vitals.dead); t.truthy(cw.respawnAt)
			p.vitals.food = 10
			Inventory.add(p.inventory, ItemStack.new(297, 1))
			pump(gs, clients)
			for _ = 1, 40 do
				ClientWorld.updateUsing(cw, true, 1 / 20)
				pump(gs, clients)
			end
			t.eq(p.vitals.food, 15)
			t.eq(cw.vitals.food, 15)
		end)
		t.test("malformed server payloads don't crash the client", function()
			local cw = ClientWorld.new()
			ClientWorld.apply(cw, 2, { buffer.fromstring("garbage") })
			ClientWorld.apply(cw, 4, { "notabuffer" })
			ClientWorld.apply(cw, 5, { 42 })
			t.eq(cw.stats.badMessages, 3)
			local _ = ItemStack
			local __ = RemeshQueue
		end)
	end)
end
