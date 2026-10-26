--!strict
-- Tracks which 16^3 sections need (re)meshing. A block change dirties its own
-- section plus the face-adjacent sections it borders; a chunk arriving or
-- leaving dirties the border sections of its four neighbours. Popping is
-- nearest-first relative to a focus point and bounded per call.

local Coords = require("../Voxel/Coords")

export type RemeshQueue = {
	dirty: { [number]: boolean },
	count: number,
	stats: { marked: number, popped: number },
}

local RemeshQueue = {}

-- section key: chunkKey * 16 + si
local function skey(cx: number, cz: number, si: number): number
	return Coords.chunkKey(cx, cz) * 16 + si
end
RemeshQueue.sectionKey = skey

function RemeshQueue.unpack(k: number): (number, number, number)
	local si = k % 16
	local cx, cz = Coords.unpackChunkKey((k - si) / 16)
	return cx, cz, si
end

function RemeshQueue.new(): RemeshQueue
	return { dirty = {}, count = 0, stats = { marked = 0, popped = 0 } }
end

function RemeshQueue.markSection(q: RemeshQueue, cx: number, cz: number, si: number)
	if si < 0 or si > 15 then
		return
	end
	local k = skey(cx, cz, si)
	if not q.dirty[k] then
		q.dirty[k] = true
		q.count += 1
		q.stats.marked += 1
	end
end

function RemeshQueue.markBlock(q: RemeshQueue, wx: number, wy: number, wz: number)
	local cx, cz, si = wx // 16, wz // 16, wy // 16
	local lx, ly, lz = wx % 16, wy % 16, wz % 16
	RemeshQueue.markSection(q, cx, cz, si)
	if lx == 0 then
		RemeshQueue.markSection(q, cx - 1, cz, si)
	elseif lx == 15 then
		RemeshQueue.markSection(q, cx + 1, cz, si)
	end
	if lz == 0 then
		RemeshQueue.markSection(q, cx, cz - 1, si)
	elseif lz == 15 then
		RemeshQueue.markSection(q, cx, cz + 1, si)
	end
	if ly == 0 then
		RemeshQueue.markSection(q, cx, cz, si - 1)
	elseif ly == 15 then
		RemeshQueue.markSection(q, cx, cz, si + 1)
	end
end

-- maxSection: highest non-empty section index of each affected chunk, or 15.
function RemeshQueue.markChunk(q: RemeshQueue, cx: number, cz: number, includeNeighbours: boolean?, top: number?)
	local t = top or 15
	for si = 0, t do
		RemeshQueue.markSection(q, cx, cz, si)
		if includeNeighbours ~= false then
			RemeshQueue.markSection(q, cx - 1, cz, si)
			RemeshQueue.markSection(q, cx + 1, cz, si)
			RemeshQueue.markSection(q, cx, cz - 1, si)
			RemeshQueue.markSection(q, cx, cz + 1, si)
		end
	end
end

-- Drops every dirty section of a chunk (it was unloaded).
function RemeshQueue.dropChunk(q: RemeshQueue, cx: number, cz: number)
	for si = 0, 15 do
		local k = skey(cx, cz, si)
		if q.dirty[k] then
			q.dirty[k] = nil
			q.count -= 1
		end
	end
end

-- Pops up to `budget` sections, nearest (in chunks, then height) to the focus.
-- `accept(cx, cz)` may reject sections whose chunk (or neighbours) aren't
-- ready yet; those stay queued.
function RemeshQueue.pop(q: RemeshQueue, budget: number, fcx: number, fcz: number, fsi: number, accept: ((cx: number, cz: number) -> boolean)?): { number }
	local cand: { number } = {}
	local score: { [number]: number } = {}
	for k in q.dirty do
		local cx, cz, si = RemeshQueue.unpack(k)
		if accept == nil or accept(cx, cz) then
			local dx, dz, dy = cx - fcx, cz - fcz, si - fsi
			score[k] = dx * dx + dz * dz + dy * dy * 0.25
			table.insert(cand, k)
		end
	end
	table.sort(cand, function(a: number, b: number): boolean
		if score[a] ~= score[b] then
			return score[a] < score[b]
		end
		return a < b
	end)
	local out: { number } = {}
	for i = 1, math.min(budget, #cand) do
		local k = cand[i]
		q.dirty[k] = nil
		q.count -= 1
		q.stats.popped += 1
		table.insert(out, k)
	end
	return out
end

return RemeshQueue
