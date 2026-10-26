--!strict
-- Player-centred chunk load/unload planning. Pure bookkeeping: callers
-- perform the actual generation/loading/meshing in the callbacks, under a
-- per-tick budget.
--
-- * Desired set = chunks within `radius` (circular) of any viewer, clipped to
--   the world border.
-- * Requests are ordered by distance to the nearest viewer, ties broken by
--   coordinates, so the order is deterministic.
-- * Requests that are no longer desired are cancelled on the next update.
-- * Loaded chunks farther than radius + hysteresis are unloaded (farthest
--   first), and also when the loaded count exceeds maxLoaded.

local Coords = require("../Voxel/Coords")

export type Viewer = { cx: number, cz: number }

export type Callbacks = {
	load: (cx: number, cz: number) -> (),
	unload: (cx: number, cz: number) -> (),
	inBounds: ((cx: number, cz: number) -> boolean)?,
}

export type Scheduler = {
	radius: number,
	hysteresis: number,
	maxLoaded: number,
	loaded: { [number]: boolean },
	loadedCount: number,
	queue: { number }, -- chunk keys, nearest first
	queued: { [number]: boolean },
	viewers: { Viewer },
	callbacks: Callbacks,
	stats: { loads: number, unloads: number, cancelled: number },
}

local ChunkScheduler = {}

function ChunkScheduler.new(callbacks: Callbacks, radius: number, opts: { hysteresis: number?, maxLoaded: number? }?): Scheduler
	local o = opts or {} :: { hysteresis: number?, maxLoaded: number? }
	return {
		radius = radius,
		hysteresis = o.hysteresis or 2,
		maxLoaded = o.maxLoaded or 4096,
		loaded = {},
		loadedCount = 0,
		queue = {},
		queued = {},
		viewers = {},
		callbacks = callbacks,
		stats = { loads = 0, unloads = 0, cancelled = 0 },
	}
end

local function distSq(s: Scheduler, cx: number, cz: number): number
	local best = math.huge
	for _, v in s.viewers do
		local dx, dz = cx - v.cx, cz - v.cz
		local d = dx * dx + dz * dz
		if d < best then
			best = d
		end
	end
	return best
end
ChunkScheduler.distSq = distSq

-- Recomputes the desired set for the given viewers and rebuilds the queue.
function ChunkScheduler.setViewers(s: Scheduler, viewers: { Viewer })
	s.viewers = viewers
	local r = s.radius
	local r2 = r * r
	local inBounds = s.callbacks.inBounds
	local want: { [number]: number } = {}
	for _, v in viewers do
		for dz = -r, r do
			for dx = -r, r do
				if dx * dx + dz * dz <= r2 then
					local cx, cz = v.cx + dx, v.cz + dz
					if inBounds == nil or inBounds(cx, cz) then
						local k = Coords.chunkKey(cx, cz)
						if not s.loaded[k] then
							want[k] = 0
						end
					end
				end
			end
		end
	end
	-- cancel queued chunks that are no longer wanted
	for k in s.queued do
		if want[k] == nil then
			s.stats.cancelled += 1
		end
	end
	local queue: { number } = {}
	local dist: { [number]: number } = {}
	for k in want do
		local cx, cz = Coords.unpackChunkKey(k)
		dist[k] = distSq(s, cx, cz)
		table.insert(queue, k)
	end
	table.sort(queue, function(a: number, b: number): boolean
		local da, db = dist[a], dist[b]
		if da ~= db then
			return da < db
		end
		return a < b
	end)
	s.queue = queue
	local queued: { [number]: boolean } = {}
	for _, k in queue do
		queued[k] = true
	end
	s.queued = queued
end

-- Unloads chunks out of range (and over budget). Returns number unloaded.
function ChunkScheduler.collect(s: Scheduler): number
	local limit = s.radius + s.hysteresis
	local limit2 = limit * limit
	local victims: { number } = {}
	local dist: { [number]: number } = {}
	for k in s.loaded do
		local cx, cz = Coords.unpackChunkKey(k)
		local d = distSq(s, cx, cz)
		dist[k] = d
		table.insert(victims, k)
	end
	table.sort(victims, function(a: number, b: number): boolean
		if dist[a] ~= dist[b] then
			return dist[a] > dist[b]
		end
		return a < b
	end)
	local n = 0
	for _, k in victims do
		if dist[k] > limit2 or s.loadedCount > s.maxLoaded then
			local cx, cz = Coords.unpackChunkKey(k)
			s.loaded[k] = nil
			s.loadedCount -= 1
			s.callbacks.unload(cx, cz)
			s.stats.unloads += 1
			n += 1
		else
			break
		end
	end
	return n
end

-- Performs up to `budget` loads (nearest first). Returns number performed.
function ChunkScheduler.step(s: Scheduler, budget: number): number
	local done = 0
	local q = s.queue
	local i = 1
	while done < budget and i <= #q do
		local k = q[i]
		i += 1
		if s.queued[k] and not s.loaded[k] then
			if s.loadedCount >= s.maxLoaded then
				break
			end
			s.queued[k] = nil
			local cx, cz = Coords.unpackChunkKey(k)
			s.loaded[k] = true
			s.loadedCount += 1
			s.callbacks.load(cx, cz)
			s.stats.loads += 1
			done += 1
		end
	end
	-- drop consumed prefix
	if i > 1 then
		table.move(q, i, #q + i - 1, 1)
		for j = #q, #q - i + 2, -1 do
			q[j] = nil
		end
	end
	return done
end

function ChunkScheduler.pending(s: Scheduler): number
	return #s.queue
end

function ChunkScheduler.isLoaded(s: Scheduler, cx: number, cz: number): boolean
	return s.loaded[Coords.chunkKey(cx, cz)] == true
end

-- Marks a chunk unloaded without invoking callbacks (e.g. its owner evicted it).
function ChunkScheduler.forget(s: Scheduler, cx: number, cz: number)
	local k = Coords.chunkKey(cx, cz)
	if s.loaded[k] then
		s.loaded[k] = nil
		s.loadedCount -= 1
	end
end

return ChunkScheduler
