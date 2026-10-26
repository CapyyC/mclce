local Inventory = require("../../src/shared/Items/Inventory")
local ItemStack = require("../../src/shared/Items/ItemStack")
local ItemRegistry = require("../../src/shared/Items/ItemRegistry")
local Mining = require("../../src/shared/Items/Mining")
local JavaRandom = require("../../src/shared/Util/JavaRandom")
local B = require("../../src/shared/Blocks/BlockRegistry")

local function tool(name)
	return ItemStack.new(ItemRegistry.idOf(name), 1)
end

return function(t)
	t.describe("ItemRegistry", function()
		t.test("classic ids and tool stats", function()
			t.eq(ItemRegistry.idOf("iron_pickaxe"), 257)
			t.eq(ItemRegistry.idOf("diamond_pickaxe"), 278)
			t.eq(ItemRegistry.idOf("wooden_pickaxe"), 270)
			t.eq(ItemRegistry.idOf("stick"), 280)
			t.eq(ItemRegistry.get(278).durability, 1561)
			t.eq(ItemRegistry.get(276).damage, 8) -- pre-1.9 diamond sword incl. base hand damage
			t.eq(ItemRegistry.maxStack(257), 1)
			t.eq(ItemRegistry.maxStack(332), 16)
			t.eq(ItemRegistry.get(B.STONE).block, B.STONE)
		end)
	end)
	t.describe("Mining", function()
		t.test("break times match the classic table (seconds)", function()
			-- stone: hand 7.5s (no harvest), wooden pick 1.15s, stone 0.6, iron 0.4, diamond 0.3, gold 0.2
			t.near(Mining.breakSeconds(B.STONE, nil), 7.5, 1e-9)
			t.near(Mining.breakSeconds(B.STONE, tool("wooden_pickaxe")), 1.15, 1e-9)
			t.near(Mining.breakSeconds(B.STONE, tool("stone_pickaxe")), 0.6, 1e-9)
			t.near(Mining.breakSeconds(B.STONE, tool("iron_pickaxe")), 0.4, 1e-9)
			t.near(Mining.breakSeconds(B.STONE, tool("diamond_pickaxe")), 0.3, 1e-9)
			t.near(Mining.breakSeconds(B.STONE, tool("golden_pickaxe")), 0.2, 1e-9)
			-- dirt by hand 0.75s, with shovel faster; obsidian diamond 9.4s
			t.near(Mining.breakSeconds(B.DIRT, nil), 0.75, 1e-9)
			t.near(Mining.breakSeconds(B.DIRT, tool("wooden_shovel")), 0.4, 1e-9)
			t.near(Mining.breakSeconds(B.idOf("obsidian"), tool("diamond_pickaxe")), 9.4, 1e-9)
			t.near(Mining.breakSeconds(B.LOG, nil), 3.0, 1e-9)
		end)
		t.test("instant, unbreakable and penalties", function()
			t.eq(Mining.breakTicks(B.TALLGRASS, nil), 0)
			t.eq(Mining.breakTicks(B.BEDROCK, tool("diamond_pickaxe")), math.huge)
			t.eq(Mining.breakTicks(B.DIRT, nil, false), Mining.breakTicks(B.DIRT, nil) * 5)
		end)
		t.test("harvest tiers", function()
			t.falsy(Mining.canHarvest(B.STONE, nil))
			t.truthy(Mining.canHarvest(B.STONE, tool("wooden_pickaxe")))
			t.falsy(Mining.canHarvest(B.IRON_ORE, tool("wooden_pickaxe")))
			t.truthy(Mining.canHarvest(B.IRON_ORE, tool("stone_pickaxe")))
			t.falsy(Mining.canHarvest(B.DIAMOND_ORE, tool("stone_pickaxe")))
			t.truthy(Mining.canHarvest(B.DIAMOND_ORE, tool("iron_pickaxe")))
			t.falsy(Mining.canHarvest(B.idOf("obsidian"), tool("iron_pickaxe")))
			t.falsy(Mining.canHarvest(B.DIAMOND_ORE, tool("golden_pickaxe")))
			t.truthy(Mining.canHarvest(B.DIRT, nil))
		end)
		t.test("drops", function()
			local r = JavaRandom.new(1)
			local function one(state, held)
				local d = Mining.drops(state, held, r)
				return d[1]
			end
			t.eq(one(B.STONE * 16, tool("wooden_pickaxe")).id, B.COBBLESTONE)
			t.eq(#Mining.drops(B.STONE * 16, nil, r), 0)
			t.eq(one(B.GRASS * 16, nil).id, B.DIRT)
			t.eq(one(B.DIAMOND_ORE * 16, tool("iron_pickaxe")).id, 264)
			t.eq(one(B.COAL_ORE * 16, tool("wooden_pickaxe")).id, 263)
			t.eq(#Mining.drops(B.GLASS * 16, nil, r), 0)
			t.eq(one(B.idOf("wool") * 16 + 14, nil).meta, 14)
			local lap = one(B.LAPIS_ORE * 16, tool("stone_pickaxe"))
			t.eq(lap.id, 351); t.eq(lap.meta, 4); t.truthy(lap.count >= 4 and lap.count <= 8)
			-- leaves: saplings ~1/20 over many trials, shears give the block
			local saplings = 0
			for _ = 1, 4000 do
				for _, d in Mining.drops(B.LEAVES * 16, nil, r) do
					if d.id == 6 then
						saplings += 1
					end
				end
			end
			t.truthy(saplings > 140 and saplings < 270, "saplings " .. saplings)
			t.eq(one(B.LEAVES * 16 + 5, tool("shears")).meta, 1)
		end)
	end)
	t.describe("Inventory", function()
		t.test("add merges then fills hotbar first", function()
			local inv = Inventory.new()
			t.eq(Inventory.add(inv, ItemStack.new(3, 40)), 0)
			t.eq(Inventory.add(inv, ItemStack.new(3, 40)), 0)
			t.eq(inv.slots[1].count, 64)
			t.eq(inv.slots[2].count, 16)
			t.eq(Inventory.count(inv, 3), 80)
		end)
		t.test("full inventory returns leftovers", function()
			local inv = Inventory.new()
			for _ = 1, 36 do
				Inventory.add(inv, ItemStack.new(257, 1))
			end
			t.eq(Inventory.add(inv, ItemStack.new(3, 10)), 10)
			t.eq(Inventory.add(inv, ItemStack.new(257, 1)), 1) -- tools don't stack
		end)
		t.test("click semantics", function()
			local inv = Inventory.new()
			Inventory.add(inv, ItemStack.new(4, 33))
			t.truthy(Inventory.click(inv, 1, "right")) -- pick half (17)
			t.eq(inv.cursor.count, 17); t.eq(inv.slots[1].count, 16)
			t.truthy(Inventory.click(inv, 5, "right")) -- place one
			t.eq(inv.slots[5].count, 1); t.eq(inv.cursor.count, 16)
			t.truthy(Inventory.click(inv, 1, "left")) -- merge all
			t.eq(inv.slots[1].count, 32); t.eq(inv.cursor, nil)
			Inventory.add(inv, ItemStack.new(3, 1)) -- goes to slot 2
			t.truthy(Inventory.click(inv, 2, "left"))
			t.truthy(Inventory.click(inv, 1, "left")) -- swap different items
			t.eq(inv.slots[1].id, 3); t.eq(inv.cursor.id, 4)
		end)
		t.test("invalid requests are rejected without side effects", function()
			local inv = Inventory.new()
			Inventory.add(inv, ItemStack.new(4, 10))
			local v = inv.version
			t.falsy(Inventory.click(inv, 0, "left"))
			t.falsy(Inventory.click(inv, 41, "left"))
			t.falsy(Inventory.click(inv, 1.5, "left"))
			t.falsy(Inventory.click(inv, "1" :: any, "left"))
			t.falsy(Inventory.click(inv, 1, "middle"))
			t.falsy(Inventory.select(inv, 10))
			t.falsy(Inventory.quickMove(inv, 40))
			t.eq(inv.version, v)
			t.falsy(ItemStack.isValid({ id = 3, meta = 0, count = 65, damage = 0 }))
			t.falsy(ItemStack.isValid({ id = 99999, meta = 0, count = 1, damage = 0 }))
			t.falsy(ItemStack.isValid({ id = 3, meta = 0, count = -1, damage = 0 }))
			t.truthy(ItemStack.isValid({ id = 3, meta = 0, count = 64, damage = 0 }))
		end)
		t.test("randomized operations conserve item counts", function()
			local inv = Inventory.new()
			local r = JavaRandom.new(77)
			local ids = { 3, 4, 257, 280, 332 }
			local expected = 0
			for _ = 1, 3000 do
				local op = r:nextInt(5)
				if op == 0 then
					local id = ids[r:nextInt(#ids) + 1]
					local n = r:nextInt(ItemRegistry.maxStack(id)) + 1
					local left = Inventory.add(inv, ItemStack.new(id, n))
					expected += n - left
				elseif op == 1 then
					Inventory.click(inv, r:nextInt(42), if r:nextBoolean() then "left" else "right")
				elseif op == 2 then
					Inventory.quickMove(inv, r:nextInt(37) + 1)
				elseif op == 3 then
					local id = ids[r:nextInt(#ids) + 1]
					expected -= Inventory.remove(inv, id, nil, r:nextInt(20) + 1)
				else
					Inventory.returnCursor(inv)
				end
				t.eq(Inventory.totalItems(inv), expected)
				for i = 1, 40 do
					local s = inv.slots[i]
					if s then
						t.truthy(s.count >= 1 and s.count <= ItemRegistry.maxStack(s.id), "stack size")
					end
				end
			end
		end)
	end)
end
