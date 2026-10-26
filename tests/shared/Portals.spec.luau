local Portals = require("../../src/shared/Sim/Portals")
local Dimensions = require("../../src/shared/Sim/Dimensions")
local GameServer = require("../../src/shared/Sim/GameServer")
local Protocol = require("../../src/shared/Net/Protocol")
local World = require("../../src/shared/Voxel/World")
local Chunk = require("../../src/shared/Voxel/Chunk")
local ItemStack = require("../../src/shared/Items/ItemStack")
local SaveManager = require("../../src/shared/Persistence/SaveManager")
local BlockUpdates = require("../../src/shared/Sim/BlockUpdates")

local OBS = 49 * 16

local function frame(w, x0, y0, z, width, height)
	-- obsidian frame along x with interior width x height starting at (x0, y0)
	for i = -1, width do
		World.setState(w, x0 + i, y0 - 1, z, OBS)
		World.setState(w, x0 + i, y0 + height, z, OBS)
	end
	for j = 0, height - 1 do
		World.setState(w, x0 - 1, y0 + j, z, OBS)
		World.setState(w, x0 + width, y0 + j, z, OBS)
	end
end

return function(t)
	t.describe("Portals", function()
		local function emptyWorld()
			local w = World.new(1024)
			for cx = -1, 0 do
				for cz = -1, 0 do
					World.putChunk(w, Chunk.new(cx, cz))
				end
			end
			return w
		end
		t.test("a 2x3 obsidian frame lights; a broken frame does not", function()
			local w = emptyWorld()
			frame(w, 0, 10, 0, 2, 3)
			t.truthy(Portals.tryIgnite(w, 1, 11, 0))
			for i = 0, 1 do
				for j = 0, 2 do
					t.eq(World.getId(w, i, 10 + j, 0), 90)
				end
			end
			local w2 = emptyWorld()
			frame(w2, 0, 10, 0, 2, 3)
			World.setState(w2, -1, 11, 0, 0) -- hole in the left column
			t.falsy(Portals.tryIgnite(w2, 0, 10, 0))
			local w3 = emptyWorld()
			frame(w3, 0, 10, 0, 1, 3) -- too narrow
			t.falsy(Portals.tryIgnite(w3, 0, 10, 0))
		end)
		t.test("larger frames along z light too", function()
			local w = emptyWorld()
			for i = -1, 4 do
				World.setState(w, 0, 9, i, OBS)
				World.setState(w, 0, 15, i, OBS)
			end
			for j = 10, 14 do
				World.setState(w, 0, j, -1, OBS)
				World.setState(w, 0, j, 4, OBS)
			end
			t.truthy(Portals.tryIgnite(w, 0, 12, 2))
			t.eq(World.getState(w, 0, 14, 3), 90 * 16 + 2)
		end)
		t.test("breaking the frame collapses the portal", function()
			local w = emptyWorld()
			local bu = BlockUpdates.new(w, {
				popBlock = function(x, y, z)
					World.setState(w, x, y, z, 0)
				end,
				skyLight = function()
					return 15
				end,
				blockLight = function()
					return 0
				end,
				skyDarken = function()
					return 0
				end,
			}, 1)
			World.addListener(w, function(x, y, z)
				BlockUpdates.onChange(bu, x, y, z)
			end)
			frame(w, 0, 10, 0, 2, 3)
			Portals.tryIgnite(w, 0, 10, 0)
			World.setState(w, 0, 9, 0, 0)
			local left = 0
			for i = 0, 1 do
				for j = 0, 2 do
					if World.getId(w, i, 10 + j, 0) == 90 then
						left += 1
					end
				end
			end
			t.eq(left, 0)
		end)
	end)
	t.describe("Dimensions", function()
		t.test("light a portal, stand in it, arrive in the Nether, return", function()
			local backend = SaveManager.memoryBackend()
			local d = Dimensions.new({ seed = "dims", viewRadius = 2, genBudget = 50, sendBudget = 50, mobs = false, backend = backend, worldId = "w" }, 3)
			t.truthy(Dimensions.open(d))
			Dimensions.addPlayer(d, 1, "a", nil, false)
			Dimensions.tick(d)
			local ow = d.worlds.overworld
			local p = ow.players[1]
			-- build a frame near spawn on a platform at y=90
			for x = -3, 5 do
				for z = -3, 3 do
					World.setState(ow.world, x, 89, z, 16)
					for y = 90, 96 do
						World.setState(ow.world, x, y, z, 0)
					end
				end
			end
			frame(ow.world, 1, 90, 0, 2, 3)
			GameServer.teleport(ow, 1, 0.5, 90, 1.5)
			p.portalCooldown = 0
			p.inventory.slots[1] = ItemStack.new(259, 1)
			p.inventory.selected = 1
			GameServer.handle(ow, 1, Protocol.C2S.PLACE, { 1, 89, 0, 2 }) -- flint & steel on the frame bottom
			t.eq(World.getId(ow.world, 1, 90, 0), 90, "portal lit")
			GameServer.setPlayerPosition(ow, 1, 1.5, 90, 0.5)
			for _ = 1, 85 do
				Dimensions.tick(d)
				if d.where[1] == "overworld" then
					GameServer.setPlayerPosition(ow, 1, 1.5, 90, 0.5)
				end
			end
			t.eq(d.where[1], "nether")
			local ne = d.worlds.nether
			local np = ne.players[1]
			t.eq(World.getId(ne.world, math.floor(np.x), math.floor(np.y), math.floor(np.z)), 90, "arrived in an exit portal")
			t.eq(np.inventory.slots[1].id, 259, "inventory carried over")
			local box = Dimensions.takeOutbox(d, 1)
			local welcomes = 0
			for _, m in box do
				if m.kind == Protocol.S2C.WELCOME then
					welcomes += 1
				end
			end
			t.truthy(welcomes >= 1, "client receives a fresh WELCOME")
			-- go back after the cooldown
			np.portalCooldown = 0
			local ex, ey, ez = np.x, np.y, np.z
			for _ = 1, 85 do
				Dimensions.tick(d)
				if d.where[1] == "nether" then
					GameServer.setPlayerPosition(ne, 1, ex, ey, ez)
				end
			end
			t.eq(d.where[1], "overworld")
			local back = ow.players[1]
			t.truthy(math.abs(back.x - 1.5) <= 16 and math.abs(back.z - 0.5) <= 16, "returned to the original portal")
			-- the record remembers the dimension
			local rec = Dimensions.removePlayer(d, 1)
			t.eq(rec.dimension, "overworld")
		end)
	end)
end
