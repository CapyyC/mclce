local SaveManager = require("../../src/shared/Persistence/SaveManager")
local Chunk = require("../../src/shared/Voxel/Chunk")
local WorldGenerator = require("../../src/shared/WorldGen/WorldGenerator")
local WorldSeed = require("../../src/shared/WorldGen/WorldSeed")

local function clockAt(t0)
	local now = t0
	return function()
		return now
	end, function(dt)
		now += dt
	end
end

local function modified(cx, cz)
	local c = WorldGenerator.generate(WorldGenerator.new(WorldSeed.fromNumber(1)), cx, cz)
	Chunk.setState(c, 3, 100, 3, 57 * 16) -- player placed a diamond block
	Chunk.setState(c, 0, 70, 0, 0)
	return c
end

return function(t)
	t.describe("SaveManager", function()
		t.test("new world, save modified chunks, reload in a fresh session", function()
			local backend, store = SaveManager.memoryBackend()
			local clock = clockAt(0)
			local sm = SaveManager.new(backend, "w1", clock)
			local ok, isNew = SaveManager.open(sm, { seed = "abc", size = 864 })
			t.truthy(ok); t.truthy(isNew)
			local a, b = modified(-1, -1), modified(5, 2)
			SaveManager.storeChunk(sm, a)
			SaveManager.storeChunk(sm, b)
			t.falsy(a.dirty)
			t.eq(SaveManager.dirtyCount(sm), 3) -- 2 regions + meta
			t.eq(SaveManager.flush(sm, 10), 3)
			t.eq(SaveManager.dirtyCount(sm), 0)
			t.truthy(store["w1/meta"]); t.truthy(store["w1/r/-1,-1"]); t.truthy(store["w1/r/1,0"])

			local sm2 = SaveManager.new(backend, "w1", clock)
			local ok2, isNew2 = SaveManager.open(sm2, {})
			t.truthy(ok2); t.falsy(isNew2)
			t.eq(sm2.meta.seed, "abc")
			t.truthy(SaveManager.ensureRegion(sm2, -1, -1))
			local la = SaveManager.loadChunk(sm2, -1, -1)
			t.truthy(la)
			t.eq(Chunk.getId(la :: any, 3, 100, 3), 57)
			t.eq(Chunk.getId(la :: any, 0, 70, 0), 0)
			-- an unmodified neighbour in the same region generates instead
			t.eq(SaveManager.loadChunk(sm2, -2, -1), nil)
			-- regions not in the index cost no request
			local gets = sm2.stats.gets
			t.truthy(SaveManager.ensureRegion(sm2, 100, 100))
			t.eq(sm2.stats.gets, gets)
		end)
		t.test("failed writes stay dirty and retry with backoff; nothing is lost", function()
			local backend = SaveManager.memoryBackend(2) -- every 2nd call fails
			local clock, advance = clockAt(0)
			local sm = SaveManager.new(backend, "w", clock)
			SaveManager.open(sm, {})
			for i = 0, 5 do
				SaveManager.storeChunk(sm, modified(i * 4, 0))
			end
			local written = 0
			for _ = 1, 50 do
				written += SaveManager.flush(sm, 3)
				advance(70)
			end
			t.eq(SaveManager.dirtyCount(sm), 0)
			t.truthy(sm.stats.failures > 0)
			-- verify every chunk is readable in a new session (with a healthy backend view)
			local sm2 = SaveManager.new(backend, "w", clock)
			local ok
			repeat
				ok = SaveManager.open(sm2, {})
			until ok
			for i = 0, 5 do
				repeat
					ok = SaveManager.ensureRegion(sm2, i * 4, 0)
				until ok
				t.truthy(SaveManager.loadChunk(sm2, i * 4, 0), "chunk " .. i)
			end
		end)
		t.test("respects request budget", function()
			local backend = SaveManager.memoryBackend()
			local sm = SaveManager.new(backend, "w", clockAt(0))
			SaveManager.open(sm, {})
			for i = 0, 9 do
				SaveManager.storeChunk(sm, modified(i * 4, 0))
			end
			t.eq(SaveManager.flush(sm, 4), 4)
			t.eq(sm.stats.sets, 4)
		end)
		t.test("edits during an in-flight write keep the region dirty", function()
			local inner, store = SaveManager.memoryBackend()
			local sm
			local c = modified(0, 0)
			local backend = {
				get = inner.get,
				set = function(k, v)
					-- simulate a yielding SetAsync during which the player edits again
					if string.find(k, "/r/") then
						Chunk.setState(c, 1, 100, 1, 16)
						SaveManager.storeChunk(sm, c)
					end
					return inner.set(k, v)
				end,
			}
			sm = SaveManager.new(backend, "w", clockAt(0))
			SaveManager.open(sm, {})
			SaveManager.storeChunk(sm, c)
			SaveManager.flush(sm, 1)
			t.truthy(SaveManager.dirtyCount(sm) >= 1)
			local _ = store
		end)
		t.test("schema: newer versions refused, migrations applied, corrupt data reported", function()
			local backend, store = SaveManager.memoryBackend()
			store["w/meta"] = { v = 99 }
			local sm = SaveManager.new(backend, "w", clockAt(0))
			local ok, err = SaveManager.open(sm, {})
			t.falsy(ok); t.truthy(string.find(err, "newer"))
			store["w/meta"] = "garbage"
			t.falsy((SaveManager.open(SaveManager.new(backend, "w", clockAt(0)), {})))
			-- fake legacy v0 meta with a migration
			SaveManager._migrations[0] = function(r)
				r.regions = r.regionList or {}
				r.regionList = nil
				return r
			end
			store["w/meta"] = { v = 0, regionList = { "0,0" }, seed = "x" }
			store["w/r/0,0"] = { v = 1, chunks = { ["0,0"] = "!!!notbase64" } }
			local sm3 = SaveManager.new(backend, "w", clockAt(0))
			t.truthy(SaveManager.open(sm3, {}))
			t.eq(sm3.meta.v, 1)
			t.truthy(sm3.regionIndex["0,0"])
			t.truthy(SaveManager.ensureRegion(sm3, 0, 0))
			local chunk, cerr = SaveManager.loadChunk(sm3, 0, 0)
			t.eq(chunk, nil); t.truthy(cerr)
			SaveManager._migrations[0] = nil
		end)
		t.test("eviction keeps dirty and in-use regions", function()
			local backend = SaveManager.memoryBackend()
			local sm = SaveManager.new(backend, "w", clockAt(0))
			SaveManager.open(sm, {})
			SaveManager.storeChunk(sm, modified(0, 0))
			SaveManager.ensureRegion(sm, 8, 8)
			t.eq(SaveManager.evictRegions(sm, function()
				return false
			end), 1) -- only the clean 8,8 region
			SaveManager.flush(sm, 5)
			t.eq(SaveManager.evictRegions(sm, function(cx, cz)
				return cx == 1 and cz == 1
			end), 0)
			t.eq(SaveManager.evictRegions(sm, function()
				return false
			end), 1)
		end)
		t.test("player records", function()
			local backend = SaveManager.memoryBackend()
			local sm = SaveManager.new(backend, "w", clockAt(0))
			local ok, rec = SaveManager.loadPlayer(sm, 42)
			t.truthy(ok); t.eq(rec, nil)
			t.truthy(SaveManager.savePlayer(sm, 42, { health = 17, pos = { 1, 2, 3 } }))
			local ok2, rec2 = SaveManager.loadPlayer(sm, 42)
			t.truthy(ok2); t.eq(rec2.health, 17); t.eq(rec2.v, 1)
		end)
	end)
end
