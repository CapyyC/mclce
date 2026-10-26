--!strict
-- A 64-bit world seed held as two 32-bit words (Luau doubles cannot hold an
-- arbitrary Java long). Text seeds follow the Java convention: a string that
-- parses as a decimal integer is used directly, anything else uses
-- String.hashCode().
local JavaRandom = require("../Util/JavaRandom")

export type WorldSeed = { hi: number, lo: number }

local WorldSeed = {}

local TWO32 = 4294967296

function WorldSeed.fromNumber(n: number): WorldSeed
	assert(n == math.floor(n) and math.abs(n) < 2 ^ 53, "seed must be a safe integer")
	local lo = n % TWO32
	local hi = (n - lo) / TWO32 -- floor division for negatives keeps two's complement
	if hi < 0 then
		hi += TWO32
	end
	return { hi = hi, lo = lo }
end

function WorldSeed.fromString(s: string): WorldSeed
	local trimmed = string.match(s, "^%s*(.-)%s*$") or s
	if string.match(trimmed, "^%-?%d+$") and #trimmed <= 16 then
		local n = tonumber(trimmed)
		if n and n ~= 0 then
			return WorldSeed.fromNumber(n)
		end
	end
	return WorldSeed.fromNumber(JavaRandom.stringHash(trimmed))
end

function WorldSeed.random(rng: JavaRandom.JavaRandom): WorldSeed
	local hi, lo = rng:nextLongParts()
	return { hi = hi % TWO32, lo = lo }
end

function WorldSeed.newRandom(seed: WorldSeed): JavaRandom.JavaRandom
	return JavaRandom.newFromParts(seed.hi, seed.lo)
end

function WorldSeed.toString(seed: WorldSeed): string
	-- decimal of the signed 64-bit value is not representable exactly; use hex
	return string.format("%08x%08x", seed.hi, seed.lo)
end

return WorldSeed
