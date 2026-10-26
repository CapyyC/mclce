local WorldGenerator = require("../../src/shared/WorldGen/WorldGenerator")
local WorldSeed = require("../../src/shared/WorldGen/WorldSeed")
local Chunk = require("../../src/shared/Voxel/Chunk")
local B = require("../../src/shared/Blocks/BlockRegistry")

local function digest(c)
	-- order-sensitive checksum over all states
	local h = 0
	for si = 0, 15 do
		local s = c.sections[si]
		if s then
			for i = 0, 4095 do
				h = (h * 31 + buffer.readu16(s.states, i * 2) + si) % 2147483647
			end
		else
			h = (h * 17 + si) % 2147483647
		end
	end
	return h
end

local function equalChunks(t, a, b, label)
	for y = 0, 255 do
		for z = 0, 15 do
			for x = 0, 15 do
				local sa, sb = Chunk.getState(a, x, y, z), Chunk.getState(b, x, y, z)
				if sa ~= sb then
					t.eq(sa, sb, string.format("%s differs at %d,%d,%d", label, x, y, z))
				end
			end
		end
	end
end

return function(t)
	t.describe("WorldGen", function()
		local seed = WorldSeed.fromNumber(20131218)
		t.test("same seed -> identical chunk; different seed -> different", function()
			local a = WorldGenerator.generate(WorldGenerator.new(seed), 1, -2)
			local b = WorldGenerator.generate(WorldGenerator.new(seed), 1, -2)
			t.eq(digest(a), digest(b))
			local c = WorldGenerator.generate(WorldGenerator.new(WorldSeed.fromNumber(7)), 1, -2)
			t.truthy(digest(a) ~= digest(c))
		end)
		t.test("generation order and cache state do not affect output", function()
			local g1 = WorldGenerator.new(seed, { cacheCapacity = 4 })
			local g2 = WorldGenerator.new(seed, { cacheCapacity = 64 })
			local coords = { { 0, 0 }, { -1, 0 }, { 0, -1 }, { -1, -1 }, { 3, 2 }, { -5, 4 } }
			local first = {}
			for _, c in coords do
				first[#first + 1] = digest(WorldGenerator.generate(g1, c[1], c[2]))
			end
			for i = #coords, 1, -1 do
				local c = coords[i]
				t.eq(digest(WorldGenerator.generate(g2, c[1], c[2])), first[i], "chunk " .. c[1] .. "," .. c[2])
			end
		end)
		t.test("bedrock floor and world limits", function()
			local c = WorldGenerator.generate(WorldGenerator.new(seed), 0, 0)
			for z = 0, 15 do
				for x = 0, 15 do
					t.eq(Chunk.getId(c, x, 0, z), B.BEDROCK)
					for y = 5, 255 do
						t.truthy(Chunk.getId(c, x, y, z) ~= B.BEDROCK, "bedrock above y=4")
					end
				end
			end
		end)
		t.test("terrain is plausible: surface heights and sea level water", function()
			local g = WorldGenerator.new(seed)
			local minH, maxH, water, grass = 999, 0, 0, 0
			for cx = -3, 2 do
				for cz = -3, 2 do
					local c = WorldGenerator.generate(g, cx, cz)
					for z = 0, 15 do
						for x = 0, 15 do
							local h = Chunk.height(c, x, z)
							minH = math.min(minH, h)
							maxH = math.max(maxH, h)
							if Chunk.getId(c, x, 62, z) == B.WATER then
								water += 1
							end
							t.eq(Chunk.getId(c, x, 63, z) == B.WATER, false, "no still water above sea level from base gen")
							for y = h - 1, 50, -1 do
								if Chunk.getId(c, x, y, z) == B.GRASS then
									grass += 1
									break
								end
							end
						end
					end
				end
			end
			t.truthy(minH >= 30 and maxH <= 200, "heights " .. minH .. ".." .. maxH)
			t.truthy(maxH - minH >= 4, "some relief")
			t.truthy(grass + water > 0)
		end)
		t.test("decorations crossing chunk borders are seamless", function()
			-- every log column in a chunk must be continuous with leaves/log above,
			-- regardless of which neighbour owns the tree: verify via two
			-- independently generated neighbour pairs being equal at the border
			local g1, g2 = WorldGenerator.new(seed, { cacheCapacity = 2 }), WorldGenerator.new(seed)
			for cx = -2, 2 do
				local a = WorldGenerator.generate(g1, cx, 1)
				WorldGenerator.generate(g2, cx + 1, 1)
				local b = WorldGenerator.generate(g2, cx, 1)
				equalChunks(t, a, b, "chunk " .. cx)
			end
		end)
		t.test("ores appear at the expected depths", function()
			local g = WorldGenerator.new(seed)
			local counts = { coal = 0, diamondHigh = 0, diamond = 0, iron = 0 }
			for cx = 0, 3 do
				for cz = 0, 3 do
					local c = WorldGenerator.generate(g, cx, cz)
					for y = 1, 140 do
						for z = 0, 15 do
							for x = 0, 15 do
								local id = Chunk.getId(c, x, y, z)
								if id == B.COAL_ORE then
									counts.coal += 1
								elseif id == B.IRON_ORE then
									counts.iron += 1
								elseif id == B.DIAMOND_ORE then
									counts.diamond += 1
									if y > 20 then
										counts.diamondHigh += 1
									end
								end
							end
						end
					end
				end
			end
			t.truthy(counts.coal > 100, "coal " .. counts.coal)
			t.truthy(counts.iron > 50, "iron " .. counts.iron)
			t.eq(counts.diamondHigh, 0)
		end)
		t.test("lazy biomeAt agrees with climate() values", function()
			local BiomeSource = require("../../src/shared/WorldGen/BiomeSource")
			local src = BiomeSource.new(seed)
			local seen = {}
			for i = 0, 400 do
				local x, z = i * 37 - 7000, i * -53 + 3000
				local t2, h, c, r, hl = BiomeSource.climate(src, x, z)
				local b = BiomeSource.biomeAt(src, x, z)
				seen[b.name] = true
				if c < -0.32 then
					t.truthy(b.ocean or b.name == "mushroom_island", b.name)
				elseif hl > 0.42 and not (c < -0.27 and t2 > -0.4 and hl < 0.4) then
					t.eq(b.name, "extreme_hills")
				end
				local _ = h + r
			end
			local n = 0
			for _ in seen do
				n += 1
			end
			t.truthy(n >= 5, "biome variety: " .. n)
		end)
		t.test("seeds: numeric text, other text uses Java hashCode", function()
			local a = WorldSeed.fromString("12345")
			t.eq(a.lo, 12345); t.eq(a.hi, 0)
			local n = WorldSeed.fromString("-1")
			t.eq(n.lo, 4294967295); t.eq(n.hi, 4294967295)
			local s = WorldSeed.fromString("Glacier")
			local JavaRandom = require("../../src/shared/Util/JavaRandom")
			local h = JavaRandom.stringHash("Glacier")
			t.eq(s.lo, h % 4294967296)
		end)
	end)
end
