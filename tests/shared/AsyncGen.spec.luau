local GameServer = require("../../src/shared/Sim/GameServer")
local WorldGenerator = require("../../src/shared/WorldGen/WorldGenerator")
local WorldSeed = require("../../src/shared/WorldGen/WorldSeed")
local World = require("../../src/shared/Voxel/World")
local Chunk = require("../../src/shared/Voxel/Chunk")
local ChunkCodec = require("../../src/shared/Persistence/ChunkCodec")

return function(t)
	t.describe("Async generation", function()
		t.test("off-thread chunks match in-thread generation; stale results dropped", function()
			local requests = {}
			local gs = GameServer.new({ seed = "async", viewRadius = 2, genBudget = 50, sendBudget = 50, mobs = false, asyncGenerate = function(cx, cz)
				table.insert(requests, { cx, cz })
			end })
			GameServer.addPlayer(gs, 1, "a")
			GameServer.tick(gs)
			t.truthy(#requests >= 12, "requests issued: " .. #requests)
			t.eq(gs.world.chunkCount, 1, "only the spawn chunk was generated in-thread")
			-- a separate "worker" generator, results delivered in reverse order through the codec
			local worker = WorldGenerator.new(WorldSeed.fromString("async"))
			for i = #requests, 1, -1 do
				local r = requests[i]
				local buf = ChunkCodec.encode(WorldGenerator.generate(worker, r[1], r[2]))
				GameServer.deliverGenerated(gs, ChunkCodec.decode(buf))
			end
			t.eq(gs.world.chunkCount, #requests + 1)
			local ref = WorldGenerator.new(WorldSeed.fromString("async"))
			local r = requests[3]
			local expect = WorldGenerator.generate(ref, r[1], r[2])
			local got = World.getChunk(gs.world, r[1], r[2])
			for y = 0, 255, 5 do
				for x = 0, 15 do
					t.eq(Chunk.getState(got, x, y, 7), Chunk.getState(expect, x, y, 7))
				end
			end
			-- deliveries for chunks nobody asked for are ignored
			t.falsy(GameServer.deliverGenerated(gs, WorldGenerator.generate(worker, 40, 40)))
			t.eq(gs.stats.staleGenerated, 1)
			-- chunks unloaded before their result arrives are dropped
			GameServer.setPlayerPosition(gs, 1, 300, 80, 0)
			for _ = 1, 30 do
				GameServer.tick(gs)
			end
			local far = requests[#requests]
			local later = {}
			for _, q in requests do
				later[q[1] .. "," .. q[2]] = true
			end
			local _ = far
			-- deliver one old request that is no longer pending (already unloaded)
			local before = gs.stats.staleGenerated
			GameServer.deliverGenerated(gs, WorldGenerator.generate(worker, requests[1][1], requests[1][2]))
			t.eq(gs.stats.staleGenerated, before + 1)
		end)
	end)
end
