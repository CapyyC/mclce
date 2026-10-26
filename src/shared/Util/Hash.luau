--!strict
--!native
-- Deterministic 32-bit integer hashing on Luau doubles via bit32.
-- Used to derive independent per-chunk / per-column random streams from the
-- world seed so generation never depends on chunk load order.

local Hash = {}

local band, bxor, rshift, lrotate = bit32.band, bit32.bxor, bit32.rshift, bit32.lrotate

-- Exact (a * b) mod 2^32 for 32-bit unsigned a, b.
local function mul32(a: number, b: number): number
	local aLo, aHi = band(a, 0xFFFF), rshift(a, 16)
	local bLo, bHi = band(b, 0xFFFF), rshift(b, 16)
	return (aLo * bLo + band(aHi * bLo + aLo * bHi, 0xFFFF) * 65536) % 4294967296
end
Hash.mul32 = mul32

local P1, P2, P3, P4, P5 = 0x9E3779B1, 0x85EBCA77, 0xC2B2AE3D, 0x27D4EB2F, 0x165667B1

local function mixIn(h: number, v: number): number
	h = (h + mul32(v % 4294967296, P3)) % 4294967296
	return mul32(lrotate(h, 17), P4)
end

local function finalize(h: number): number
	h = bxor(h, rshift(h, 15))
	h = mul32(h, P2)
	h = bxor(h, rshift(h, 13))
	h = mul32(h, P3)
	return bxor(h, rshift(h, 16))
end

-- Hash of up to five integers (negative values are reduced mod 2^32).
function Hash.hash(a: number, b: number?, c: number?, d: number?, e: number?): number
	local h = (P5 + 20) % 4294967296
	h = mixIn(h, a)
	if b then
		h = mixIn(h, b)
	end
	if c then
		h = mixIn(h, c)
	end
	if d then
		h = mixIn(h, d)
	end
	if e then
		h = mixIn(h, e)
	end
	return finalize(h)
end

-- Uniform float in [0, 1) from a hash.
function Hash.unit(h: number): number
	return h / 4294967296
end

Hash._P1 = P1

return Hash
