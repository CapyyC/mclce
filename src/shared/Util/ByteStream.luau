--!strict
--!native
-- Growable little-endian byte writer and bounds-checked reader over buffers.
-- Readers raise "truncated" errors instead of reading garbage, so decoders
-- can pcall untrusted input (network / corrupted saves) safely.

local ByteStream = {}

export type Writer = { buf: buffer, len: number }
export type Reader = { buf: buffer, pos: number, size: number }

function ByteStream.writer(initial: number?): Writer
	return { buf = buffer.create(initial or 256), len = 0 }
end

local function ensure(w: Writer, extra: number)
	local need = w.len + extra
	local cap = buffer.len(w.buf)
	if need > cap then
		while cap < need do
			cap *= 2
		end
		local nb = buffer.create(cap)
		buffer.copy(nb, 0, w.buf, 0, w.len)
		w.buf = nb
	end
end

function ByteStream.u8(w: Writer, v: number)
	ensure(w, 1)
	buffer.writeu8(w.buf, w.len, v)
	w.len += 1
end

function ByteStream.u16(w: Writer, v: number)
	ensure(w, 2)
	buffer.writeu16(w.buf, w.len, v)
	w.len += 2
end

function ByteStream.i32(w: Writer, v: number)
	ensure(w, 4)
	buffer.writei32(w.buf, w.len, v)
	w.len += 4
end

function ByteStream.u32(w: Writer, v: number)
	ensure(w, 4)
	buffer.writeu32(w.buf, w.len, v)
	w.len += 4
end

function ByteStream.f64(w: Writer, v: number)
	ensure(w, 8)
	buffer.writef64(w.buf, w.len, v)
	w.len += 8
end

-- Unsigned LEB128 varint (v must be a non-negative integer < 2^53).
function ByteStream.varint(w: Writer, v: number)
	assert(v >= 0 and v == math.floor(v), "varint must be a non-negative integer")
	repeat
		local b = v % 128
		v = (v - b) / 128
		if v > 0 then
			b += 128
		end
		ByteStream.u8(w, b)
	until v == 0
end

function ByteStream.str(w: Writer, s: string)
	ByteStream.varint(w, #s)
	ensure(w, #s)
	buffer.writestring(w.buf, w.len, s)
	w.len += #s
end

function ByteStream.bytes(w: Writer, b: buffer)
	local n = buffer.len(b)
	ensure(w, n)
	buffer.copy(w.buf, w.len, b, 0, n)
	w.len += n
end

-- Trimmed copy of the written bytes.
function ByteStream.finish(w: Writer): buffer
	local out = buffer.create(w.len)
	buffer.copy(out, 0, w.buf, 0, w.len)
	return out
end

function ByteStream.reader(b: buffer): Reader
	return { buf = b, pos = 0, size = buffer.len(b) }
end

local function need(r: Reader, n: number)
	if r.pos + n > r.size then
		error("truncated", 0)
	end
end

function ByteStream.ru8(r: Reader): number
	need(r, 1)
	local v = buffer.readu8(r.buf, r.pos)
	r.pos += 1
	return v
end

function ByteStream.ru16(r: Reader): number
	need(r, 2)
	local v = buffer.readu16(r.buf, r.pos)
	r.pos += 2
	return v
end

function ByteStream.ri32(r: Reader): number
	need(r, 4)
	local v = buffer.readi32(r.buf, r.pos)
	r.pos += 4
	return v
end

function ByteStream.ru32(r: Reader): number
	need(r, 4)
	local v = buffer.readu32(r.buf, r.pos)
	r.pos += 4
	return v
end

function ByteStream.rf64(r: Reader): number
	need(r, 8)
	local v = buffer.readf64(r.buf, r.pos)
	r.pos += 8
	return v
end

function ByteStream.rvarint(r: Reader): number
	local v, mul = 0, 1
	for _ = 1, 8 do
		local b = ByteStream.ru8(r)
		v += (b % 128) * mul
		if b < 128 then
			return v
		end
		mul *= 128
	end
	error("varint too long", 0)
end

function ByteStream.rstr(r: Reader, maxLen: number?): string
	local n = ByteStream.rvarint(r)
	if maxLen and n > maxLen then
		error("string too long", 0)
	end
	need(r, n)
	local s = buffer.readstring(r.buf, r.pos, n)
	r.pos += n
	return s
end

function ByteStream.atEnd(r: Reader): boolean
	return r.pos >= r.size
end

return ByteStream
