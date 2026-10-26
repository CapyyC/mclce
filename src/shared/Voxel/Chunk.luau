--!strict
--!native
-- A 16 x 256 x 16 chunk column made of lazily allocated 16^3 sections.
-- Each section stores packed block states (id*16+meta) as u16 in a buffer.
-- An all-air section is represented by nil, so sky-heavy columns are cheap.

local Coords = require("./Coords")

local SECTION_BYTES = Coords.SECTION_VOLUME * 2

export type Section = {
	states: buffer,
	nonAir: number,
}

export type Chunk = {
	cx: number,
	cz: number,
	sections: { [number]: Section? }, -- keys 0..15
	-- Incremented on every change of a section; renderers compare against the
	-- version they last meshed to detect staleness.
	sectionVersion: { number },
	-- Highest y+1 of any non-air block per column (0 = empty column).
	heightmap: buffer, -- 256 x u16
	-- Persistence bookkeeping.
	dirty: boolean,
	generated: boolean,
}

local Chunk = {}

local function newSection(): Section
	return { states = buffer.create(SECTION_BYTES), nonAir = 0 }
end

function Chunk.new(cx: number, cz: number): Chunk
	return {
		cx = cx,
		cz = cz,
		sections = {},
		sectionVersion = table.create(Coords.SECTION_COUNT, 0),
		heightmap = buffer.create(512),
		dirty = false,
		generated = false,
	}
end

-- Local coordinates x,z in [0,15], y in [0,255]. Out-of-range y returns air.
function Chunk.getState(chunk: Chunk, x: number, y: number, z: number): number
	if y < 0 or y >= 256 then
		return 0
	end
	local s = chunk.sections[y // 16]
	if s == nil then
		return 0
	end
	return buffer.readu16(s.states, (x + z * 16 + (y % 16) * 256) * 2)
end

function Chunk.getId(chunk: Chunk, x: number, y: number, z: number): number
	return Chunk.getState(chunk, x, y, z) // 16
end

local function recomputeColumnHeight(chunk: Chunk, x: number, z: number, fromY: number)
	local y = fromY
	while y >= 0 do
		local s = chunk.sections[y // 16]
		if s == nil then
			y = (y // 16) * 16 - 1
		else
			if buffer.readu16(s.states, (x + z * 16 + (y % 16) * 256) * 2) ~= 0 then
				break
			end
			y -= 1
		end
	end
	buffer.writeu16(chunk.heightmap, (x + z * 16) * 2, y + 1)
end

-- Sets a block state; returns the previous state. Writes outside the world
-- height are ignored and return 0. markDirty=false is used by generators so
-- that freshly generated chunks are not considered player-modified.
function Chunk.setState(chunk: Chunk, x: number, y: number, z: number, state: number, markDirty: boolean?): number
	if y < 0 or y >= 256 then
		return 0
	end
	local si = y // 16
	local s = chunk.sections[si]
	if s == nil then
		if state == 0 then
			return 0
		end
		s = newSection()
		chunk.sections[si] = s
	end
	assert(s)
	local off = (x + z * 16 + (y % 16) * 256) * 2
	local old = buffer.readu16(s.states, off)
	if old == state then
		return old
	end
	buffer.writeu16(s.states, off, state)
	if old == 0 then
		s.nonAir += 1
	elseif state == 0 then
		s.nonAir -= 1
		if s.nonAir == 0 then
			chunk.sections[si] = nil
		end
	end
	chunk.sectionVersion[si + 1] += 1
	if markDirty ~= false then
		chunk.dirty = true
	end
	local hOff = (x + z * 16) * 2
	local h = buffer.readu16(chunk.heightmap, hOff)
	if state ~= 0 and y + 1 > h then
		buffer.writeu16(chunk.heightmap, hOff, y + 1)
	elseif state == 0 and y + 1 == h then
		recomputeColumnHeight(chunk, x, z, y - 1)
	end
	return old
end

function Chunk.height(chunk: Chunk, x: number, z: number): number
	return buffer.readu16(chunk.heightmap, (x + z * 16) * 2)
end

function Chunk.getSection(chunk: Chunk, si: number): Section?
	return chunk.sections[si]
end

-- Replaces a whole section (used by deserialisation). states must be a
-- SECTION_BYTES buffer; it is adopted, not copied.
function Chunk.putSection(chunk: Chunk, si: number, states: buffer?)
	if states == nil then
		chunk.sections[si] = nil
	else
		assert(buffer.len(states) == SECTION_BYTES, "bad section size")
		local n = 0
		for i = 0, SECTION_BYTES - 2, 2 do
			if buffer.readu16(states, i) ~= 0 then
				n += 1
			end
		end
		chunk.sections[si] = if n > 0 then { states = states, nonAir = n } else nil
	end
	chunk.sectionVersion[si + 1] += 1
end

-- Full heightmap rebuild (after bulk generation or load).
function Chunk.rebuildHeightmap(chunk: Chunk)
	for z = 0, 15 do
		for x = 0, 15 do
			recomputeColumnHeight(chunk, x, z, 255)
		end
	end
end

function Chunk.highestSection(chunk: Chunk): number
	for si = Coords.SECTION_COUNT - 1, 0, -1 do
		if chunk.sections[si] then
			return si
		end
	end
	return -1
end

function Chunk.countNonAir(chunk: Chunk): number
	local n = 0
	for _, s in chunk.sections do
		n += s.nonAir
	end
	return n
end

-- Approximate retained bytes (buffers only), for memory budgets.
function Chunk.memoryBytes(chunk: Chunk): number
	local n = 512
	for _ in chunk.sections do
		n += SECTION_BYTES
	end
	return n
end

Chunk.SECTION_BYTES = SECTION_BYTES

return Chunk
