--!strict
-- World persistence on top of a key/value backend shaped like Roblox
-- DataStores (string keys, JSON-able values, ~4 MB per value, throttled,
-- calls may fail). Engine-independent: the Roblox adapter wraps
-- DataStore:GetAsync/SetAsync in pcall and returns (ok, value | err).
--
-- Layout (all keys prefixed with the world id):
--   <world>/meta            { v, seed, size, time, regions = { "rx,rz", ... } }
--   <world>/r/<rx>,<rz>     { v, chunks = { ["lx,lz"] = base64 ChunkCodec } }
--   <world>/p/<userId>      { v, ...player state }
-- Regions are 4x4 chunks, so one request saves up to 16 modified chunks.
-- Only player-modified chunks are stored; untouched chunks regenerate from
-- the seed. Dirty regions are written by flush() under a request budget with
-- bounded exponential-backoff retries; a region is only marked clean after
-- its write succeeds, so failures never lose data while the server runs.

local Chunk = require("../Voxel/Chunk")
local ChunkCodec = require("./ChunkCodec")
local Base64 = require("../Util/Base64")

export type Backend = {
	get: (key: string) -> (boolean, any),
	set: (key: string, value: any) -> (boolean, string?),
}

export type Region = { chunks: { [string]: string }, dirty: boolean, retryAt: number, failures: number, bytes: number }

export type SaveManager = {
	backend: Backend,
	worldId: string,
	meta: { [string]: any },
	metaDirty: boolean,
	regions: { [string]: Region },
	regionIndex: { [string]: boolean }, -- regions that exist in the backend
	clock: () -> number,
	stats: { gets: number, sets: number, failures: number, giveUps: number },
	maxRetries: number,
	maxValueBytes: number,
}

local SaveManager = {}

SaveManager.SCHEMA = 1
SaveManager.REGION_SHIFT = 2 -- 4x4 chunks

-- Migrations from version n to n+1, applied in order on load.
local MIGRATIONS: { [number]: (any) -> any } = {}

local function migrate(record: any, label: string): any
	if type(record) ~= "table" then
		error("corrupt " .. label, 0)
	end
	local v = record.v
	if type(v) ~= "number" then
		error("missing schema version in " .. label, 0)
	end
	if v > SaveManager.SCHEMA then
		error(label .. " was written by a newer version (" .. v .. ")", 0)
	end
	while v < SaveManager.SCHEMA do
		local m = MIGRATIONS[v]
		assert(m, "no migration from " .. v)
		record = m(record)
		v += 1
		record.v = v
	end
	return record
end
SaveManager._migrations = MIGRATIONS

function SaveManager.regionOf(cx: number, cz: number): (number, number)
	return cx // 4, cz // 4
end

local function regionKey(rx: number, rz: number): string
	return rx .. "," .. rz
end

function SaveManager.new(backend: Backend, worldId: string, clock: () -> number): SaveManager
	return {
		backend = backend,
		worldId = worldId,
		meta = {},
		metaDirty = false,
		regions = {},
		regionIndex = {},
		clock = clock,
		stats = { gets = 0, sets = 0, failures = 0, giveUps = 0 },
		maxRetries = 8,
		maxValueBytes = 4000000,
	}
end

local function get(sm: SaveManager, key: string): (boolean, any)
	sm.stats.gets += 1
	local ok, v = sm.backend.get(sm.worldId .. "/" .. key)
	if not ok then
		sm.stats.failures += 1
	end
	return ok, v
end

-- Loads (or initialises) world metadata. Returns (ok, isNewWorld | err).
function SaveManager.open(sm: SaveManager, defaults: { [string]: any }): (boolean, any)
	local ok, v = get(sm, "meta")
	if not ok then
		return false, v
	end
	if v == nil then
		sm.meta = table.clone(defaults)
		sm.meta.v = SaveManager.SCHEMA
		sm.meta.regions = {}
		sm.metaDirty = true
		return true, true
	end
	local okM, rec = pcall(migrate, v, "world meta")
	if not okM then
		return false, rec
	end
	sm.meta = rec
	for _, k in rec.regions or {} do
		sm.regionIndex[k] = true
	end
	return true, false
end

-- Ensures the region holding chunk (cx, cz) is resident. Returns (ok, err).
-- Regions not in the index are known to be empty and cost no request.
function SaveManager.ensureRegion(sm: SaveManager, cx: number, cz: number): (boolean, string?)
	local rx, rz = SaveManager.regionOf(cx, cz)
	local k = regionKey(rx, rz)
	if sm.regions[k] then
		return true, nil
	end
	if not sm.regionIndex[k] then
		sm.regions[k] = { chunks = {}, dirty = false, retryAt = 0, failures = 0, bytes = 0 }
		return true, nil
	end
	local ok, v = get(sm, "r/" .. k)
	if not ok then
		return false, tostring(v)
	end
	local chunks: { [string]: string } = {}
	local bytes = 0
	if v ~= nil then
		local okM, rec = pcall(migrate, v, "region " .. k)
		if not okM then
			return false, rec
		end
		for lk, data in rec.chunks or {} do
			if type(lk) == "string" and type(data) == "string" then
				chunks[lk] = data
				bytes += #data
			end
		end
	end
	sm.regions[k] = { chunks = chunks, dirty = false, retryAt = 0, failures = 0, bytes = bytes }
	return true, nil
end

-- Returns the saved chunk if the player modified it, nil if it should be
-- generated. The region must be resident (ensureRegion). Corrupt chunk data
-- is reported and treated as missing rather than crashing the server.
function SaveManager.loadChunk(sm: SaveManager, cx: number, cz: number): (Chunk.Chunk?, string?)
	local rx, rz = SaveManager.regionOf(cx, cz)
	local r = sm.regions[regionKey(rx, rz)]
	assert(r, "region not resident")
	local data = r.chunks[(cx - rx * 4) .. "," .. (cz - rz * 4)]
	if data == nil then
		return nil, nil
	end
	local b = Base64.decode(data)
	if b == nil then
		return nil, "corrupt base64"
	end
	local ok, chunk = pcall(ChunkCodec.decode, b)
	if not ok then
		return nil, tostring(chunk)
	end
	if chunk.cx ~= cx or chunk.cz ~= cz then
		return nil, "chunk coordinate mismatch"
	end
	return chunk, nil
end

-- Records a modified chunk into its (resident) region and marks it dirty.
function SaveManager.storeChunk(sm: SaveManager, chunk: Chunk.Chunk)
	local rx, rz = SaveManager.regionOf(chunk.cx, chunk.cz)
	local k = regionKey(rx, rz)
	local r = sm.regions[k]
	if r == nil then
		r = { chunks = {}, dirty = false, retryAt = 0, failures = 0, bytes = 0 }
		sm.regions[k] = r
	end
	assert(r)
	local lk = (chunk.cx - rx * 4) .. "," .. (chunk.cz - rz * 4)
	local old = r.chunks[lk]
	local data = Base64.encode(ChunkCodec.encode(chunk))
	r.bytes += #data - (if old then #old else 0)
	r.chunks[lk] = data
	r.dirty = true
	chunk.dirty = false
end

function SaveManager.setMeta(sm: SaveManager, key: string, value: any)
	sm.meta[key] = value
	sm.metaDirty = true
end

function SaveManager.dirtyCount(sm: SaveManager): number
	local n = if sm.metaDirty then 1 else 0
	for _, r in sm.regions do
		if r.dirty then
			n += 1
		end
	end
	return n
end

-- Writes up to `budget` dirty records whose retry time has come. Regions are
-- written before meta so the index never references unwritten regions.
-- Returns the number of successful writes.
function SaveManager.flush(sm: SaveManager, budget: number): number
	local now = sm.clock()
	local done = 0
	local keys: { string } = {}
	for k, r in sm.regions do
		if r.dirty and r.retryAt <= now then
			table.insert(keys, k)
		end
	end
	table.sort(keys)
	for _, k in keys do
		if budget <= 0 then
			break
		end
		local r = sm.regions[k]
		budget -= 1
		sm.stats.sets += 1
		if r.bytes > sm.maxValueBytes then
			-- cannot happen with 16 chunks of bounded size; refuse rather than truncate
			sm.stats.giveUps += 1
			r.retryAt = math.huge
			continue
		end
		-- snapshot the chunks table: if more edits arrive while a yielding
		-- write is in flight, the region stays dirty
		local snapshot = table.clone(r.chunks)
		r.dirty = false
		local ok = sm.backend.set(sm.worldId .. "/r/" .. k, { v = SaveManager.SCHEMA, chunks = snapshot })
		if ok then
			done += 1
			r.failures = 0
			if not sm.regionIndex[k] then
				sm.regionIndex[k] = true
				local list = sm.meta.regions or {}
				table.insert(list, k)
				table.sort(list)
				sm.meta.regions = list
				sm.metaDirty = true
			end
		else
			sm.stats.failures += 1
			r.dirty = true
			r.failures += 1
			if r.failures > sm.maxRetries then
				sm.stats.giveUps += 1
			end
			r.retryAt = now + math.min(2 ^ r.failures, 60)
		end
	end
	if sm.metaDirty and budget > 0 then
		sm.stats.sets += 1
		sm.metaDirty = false
		local ok = sm.backend.set(sm.worldId .. "/meta", table.clone(sm.meta))
		if ok then
			done += 1
		else
			sm.stats.failures += 1
			sm.metaDirty = true
		end
	end
	return done
end

-- Drops resident regions that are clean and hold no loaded chunk.
function SaveManager.evictRegions(sm: SaveManager, isChunkLoaded: (cx: number, cz: number) -> boolean): number
	local n = 0
	for k, r in sm.regions do
		if r.dirty then
			continue
		end
		local rx, rz = string.match(k, "^(%-?%d+),(%-?%d+)$")
		local bx, bz = tonumber(rx) :: number * 4, tonumber(rz) :: number * 4
		local any = false
		for dz = 0, 3 do
			for dx = 0, 3 do
				if isChunkLoaded(bx + dx, bz + dz) then
					any = true
				end
			end
		end
		if not any then
			sm.regions[k] = nil
			n += 1
		end
	end
	return n
end

-- Player records ------------------------------------------------------------

function SaveManager.loadPlayer(sm: SaveManager, userId: number): (boolean, any)
	local ok, v = get(sm, "p/" .. tostring(userId))
	if not ok then
		return false, v
	end
	if v == nil then
		return true, nil
	end
	local okM, rec = pcall(migrate, v, "player " .. userId)
	if not okM then
		return false, rec
	end
	return true, rec
end

function SaveManager.savePlayer(sm: SaveManager, userId: number, record: { [string]: any }): (boolean, string?)
	local r = table.clone(record)
	r.v = SaveManager.SCHEMA
	sm.stats.sets += 1
	local ok, err = sm.backend.set(sm.worldId .. "/p/" .. tostring(userId), r)
	if not ok then
		sm.stats.failures += 1
	end
	return ok, err
end

-- In-memory backend with fault injection, for tests and Studio play-solo.
function SaveManager.memoryBackend(failEvery: number?): (Backend, { [string]: any })
	local store: { [string]: any } = {}
	local calls = 0
	local function deep(v: any): any
		if type(v) ~= "table" then
			return v
		end
		local c = {}
		for k, x in v do
			c[k] = deep(x)
		end
		return c
	end
	local backend: Backend = {
		get = function(key: string): (boolean, any)
			calls += 1
			if failEvery and calls % failEvery == 0 then
				return false, "injected failure"
			end
			return true, deep(store[key])
		end,
		set = function(key: string, value: any): (boolean, string?)
			calls += 1
			if failEvery and calls % failEvery == 0 then
				return false, "injected failure"
			end
			store[key] = deep(value)
			return true, nil
		end,
	}
	return backend, store
end

return SaveManager
