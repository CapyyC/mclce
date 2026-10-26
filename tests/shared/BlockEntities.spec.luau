local BlockEntities = require("../../src/shared/Sim/BlockEntities")
local ItemStack = require("../../src/shared/Items/ItemStack")

return function(t)
	t.describe("BlockEntities", function()
		t.test("furnace smelts 8 iron ore with one coal (1600 ticks / 200 per item)", function()
			local f = BlockEntities.new("furnace")
			f.slots[1] = ItemStack.new(15, 10)
			f.slots[2] = ItemStack.new(263, 2)
			local litTicks = 0
			for _ = 1, 1600 do
				local _, lit = BlockEntities.tickFurnace(f)
				if lit then
					litTicks += 1
				end
			end
			t.eq(f.slots[3].id, 265)
			t.eq(f.slots[3].count, 8, "one coal smelts exactly 8 items")
			t.eq(litTicks, 1600)
			t.eq(f.slots[2].count, 1, "second coal untouched so far")
			for _ = 1, 10 do
				BlockEntities.tickFurnace(f)
			end
			t.eq(f.slots[2], nil, "second coal lit for the remaining ore")
			t.eq(f.slots[1].count, 2)
		end)
		t.test("no fuel is wasted without something to smelt", function()
			local f = BlockEntities.new("furnace")
			f.slots[2] = ItemStack.new(263, 3)
			for _ = 1, 100 do
				BlockEntities.tickFurnace(f)
			end
			t.eq(f.slots[2].count, 3)
			t.eq(f.burn, 0)
			f.slots[1] = ItemStack.new(3, 1) -- dirt does not smelt
			BlockEntities.tickFurnace(f)
			t.eq(f.slots[2].count, 3)
		end)
		t.test("full or mismatched output blocks smelting", function()
			local f = BlockEntities.new("furnace")
			f.slots[1] = ItemStack.new(12, 5) -- sand -> glass
			f.slots[2] = ItemStack.new(263, 1)
			f.slots[3] = ItemStack.new(265, 1) -- iron ingot occupies output
			for _ = 1, 300 do
				BlockEntities.tickFurnace(f)
			end
			t.eq(f.slots[1].count, 5)
			t.eq(f.slots[2].count, 1)
		end)
		t.test("slot rules: fuel slot accepts only fuel, output is take-only", function()
			local f = BlockEntities.new("furnace")
			local ok, cur = BlockEntities.click(f, 2, ItemStack.new(3, 4), "left")
			t.falsy(ok); t.eq(cur.count, 4)
			ok, cur = BlockEntities.click(f, 2, ItemStack.new(263, 4), "left")
			t.truthy(ok); t.eq(cur, nil); t.eq(f.slots[2].count, 4)
			ok, cur = BlockEntities.click(f, 3, ItemStack.new(265, 1), "left")
			t.falsy(ok)
			f.slots[3] = ItemStack.new(265, 3)
			ok, cur = BlockEntities.click(f, 3, ItemStack.new(265, 1), "left")
			t.truthy(ok); t.eq(cur.count, 4); t.eq(f.slots[3], nil)
			t.falsy((BlockEntities.click(f, 4, nil, "left")))
			t.falsy((BlockEntities.click(f, 0, nil, "left")))
		end)
		t.test("chest stores 27 stacks", function()
			local c = BlockEntities.new("chest")
			for i = 1, 27 do
				local ok = BlockEntities.click(c, i, ItemStack.new(4, 64), "left")
				t.truthy(ok)
			end
			t.falsy((BlockEntities.click(c, 28, ItemStack.new(4, 1), "left")))
			t.eq(#BlockEntities.contents(c), 27)
		end)
	end)
end
