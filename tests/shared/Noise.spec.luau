local JavaRandom = require("../../src/shared/Util/JavaRandom")
local PerlinNoise = require("../../src/shared/Util/PerlinNoise")
local Hash = require("../../src/shared/Util/Hash")

return function(t)
	t.describe("PerlinNoise", function()
		t.test("permutation is a permutation of 0..255, duplicated", function()
			local n = PerlinNoise.new(JavaRandom.new(1))
			local seen = {}
			for i = 1, 256 do
				t.falsy(seen[n.perm[i]])
				seen[n.perm[i]] = true
				t.eq(n.perm[i], n.perm[i + 256])
			end
		end)
		t.test("deterministic for a seed, different across seeds", function()
			local a = PerlinNoise.new(JavaRandom.new(99))
			local b = PerlinNoise.new(JavaRandom.new(99))
			local c = PerlinNoise.new(JavaRandom.new(100))
			local diff = 0
			for i = 1, 50 do
				local x, y, z = i * 1.37, i * -0.71, i * 2.11
				t.eq(PerlinNoise.sample(a, x, y, z), PerlinNoise.sample(b, x, y, z))
				diff += math.abs(PerlinNoise.sample(a, x, y, z) - PerlinNoise.sample(c, x, y, z))
			end
			t.truthy(diff > 1)
		end)
		t.test("zero at lattice points (relative to offset) and bounded", function()
			local n = PerlinNoise.new(JavaRandom.new(5))
			n.ox, n.oy, n.oz = 0, 0, 0
			for i = -5, 5 do
				t.near(PerlinNoise.sample(n, i, i * 2, -i), 0, 1e-12)
			end
			local r = JavaRandom.new(6)
			local lo, hi = 0, 0
			for _ = 1, 4000 do
				local v = PerlinNoise.sample(n, r:nextDouble() * 500 - 250, r:nextDouble() * 500, r:nextDouble() * 500 - 250)
				lo = math.min(lo, v)
				hi = math.max(hi, v)
			end
			t.truthy(lo >= -1.1 and hi <= 1.1, "range " .. lo .. " " .. hi)
			t.truthy(lo < -0.4 and hi > 0.4, "has spread")
		end)
		t.test("continuous: small steps give small changes", function()
			local n = PerlinNoise.new(JavaRandom.new(7))
			local prev = PerlinNoise.sample(n, -3, 0.5, 2)
			for i = 1, 1000 do
				local v = PerlinNoise.sample(n, -3 + i * 0.001, 0.5, 2)
				t.truthy(math.abs(v - prev) < 0.02)
				prev = v
			end
		end)
		t.test("fbm normalised", function()
			local o = PerlinNoise.Octaves.new(JavaRandom.new(8), 4)
			for i = 1, 200 do
				local v = PerlinNoise.Octaves.fbm(o, i * 0.37, 0, i * -0.13)
				t.truthy(v >= -1.1 and v <= 1.1)
			end
		end)
	end)
	t.describe("Hash", function()
		t.test("mul32 exact vs reference", function()
			-- reference via 16-bit long multiplication on small values
			t.eq(Hash.mul32(0xFFFFFFFF, 0xFFFFFFFF), 1)
			t.eq(Hash.mul32(0x12345678, 0x9ABCDEF0), 0x242D2080) -- (0x12345678*0x9ABCDEF0) mod 2^32
			t.eq(Hash.mul32(65536, 65536), 0)
		end)
		t.test("deterministic, sensitive to every input", function()
			t.eq(Hash.hash(1, 2, 3), Hash.hash(1, 2, 3))
			t.truthy(Hash.hash(1, 2, 3) ~= Hash.hash(1, 2, 4))
			t.truthy(Hash.hash(-1, 0) ~= Hash.hash(0, -1))
			local h = Hash.hash(-5, 7)
			t.truthy(h >= 0 and h < 4294967296 and h == math.floor(h))
		end)
		t.test("roughly uniform buckets", function()
			local b = table.create(8, 0)
			for i = 1, 8000 do
				local k = Hash.hash(i, 12345) % 8 + 1
				b[k] += 1
			end
			for i = 1, 8 do
				t.truthy(b[i] > 850 and b[i] < 1150, "bucket " .. i .. "=" .. b[i])
			end
		end)
	end)
end
