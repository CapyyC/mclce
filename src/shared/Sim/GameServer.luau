--!strict
-- Engine-independent authoritative server simulation.
--
-- Owns the World, generation, persistence, players' inventories and item
-- entities; validates every client request; produces per-player outgoing
-- messages in an outbox that the Roblox adapter flushes to RemoteEvents.
-- Positions are in block units (feet position). The adapter feeds player
-- positions from characters (Roblox physics) each tick.

local Config = require("../Config")
local Coords = require("../Voxel/Coords")
local World = require("../Voxel/World")
local BlockRegistry = require("../Blocks/BlockRegistry")
local WorldGenerator = require("../WorldGen/WorldGenerator")
local WorldSeed = require("../WorldGen/WorldSeed")
local ChunkScheduler = require("../Streaming/ChunkScheduler")
local ChunkCodec = require("../Persistence/ChunkCodec")
local SaveManager = require("../Persistence/SaveManager")
local Protocol = require("../Net/Protocol")
local Inventory = require("../Items/Inventory")
local ItemStack = require("../Items/ItemStack")
local ItemRegistry = require("../Items/ItemRegistry")
local Mining = require("../Items/Mining")
local Crafting = require("../Items/Crafting")
local Collision = require("../Physics/Collision")
local ItemEntities = require("./ItemEntities")
local JavaRandom = require("../Util/JavaRandom")
local Faces = require("../Mesh/Faces")
local Survival = require("./Survival")
local Fluids = require("./Fluids")
local LightEngine = require("../Voxel/LightEngine")

local C2S, S2C = Protocol.C2S, Protocol.S2C

export type Player = {
	id: number,
	name: string,
	x: number,
	y: number,
	z: number,
	gamemode: string, -- "survival" | "creative"
	inventory: Inventory.Inventory,
	sentInvVersion: number,
	breaking: { x: number, y: number, z: number, tick: number }?,
	sent: { [number]: boolean },
	sentCount: number,
	tokens: number,
	rejected: number, -- invalid/denied requests (diagnostics, kick heuristics)
	loaded: boolean, -- player data finished loading
	joined: boolean, -- client is listening; nothing is sent before this
	vitals: Survival.Vitals,
	sentVitals: string,
	eating: { tick: number, slot: number }?,
	lastX: number,
	lastZ: number,
}

export type Outgoing = { kind: number, args: { any } }

export type Options = {
	seed: string?,
	worldSize: number?,
	worldId: string?,
	backend: SaveManager.Backend?,
	clock: (() -> number)?,
	viewRadius: number?,
	genBudget: number?,
	sendBudget: number?,
}

export type GameServer = {
	world: World.World,
	generator: WorldGenerator.WorldGenerator,
	seedText: string,
	scheduler: ChunkScheduler.Scheduler,
	save: SaveManager.SaveManager?,
	players: { [number]: Player },
	outbox: { [number]: { Outgoing } },
	pendingChanges: { number }, -- flat x, y, z, state
	items: ItemEntities.ItemEntities,
	fluids: Fluids.Fluids,
	light: LightEngine.LightEngine,
	rng: JavaRandom.JavaRandom,
	tickCount: number,
	worldTime: number,
	viewRadius: number,
	sendBudget: number,
	genBudget: number,
	failedLoads: { [number]: number }, -- chunk key -> retry tick
	clock: () -> number,
	stats: { [string]: number },
}

local GameServer = {}

GameServer.EAT_TICKS = 32
GameServer.DIFFICULTY = 2 -- normal

local function send(gs: GameServer, pid: number, kind: number, ...: any)
	local box = gs.outbox[pid]
	if box then
		table.insert(box, { kind = kind, args = { ... } })
	end
end

local function count(gs: GameServer, key: string)
	gs.stats[key] = (gs.stats[key] or 0) + 1
end

function GameServer.new(opts: Options): GameServer
	local seedText = opts.seed or Config.DEFAULT_SEED
	local seed = WorldSeed.fromString(seedText)
	local clock = opts.clock or os.clock
	local world = World.new(opts.worldSize or Config.WORLD_SIZE)
	local gs: GameServer
	local save = if opts.backend then SaveManager.new(opts.backend, opts.worldId or "world", clock) else nil
	gs = {
		world = world,
		generator = WorldGenerator.new(seed, { cacheCapacity = 256 }),
		seedText = seedText,
		scheduler = nil :: any,
		save = save,
		players = {},
		outbox = {},
		pendingChanges = {},
		items = ItemEntities.new(),
		fluids = nil :: any,
		light = LightEngine.new(world),
		rng = JavaRandom.new(seed.lo),
		tickCount = 0,
		worldTime = 0,
		viewRadius = opts.viewRadius or Config.SERVER_VIEW_RADIUS,
		sendBudget = opts.sendBudget or Config.SEND_BUDGET_PER_TICK,
		genBudget = opts.genBudget or Config.GEN_BUDGET_PER_TICK,
		failedLoads = {},
		clock = clock,
		stats = {},
	}
	gs.scheduler = ChunkScheduler.new({
		load = function(cx, cz)
			GameServer._loadChunk(gs, cx, cz)
		end,
		unload = function(cx, cz)
			GameServer._unloadChunk(gs, cx, cz)
		end,
		inBounds = function(cx, cz)
			return World.chunkInBorder(world, cx, cz) and gs.failedLoads[Coords.chunkKey(cx, cz)] == nil
		end,
	}, gs.viewRadius + 1, { hysteresis = 2, maxLoaded = Config.MAX_LOADED_CHUNKS })
	gs.fluids = Fluids.new(world, 2048)
	World.addListener(world, function(x, y, z, old, new)
		LightEngine.onBlockChanged(gs.light, x, y, z, old // 16, new // 16)
		local p = gs.pendingChanges
		local n = #p
		p[n + 1], p[n + 2], p[n + 3], p[n + 4] = x, y, z, new
	end)
	return gs
end

-- Opens persistence. Returns (ok, err). Must succeed before players join
-- when a backend is configured (otherwise saved edits could be overwritten).
function GameServer.open(gs: GameServer): (boolean, string?)
	if gs.save == nil then
		return true, nil
	end
	local ok, res = SaveManager.open(gs.save, { seed = gs.seedText, size = gs.world.maxX - gs.world.minX + 1, time = 0 })
	if not ok then
		return false, tostring(res)
	end
	if not res then
		-- existing world: its seed wins
		local seedText = gs.save.meta.seed
		if type(seedText) == "string" and seedText ~= gs.seedText then
			gs.seedText = seedText
			gs.generator = WorldGenerator.new(WorldSeed.fromString(seedText), { cacheCapacity = 256 })
		end
		gs.worldTime = tonumber(gs.save.meta.time) or 0
	end
	return true, nil
end

function GameServer._loadChunk(gs: GameServer, cx: number, cz: number)
	local chunk = nil
	if gs.save then
		local ok, err = SaveManager.ensureRegion(gs.save, cx, cz)
		if not ok then
			-- never generate over data we failed to read; retry later
			gs.failedLoads[Coords.chunkKey(cx, cz)] = gs.tickCount + 100
			ChunkScheduler.forget(gs.scheduler, cx, cz)
			count(gs, "loadFailures")
			local _ = err
			return
		end
		local saved, cerr = SaveManager.loadChunk(gs.save, cx, cz)
		if cerr then
			count(gs, "corruptChunks")
		end
		chunk = saved
	end
	if chunk == nil then
		chunk = WorldGenerator.generate(gs.generator, cx, cz)
		count(gs, "generated")
	else
		count(gs, "loadedFromSave")
	end
	World.putChunk(gs.world, chunk :: any)
	LightEngine.addChunk(gs.light, cx, cz)
end

function GameServer._unloadChunk(gs: GameServer, cx: number, cz: number)
	local c = World.getChunk(gs.world, cx, cz)
	if c == nil then
		return
	end
	if c.dirty and gs.save then
		SaveManager.storeChunk(gs.save, c)
	end
	World.removeChunk(gs.world, cx, cz)
	LightEngine.removeChunk(gs.light, cx, cz)
	count(gs, "unloaded")
end

-- Players -------------------------------------------------------------------

function GameServer.spawnPoint(gs: GameServer): (number, number, number)
	-- highest non-air block at the origin column (generates it if needed)
	if not World.isLoaded(gs.world, 0, 0) then
		GameServer._loadChunk(gs, 0, 0)
		if World.isLoaded(gs.world, 0, 0) then
			ChunkScheduler.markLoaded(gs.scheduler, 0, 0)
		end
	end
	return 0.5, World.height(gs.world, 0, 0), 0.5
end

-- `waitForJoin`: when true, nothing is sent until the client sends JOIN
-- (the Roblox adapter uses this so no message precedes the client listener).
function GameServer.addPlayer(gs: GameServer, id: number, name: string, record: { [string]: any }?, waitForJoin: boolean?): Player
	local x, y, z = GameServer.spawnPoint(gs)
	local p: Player = {
		id = id,
		name = name,
		x = x,
		y = y,
		z = z,
		gamemode = "survival",
		inventory = Inventory.new(),
		sentInvVersion = -1,
		breaking = nil,
		sent = {},
		sentCount = 0,
		tokens = Config.ACTION_BURST,
		rejected = 0,
		loaded = true,
		joined = false,
		vitals = Survival.new(),
		sentVitals = "",
		eating = nil,
		lastX = x,
		lastZ = z,
	}
	if record then
		GameServer._applyRecord(p, record)
	end
	gs.players[id] = p
	gs.outbox[id] = {}
	if not waitForJoin then
		GameServer._join(gs, p)
	end
	return p
end

function GameServer._join(gs: GameServer, p: Player)
	-- (re)start the session for this client: welcome + resend everything
	p.joined = true
	p.sent = {}
	p.sentCount = 0
	p.sentInvVersion = -1
	p.sentVitals = ""
	send(gs, p.id, S2C.WELCOME, { seed = gs.seedText, size = gs.world.maxX - gs.world.minX + 1, x = p.x, y = p.y, z = p.z, gamemode = p.gamemode })
end

function GameServer._applyRecord(p: Player, r: { [string]: any })
	if type(r.pos) == "table" and #r.pos == 3 then
		local x, y, z = r.pos[1], r.pos[2], r.pos[3]
		if type(x) == "number" and type(y) == "number" and type(z) == "number" and x == x and y == y and z == z then
			p.x, p.y, p.z = x, math.clamp(y, 0, 300), z
		end
	end
	if r.gamemode == "creative" or r.gamemode == "survival" then
		p.gamemode = r.gamemode
	end
	if type(r.health) == "number" and r.health == r.health then
		p.vitals.health = math.clamp(r.health, 1, 20)
	end
	if type(r.food) == "number" and r.food == r.food then
		p.vitals.food = math.clamp(r.food, 0, 20)
	end
	if type(r.saturation) == "number" and r.saturation == r.saturation then
		p.vitals.saturation = math.clamp(r.saturation, 0, p.vitals.food)
	end
	if type(r.inventory) == "table" then
		for k, s in r.inventory do
			local slot = tonumber(k)
			if slot and Inventory.validSlot(slot) and ItemStack.isValid(s) then
				p.inventory.slots[slot] = ItemStack.new(s.id, s.count, s.meta, s.damage)
			end
		end
	end
	if type(r.selected) == "number" then
		Inventory.select(p.inventory, r.selected)
	end
end

function GameServer.playerRecord(p: Player): { [string]: any }
	local inv = {}
	for i = 1, Inventory.SIZE do
		local s = p.inventory.slots[i]
		if s then
			inv[tostring(i)] = { id = s.id, meta = s.meta, count = s.count, damage = s.damage }
		end
	end
	if p.inventory.cursor then
		Inventory.returnCursor(p.inventory)
	end
	local v = p.vitals
	return { pos = { p.x, p.y, p.z }, gamemode = p.gamemode, health = if v.dead then 20 else v.health, food = v.food, saturation = v.saturation, inventory = inv, selected = p.inventory.selected }
end

function GameServer.removePlayer(gs: GameServer, id: number): { [string]: any }?
	local p = gs.players[id]
	if p == nil then
		return nil
	end
	gs.players[id] = nil
	gs.outbox[id] = nil
	return GameServer.playerRecord(p)
end

function GameServer.setPlayerPosition(gs: GameServer, id: number, x: number, y: number, z: number)
	local p = gs.players[id]
	if p and x == x and y == y and z == z and math.abs(x) < 1e7 and math.abs(z) < 1e7 then
		p.x, p.y, p.z = x, y, z
	end
end

-- Teleports a player (respawn/commands): resets fall tracking and movement accounting.
function GameServer.teleport(gs: GameServer, id: number, x: number, y: number, z: number)
	local p = gs.players[id]
	if p then
		p.x, p.y, p.z = x, y, z
		p.lastX, p.lastZ = x, z
		p.vitals.fallStartY = nil
	end
end

-- Requests ------------------------------------------------------------------

local function spendToken(gs: GameServer, p: Player): boolean
	if p.tokens < 1 then
		count(gs, "rateLimited")
		return false
	end
	p.tokens -= 1
	return true
end

local function inReach(p: Player, x: number, y: number, z: number): boolean
	local reach = (if p.gamemode == "creative" then Config.REACH_CREATIVE else Config.REACH_SURVIVAL) + Config.REACH_TOLERANCE
	-- distance from the eye to the nearest point of the block
	local ex, ey, ez = p.x, p.y + 1.62, p.z
	local dx = math.max(x - ex, 0, ex - (x + 1))
	local dy = math.max(y - ey, 0, ey - (y + 1))
	local dz = math.max(z - ez, 0, ez - (z + 1))
	return dx * dx + dy * dy + dz * dz <= reach * reach
end

local function reject(gs: GameServer, p: Player, x: number?, y: number?, z: number?)
	p.rejected += 1
	count(gs, "rejected")
	if x and y and z then
		send(gs, p.id, S2C.BREAK_REJECTED, x, y, z, World.getState(gs.world, x, y, z))
	end
end

local function canEdit(gs: GameServer, p: Player, x: number, y: number, z: number): boolean
	return World.isLoaded(gs.world, x, z) and World.inBorder(gs.world, x, z) and y >= 0 and y <= 255 and inReach(p, x, y, z)
end

local function doBreak(gs: GameServer, p: Player, x: number, y: number, z: number)
	local state = World.getState(gs.world, x, y, z)
	local id = state // 16
	World.setState(gs.world, x, y, z, 0)
	count(gs, "blocksBroken")
	if p.gamemode == "survival" then
		Survival.exhaust(p.vitals, Survival.EXHAUSTION.breakBlock)
		local held = Inventory.held(p.inventory)
		for _, drop in Mining.drops(state, held, gs.rng) do
			ItemEntities.spawn(gs.items, x + 0.5, y + 0.25, z + 0.5, drop, (gs.rng:nextFloat() - 0.5) * 0.2, 0.2, (gs.rng:nextFloat() - 0.5) * 0.2)
		end
		-- tool wear (instant-break blocks don't wear tools)
		if held and BlockRegistry.hardness(id) > 0 then
			local def = ItemRegistry.get(held.id)
			if def and def.durability then
				local wear = if def.tool == "sword" then 2 else 1
				local dmg = held.damage + wear
				local inv = p.inventory
				inv.slots[inv.selected] = if dmg >= def.durability then nil else ItemStack.new(held.id, 1, held.meta, dmg)
				inv.version += 1
			end
		end
	end
end

local function handleStartBreak(gs: GameServer, p: Player, m: Protocol.Message)
	local x, y, z = m.x, m.y, m.z
	if not canEdit(gs, p, x, y, z) then
		return reject(gs, p, x, y, z)
	end
	local state = World.getState(gs.world, x, y, z)
	local id = state // 16
	if id == 0 or BlockRegistry.isLiquid(id) then
		return reject(gs, p, x, y, z)
	end
	if p.gamemode == "creative" then
		return doBreak(gs, p, x, y, z)
	end
	local ticks = Mining.breakTicks(id, Inventory.held(p.inventory), true, false)
	if ticks == math.huge then
		return reject(gs, p, x, y, z)
	end
	if ticks == 0 then
		return doBreak(gs, p, x, y, z)
	end
	p.breaking = { x = x, y = y, z = z, tick = gs.tickCount }
end

local function handleFinishBreak(gs: GameServer, p: Player, m: Protocol.Message)
	local b = p.breaking
	local x, y, z = m.x, m.y, m.z
	p.breaking = nil
	if b == nil or b.x ~= x or b.y ~= y or b.z ~= z or not canEdit(gs, p, x, y, z) then
		return reject(gs, p, x, y, z)
	end
	local id = World.getId(gs.world, x, y, z)
	if id == 0 then
		return reject(gs, p, x, y, z)
	end
	local need = Mining.breakTicks(id, Inventory.held(p.inventory), true, false)
	if need == math.huge or gs.tickCount - b.tick < math.floor(need * Config.BREAK_TIME_TOLERANCE) then
		count(gs, "fastBreak")
		return reject(gs, p, x, y, z)
	end
	doBreak(gs, p, x, y, z)
end

local function playerBox(p: Player): Collision.Box
	return Collision.box(p.x, p.y, p.z, 0.3, 1.8)
end

local function boxIntersectsBlock(b: Collision.Box, x: number, y: number, z: number): boolean
	return b.maxX > x and b.minX < x + 1 and b.maxY > y and b.minY < y + 1 and b.maxZ > z and b.minZ < z + 1
end

local function handlePlace(gs: GameServer, p: Player, m: Protocol.Message)
	local tx, ty, tz, face = m.x, m.y, m.z, m.face
	if not canEdit(gs, p, tx, ty, tz) then
		return reject(gs, p, tx, ty, tz)
	end
	local held = Inventory.held(p.inventory)
	local def = if held then ItemRegistry.get(held.id) else nil
	if held == nil or def == nil or def.block == nil then
		return reject(gs, p)
	end
	local blockId = def.block :: number
	local targetId = World.getId(gs.world, tx, ty, tz)
	if targetId == 0 then
		-- must click an existing block face
		return reject(gs, p, tx, ty, tz)
	end
	local x, y, z = tx, ty, tz
	if not BlockRegistry.isReplaceable(targetId) then
		x, y, z = tx + Faces.DX[face], ty + Faces.DY[face], tz + Faces.DZ[face]
	end
	if y < 0 or y > 255 or not World.isLoaded(gs.world, x, z) or not World.inBorder(gs.world, x, z) then
		return reject(gs, p, x, math.clamp(y, 0, 255), z)
	end
	if not BlockRegistry.isReplaceable(World.getId(gs.world, x, y, z)) then
		return reject(gs, p, x, y, z)
	end
	if BlockRegistry.isSolid(blockId) then
		for _, other in gs.players do
			if boxIntersectsBlock(playerBox(other), x, y, z) then
				return reject(gs, p, x, y, z)
			end
		end
	end
	-- plants need suitable ground
	local bdef = BlockRegistry.get(blockId)
	if bdef and bdef.shape == "cross" then
		local below = World.getId(gs.world, x, y - 1, z)
		if below ~= 2 and below ~= 3 and below ~= 60 and below ~= 12 and blockId ~= 30 then
			return reject(gs, p, x, y, z)
		end
	end
	local meta = 0
	if blockId == 17 or blockId == 162 or blockId == 5 or blockId == 35 or blockId == 1 or blockId == 6 or blockId == 18 then
		meta = held.meta % 16
	end
	World.setState(gs.world, x, y, z, blockId * 16 + meta)
	count(gs, "blocksPlaced")
	if p.gamemode == "survival" then
		Inventory.consumeHeld(p.inventory, 1)
	end
end

function GameServer.handle(gs: GameServer, id: number, kind: any, args: { any })
	local p = gs.players[id]
	if p == nil then
		return
	end
	local m = Protocol.decodeC2S(kind, args)
	if m == nil then
		p.rejected += 1
		count(gs, "malformed")
		return
	end
	if not spendToken(gs, p) then
		return
	end
	local k = m.kind
	if p.vitals.dead and k ~= C2S.RESPAWN and k ~= C2S.CHAT and k ~= C2S.HELLO then
		p.rejected += 1
		return
	end
	if k == C2S.START_BREAK then
		handleStartBreak(gs, p, m)
	elseif k == C2S.FINISH_BREAK then
		handleFinishBreak(gs, p, m)
	elseif k == C2S.CANCEL_BREAK then
		p.breaking = nil
	elseif k == C2S.PLACE then
		handlePlace(gs, p, m)
	elseif k == C2S.SELECT_SLOT then
		Inventory.select(p.inventory, m.index)
	elseif k == C2S.INV_CLICK then
		if not Inventory.click(p.inventory, m.slot, m.button) then
			p.rejected += 1
		end
	elseif k == C2S.INV_QUICK_MOVE then
		Inventory.quickMove(p.inventory, m.slot)
	elseif k == C2S.CLOSE_CONTAINER then
		local left = Inventory.returnCursor(p.inventory)
		if left > 0 and p.inventory.cursor then
			ItemEntities.spawn(gs.items, p.x, p.y + 1.3, p.z, p.inventory.cursor)
			p.inventory.cursor = nil
		end
	elseif k == C2S.CRAFT then
		-- 3x3 crafting requires a crafting table within reach
		local grid = m.grid
		if grid == 3 and not GameServer._nearBlock(gs, p, 58, 4) then
			grid = 2
		end
		if not Crafting.craft(p.inventory, m.recipe, grid) then
			p.rejected += 1
		end
	elseif k == C2S.CHAT then
		for pid in gs.players do
			send(gs, pid, S2C.CHAT, p.name, m.text)
		end
	elseif k == C2S.JOIN then
		GameServer._join(gs, p)
	elseif k == C2S.HELLO then
		p.sentInvVersion = -1
		p.sentVitals = ""
	elseif k == C2S.RESPAWN then
		if p.vitals.dead then
			Survival.respawn(p.vitals)
			local x, y, z = GameServer.spawnPoint(gs)
			GameServer.teleport(gs, p.id, x, y, z)
			send(gs, p.id, S2C.RESPAWNED, x, y, z)
		end
	elseif k == C2S.USE_START then
		local held = Inventory.held(p.inventory)
		local def = if held then ItemRegistry.get(held.id) else nil
		if def and def.food and p.vitals.food < Survival.MAX_FOOD then
			p.eating = { tick = gs.tickCount, slot = p.inventory.selected }
		else
			p.eating = nil
		end
	elseif k == C2S.USE_FINISH then
		local e = p.eating
		p.eating = nil
		local held = Inventory.held(p.inventory)
		local def = if held then ItemRegistry.get(held.id) else nil
		if e and def and def.food and e.slot == p.inventory.selected and gs.tickCount - e.tick >= math.floor(GameServer.EAT_TICKS * Config.BREAK_TIME_TOLERANCE) then
			if Survival.eat(p.vitals, def.food, def.saturation or 0) then
				Inventory.consumeHeld(p.inventory, 1)
				if def.name == "mushroom_stew" then
					Inventory.add(p.inventory, ItemStack.new(281, 1))
				end
			end
		else
			p.rejected += 1
		end
	end
end

function GameServer._nearBlock(gs: GameServer, p: Player, blockId: number, radius: number): boolean
	local bx, by, bz = math.floor(p.x), math.floor(p.y), math.floor(p.z)
	for y = by - radius, by + radius do
		for z = bz - radius, bz + radius do
			for x = bx - radius, bx + radius do
				if World.getId(gs.world, x, y, z) == blockId then
					return true
				end
			end
		end
	end
	return false
end

-- Survival ------------------------------------------------------------------

local function supported(gs: GameServer, p: Player): (boolean, boolean)
	local world = gs.world
	local y = math.floor(p.y - 0.05)
	local onGround = false
	for _, o in { { -0.3, -0.3 }, { 0.3, -0.3 }, { -0.3, 0.3 }, { 0.3, 0.3 } } do
		local h = Collision.solidHeight(World.getState(world, math.floor(p.x + o[1]), y, math.floor(p.z + o[2])))
		if h > 0 and p.y - (y + h) < 0.1 then
			onGround = true
		end
	end
	local inLiquid = BlockRegistry.isLiquid(World.getId(world, math.floor(p.x), math.floor(p.y + 0.1), math.floor(p.z)))
	return onGround, inLiquid
end

function GameServer.kill(gs: GameServer, p: Player, cause: string)
	if not p.vitals.dead then
		Survival.damage(p.vitals, p.vitals.health)
	end
	GameServer._onDeath(gs, p, cause)
end

function GameServer._onDeath(gs: GameServer, p: Player, cause: string)
	p.breaking, p.eating = nil, nil
	-- drop everything (keepInventory off)
	Inventory.returnCursor(p.inventory)
	for i = 1, Inventory.SIZE do
		local s = p.inventory.slots[i]
		if s then
			ItemEntities.spawn(gs.items, p.x, p.y + 1, p.z, s, (gs.rng:nextFloat() - 0.5) * 0.4, 0.2, (gs.rng:nextFloat() - 0.5) * 0.4)
			p.inventory.slots[i] = nil
		end
	end
	p.inventory.cursor = nil
	p.inventory.version += 1
	count(gs, "deaths")
	send(gs, p.id, S2C.DIED, cause)
end

function GameServer.damage(gs: GameServer, p: Player, amount: number, cause: string): number
	if p.gamemode == "creative" or p.vitals.dead then
		return 0
	end
	local dealt, died = Survival.damage(p.vitals, amount)
	if died then
		GameServer._onDeath(gs, p, cause)
	end
	return dealt
end

function GameServer._tickSurvival(gs: GameServer, p: Player)
	local v = p.vitals
	if v.dead then
		return
	end
	local onGround, inLiquid = supported(gs, p)
	local loaded = World.isLoaded(gs.world, math.floor(p.x), math.floor(p.z))
	if loaded and p.gamemode == "survival" then
		local fall = Survival.trackFall(v, p.y, onGround, inLiquid)
		if fall > 0 then
			GameServer.damage(gs, p, fall, "fell")
		end
		local dx, dz = p.x - p.lastX, p.z - p.lastZ
		local dist = math.sqrt(dx * dx + dz * dz)
		if dist < 2 then -- ignore teleports
			local sprint = dist > 0.23 -- faster than walking speed (4.3 b/s)
			Survival.exhaust(v, dist * (if sprint then Survival.EXHAUSTION.sprintPerBlock else Survival.EXHAUSTION.walkPerBlock))
		end
		if p.y < -64 then
			GameServer.damage(gs, p, 4, "void")
		end
		local dmg = Survival.tickFood(v, GameServer.DIFFICULTY)
		if v.dead and dmg > 0 then
			GameServer._onDeath(gs, p, "starved")
		end
	else
		v.fallStartY = nil
	end
	p.lastX, p.lastZ = p.x, p.z
end

-- Tick ----------------------------------------------------------------------

local function inventorySnapshot(inv: Inventory.Inventory): { [string]: any }
	local slots = {}
	for i = 1, Inventory.SIZE do
		local s = inv.slots[i]
		if s then
			slots[tostring(i)] = { s.id, s.meta, s.count, s.damage }
		end
	end
	local c = inv.cursor
	return { slots = slots, selected = inv.selected, cursor = if c then { c.id, c.meta, c.count, c.damage } else nil }
end

local function replicateChunks(gs: GameServer, p: Player)
	local pcx, pcz = math.floor(p.x) // 16, math.floor(p.z) // 16
	local r = gs.viewRadius
	-- unload far chunks
	local limit = (r + 2) * (r + 2)
	for k in p.sent do
		local cx, cz = Coords.unpackChunkKey(k)
		local dx, dz = cx - pcx, cz - pcz
		if dx * dx + dz * dz > limit or not World.getChunk(gs.world, cx, cz) then
			p.sent[k] = nil
			p.sentCount -= 1
			send(gs, p.id, S2C.UNLOAD, cx, cz)
		end
	end
	-- send nearest unsent loaded chunks
	local cand: { number } = {}
	local dist: { [number]: number } = {}
	for dz = -r, r do
		for dx = -r, r do
			local d = dx * dx + dz * dz
			if d <= r * r then
				local k = Coords.chunkKey(pcx + dx, pcz + dz)
				if not p.sent[k] and gs.world.chunks[k] then
					table.insert(cand, k)
					dist[k] = d
				end
			end
		end
	end
	table.sort(cand, function(a: number, b: number): boolean
		if dist[a] ~= dist[b] then
			return dist[a] < dist[b]
		end
		return a < b
	end)
	for i = 1, math.min(#cand, gs.sendBudget) do
		local k = cand[i]
		p.sent[k] = true
		p.sentCount += 1
		send(gs, p.id, S2C.CHUNK, ChunkCodec.encode(gs.world.chunks[k]))
		count(gs, "chunksSent")
	end
end

function GameServer.tick(gs: GameServer)
	gs.tickCount += 1
	gs.worldTime = (gs.worldTime + 1) % 24000
	-- refill action tokens
	local refill = Config.ACTIONS_PER_SECOND / Config.TICK_RATE
	for _, p in gs.players do
		p.tokens = math.min(Config.ACTION_BURST, p.tokens + refill)
	end
	-- retry failed loads whose delay expired
	for k, at in gs.failedLoads do
		if at <= gs.tickCount then
			gs.failedLoads[k] = nil
		end
	end
	-- survival
	for _, p in gs.players do
		GameServer._tickSurvival(gs, p)
	end
	-- chunk lifecycle
	local viewers = {}
	for _, p in gs.players do
		table.insert(viewers, { cx = math.floor(p.x) // 16, cz = math.floor(p.z) // 16 })
	end
	if gs.tickCount % 10 == 1 or ChunkScheduler.pending(gs.scheduler) == 0 then
		ChunkScheduler.setViewers(gs.scheduler, viewers)
	end
	ChunkScheduler.step(gs.scheduler, gs.genBudget)
	if gs.tickCount % 20 == 0 and #viewers > 0 then
		ChunkScheduler.collect(gs.scheduler)
	end
	-- fluids
	Fluids.step(gs.fluids)
	-- entities
	local world = gs.world
	ItemEntities.tick(gs.items, function(x, y, z)
		return World.getState(world, x, y, z)
	end, function(x, z)
		return World.isLoaded(world, math.floor(x), math.floor(z))
	end)
	if gs.tickCount % 10 == 0 then
		ItemEntities.merge(gs.items)
	end
	for _, p in gs.players do
		if not p.vitals.dead then
			for _, e in ItemEntities.inPickupRange(gs.items, p.x, p.y, p.z) do
				local left = Inventory.add(p.inventory, e.stack)
				if left == 0 then
					ItemEntities.remove(gs.items, e.id)
				elseif left < e.stack.count then
					e.stack = ItemStack.copy(e.stack, left)
				end
			end
		end
	end
	-- replication
	local changes = gs.pendingChanges
	gs.pendingChanges = {}
	local ev = ItemEntities.takeEvents(gs.items)
	for _, p in gs.players do
		if not p.joined then
			continue
		end
		replicateChunks(gs, p)
		if #changes > 0 then
			local mine: { number } = {}
			for i = 1, #changes, 4 do
				local k = Coords.chunkKey(changes[i] // 16, changes[i + 2] // 16)
				if p.sent[k] then
					table.move(changes, i, i + 3, #mine + 1, mine)
				end
			end
			if #mine > 0 then
				send(gs, p.id, S2C.BLOCKS, Protocol.encodeBlockChanges(mine))
			end
		end
		local v = p.vitals
		local vs = string.format("%d:%d:%.1f:%s:%s", v.health, v.food, v.saturation, tostring(v.dead), p.gamemode)
		if vs ~= p.sentVitals then
			p.sentVitals = vs
			send(gs, p.id, S2C.PLAYER, { health = v.health, food = v.food, saturation = v.saturation, dead = v.dead, gamemode = p.gamemode })
		end
		if p.inventory.version ~= p.sentInvVersion then
			p.sentInvVersion = p.inventory.version
			send(gs, p.id, S2C.INVENTORY, inventorySnapshot(p.inventory))
		end
		if #ev.spawned + #ev.removed + #ev.moved > 0 then
			local spawned = {}
			for _, e in ev.spawned do
				if gs.items.list[e.id] then
					table.insert(spawned, { e.id, e.x, e.y, e.z, e.stack.id, e.stack.meta, e.stack.count })
				end
			end
			local moved = {}
			for _, e in ev.moved do
				if gs.items.list[e.id] then
					table.insert(moved, { e.id, e.x, e.y, e.z })
				end
			end
			send(gs, p.id, S2C.ITEMS, { spawned = spawned, moved = moved, removed = ev.removed })
		end
	end
	if gs.tickCount % 200 == 0 then
		for pid in gs.players do
			send(gs, pid, S2C.TIME, gs.worldTime)
		end
	end
end

-- Persistence ---------------------------------------------------------------

-- Moves dirty loaded chunks into the save buffer and flushes up to `budget`
-- requests. Call periodically (e.g. every few seconds) from the adapter.
function GameServer.autosave(gs: GameServer, budget: number): number
	local sm = gs.save
	if sm == nil then
		return 0
	end
	for _, c in gs.world.chunks do
		if c.dirty then
			SaveManager.storeChunk(sm, c)
		end
	end
	SaveManager.setMeta(sm, "time", gs.worldTime)
	local n = SaveManager.flush(sm, budget)
	SaveManager.evictRegions(sm, function(cx, cz)
		return World.isLoaded(gs.world, cx * 16, cz * 16)
	end)
	return n
end

function GameServer.takeOutbox(gs: GameServer, pid: number): { Outgoing }
	local box = gs.outbox[pid] or {}
	if gs.outbox[pid] then
		gs.outbox[pid] = {}
	end
	return box
end

return GameServer
