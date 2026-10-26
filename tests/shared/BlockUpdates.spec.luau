local BlockUpdates = require("../../src/shared/Sim/BlockUpdates")
local World = require("../../src/shared/Voxel/World")
local Chunk = require("../../src/shared/Voxel/Chunk")
local B = require("../../src/shared/Blocks/BlockRegistry")

local function setup(opts)
	opts = opts or {}
	local w = World.new(1024)
	for cx = -1, 0 do
		for cz = -1, 0 do
			World.putChunk(w, Chunk.new(cx, cz))
		end
	end
	for x = -16, 15 do
		for z = -16, 15 do
			World.setState(w, x, 10, z, B.DIRT * 16)
		end
	end
	local popped = {}
	local bu
	bu = BlockUpdates.new(w, {
		popBlock = function(x, y, z)
			table.insert(popped, { x, y, z, World.getId(w, x, y, z) })
			World.setState(w, x, y, z, 0)
		end,
		skyLight = function()
			return opts.sky or 15
		end,
		blockLight = function()
			return opts.block or 0
		end,
		skyDarken = function()
			return 0
		end,
	}, 1)
	World.addListener(w, function(x, y, z)
		BlockUpdates.onChange(bu, x, y, z)
	end)
	return w, bu, popped
end

return function(t)
	t.describe("BlockUpdates", function()
		t.test("plants pop when their soil is removed", function()
			local w, _, popped = setup()
			World.setState(w, 1, 11, 1, B.TALLGRASS * 16)
			World.setState(w, 1, 10, 1, 0)
			t.eq(World.getId(w, 1, 11, 1), 0)
			t.eq(#popped, 1); t.eq(popped[1][4], B.TALLGRASS)
		end)
		t.test("wall torch pops when its wall is removed; floor torch stays", function()
			local w, _, popped = setup()
			World.setState(w, 2, 11, 2, B.STONE * 16)
			World.setState(w, 3, 11, 2, B.TORCH * 16 + 1) -- attached to the block at -x
			World.setState(w, 5, 11, 5, B.TORCH * 16 + 5)
			World.setState(w, 2, 11, 2, 0)
			t.eq(World.getId(w, 3, 11, 2), 0)
			t.eq(World.getId(w, 5, 11, 5), B.TORCH)
			t.eq(#popped, 1)
		end)
		t.test("sand falls through air and water to the floor", function()
			local w = setup()
			World.setState(w, 4, 14, 4, B.WATER * 16)
			World.setState(w, 4, 20, 4, B.SAND * 16)
			t.eq(World.getId(w, 4, 20, 4), 0)
			t.eq(World.getId(w, 4, 11, 4), B.SAND)
			-- a stack collapses when its base is removed
			World.setState(w, 6, 8, 6, B.STONE * 16)
			for y = 11, 13 do
				World.setState(w, 6, y, 6, B.GRAVEL * 16)
			end
			World.setState(w, 6, 10, 6, 0) -- remove the dirt under the stack
			local n = 0
			for y = 9, 13 do
				if World.getId(w, 6, y, 6) == B.GRAVEL then
					n += 1
				end
			end
			t.eq(n, 3)
			t.eq(World.getId(w, 6, 9, 6), B.GRAVEL)
			t.eq(World.getId(w, 6, 12, 6), 0)
		end)
		t.test("wheat grows to maturity on hydrated farmland in light", function()
			local w, bu = setup()
			World.setState(w, 0, 10, 0, 60 * 16)
			World.setState(w, 2, 10, 0, B.WATER * 16)
			World.setState(w, 0, 11, 0, 59 * 16)
			for _ = 1, 400 do
				BlockUpdates.randomTick(bu, 0, 10, 0)
				BlockUpdates.randomTick(bu, 0, 11, 0)
			end
			t.eq(World.getState(w, 0, 11, 0), 59 * 16 + 7)
			t.eq(World.getState(w, 0, 10, 0) % 16, 7, "hydrated")
		end)
		t.test("dry farmland without a crop reverts to dirt", function()
			local w, bu = setup()
			World.setState(w, 0, 10, 0, 60 * 16)
			for _ = 1, 3 do
				BlockUpdates.randomTick(bu, 0, 10, 0)
			end
			t.eq(World.getId(w, 0, 10, 0), B.DIRT)
		end)
		t.test("a sapling grows into a tree", function()
			local w, bu = setup()
			World.setState(w, 0, 11, 0, B.idOf("sapling") * 16)
			for _ = 1, 300 do
				BlockUpdates.randomTick(bu, 0, 11, 0)
			end
			t.eq(World.getId(w, 0, 11, 0), B.LOG)
			t.eq(World.getId(w, 0, 12, 0), B.LOG)
			local leaves = 0
			for y = 13, 20 do
				for x = -2, 2 do
					for z = -2, 2 do
						if World.getId(w, x, y, z) == B.LEAVES then
							leaves += 1
						end
					end
				end
			end
			t.truthy(leaves > 20, "leaves " .. leaves)
		end)
		t.test("leaves decay once no log is within 4 blocks, player leaves never", function()
			local w, bu, popped = setup()
			World.setState(w, 0, 15, 0, B.LEAVES * 16)
			World.setState(w, 1, 15, 0, B.LEAVES * 16 + 4) -- player-placed
			World.setState(w, 0, 14, 0, B.LOG * 16)
			BlockUpdates.randomTick(bu, 0, 15, 0)
			t.eq(World.getId(w, 0, 15, 0), B.LEAVES)
			World.setState(w, 0, 14, 0, 0)
			BlockUpdates.randomTick(bu, 0, 15, 0)
			BlockUpdates.randomTick(bu, 1, 15, 0)
			t.eq(World.getId(w, 0, 15, 0), 0)
			t.eq(World.getId(w, 1, 15, 0), B.LEAVES)
			t.eq(#popped, 1)
		end)
		t.test("grass spreads to lit dirt and dies in the dark under opaque blocks", function()
			local w, bu = setup()
			World.setState(w, 0, 10, 0, B.GRASS * 16)
			for _ = 1, 400 do
				BlockUpdates.randomTick(bu, 0, 10, 0)
			end
			local grass = 0
			for x = -1, 1 do
				for z = -1, 1 do
					if World.getId(w, x, 10, z) == B.GRASS then
						grass += 1
					end
				end
			end
			t.eq(grass, 9)
			local w2, bu2 = setup({ sky = 0 })
			World.setState(w2, 0, 10, 0, B.GRASS * 16)
			World.setState(w2, 0, 11, 0, B.STONE * 16)
			BlockUpdates.randomTick(bu2, 0, 10, 0)
			t.eq(World.getId(w2, 0, 10, 0), B.DIRT)
		end)
		t.test("sugar cane grows to 3 high beside water", function()
			local w, bu = setup()
			World.setState(w, 0, 9, 0, B.STONE * 16) -- sand needs support or it falls
			World.setState(w, 0, 10, 0, B.SAND * 16)
			World.setState(w, 1, 10, 0, B.WATER * 16)
			World.setState(w, 0, 11, 0, 83 * 16)
			for _ = 1, 100 do
				for y = 11, 13 do
					BlockUpdates.randomTick(bu, 0, y, 0)
				end
			end
			t.eq(World.getId(w, 0, 13, 0), 83)
			t.eq(World.getId(w, 0, 14, 0), 0)
			-- removing the water pops the whole column
			World.setState(w, 1, 9, 0, B.STONE * 16)
			World.setState(w, 1, 10, 0, B.SAND * 16)
			BlockUpdates.randomTick(bu, 0, 11, 0) -- the diagonal loss is noticed on the next random tick
			t.eq(World.getId(w, 0, 11, 0), 0)
			t.eq(World.getId(w, 0, 13, 0), 0)
		end)
	end)
end
