local Inventory = require("../../src/shared/Items/Inventory")
local ItemStack = require("../../src/shared/Items/ItemStack")
local Crafting = require("../../src/shared/Items/Crafting")
local Recipes = require("../../src/shared/Items/Recipes")
local ItemRegistry = require("../../src/shared/Items/ItemRegistry")

return function(t)
	t.describe("Crafting", function()
		t.test("all recipe outputs and inputs are registered items", function()
			for _, r in Recipes.all() do
				t.truthy(ItemRegistry.get(r.output.id), r.name .. " output")
				for _, i in r.inputs do
					t.truthy(ItemRegistry.get(i.id), r.name .. " input " .. i.id)
				end
			end
		end)
		t.test("log -> planks -> sticks -> wooden pickaxe progression", function()
			local inv = Inventory.new()
			Inventory.add(inv, ItemStack.new(17, 2, 0))
			local planks = Recipes.byName("planks_0")
			t.truthy(Crafting.craft(inv, planks.id, 2))
			t.truthy(Crafting.craft(inv, planks.id, 2))
			t.eq(Inventory.count(inv, 5), 8)
			t.truthy(Crafting.craft(inv, Recipes.byName("stick").id, 2))
			t.eq(Inventory.count(inv, 280), 4)
			-- pickaxe needs a crafting table (3x3)
			local pick = Recipes.byName("wooden_pickaxe")
			t.falsy(Crafting.craft(inv, pick.id, 2))
			t.truthy(Crafting.craft(inv, pick.id, 3))
			t.eq(Inventory.count(inv, 270), 1)
			t.eq(Inventory.count(inv, 5), 3)
			t.eq(Inventory.count(inv, 280), 2)
		end)
		t.test("planks from birch logs keep the variant", function()
			local inv = Inventory.new()
			Inventory.add(inv, ItemStack.new(17, 1, 2))
			t.falsy(Crafting.craft(inv, Recipes.byName("planks_0").id, 2))
			t.truthy(Crafting.craft(inv, Recipes.byName("planks_2").id, 2))
			t.eq(Inventory.count(inv, 5, 2), 4)
		end)
		t.test("available() lists only craftable recipes for the grid", function()
			local inv = Inventory.new()
			Inventory.add(inv, ItemStack.new(5, 8))
			local names2, names3 = {}, {}
			for _, r in Crafting.available(inv, 2) do
				names2[r.name] = true
			end
			for _, r in Crafting.available(inv, 3) do
				names3[r.name] = true
			end
			t.truthy(names2.crafting_table); t.truthy(names2.stick); t.falsy(names2.chest)
			t.truthy(names3.chest)
			t.falsy(names3.wooden_pickaxe) -- no sticks
		end)
		t.test("failed crafts are atomic (full inventory, bad ids)", function()
			local inv = Inventory.new()
			Inventory.add(inv, ItemStack.new(42, 1)) -- iron block
			for _ = 1, 35 do
				Inventory.add(inv, ItemStack.new(257, 1))
			end
			local v = inv.version
			-- unpacking removes the block, frees its slot, so 9 ingots fit
			t.truthy(Crafting.craft(inv, Recipes.byName("iron_block_unpack").id, 2))
			t.eq(Inventory.count(inv, 265), 9)
			local inv2 = Inventory.new()
			for _ = 1, 36 do
				Inventory.add(inv2, ItemStack.new(257, 1))
			end
			inv2.slots[36] = ItemStack.new(17, 1)
			local total = Inventory.totalItems(inv2)
			v = inv2.version
			-- planks_0 consumes the log but... output 4 planks fits in the freed slot
			t.truthy(Crafting.craft(inv2, Recipes.byName("planks_0").id, 2))
			t.eq(Inventory.totalItems(inv2), total - 1 + 4)
			t.falsy(Crafting.craft(inv2, 9999, 3))
			t.falsy(Crafting.craft(inv2, "1" :: any, 3))
			local _ = v
		end)
		t.test("rollback when output cannot fit", function()
			local inv = Inventory.new()
			-- 35 tools + 1 slot with 63 sticks + planks in cursor? Use: all slots
			-- full, planks stack of 2 in slot 1 (craft stick uses both -> slot frees). Instead
			-- craft torches: inputs coal(1 of 2) + stick(1 of 2), outputs 4 torches needing a new slot.
			inv.slots[1] = ItemStack.new(263, 2)
			inv.slots[2] = ItemStack.new(280, 2)
			for i = 3, 36 do
				inv.slots[i] = ItemStack.new(257, 1)
			end
			local total = Inventory.totalItems(inv)
			t.falsy(Crafting.craft(inv, Recipes.byName("torch").id, 2))
			t.eq(Inventory.totalItems(inv), total)
			t.eq(inv.slots[1].count, 2)
			t.eq(inv.slots[2].count, 2)
		end)
		t.test("smelting and fuel", function()
			t.eq(Recipes.smeltResult(15, 0).output, 265)
			t.eq(Recipes.smeltResult(17, 2).outputMeta, 1)
			t.eq(Recipes.smeltResult(3, 0), nil)
			t.eq(Recipes.fuelTicks(263), 1600)
			t.eq(Recipes.fuelTicks(3), 0)
		end)
	end)
end
