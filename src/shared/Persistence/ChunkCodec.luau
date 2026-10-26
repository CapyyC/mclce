--!strict
--!native
-- Versioned binary chunk serialisation shared by networking and saves.
--
-- v2 layout (little endian; v1 = same without block entities):
--   u8  version (=1)
--   i32 cx, i32 cz
--   u16 sectionMask (bit si set = section present)
--   per present section, ascending si:
--     varint runCount, then runCount x (varint length, u16 state)
--     runs cover the 4096 states in section index order (x + z*16 + y*256)
--   v1: varint 0 (reserved)
--   v2: varint entityCount, per entity:
--     u16 localIndex (x + z*16 + y*256), str kind, varint slotCount,
--     slotCount x (u8 slot, u16 id, u8 meta, u8 count, u16 damage),
--     varint burn, varint burnTotal, varint cook
-- Unknown block ids are preserved verbatim.

local Chunk = require("../Voxel/Chunk")
local ByteStream = require("../Util/ByteStream")

local ChunkCodec = {}

ChunkCodec.VERSION = 2
ChunkCodec.MAX_ENTITIES = 4096

function ChunkCodec.encode(chunk: Chunk.Chunk): buffer
	local w = ByteStream.writer(1024)
	ByteStream.u8(w, ChunkCodec.VERSION)
	ByteStream.i32(w, chunk.cx)
	ByteStream.i32(w, chunk.cz)
	local mask = 0
	for si = 0, 15 do
		if chunk.sections[si] then
			mask += 2 ^ si
		end
	end
	ByteStream.u16(w, mask)
	-- scratch for runs so the run count can precede them
	local runLen: { number } = {}
	local runState: { number } = {}
	for si = 0, 15 do
		local s = chunk.sections[si]
		if s == nil then
			continue
		end
		local states = s.states
		local n = 0
		local cur = buffer.readu16(states, 0)
		local len = 1
		for i = 1, 4095 do
			local v = buffer.readu16(states, i * 2)
			if v == cur then
				len += 1
			else
				n += 1
				runLen[n] = len
				runState[n] = cur
				cur = v
				len = 1
			end
		end
		n += 1
		runLen[n] = len
		runState[n] = cur
		ByteStream.varint(w, n)
		for r = 1, n do
			ByteStream.varint(w, runLen[r])
			ByteStream.u16(w, runState[r])
		end
	end
	-- block entities, sorted by index for deterministic output
	local bes = chunk.blockEntities
	local keys: { number } = {}
	if bes then
		for k in bes do
			table.insert(keys, k)
		end
		table.sort(keys)
	end
	ByteStream.varint(w, #keys)
	for _, k in keys do
		local e = (bes :: any)[k]
		ByteStream.u16(w, k)
		ByteStream.str(w, e.kind)
		local slots: { number } = {}
		for i, st in e.slots do
			if st then
				table.insert(slots, i)
			end
		end
		table.sort(slots)
		ByteStream.varint(w, #slots)
		for _, i in slots do
			local st = e.slots[i]
			ByteStream.u8(w, i)
			ByteStream.u16(w, st.id)
			ByteStream.u8(w, st.meta)
			ByteStream.u8(w, st.count)
			ByteStream.u16(w, st.damage)
		end
		ByteStream.varint(w, e.burn or 0)
		ByteStream.varint(w, e.burnTotal or 0)
		ByteStream.varint(w, e.cook or 0)
	end
	return ByteStream.finish(w)
end

-- Decodes; raises on malformed input (callers pcall untrusted data).
function ChunkCodec.decode(b: buffer): Chunk.Chunk
	local r = ByteStream.reader(b)
	local version = ByteStream.ru8(r)
	if version ~= 1 and version ~= 2 then
		error("unsupported chunk version " .. version, 0)
	end
	local cx = ByteStream.ri32(r)
	local cz = ByteStream.ri32(r)
	local mask = ByteStream.ru16(r)
	local chunk = Chunk.new(cx, cz)
	for si = 0, 15 do
		if bit32.extract(mask, si) == 0 then
			continue
		end
		local states = buffer.create(Chunk.SECTION_BYTES)
		local runs = ByteStream.rvarint(r)
		if runs < 1 or runs > 4096 then
			error("bad run count", 0)
		end
		local pos = 0
		for _ = 1, runs do
			local len = ByteStream.rvarint(r)
			local st = ByteStream.ru16(r)
			if len < 1 or pos + len > 4096 then
				error("run overflow", 0)
			end
			if st ~= 0 then
				for i = pos, pos + len - 1 do
					buffer.writeu16(states, i * 2, st)
				end
			end
			pos += len
		end
		if pos ~= 4096 then
			error("section underrun", 0)
		end
		Chunk.putSection(chunk, si, states)
	end
	local n = ByteStream.rvarint(r)
	if version == 1 and n > 0 then
		error("v1 chunks carry no block entities", 0)
	end
	if n > ChunkCodec.MAX_ENTITIES then
		error("too many block entities", 0)
	end
	for _ = 1, n do
		local idx = ByteStream.ru16(r)
		local kind = ByteStream.rstr(r, 32)
		local slotCount = ByteStream.rvarint(r)
		if slotCount > 64 then
			error("too many slots", 0)
		end
		local e = { kind = kind, slots = {}, burn = 0, burnTotal = 0, cook = 0, version = 0 }
		for _ = 1, slotCount do
			local slot = ByteStream.ru8(r)
			local id = ByteStream.ru16(r)
			local meta = ByteStream.ru8(r)
			local count = ByteStream.ru8(r)
			local damage = ByteStream.ru16(r)
			if slot < 1 or count < 1 then
				error("bad slot", 0)
			end
			e.slots[slot] = { id = id, meta = meta, count = count, damage = damage }
		end
		e.burn = ByteStream.rvarint(r)
		e.burnTotal = ByteStream.rvarint(r)
		e.cook = ByteStream.rvarint(r)
		if chunk.blockEntities == nil then
			chunk.blockEntities = {}
		end
		(chunk.blockEntities :: any)[idx] = e
	end
	Chunk.rebuildHeightmap(chunk)
	chunk.generated = true
	return chunk
end

return ChunkCodec
