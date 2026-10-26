local World = require("../src/shared/Voxel/World")
local LightEngine = require("../src/shared/Voxel/LightEngine")
local WorldGenerator = require("../src/shared/WorldGen/WorldGenerator")
local WorldSeed = require("../src/shared/WorldGen/WorldSeed")

return function(Bench)
	local g = WorldGenerator.new(WorldSeed.fromNumber(20131218))
	local w = World.new(1024)
	for cx = -2, 2 do
		for cz = -2, 2 do
			World.putChunk(w, WorldGenerator.generate(g, cx, cz))
		end
	end
	Bench.run("light.addChunk (generated, 5x5 stitched)", 25, function(n)
		local le
		local visits = 0
		for i = 1, n do
			if (i - 1) % 25 == 0 then
				le = LightEngine.new(w)
			end
			local k = (i - 1) % 25
			LightEngine.addChunk(le, k % 5 - 2, k // 5 - 2)
		end
		visits = le.stats.visits
		return { visits = visits }
	end)
	local le = LightEngine.new(w)
	for cx = -2, 2 do
		for cz = -2, 2 do
			LightEngine.addChunk(le, cx, cz)
		end
	end
	World.addListener(w, function(x, y, z, o, nw)
		LightEngine.onBlockChanged(le, x, y, z, o // 16, nw // 16)
	end)
	Bench.run("light.onBlockChanged (dig + refill at surface)", 400, function(n)
		local before = le.stats.visits
		for i = 1, n do
			local x, z = (i * 7) % 32 - 16, (i * 13) % 32 - 16
			local y = World.height(w, x, z) - 1
			local st = World.getState(w, x, y, z)
			World.setState(w, x, y, z, 0)
			World.setState(w, x, y, z, st)
		end
		return { visitsPerEdit = (le.stats.visits - before) // (2 * n) }
	end)
end
