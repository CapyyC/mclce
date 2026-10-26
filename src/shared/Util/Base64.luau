--!strict
--!native
-- RFC 4648 base64 (with padding) between buffers and strings. DataStore
-- values must be valid UTF-8, so binary chunk data is stored base64-encoded.

local Base64 = {}

local ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local ENC = buffer.create(64)
local DEC = buffer.create(256)
buffer.fill(DEC, 0, 255)
for i = 0, 63 do
	local c = string.byte(ALPHABET, i + 1)
	buffer.writeu8(ENC, i, c)
	buffer.writeu8(DEC, c, i)
end

function Base64.encode(b: buffer): string
	local n = buffer.len(b)
	local out = buffer.create(((n + 2) // 3) * 4)
	local o = 0
	local i = 0
	while i + 2 < n do
		local v = buffer.readu8(b, i) * 65536 + buffer.readu8(b, i + 1) * 256 + buffer.readu8(b, i + 2)
		buffer.writeu8(out, o, buffer.readu8(ENC, v // 262144))
		buffer.writeu8(out, o + 1, buffer.readu8(ENC, (v // 4096) % 64))
		buffer.writeu8(out, o + 2, buffer.readu8(ENC, (v // 64) % 64))
		buffer.writeu8(out, o + 3, buffer.readu8(ENC, v % 64))
		i += 3
		o += 4
	end
	local rem = n - i
	if rem == 1 then
		local v = buffer.readu8(b, i) * 65536
		buffer.writeu8(out, o, buffer.readu8(ENC, v // 262144))
		buffer.writeu8(out, o + 1, buffer.readu8(ENC, (v // 4096) % 64))
		buffer.writeu8(out, o + 2, 61)
		buffer.writeu8(out, o + 3, 61)
	elseif rem == 2 then
		local v = buffer.readu8(b, i) * 65536 + buffer.readu8(b, i + 1) * 256
		buffer.writeu8(out, o, buffer.readu8(ENC, v // 262144))
		buffer.writeu8(out, o + 1, buffer.readu8(ENC, (v // 4096) % 64))
		buffer.writeu8(out, o + 2, buffer.readu8(ENC, (v // 64) % 64))
		buffer.writeu8(out, o + 3, 61)
	end
	return buffer.tostring(out)
end

-- Returns nil for malformed input.
function Base64.decode(s: string): buffer?
	local n = #s
	if n % 4 ~= 0 then
		return nil
	end
	if n == 0 then
		return buffer.create(0)
	end
	local src = buffer.fromstring(s)
	local pad = 0
	if buffer.readu8(src, n - 1) == 61 then
		pad += 1
		if buffer.readu8(src, n - 2) == 61 then
			pad += 1
		end
	end
	local out = buffer.create(n // 4 * 3 - pad)
	local o = 0
	for i = 0, n - 1, 4 do
		local v = 0
		for k = 0, 3 do
			local c = buffer.readu8(src, i + k)
			local d
			if c == 61 and i + k >= n - pad then
				d = 0
			else
				d = buffer.readu8(DEC, c)
				if d == 255 then
					return nil
				end
			end
			v = v * 64 + d
		end
		local b0, b1, b2 = v // 65536, (v // 256) % 256, v % 256
		buffer.writeu8(out, o, b0)
		if o + 1 < buffer.len(out) then
			buffer.writeu8(out, o + 1, b1)
		end
		if o + 2 < buffer.len(out) then
			buffer.writeu8(out, o + 2, b2)
		end
		o += 3
	end
	return out
end

return Base64
