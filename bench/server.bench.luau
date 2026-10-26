local GameServer = require("../src/shared/Sim/GameServer")

return function(Bench)
	local gs = GameServer.new({ seed = "bench", viewRadius = 6, genBudget = 2, sendBudget = 4 })
	local spots = { { 0.5, 0.5 }, { 100.5, 0.5 }, { -150.5, 80.5 }, { 30.5, -200.5 } }
	for i, s in spots do
		GameServer.addPlayer(gs, i, "p" .. i)
		GameServer.setPlayerPosition(gs, i, s[1], 80, s[2])
	end
	-- warm up: let streaming settle so the steady-state tick is measured too
	local t0 = os.clock()
	local ticks = 0
	repeat
		GameServer.tick(gs)
		for i = 1, #spots do
			GameServer.takeOutbox(gs, i)
		end
		ticks += 1
	until gs.scheduler.queue[1] == nil and ticks > 20 or ticks > 2000
	local warm = os.clock() - t0
	print(string.format("%-40s %10d ticks %12.1f ms total (%.2f ms/tick, %d chunks)", "server warm-up (4 players, r=6)", ticks, warm * 1000, warm * 1000 / ticks, gs.world.chunkCount))
	Bench.run("server.tick steady state (4 players)", 200, function(n)
		for _ = 1, n do
			GameServer.tick(gs)
			for i = 1, #spots do
				GameServer.takeOutbox(gs, i)
			end
		end
		return { mobs = gs.mobs.count, items = gs.items.count, fluidsPending = gs.fluids.count }
	end)
end
