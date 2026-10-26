--!strict
--!native
-- Versioned binary chunk serialisation shared by networking and saves.
--
-- v1 layout (little endian):
--   u8  version (=1)
--   i32 cx, i32 cz
--   u16 sectionMask (bit si set = section present)
--   per present section, ascending si:
--     varint runCount, then runCount x (varint length, u16 state)
--     runs cover the 4096 states in section index order (x + z*16 + y*256)
--   varint blockEntityBytes, then that many opaque bytes (reserved; 0 in v1)
-- Unknown block ids are preserved verbatim.

local Chunk = require("../Voxel/Chunk")
local ByteStream = require("../Util/ByteStream")

local ChunkCodec = {}

ChunkCodec.VERSION = 1

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
	ByteStream.varint(w, 0) -- block entities (reserved)
	return ByteStream.finish(w)
end

-- Decodes; raises on malformed input (callers pcall untrusted data).
function ChunkCodec.decode(b: buffer): Chunk.Chunk
	local r = ByteStream.reader(b)
	local version = ByteStream.ru8(r)
	if version ~= 1 then
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
	local beBytes = ByteStream.rvarint(r)
	if beBytes > 0 then
		error("block entities not supported in v1", 0)
	end
	Chunk.rebuildHeightmap(chunk)
	chunk.generated = true
	return chunk
end

return ChunkCodec
