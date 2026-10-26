--!strict
--!native
-- Bit-exact implementation of java.util.Random (48-bit LCG) in Luau doubles.
-- Legacy Console Edition derives from the Java codebase and seeds its
-- generators with this algorithm, so matching it is a prerequisite for any
-- seed-faithful generation. The 48-bit state is held as two 24-bit limbs so
-- every intermediate product stays below 2^53.

local JavaRandom = {}
JavaRandom.__index = JavaRandom

export type JavaRandom = typeof(setmetatable({} :: { hi: number, lo: number }, JavaRandom))

local TWO24 = 16777216
local TWO31 = 2147483648
local TWO32 = 4294967296
local TWO48 = 281474976710656
local M_HI = 0x5DE
local M_LO = 0xECE66D

-- Accepts any safe integer (|n| < 2^53); uses its low 48 bits as Java does.
-- For full 64-bit seeds use newFromParts with the two 32-bit halves.
function JavaRandom.new(seed: number): JavaRandom
	local self = setmetatable({ hi = 0, lo = 0 }, JavaRandom)
	self:setSeed(seed)
	return self
end

-- hi32 is the signed or unsigned upper word, lo32 the unsigned lower word.
function JavaRandom.newFromParts(hi32: number, lo32: number): JavaRandom
	local self = setmetatable({ hi = 0, lo = 0 }, JavaRandom)
	self:setSeedParts(hi32, lo32)
	return self
end

local function scramble(self: JavaRandom, s48: number)
	local lo = s48 % TWO24
	local hi = (s48 - lo) / TWO24
	self.lo = bit32.bxor(lo, M_LO)
	self.hi = bit32.bxor(hi, M_HI)
end

function JavaRandom.setSeed(self: JavaRandom, seed: number)
	assert(seed == math.floor(seed) and math.abs(seed) < 2 ^ 53, "seed must be a safe integer")
	scramble(self, seed % TWO48)
end

function JavaRandom.setSeedParts(self: JavaRandom, hi32: number, lo32: number)
	-- low 48 bits = (hi32 & 0xFFFF) * 2^32 + lo32
	local h = bit32.band(hi32 % TWO32, 0xFFFF)
	scramble(self, h * TWO32 + (lo32 % TWO32))
end

-- Advances the LCG and returns the top `bits` bits (unsigned, < 2^bits).
local function step(self: JavaRandom, bits: number): number
	local sHi, sLo = self.hi, self.lo
	local lo = sLo * M_LO + 0xB
	local newLo = lo % TWO24
	local carry = (lo - newLo) / TWO24
	local cross = (sHi * M_LO + sLo * M_HI + carry) % TWO24
	self.hi = cross
	self.lo = newLo
	return (cross * TWO24 + newLo) // 2 ^ (48 - bits)
end

-- java: protected int next(int bits) (signed when bits == 32)
function JavaRandom.next(self: JavaRandom, bits: number): number
	local v = step(self, bits)
	if bits == 32 and v >= TWO31 then
		v -= TWO32
	end
	return v
end

function JavaRandom.nextInt(self: JavaRandom, bound: number?): number
	if bound == nil then
		return self:next(32)
	end
	assert(bound > 0, "bound must be positive")
	if bit32.band(bound, bound - 1) == 0 and bound <= TWO31 then
		-- (int)((bound * (long)next(31)) >> 31)
		return (bound * step(self, 31)) // TWO31
	end
	local bits, val
	repeat
		bits = step(self, 31)
		val = bits % bound
	until bits - val + (bound - 1) < TWO31
	return val
end

function JavaRandom.nextBoolean(self: JavaRandom): boolean
	return step(self, 1) ~= 0
end

function JavaRandom.nextFloat(self: JavaRandom): number
	return step(self, 24) / TWO24
end

function JavaRandom.nextDouble(self: JavaRandom): number
	local a = step(self, 26)
	local b = step(self, 27)
	return (a * 134217728 + b) / 9007199254740992
end

-- Returns the 64-bit result as (hi32 signed, lo32 unsigned), since it cannot
-- be represented exactly in a double. Equals ((long)next(32) << 32) + next(32).
function JavaRandom.nextLongParts(self: JavaRandom): (number, number)
	local hi = self:next(32)
	local lo = self:next(32)
	if lo < 0 then
		-- adding a negative low word borrows from the high word
		hi -= 1
		lo += TWO32
	end
	if hi < -TWO31 then
		hi += TWO32
	end
	return hi, lo
end

-- Java's String.hashCode (UTF-16 code units; exact for BMP text), used to
-- turn non-numeric world seed text into a seed.
function JavaRandom.stringHash(s: string): number
	local h = 0
	for _, cp in utf8.codes(s) do
		if cp >= 0x10000 then
			local v = cp - 0x10000
			h = (h * 31 + 0xD800 + v // 1024) % TWO32
			h = (h * 31 + 0xDC00 + v % 1024) % TWO32
		else
			h = (h * 31 + cp) % TWO32
		end
	end
	if h >= TWO31 then
		h -= TWO32
	end
	return h
end

return JavaRandom
