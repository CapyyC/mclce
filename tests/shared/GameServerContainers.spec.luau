local GameServer = require("../../src/shared/Sim/GameServer")
local Protocol = require("../../src/shared/Net/Protocol")
local World = require("../../src/shared/Voxel/World")
local Inventory = require("../../src/shared/Items/Inventory")
local ItemStack = require("../../src/shared/Items/ItemStack")
local SaveManager = require("../../src/shared/Persistence/SaveManager")
local BlockEntities = require("../../src/shared/Sim/BlockEntities")
local B = require("../../src/shared/Blocks/BlockRegistry")

local C, S = Protocol.C2S, Protocol.S2C

local function setup(opts)
	opts = opts or {}
	local gs = GameServer.new({ seed = "containers", viewRadius = 2, genBudget = 50, sendBudget = 50, mobs = false, backend = opts.backend, worldId = "w" })
	GameServer.open(gs)
	local p = GameServer.addPlayer(gs, 1, "a", opts.record)
	GameServer.tick(gs)
	if opts.noPlatform then
		return gs, p
	end
	for x = -4, 4 do
		for z = -4, 4 do
			World.setState(gs.world, x, 80, z, B.STONE * 16)
			for y = 81, 86 do
				World.setState(gs.world, x, y, z, 0)
			end
		end
	end
	GameServer.teleport(gs, 1, 0.5, 81, 0.5)
	GameServer.tick(gs)
	GameServer.takeOutbox(gs, 1)
	return gs, p
end

local function last(box, kind)
	local m
	for _, x in box do
		if x.kind == kind then
			m = x
		end
	end
	return m
end

return function(t)
	t.describe("GameServer containers", function()
		t.test("place a furnace, load it, smelt, take the output", function()
			local gs, p = setup()
			Inventory.add(p.inventory, ItemStack.new(61, 1))
			GameServer.handle(gs, 1, C.PLACE, { 2, 80, 0, 2 }) -- on top of the floor at x=2
			t.eq(World.getId(gs.world, 2, 81, 0), 61)
			t.eq(World.getState(gs.world, 2, 81, 0) % 16, 4, "faces the player (west)")
			t.truthy(BlockEntities.get(gs.world, 2, 81, 0))
			-- open it by "using" it
			Inventory.add(p.inventory, ItemStack.new(15, 2))
			Inventory.add(p.inventory, ItemStack.new(263, 1))
			GameServer.handle(gs, 1, C.PLACE, { 2, 81, 0, 1 })
			GameServer.tick(gs)
			local m = last(GameServer.takeOutbox(gs, 1), S.CONTAINER)
			t.truthy(m and m.args[1].state.kind == "furnace", "container opened")
			-- move ore (slot 1 of inventory) into input, coal into fuel
			local oreSlot, coalSlot
			for i = 1, 36 do
				local s = p.inventory.slots[i]
				if s and s.id == 15 then
					oreSlot = i
				elseif s and s.id == 263 then
					coalSlot = i
				end
			end
			GameServer.handle(gs, 1, C.INV_CLICK, { oreSlot, "left" })
			GameServer.handle(gs, 1, C.CONTAINER_CLICK, { 1, "left" })
			GameServer.handle(gs, 1, C.INV_CLICK, { coalSlot, "left" })
			GameServer.handle(gs, 1, C.CONTAINER_CLICK, { 3, "left" }) -- output refuses
			GameServer.handle(gs, 1, C.CONTAINER_CLICK, { 2, "left" })
			t.eq(p.inventory.cursor, nil)
			for _ = 1, 3 do
				GameServer.tick(gs)
			end
			t.eq(World.getId(gs.world, 2, 81, 0), 62, "lit furnace")
			for _ = 1, 400 do
				GameServer.tick(gs)
			end
			local e = BlockEntities.get(gs.world, 2, 81, 0)
			t.eq(e.slots[3].id, 265); t.eq(e.slots[3].count, 2)
			GameServer.handle(gs, 1, C.CONTAINER_CLICK, { 3, "left" })
			GameServer.handle(gs, 1, C.CLOSE_CONTAINER, {})
			t.eq(Inventory.count(p.inventory, 265), 2)
			GameServer.tick(gs)
			t.eq(last(GameServer.takeOutbox(gs, 1), S.CONTAINER).args[1], false)
		end)
		t.test("breaking a chest drops its contents", function()
			local gs, p = setup()
			p.gamemode = "creative"
			World.setState(gs.world, 2, 81, 0, 54 * 16)
			local e = BlockEntities.get(gs.world, 2, 81, 0)
			t.truthy(e)
			e.slots[5] = ItemStack.new(264, 3)
			GameServer.handle(gs, 1, C.START_BREAK, { 2, 81, 0 })
			t.eq(BlockEntities.get(gs.world, 2, 81, 0), nil)
			local diamonds = 0
			for _, it in gs.items.list do
				if it.stack.id == 264 then
					diamonds += it.stack.count
				end
			end
			t.eq(diamonds, 3)
		end)
		t.test("container clicks without an open container or out of reach are rejected", function()
			local gs, p = setup()
			World.setState(gs.world, 2, 81, 0, 54 * 16)
			GameServer.handle(gs, 1, C.CONTAINER_CLICK, { 1, "left" })
			t.eq(p.rejected, 1)
			GameServer.handle(gs, 1, C.PLACE, { 2, 81, 0, 1 })
			GameServer.teleport(gs, 1, 30.5, 81, 0.5)
			GameServer.tick(gs)
			t.eq(p.open, nil, "closed when walking away")
		end)
		t.test("chest contents persist across restarts", function()
			local backend = SaveManager.memoryBackend()
			local gs, p = setup({ backend = backend })
			World.setState(gs.world, 3, 81, 1, 54 * 16)
			BlockEntities.get(gs.world, 3, 81, 1).slots[27] = ItemStack.new(57, 9)
			GameServer.autosave(gs, 20)
			local gs2 = setup({ backend = backend, noPlatform = true })
			local e = BlockEntities.get(gs2.world, 3, 81, 1)
			t.truthy(e, "chest entity reloaded")
			t.eq(e.slots[27].id, 57); t.eq(e.slots[27].count, 9)
			local _ = p
		end)
	end)
end
