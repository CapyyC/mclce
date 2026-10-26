local GameServer = require("../../src/shared/Sim/GameServer")
local Protocol = require("../../src/shared/Net/Protocol")
local Inventory = require("../../src/shared/Items/Inventory")

local C, S = Protocol.C2S, Protocol.S2C

local function lastChat(gs)
	local text
	for _, m in GameServer.takeOutbox(gs, 1) do
		if m.kind == S.CHAT then
			text = m.args[2]
		end
	end
	return text
end

return function(t)
	t.describe("Commands", function()
		t.test("admins can change mode, time, weather, give, tp, heal", function()
			local gs = GameServer.new({ seed = "cmd", viewRadius = 1, genBudget = 50, mobs = false })
			local p = GameServer.addPlayer(gs, 1, "host")
			gs.admins[1] = true
			GameServer.handle(gs, 1, C.CHAT, { "/gamemode creative" })
			t.eq(p.gamemode, "creative")
			t.eq(lastChat(gs), "Game mode set to creative")
			GameServer.handle(gs, 1, C.CHAT, { "/time set night" })
			t.eq(gs.worldTime, 13000)
			GameServer.handle(gs, 1, C.CHAT, { "/weather thunder" })
			t.truthy(gs.weather.raining and gs.weather.thundering)
			GameServer.handle(gs, 1, C.CHAT, { "/give diamond_pickaxe" })
			t.eq(Inventory.count(p.inventory, 278), 1)
			GameServer.handle(gs, 1, C.CHAT, { "/give 4 130" })
			t.eq(Inventory.count(p.inventory, 4), 130)
			GameServer.handle(gs, 1, C.CHAT, { "/tp 10 90 -5" })
			t.eq(p.x, 10); t.eq(p.z, -5)
			p.vitals.health = 3
			GameServer.handle(gs, 1, C.CHAT, { "/heal" })
			t.eq(p.vitals.health, 20)
			GameServer.handle(gs, 1, C.CHAT, { "/give nonsense" })
			t.eq(lastChat(gs), "Unknown item")
		end)
		t.test("non-admins are refused; normal chat is broadcast", function()
			local gs = GameServer.new({ seed = "cmd", viewRadius = 1, genBudget = 50, mobs = false })
			local p = GameServer.addPlayer(gs, 1, "guest")
			GameServer.handle(gs, 1, C.CHAT, { "/gamemode creative" })
			t.eq(p.gamemode, "survival")
			t.eq(lastChat(gs), "Only the host can use commands")
			GameServer.handle(gs, 1, C.CHAT, { "hello" })
			t.eq(lastChat(gs), "hello")
		end)
	end)
end
