local LightEngine = require("../../src/shared/Voxel/LightEngine")
local World = require("../../src/shared/Voxel/World")
local Chunk = require("../../src/shared/Voxel/Chunk")
local B = require("../../src/shared/Blocks/BlockRegistry")

local TOP = 64 -- tests keep all blocks below this; above is trivially sky 15

-- Brute-force fixpoint: relax until stable, using only World + the rules.
local function reference(w, x0, x1, z0, z1)
	local sky, blk = {}, {}
	local function key(x, y, z)
		return (x - x0) + (z - z0) * 64 + y * 4096
	end
	local function op(x, y, z)
		if x < x0 or x > x1 or z < z0 or z > z1 then
			return 15 -- outside the loaded area: no light passes (engine ignores unloaded)
		end
		return B.opacity(World.getId(w, x, y, z))
	end
	for y = 0, TOP do
		for z = z0, z1 do
			for x = x0, x1 do
				sky[key(x, y, z)] = 0
				blk[key(x, y, z)] = B.emission(World.getId(w, x, y, z))
			end
		end
	end
	local function get(t, x, y, z, isSky)
		if y > TOP then
			return if isSky then 15 else 0
		end
		if y < 0 or x < x0 or x > x1 or z < z0 or z > z1 then
			return 0
		end
		return t[key(x, y, z)]
	end
	local changed = true
	while changed do
		changed = false
		for y = TOP, 0, -1 do
			for z = z0, z1 do
				for x = x0, x1 do
					local o = op(x, y, z)
					local cost = math.max(1, o)
					for _, isSky in { true, false } do
						local t = if isSky then sky else blk
						local best = t[key(x, y, z)]
						local above = get(t, x, y + 1, z, isSky)
						if isSky and above == 15 and o == 0 then
							best = math.max(best, 15)
						end
						for _, d in { { 1, 0, 0 }, { -1, 0, 0 }, { 0, 1, 0 }, { 0, -1, 0 }, { 0, 0, 1 }, { 0, 0, -1 } } do
							local l = get(t, x + d[1], y + d[2], z + d[3], isSky) - cost
							if l > best then
								best = l
							end
						end
						if best > t[key(x, y, z)] then
							t[key(x, y, z)] = best
							changed = true
						end
					end
				end
			end
		end
	end
	return function(x, y, z)
		return sky[key(x, y, z)], blk[key(x, y, z)]
	end
end

local function compare(t, le, w, label)
	local ref = reference(w, -16, 15, -16, 15)
	local bad = 0
	for y = 0, TOP do
		for z = -16, 15 do
			for x = -16, 15 do
				local rs, rb = ref(x, y, z)
				local s, b = LightEngine.sky(le, x, y, z), LightEngine.block(le, x, y, z)
				if s ~= rs or b ~= rb then
					bad += 1
					if bad <= 3 then
						print(string.format("  %s mismatch at %d,%d,%d sky %d/%d block %d/%d", label, x, y, z, s, rs, b, rb))
					end
				end
			end
		end
	end
	t.eq(bad, 0, label .. " mismatches")
end

local function makeWorld(seed)
	local w = World.new(1024)
	for cx = -1, 0 do
		for cz = -1, 0 do
			World.putChunk(w, Chunk.new(cx, cz))
		end
	end
	local s = seed
	local function rnd(n)
		s = (s * 1103515245 + 12345) % 2147483648
		return (s // 65536) % n
	end
	-- terrain: stone up to y 20..28 with caves, some glass/leaves/water, torches
	for z = -16, 15 do
		for x = -16, 15 do
			local h = 20 + rnd(8)
			for y = 0, h do
				World.setState(w, x, y, z, B.STONE * 16)
			end
		end
	end
	for _ = 1, 300 do
		World.setState(w, rnd(32) - 16, 5 + rnd(20), rnd(32) - 16, 0)
	end
	for _ = 1, 30 do
		World.setState(w, rnd(32) - 16, 29 + rnd(10), rnd(32) - 16, ({ B.GLASS, B.LEAVES, B.WATER, B.STONE })[rnd(4) + 1] * 16)
	end
	for _ = 1, 8 do
		World.setState(w, rnd(32) - 16, 6 + rnd(20), rnd(32) - 16, B.TORCH * 16)
	end
	return w, rnd
end

return function(t)
	t.describe("LightEngine", function()
		t.test("open sky is 15 everywhere above ground, 0 underground", function()
			local w = World.new(1024)
			World.putChunk(w, Chunk.new(0, 0))
			for x = 0, 15 do
				for z = 0, 15 do
					for y = 0, 9 do
						World.setState(w, x, y, z, B.STONE * 16)
					end
				end
			end
			local le = LightEngine.new(w)
			LightEngine.addChunk(le, 0, 0)
			t.eq(LightEngine.sky(le, 5, 10, 5), 15)
			t.eq(LightEngine.sky(le, 5, 9, 5), 0)
			t.eq(LightEngine.light(le, 5, 10, 5, 11), 4, "night")
		end)
		t.test("torch light falls off by 1 per block", function()
			local w = World.new(1024)
			World.putChunk(w, Chunk.new(0, 0))
			for x = 0, 15 do
				for z = 0, 15 do
					World.setState(w, x, 30, z, B.STONE * 16) -- roof
				end
			end
			World.setState(w, 8, 10, 8, B.TORCH * 16)
			local le = LightEngine.new(w)
			LightEngine.addChunk(le, 0, 0)
			t.eq(LightEngine.block(le, 8, 10, 8), 14)
			t.eq(LightEngine.block(le, 11, 10, 8), 11)
			t.eq(LightEngine.block(le, 10, 12, 9), 9)
		end)
		t.test("initial lighting of a 2x2 world equals the brute-force fixpoint", function()
			local w = makeWorld(11)
			local le = LightEngine.new(w)
			for cx = -1, 0 do
				for cz = -1, 0 do
					LightEngine.addChunk(le, cx, cz)
				end
			end
			compare(t, le, w, "initial")
		end)
		t.test("incremental updates after random edits equal the fixpoint", function()
			local w, rnd = makeWorld(23)
			local le = LightEngine.new(w)
			for cx = -1, 0 do
				for cz = -1, 0 do
					LightEngine.addChunk(le, cx, cz)
				end
			end
			World.addListener(w, function(x, y, z, old, new)
				LightEngine.onBlockChanged(le, x, y, z, old // 16, new // 16)
			end)
			local palette = { 0, 0, B.STONE, B.GLASS, B.TORCH, B.LEAVES, B.idOf("glowstone") }
			for i = 1, 60 do
				World.setState(w, rnd(32) - 16, rnd(40), rnd(32) - 16, palette[rnd(#palette) + 1] * 16)
				if i % 30 == 0 then
					compare(t, le, w, "after " .. i .. " edits")
				end
			end
		end)
	end)
end
