local GameServer = require("../../src/shared/Sim/GameServer")
local Protocol = require("../../src/shared/Net/Protocol")
local World = require("../../src/shared/Voxel/World")
local Inventory = require("../../src/shared/Items/Inventory")
local ItemStack = require("../../src/shared/Items/ItemStack")
local SaveManager = require("../../src/shared/Persistence/SaveManager")
local ChunkCodec = require("../../src/shared/Persistence/ChunkCodec")
local B = require("../../src/shared/Blocks/BlockRegistry")

local C, S = Protocol.C2S, Protocol.S2C

local function newServer(opts)
	opts = opts or {}
	opts.seed = opts.seed or "test-seed"
	opts.viewRadius = opts.viewRadius or 2
	opts.genBudget = opts.genBudget or 50
	opts.sendBudget = opts.sendBudget or 50
	if opts.mobs == nil then
		opts.mobs = false
	end
	return GameServer.new(opts)
end

local function kinds(box, kind)
	local out = {}
	for _, m in box do
		if m.kind == kind then
			table.insert(out, m)
		end
	end
	return out
end

-- Builds a 9x9 stone platform at y=80 with air above and puts the player on
-- it at (0.5, 81, 0.5). Returns the platform y.
local function standAtSpawn(gs, p)
	local Y = 80
	for x = -4, 4 do
		for z = -4, 4 do
			World.setState(gs.world, x, Y, z, B.STONE * 16)
			for y = Y + 1, Y + 6 do
				World.setState(gs.world, x, y, z, 0)
			end
		end
	end
	GameServer.setPlayerPosition(gs, p.id, 0.5, Y + 1, 0.5)
	return Y
end

return function(t)
	t.describe("GameServer", function()
		t.test("join -> welcome, chunks streamed nearest-first, inventory sent", function()
			local gs = newServer()
			local p = GameServer.addPlayer(gs, 1, "alice")
			for _ = 1, 5 do
				GameServer.tick(gs)
			end
			local box = GameServer.takeOutbox(gs, 1)
			t.eq(#kinds(box, S.WELCOME), 1)
			local chunks = kinds(box, S.CHUNK)
			t.eq(#chunks, 13) -- radius 2 circle
			local first = ChunkCodec.decode(chunks[1].args[1])
			t.eq(first.cx, 0); t.eq(first.cz, 0)
			t.eq(#kinds(box, S.INVENTORY), 1)
			t.truthy(p.y > 40)
		end)
		t.test("survival break requires time; creative is instant; drops are picked up", function()
			local gs = newServer()
			local p = GameServer.addPlayer(gs, 1, "a")
			GameServer.tick(gs)
			local y = standAtSpawn(gs, p)
			local x, z = 1, 0
			-- make a known dirt block next to the player at foot level
			World.setState(gs.world, x, y + 1, z, B.DIRT * 16)
			GameServer.takeOutbox(gs, 1)
			GameServer.handle(gs, 1, C.START_BREAK, { x, y + 1, z })
			GameServer.handle(gs, 1, C.FINISH_BREAK, { x, y + 1, z })
			t.eq(World.getId(gs.world, x, y + 1, z), B.DIRT, "too fast: rejected")
			t.eq(#kinds(GameServer.takeOutbox(gs, 1), S.BREAK_REJECTED), 1)
			GameServer.handle(gs, 1, C.START_BREAK, { x, y + 1, z })
			for _ = 1, 15 do -- dirt by hand = 15 ticks
				GameServer.tick(gs)
			end
			GameServer.handle(gs, 1, C.FINISH_BREAK, { x, y + 1, z })
			t.eq(World.getId(gs.world, x, y + 1, z), 0)
			for _ = 1, 40 do
				GameServer.tick(gs)
			end
			t.eq(Inventory.count(p.inventory, B.DIRT), 1, "dirt picked up")
			-- creative
			p.gamemode = "creative"
			World.setState(gs.world, x, y + 1, z, B.STONE * 16)
			GameServer.handle(gs, 1, C.START_BREAK, { x, y + 1, z })
			t.eq(World.getId(gs.world, x, y + 1, z), 0)
		end)
		t.test("place consumes the held block and replicates the change", function()
			local gs = newServer()
			local p = GameServer.addPlayer(gs, 1, "a")
			local p2 = GameServer.addPlayer(gs, 2, "b")
			for _ = 1, 3 do
				GameServer.tick(gs)
			end
			local y = standAtSpawn(gs, p)
			GameServer.setPlayerPosition(gs, 2, 8.5, World.height(gs.world, 8, 8), 8.5)
			Inventory.add(p.inventory, ItemStack.new(B.COBBLESTONE, 2))
			GameServer.tick(gs) -- flush the platform edits
			GameServer.takeOutbox(gs, 1)
			GameServer.takeOutbox(gs, 2)
			-- click the top face of the block under (2, y, 0)
			local gy = y
			GameServer.handle(gs, 1, C.PLACE, { 2, gy, 0, 2 })
			t.eq(World.getId(gs.world, 2, gy + 1, 0), B.COBBLESTONE)
			t.eq(Inventory.count(p.inventory, B.COBBLESTONE), 1)
			GameServer.tick(gs)
			local b2 = kinds(GameServer.takeOutbox(gs, 2), S.BLOCKS)
			t.eq(#b2, 1, "other player receives the change")
			local ch = Protocol.decodeBlockChanges(b2[1].args[1])
			t.eq(ch[1], 2); t.eq(ch[2], gy + 1); t.eq(ch[4], B.COBBLESTONE * 16)
			local _ = y
			local __ = p2
		end)
		t.test("invalid placements are rejected", function()
			local gs = newServer()
			local p = GameServer.addPlayer(gs, 1, "a")
			GameServer.tick(gs)
			local y = standAtSpawn(gs, p)
			Inventory.add(p.inventory, ItemStack.new(B.COBBLESTONE, 5))
			local before = Inventory.count(p.inventory, B.COBBLESTONE)
			-- into the player's own body
			GameServer.handle(gs, 1, C.PLACE, { 0, y, 0, 2 })
			-- out of reach (still loaded)
			World.setState(gs.world, 12, y, 0, B.STONE * 16)
			GameServer.handle(gs, 1, C.PLACE, { 12, y, 0, 2 })
			-- clicking air
			GameServer.handle(gs, 1, C.PLACE, { 1, y + 3, 0, 2 })
			-- malformed
			GameServer.handle(gs, 1, C.PLACE, { 0, y, 0, 9 })
			GameServer.handle(gs, 1, C.PLACE, { "x", y, 0, 1 })
			t.eq(Inventory.count(p.inventory, B.COBBLESTONE), before)
			t.truthy(p.rejected >= 5)
			-- holding a non-block item
			p.inventory.slots[1] = ItemStack.new(280, 1)
			p.inventory.selected = 1
			GameServer.handle(gs, 1, C.PLACE, { 1, y, 0, 2 })
			t.eq(World.getId(gs.world, 1, y + 1, 0), 0)
		end)
		t.test("bedrock is unbreakable in survival; reach enforced for breaking", function()
			local gs = newServer()
			local p = GameServer.addPlayer(gs, 1, "a")
			GameServer.tick(gs)
			GameServer.setPlayerPosition(gs, 1, 0.5, 1, 0.5)
			GameServer.handle(gs, 1, C.START_BREAK, { 0, 0, 0 })
			t.eq(World.getId(gs.world, 0, 0, 0), B.BEDROCK)
			p.gamemode = "creative"
			GameServer.handle(gs, 1, C.START_BREAK, { 0, 100, 0 })
			t.truthy(p.rejected >= 2)
		end)
		t.test("rate limiting drops floods", function()
			local gs = newServer()
			local p = GameServer.addPlayer(gs, 1, "a")
			for _ = 1, 200 do
				GameServer.handle(gs, 1, C.SELECT_SLOT, { 2 })
			end
			t.truthy((gs.stats.rateLimited or 0) >= 150)
			local _ = p
		end)
		t.test("crafting through the server; 3x3 needs a nearby table", function()
			local gs = newServer()
			local p = GameServer.addPlayer(gs, 1, "a")
			GameServer.tick(gs)
			standAtSpawn(gs, p)
			Inventory.add(p.inventory, ItemStack.new(5, 3))
			Inventory.add(p.inventory, ItemStack.new(280, 2))
			local Recipes = require("../../src/shared/Items/Recipes")
			GameServer.handle(gs, 1, C.CRAFT, { Recipes.byName("wooden_pickaxe").id, 3 })
			t.eq(Inventory.count(p.inventory, 270), 0, "no table nearby")
			World.setState(gs.world, 2, math.floor(p.y), 0, 58 * 16)
			GameServer.handle(gs, 1, C.CRAFT, { Recipes.byName("wooden_pickaxe").id, 3 })
			t.eq(Inventory.count(p.inventory, 270), 1)
		end)
		t.test("edits persist across server restarts via the save backend", function()
			local backend = SaveManager.memoryBackend()
			local gs = newServer({ backend = backend, worldId = "w" })
			t.truthy(GameServer.open(gs))
			local p = GameServer.addPlayer(gs, 7, "a")
			for _ = 1, 3 do
				GameServer.tick(gs)
			end
			p.gamemode = "creative"
			local gy = standAtSpawn(gs, p)
			Inventory.add(p.inventory, ItemStack.new(57, 1))
			GameServer.handle(gs, 7, C.PLACE, { 1, gy, 1, 2 })
			t.eq(World.getId(gs.world, 1, gy + 1, 1), 57)
			local rec = GameServer.removePlayer(gs, 7)
			SaveManager.savePlayer(gs.save, 7, rec)
			GameServer.autosave(gs, 10)

			local gs2 = newServer({ backend = backend, worldId = "w", seed = "a different seed is ignored" })
			t.truthy(GameServer.open(gs2))
			t.eq(gs2.seedText, "test-seed")
			local ok, prec = SaveManager.loadPlayer(gs2.save, 7)
			t.truthy(ok)
			local p2 = GameServer.addPlayer(gs2, 7, "a", prec)
			t.eq(p2.gamemode, "creative")
			for _ = 1, 3 do
				GameServer.tick(gs2)
			end
			t.eq(World.getId(gs2.world, 1, gy + 1, 1), 57, "placed block survived restart")
			t.eq((gs2.stats.loadedFromSave or 0) >= 1, true)
		end)
		t.test("failed region reads never generate over saved data", function()
			local inner = SaveManager.memoryBackend()
			local failing = true
			local backend = {
				get = function(k)
					if failing and string.find(k, "/r/") then
						return false, "throttled"
					end
					return inner.get(k)
				end,
				set = inner.set,
			}
			-- pre-populate a saved region index
			local gs0 = newServer({ backend = inner, worldId = "w" })
			GameServer.open(gs0)
			local p0 = GameServer.addPlayer(gs0, 1, "a")
			GameServer.tick(gs0)
			p0.gamemode = "creative"
			standAtSpawn(gs0, p0)
			World.setState(gs0.world, 3, 120, 3, 57 * 16)
			GameServer.autosave(gs0, 10)

			local gs = newServer({ backend = backend, worldId = "w" })
			t.truthy(GameServer.open(gs))
			GameServer.addPlayer(gs, 1, "a")
			GameServer.tick(gs)
			t.eq(World.getChunk(gs.world, 0, 0), nil)
			t.truthy((gs.stats.loadFailures or 0) >= 1)
			failing = false
			for _ = 1, 120 do
				GameServer.tick(gs)
			end
			t.eq(World.getId(gs.world, 3, 120, 3), 57)
		end)
	end)
end
