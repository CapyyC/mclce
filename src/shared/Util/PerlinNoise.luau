--!strict
--!native
-- Ken Perlin's "Improved Noise" (2002 reference implementation, public
-- domain algorithm) with a permutation shuffled from a JavaRandom stream and
-- a random coordinate offset, the construction used by classic Minecraft-
-- family generators. Octave sums are provided by OctaveNoise.

local JavaRandom = require("./JavaRandom")

export type Perlin = {
	perm: { number }, -- 512 entries, 1-based
	permBuf: buffer, -- same 512 entries as u8, for the fast path
	ox: number,
	oy: number,
	oz: number,
}

local PerlinNoise = {}

function PerlinNoise.new(rng: JavaRandom.JavaRandom): Perlin
	local ox = rng:nextDouble() * 256
	local oy = rng:nextDouble() * 256
	local oz = rng:nextDouble() * 256
	local p = table.create(512, 0)
	for i = 0, 255 do
		p[i + 1] = i
	end
	for i = 0, 255 do
		local j = rng:nextInt(256 - i) + i
		p[i + 1], p[j + 1] = p[j + 1], p[i + 1]
	end
	for i = 0, 255 do
		p[i + 257] = p[i + 1]
	end
	local pb = buffer.create(512)
	for i = 0, 511 do
		buffer.writeu8(pb, i, p[i + 1])
	end
	return { perm = p, permBuf = pb, ox = ox, oy = oy, oz = oz }
end

local function fade(t: number): number
	return t * t * t * (t * (t * 6 - 15) + 10)
end

local function grad(hash: number, x: number, y: number, z: number): number
	local h = hash % 16
	local u = if h < 8 then x else y
	local v = if h < 4 then y elseif h == 12 or h == 14 then x else z
	return (if h % 2 == 0 then u else -u) + (if (h // 2) % 2 == 0 then v else -v)
end

-- Gradient vectors for the 16 hash values, derived from grad() so the fast
-- path is exactly the reference function: grad(h,x,y,z) = GX*x + GY*y + GZ*z.
local GX, GY, GZ = buffer.create(16), buffer.create(16), buffer.create(16)
for h = 0, 15 do
	buffer.writei8(GX, h, grad(h, 1, 0, 0))
	buffer.writei8(GY, h, grad(h, 0, 1, 0))
	buffer.writei8(GZ, h, grad(h, 0, 0, 1))
end

-- Reference implementation (kept for tests; mirrors Perlin's Java code).
function PerlinNoise.sampleReference(n: Perlin, x: number, y: number, z: number): number
	x += n.ox
	y += n.oy
	z += n.oz
	local fx, fy, fz = math.floor(x), math.floor(y), math.floor(z)
	local X, Y, Z = fx % 256, fy % 256, fz % 256
	x -= fx
	y -= fy
	z -= fz
	local u, v, w = fade(x), fade(y), fade(z)
	local p = n.perm
	local A = p[X + 1] + Y
	local AA = p[A + 1] + Z
	local AB = p[A + 2] + Z
	local Bv = p[X + 2] + Y
	local BA = p[Bv + 1] + Z
	local BB = p[Bv + 2] + Z
	local x1, y1, z1 = x - 1, y - 1, z - 1
	local g1 = grad(p[AA + 1], x, y, z)
	local g2 = grad(p[BA + 1], x1, y, z)
	local g3 = grad(p[AB + 1], x, y1, z)
	local g4 = grad(p[BB + 1], x1, y1, z)
	local g5 = grad(p[AA + 2], x, y, z1)
	local g6 = grad(p[BA + 2], x1, y, z1)
	local g7 = grad(p[AB + 2], x, y1, z1)
	local g8 = grad(p[BB + 2], x1, y1, z1)
	local l1 = g1 + u * (g2 - g1)
	local l2 = g3 + u * (g4 - g3)
	local l3 = g5 + u * (g6 - g5)
	local l4 = g7 + u * (g8 - g7)
	local m1 = l1 + v * (l2 - l1)
	local m2 = l3 + v * (l4 - l3)
	return m1 + w * (m2 - m1)
end

-- Returns noise in roughly [-1, 1]. Optimised: u8 permutation buffer and
-- table-driven gradients (no branches), identical results to the reference.
function PerlinNoise.sample(n: Perlin, x: number, y: number, z: number): number
	x += n.ox
	y += n.oy
	z += n.oz
	local fx, fy, fz = math.floor(x), math.floor(y), math.floor(z)
	local X, Y, Z = fx % 256, fy % 256, fz % 256
	x -= fx
	y -= fy
	z -= fz
	local u = x * x * x * (x * (x * 6 - 15) + 10)
	local v = y * y * y * (y * (y * 6 - 15) + 10)
	local w = z * z * z * (z * (z * 6 - 15) + 10)
	local p = n.permBuf
	local A = buffer.readu8(p, X) + Y
	local AA = buffer.readu8(p, A) + Z
	local AB = buffer.readu8(p, A + 1) + Z
	local Bv = buffer.readu8(p, X + 1) + Y
	local BA = buffer.readu8(p, Bv) + Z
	local BB = buffer.readu8(p, Bv + 1) + Z
	local x1, y1, z1 = x - 1, y - 1, z - 1
	local h = buffer.readu8(p, AA) % 16
	local g1 = buffer.readi8(GX, h) * x + buffer.readi8(GY, h) * y + buffer.readi8(GZ, h) * z
	h = buffer.readu8(p, BA) % 16
	local g2 = buffer.readi8(GX, h) * x1 + buffer.readi8(GY, h) * y + buffer.readi8(GZ, h) * z
	h = buffer.readu8(p, AB) % 16
	local g3 = buffer.readi8(GX, h) * x + buffer.readi8(GY, h) * y1 + buffer.readi8(GZ, h) * z
	h = buffer.readu8(p, BB) % 16
	local g4 = buffer.readi8(GX, h) * x1 + buffer.readi8(GY, h) * y1 + buffer.readi8(GZ, h) * z
	h = buffer.readu8(p, AA + 1) % 16
	local g5 = buffer.readi8(GX, h) * x + buffer.readi8(GY, h) * y + buffer.readi8(GZ, h) * z1
	h = buffer.readu8(p, BA + 1) % 16
	local g6 = buffer.readi8(GX, h) * x1 + buffer.readi8(GY, h) * y + buffer.readi8(GZ, h) * z1
	h = buffer.readu8(p, AB + 1) % 16
	local g7 = buffer.readi8(GX, h) * x + buffer.readi8(GY, h) * y1 + buffer.readi8(GZ, h) * z1
	h = buffer.readu8(p, BB + 1) % 16
	local g8 = buffer.readi8(GX, h) * x1 + buffer.readi8(GY, h) * y1 + buffer.readi8(GZ, h) * z1
	local l1 = g1 + u * (g2 - g1)
	local l2 = g3 + u * (g4 - g3)
	local l3 = g5 + u * (g6 - g5)
	local l4 = g7 + u * (g8 - g7)
	local m1 = l1 + v * (l2 - l1)
	local m2 = l3 + v * (l4 - l3)
	return m1 + w * (m2 - m1)
end

export type Octaves = { layers: { Perlin }, count: number }

local OctaveNoise = {}
PerlinNoise.Octaves = OctaveNoise

function OctaveNoise.new(rng: JavaRandom.JavaRandom, count: number): Octaves
	local layers: { Perlin } = {}
	for i = 1, count do
		layers[i] = PerlinNoise.new(rng)
	end
	return { layers = layers, count = count }
end

-- Sum of octaves; octave i has frequency 2^-(i-1) relative to the input
-- scale and amplitude 2^(i-1) (classic "lowest octave first" convention), so
-- the result spans roughly [-(2^count - 1), 2^count - 1].
function OctaveNoise.sample(o: Octaves, x: number, y: number, z: number): number
	local total = 0
	local f = 1
	local layers = o.layers
	for i = 1, o.count do
		total += PerlinNoise.sample(layers[i], x * f, y * f, z * f) / f
		f *= 0.5
	end
	return total
end

-- Normalised fractal noise in about [-1, 1]: octave i frequency 2^(i-1).
function OctaveNoise.fbm(o: Octaves, x: number, y: number, z: number): number
	local total, amp, f, norm = 0, 1, 1, 0
	local layers = o.layers
	for i = 1, o.count do
		total += PerlinNoise.sample(layers[i], x * f, y * f, z * f) * amp
		norm += amp
		amp *= 0.5
		f *= 2
	end
	return total / norm
end

return PerlinNoise
