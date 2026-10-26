local ChunkScheduler = require("../../src/shared/Streaming/ChunkScheduler")
local RemeshQueue = require("../../src/shared/Streaming/RemeshQueue")

local function harness(radius, opts)
	local log = { loads = {}, unloads = {} }
	local s = ChunkScheduler.new({
		load = function(cx, cz)
			table.insert(log.loads, cx .. "," .. cz)
		end,
		unload = function(cx, cz)
			table.insert(log.unloads, cx .. "," .. cz)
		end,
		inBounds = opts and opts.inBounds,
	}, radius, opts)
	return s, log
end

return function(t)
	t.describe("ChunkScheduler", function()
		t.test("loads nearest first, deterministic order, circular radius", function()
			local s, log = harness(2)
			ChunkScheduler.setViewers(s, { { cx = 0, cz = 0 } })
			t.eq(ChunkScheduler.pending(s), 13) -- lattice points with dx^2+dz^2 <= 4
			ChunkScheduler.step(s, 100)
			t.eq(log.loads[1], "0,0")
			t.eq(#log.loads, 13)
			local s2, log2 = harness(2)
			ChunkScheduler.setViewers(s2, { { cx = 0, cz = 0 } })
			ChunkScheduler.step(s2, 100)
			t.deepEq(log.loads, log2.loads)
		end)
		t.test("budget bounds work per step", function()
			local s, log = harness(4)
			ChunkScheduler.setViewers(s, { { cx = 0, cz = 0 } })
			t.eq(ChunkScheduler.step(s, 3), 3)
			t.eq(#log.loads, 3)
			t.eq(ChunkScheduler.step(s, 3), 3)
			t.eq(#log.loads, 6)
		end)
		t.test("moving viewer cancels stale requests and unloads with hysteresis", function()
			local s, log = harness(2, { hysteresis = 1 })
			ChunkScheduler.setViewers(s, { { cx = 0, cz = 0 } })
			ChunkScheduler.step(s, 100)
			ChunkScheduler.setViewers(s, { { cx = 100, cz = 0 } })
			t.truthy(s.stats.cancelled == 0)
			ChunkScheduler.step(s, 2)
			ChunkScheduler.setViewers(s, { { cx = 0, cz = 0 } })
			t.truthy(s.stats.cancelled > 0, "requests around (100,0) cancelled")
			-- the 2 chunks loaded near (100,0) are far now
			t.eq(ChunkScheduler.collect(s), 2)
			-- chunks at distance 3 from (0,0) stay within radius+hysteresis
			ChunkScheduler.setViewers(s, { { cx = 1, cz = 0 } })
			t.eq(ChunkScheduler.collect(s), 0)
			ChunkScheduler.setViewers(s, { { cx = 5, cz = 0 } })
			t.truthy(ChunkScheduler.collect(s) > 0)
			for _, u in log.unloads do
				t.truthy(u ~= nil)
			end
		end)
		t.test("respects bounds and max loaded budget", function()
			local s = harness(3, {
				maxLoaded = 5,
				inBounds = function(cx, cz)
					return cx >= 0 and cz >= 0
				end,
			})
			ChunkScheduler.setViewers(s, { { cx = 0, cz = 0 } })
			ChunkScheduler.step(s, 100)
			t.eq(s.loadedCount, 5)
			for k in s.loaded do
				local Coords = require("../../src/shared/Voxel/Coords")
				local cx, cz = Coords.unpackChunkKey(k)
				t.truthy(cx >= 0 and cz >= 0)
			end
		end)
		t.test("multiple viewers union", function()
			local s = harness(1)
			ChunkScheduler.setViewers(s, { { cx = 0, cz = 0 }, { cx = 10, cz = 10 } })
			t.eq(ChunkScheduler.pending(s), 10)
		end)
	end)
	t.describe("RemeshQueue", function()
		t.test("interior block dirties one section", function()
			local q = RemeshQueue.new()
			RemeshQueue.markBlock(q, 5, 40, 5)
			t.eq(q.count, 1)
		end)
		t.test("corner block dirties face neighbours across chunks (negative coords)", function()
			local q = RemeshQueue.new()
			RemeshQueue.markBlock(q, -16, 16, -1) -- chunk (-1,-1), local x=0,z=15,y=0 of si=1
			t.eq(q.count, 4)
			local got = {}
			for _, k in RemeshQueue.pop(q, 10, 0, 0, 0) do
				local cx, cz, si = RemeshQueue.unpack(k)
				got[cx .. "," .. cz .. "," .. si] = true
			end
			t.truthy(got["-1,-1,1"]); t.truthy(got["-2,-1,1"]); t.truthy(got["-1,0,1"]); t.truthy(got["-1,-1,0"])
			t.eq(q.count, 0)
		end)
		t.test("world top/bottom don't create invalid sections", function()
			local q = RemeshQueue.new()
			RemeshQueue.markBlock(q, 3, 0, 3)
			RemeshQueue.markBlock(q, 3, 255, 3)
			t.eq(q.count, 2)
		end)
		t.test("pop is nearest-first, bounded, and honours accept", function()
			local q = RemeshQueue.new()
			RemeshQueue.markChunk(q, 5, 5, false, 0)
			RemeshQueue.markChunk(q, 1, 0, false, 0)
			RemeshQueue.markChunk(q, -3, 0, false, 0)
			local first = RemeshQueue.pop(q, 1, 0, 0, 0)
			local cx = RemeshQueue.unpack(first[1])
			t.eq(cx, 1)
			local none = RemeshQueue.pop(q, 5, 0, 0, 0, function()
				return false
			end)
			t.eq(#none, 0)
			t.eq(q.count, 2)
			RemeshQueue.dropChunk(q, 5, 5)
			t.eq(q.count, 1)
		end)
	end)
end
