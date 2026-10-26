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
local Chunk = require("../Voxel/Chunk")
local Survival = require("./Survival")
local Fluids = require("./Fluids")
local LightEngine = require("../Voxel/LightEngine")
local Mobs = require("./Mobs")
local MobTypes = require("./MobTypes")
local Time = require("./Time")
local BlockEntities = require("./BlockEntities")
local BlockUpdates = require("./BlockUpdates")
local Redstone = require("./Redstone")
local Portals = require("./Portals")

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
	knownMobs: { [number]: boolean },
	portalTicks: number,
	portalCooldown: number,
	sleeping: { x: number, y: number, z: number, ticks: number }?,
	spawn: { number }?, -- bed position (foot) or nil for world spawn
	drawing: { tick: number, slot: number }?, -- bow charge
	open: { x: number, y: number, z: number, version: number }?,
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
	sendBytesPerSecond: number?,
	mobs: boolean?, -- natural mob spawning (default on)
	asyncGenerate: ((cx: number, cz: number, dimension: string, seedText: string) -> ())?, -- off-thread generation hook
	dimension: string?, -- "overworld" (default) | "nether"
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
	mobs: Mobs.Mobs,
	mobsEnabled: boolean,
	dimension: string,
	asyncGenerate: ((cx: number, cz: number, dimension: string, seedText: string) -> ())?,
	pendingGen: { [number]: boolean },
	furnaces: { [number]: { number } }, -- position key -> {x, y, z}
	spawners: { [number]: { number } },
	updates: BlockUpdates.BlockUpdates,
	redstone: Redstone.Redstone,
	plates: { [number]: { number } },
	randomTickRadius: number,
	rng: JavaRandom.JavaRandom,
	tickCount: number,
	worldTime: number,
	viewRadius: number,
	sendBudget: number,
	sendBytesPerTick: number,
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
		generator = WorldGenerator.new(seed, { cacheCapacity = 256, dimension = opts.dimension }),
		seedText = seedText,
		scheduler = nil :: any,
		save = save,
		players = {},
		outbox = {},
		pendingChanges = {},
		items = ItemEntities.new(),
		fluids = nil :: any,
		light = LightEngine.new(world, opts.dimension == "nether"),
		mobs = Mobs.new(seed.lo + 7),
		mobsEnabled = opts.mobs ~= false,
		dimension = opts.dimension or "overworld",
		asyncGenerate = opts.asyncGenerate,
		pendingGen = {},
		furnaces = {},
		spawners = {},
		updates = nil :: any,
		redstone = Redstone.new(world),
		plates = {},
		randomTickRadius = 4,
		rng = JavaRandom.new(seed.lo),
		tickCount = 0,
		worldTime = 0,
		viewRadius = opts.viewRadius or Config.SERVER_VIEW_RADIUS,
		sendBudget = opts.sendBudget or Config.SEND_BUDGET_PER_TICK,
		sendBytesPerTick = (opts.sendBytesPerSecond or Config.SEND_BYTES_PER_SECOND) / Config.TICK_RATE,
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
	gs.fluids = Fluids.new(world, 2048, gs.dimension == "nether")
	gs.updates = BlockUpdates.new(world, {
		popBlock = function(x, y, z)
			local st = World.getState(world, x, y, z)
			World.setState(world, x, y, z, 0)
			for _, drop in Mining.drops(st, nil, gs.rng) do
				ItemEntities.spawn(gs.items, x + 0.5, y + 0.3, z + 0.5, drop)
			end
		end,
		skyLight = function(x, y, z)
			return LightEngine.sky(gs.light, x, y, z)
		end,
		blockLight = function(x, y, z)
			return LightEngine.block(gs.light, x, y, z)
		end,
		skyDarken = function()
			return Time.skyDarken(gs.worldTime)
		end,
	}, seed.lo + 13)
	World.addListener(world, function(x, y, z, old, new)
		LightEngine.onBlockChanged(gs.light, x, y, z, old // 16, new // 16)
		GameServer._blockEntityChange(gs, x, y, z, old // 16, new // 16)
		BlockUpdates.onChange(gs.updates, x, y, z)
		Redstone.onChange(gs.redstone, x, y, z, old // 16, new // 16)
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
			gs.generator = WorldGenerator.new(WorldSeed.fromString(seedText), { cacheCapacity = 256, dimension = gs.dimension })
		end
		gs.worldTime = tonumber(gs.save.meta.time) or 0
	end
	return true, nil
end

-- sync = true forces in-thread generation (spawn point, portal arrival).
function GameServer._loadChunk(gs: GameServer, cx: number, cz: number, sync: boolean?)
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
	if chunk == nil and gs.asyncGenerate and not sync then
		-- generated off-thread (Roblox Actors); arrives via deliverGenerated
		gs.pendingGen[Coords.chunkKey(cx, cz)] = true
		count(gs, "asyncRequested")
		gs.asyncGenerate(cx, cz, gs.dimension, gs.seedText)
		return
	end
	if chunk == nil then
		chunk = WorldGenerator.generate(gs.generator, cx, cz)
		count(gs, "generated")
	else
		count(gs, "loadedFromSave")
	end
	GameServer._installChunk(gs, chunk :: any)
end

-- Accepts an asynchronously generated chunk. Results for chunks that were
-- unloaded (or already present) meanwhile are dropped.
function GameServer.deliverGenerated(gs: GameServer, chunk: Chunk.Chunk): boolean
	local k = Coords.chunkKey(chunk.cx, chunk.cz)
	if not gs.pendingGen[k] then
		count(gs, "staleGenerated")
		return false
	end
	gs.pendingGen[k] = nil
	if World.getChunk(gs.world, chunk.cx, chunk.cz) then
		return false
	end
	count(gs, "generated")
	GameServer._installChunk(gs, chunk)
	return true
end

function GameServer._installChunk(gs: GameServer, chunk: Chunk.Chunk)
	local cx, cz = chunk.cx, chunk.cz
	World.putChunk(gs.world, chunk :: any)
	LightEngine.addChunk(gs.light, cx, cz)
	local bes = (chunk :: any).blockEntities
	if bes then
		for idx, e in bes do
			local x, z, y = cx * 16 + idx % 16, cz * 16 + (idx // 16) % 16, idx // 256
			if e.kind == "furnace" then
				gs.furnaces[Fluids.key(x, y, z)] = { x, y, z }
			elseif BlockEntities.isSpawner(e) then
				gs.spawners[Fluids.key(x, y, z)] = { x, y, z }
			end
		end
	end
end

function GameServer._unloadChunk(gs: GameServer, cx: number, cz: number)
	gs.pendingGen[Coords.chunkKey(cx, cz)] = nil
	local c = World.getChunk(gs.world, cx, cz)
	if c == nil then
		return
	end
	if c.dirty and gs.save then
		SaveManager.storeChunk(gs.save, c)
	end
	for _, set in { gs.furnaces, gs.spawners } do
		for k, pos in set do
			if pos[1] // 16 == cx and pos[3] // 16 == cz then
				set[k] = nil
			end
		end
	end
	World.removeChunk(gs.world, cx, cz)
	LightEngine.removeChunk(gs.light, cx, cz)
	count(gs, "unloaded")
end

-- Players -------------------------------------------------------------------

function GameServer.spawnPoint(gs: GameServer): (number, number, number)
	-- highest non-air block at the origin column (generates it if needed)
	if not World.isLoaded(gs.world, 0, 0) then
		GameServer._loadChunk(gs, 0, 0, true)
		if World.isLoaded(gs.world, 0, 0) then
			ChunkScheduler.markLoaded(gs.scheduler, 0, 0)
		end
	end
	if gs.dimension == "nether" then
		for y = 33, 120 do
			if BlockRegistry.isSolid(World.getId(gs.world, 0, y - 1, 0)) and World.getId(gs.world, 0, y, 0) == 0 and World.getId(gs.world, 0, y + 1, 0) == 0 then
				return 0.5, y, 0.5
			end
		end
		return 0.5, 64, 0.5
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
		knownMobs = {},
		portalTicks = 0,
		portalCooldown = 100,
		sleeping = nil,
		spawn = nil,
		drawing = nil,
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
	p.knownMobs = {}
	p.sent = {}
	p.sentCount = 0
	p.sentInvVersion = -1
	p.sentVitals = ""
	send(gs, p.id, S2C.WELCOME, { seed = gs.seedText, size = gs.world.maxX - gs.world.minX + 1, x = p.x, y = p.y, z = p.z, gamemode = p.gamemode, dimension = gs.dimension })
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
	if type(r.spawn) == "table" and #r.spawn == 3 then
		p.spawn = { r.spawn[1], r.spawn[2], r.spawn[3] }
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
	return { pos = { p.x, p.y, p.z }, gamemode = p.gamemode, health = if v.dead then 20 else v.health, food = v.food, saturation = v.saturation, inventory = inv, selected = p.inventory.selected, spawn = p.spawn }
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
	if id == 26 then
		local meta = state % 16
		local d = meta % 4
		local sx = if d == 3 then 1 elseif d == 1 then -1 else 0
		local sz = if d == 0 then 1 elseif d == 2 then -1 else 0
		local sign = if meta >= 8 then -1 else 1 -- head points back to its foot
		local ox, oz = x + sx * sign, z + sz * sign
		if World.getId(gs.world, ox, y, oz) == 26 then
			World.setState(gs.world, ox, y, oz, 0)
		end
		if meta >= 8 then
			-- drop from the foot only
			World.setState(gs.world, x, y, z, 0)
			if p.gamemode == "survival" then
				ItemEntities.spawn(gs.items, x + 0.5, y + 0.5, z + 0.5, ItemStack.new(355, 1))
			end
			return
		end
	end
	if (id == 64 or id == 71) and state % 16 >= 8 then
		-- breaking the upper half breaks the door from its lower half (one drop)
		if World.getId(gs.world, x, y - 1, z) == id then
			return doBreak(gs, p, x, y - 1, z)
		end
	end
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

-- Items with special "use" behaviour. Returns true when the use was handled
-- (successfully or rejected) so normal placement is skipped.
function GameServer._useItem(gs: GameServer, p: Player, held: ItemStack.ItemStack, def: ItemRegistry.ItemDef, tx: number, ty: number, tz: number, face: number): boolean
	local world = gs.world
	local target = World.getState(world, tx, ty, tz)
	local tid = target // 16
	local survival = p.gamemode == "survival"
	local function consume()
		if survival then
			Inventory.consumeHeld(p.inventory, 1)
		end
	end
	local function replaceHeld(id: number)
		if survival then
			local inv = p.inventory
			if held.count > 1 then
				Inventory.consumeHeld(inv, 1)
				if Inventory.add(inv, ItemStack.new(id, 1)) > 0 then
					ItemEntities.spawn(gs.items, p.x, p.y + 1, p.z, ItemStack.new(id, 1))
				end
			else
				inv.slots[inv.selected] = ItemStack.new(id, 1)
				inv.version += 1
			end
		end
	end
	if held.id == 259 then -- flint and steel: light a portal in the cell in front of the face
		local fx, fy, fz = tx + Faces.DX[face], ty + Faces.DY[face], tz + Faces.DZ[face]
		if Portals.tryIgnite(world, fx, fy, fz) then
			if survival and def.durability then
				local nd = held.damage + 1
				p.inventory.slots[p.inventory.selected] = if nd >= def.durability then nil else ItemStack.new(held.id, 1, held.meta, nd)
				p.inventory.version += 1
			end
		else
			reject(gs, p)
		end
		return true
	elseif def.tool == "hoe" then
		if face ~= 3 and (tid == 2 or tid == 3) and World.getId(world, tx, ty + 1, tz) == 0 then
			World.setState(world, tx, ty, tz, 60 * 16)
			if survival and def.durability then
				local nd = held.damage + 1
				p.inventory.slots[p.inventory.selected] = if nd >= def.durability then nil else ItemStack.new(held.id, 1, held.meta, nd)
				p.inventory.version += 1
			end
		else
			reject(gs, p)
		end
		return true
	elseif held.id == 295 then -- seeds
		if face == 2 and tid == 60 and World.getId(world, tx, ty + 1, tz) == 0 then
			World.setState(world, tx, ty + 1, tz, 59 * 16)
			consume()
		else
			reject(gs, p)
		end
		return true
	elseif held.id == 325 then -- empty bucket: scoop a source block
		if (tid == 9 or tid == 11) and target % 16 == 0 then
			World.setState(world, tx, ty, tz, 0)
			replaceHeld(if tid == 9 then 326 else 327)
		else
			reject(gs, p)
		end
		return true
	elseif held.id == 326 or held.id == 327 then
		local x, y, z = tx, ty, tz
		if not BlockRegistry.isReplaceable(tid) or BlockRegistry.isLiquid(tid) and target % 16 == 0 then
			x, y, z = tx + Faces.DX[face], ty + Faces.DY[face], tz + Faces.DZ[face]
		end
		local cur = World.getId(world, x, y, z)
		if held.id == 326 and gs.dimension == "nether" then
			replaceHeld(325) -- water evaporates
			return true
		end
		if y >= 0 and y <= 255 and World.isLoaded(world, x, z) and World.inBorder(world, x, z) and (BlockRegistry.isReplaceable(cur) and not (BlockRegistry.isLiquid(cur) and World.getState(world, x, y, z) % 16 == 0)) then
			World.setState(world, x, y, z, (if held.id == 326 then 9 else 11) * 16)
			replaceHeld(325)
		else
			reject(gs, p)
		end
		return true
	end
	return false
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
	-- "use" on a container opens it instead of placing
	local useKind = BlockEntities.kindForBlock(World.getId(gs.world, tx, ty, tz))
	if useKind == "chest" or useKind == "furnace" then
		GameServer._openContainer(gs, p, tx, ty, tz)
		return
	end
	-- levers, buttons and wooden doors are used, not built on
	if Redstone.use(gs.redstone, tx, ty, tz) then
		return
	end
	if World.getId(gs.world, tx, ty, tz) == 26 then
		GameServer._useBed(gs, p, tx, ty, tz)
		return
	end
	local held = Inventory.held(p.inventory)
	local def = if held then ItemRegistry.get(held.id) else nil
	if held and def and GameServer._useItem(gs, p, held, def, tx, ty, tz, face) then
		return
	end
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
	local placeUpper = false
	if blockId == 61 or blockId == 54 or blockId == 86 then
		-- face the player: 2 north (-z), 3 south (+z), 4 west (-x), 5 east (+x)
		local dx, dz = p.x - (x + 0.5), p.z - (z + 0.5)
		if math.abs(dx) > math.abs(dz) then
			meta = if dx > 0 then 5 else 4
		else
			meta = if dz > 0 then 3 else 2
		end
	end
	if blockId == 17 or blockId == 162 or blockId == 5 or blockId == 35 or blockId == 1 or blockId == 6 then
		meta = held.meta % 16
	elseif blockId == 18 or blockId == 161 then
		meta = held.meta % 4 + 4 -- player-placed leaves never decay
	elseif blockId == 50 or blockId == 76 or blockId == 69 or blockId == 77 then
		-- torches, levers and buttons attach to the clicked face
		local ATTACH_META = { [0] = 1, 2, 5, -1, 3, 4 }
		meta = ATTACH_META[face]
		if meta < 0 or (blockId == 77 and meta == 5) then
			return reject(gs, p, x, y, z)
		end
	elseif blockId == 55 or blockId == 70 or blockId == 72 then
		if not BlockRegistry.occludes(World.getId(gs.world, x, y - 1, z)) then
			return reject(gs, p, x, y, z)
		end
	elseif blockId == 26 then
		-- beds: foot here, head one block away from the player (meta 0 +z, 1 -x, 2 -z, 3 +x)
		local dx, dz = (x + 0.5) - p.x, (z + 0.5) - p.z
		meta = if math.abs(dx) > math.abs(dz) then (if dx > 0 then 3 else 1) else (if dz > 0 then 0 else 2)
		local hx, hz = x + (if meta == 3 then 1 elseif meta == 1 then -1 else 0), z + (if meta == 0 then 1 elseif meta == 2 then -1 else 0)
		if not BlockRegistry.isReplaceable(World.getId(gs.world, hx, y, hz)) or not BlockRegistry.occludes(World.getId(gs.world, x, y - 1, z)) or not BlockRegistry.occludes(World.getId(gs.world, hx, y - 1, hz)) then
			return reject(gs, p, x, y, z)
		end
		World.setStates(gs.world, { x, y, z, 26 * 16 + meta, hx, y, hz, 26 * 16 + meta + 8 })
		if p.gamemode == "survival" then
			Inventory.consumeHeld(p.inventory, 1)
		end
		return
	elseif blockId == 64 or blockId == 71 then
		-- doors: two blocks tall on solid ground, facing away from the player
		if y >= 255 or not BlockRegistry.occludes(World.getId(gs.world, x, y - 1, z)) or not BlockRegistry.isReplaceable(World.getId(gs.world, x, y + 1, z)) then
			return reject(gs, p, x, y, z)
		end
		local dx, dz = p.x - (x + 0.5), p.z - (z + 0.5)
		meta = if math.abs(dx) > math.abs(dz) then (if dx > 0 then 2 else 0) else (if dz > 0 then 3 else 1)
		placeUpper = true
	end
	World.setState(gs.world, x, y, z, blockId * 16 + meta)
	if placeUpper then
		World.setState(gs.world, x, y + 1, z, blockId * 16 + 8)
	end
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
	elseif k == C2S.CONTAINER_CLICK then
		local o = p.open
		local e = if o then BlockEntities.get(gs.world, o.x, o.y, o.z) else nil
		if o == nil or e == nil or not inReach(p, o.x, o.y, o.z) then
			p.rejected += 1
			return
		end
		local ok, cursor = BlockEntities.click(e, m.slot, p.inventory.cursor, m.button)
		if ok then
			p.inventory.cursor = cursor
			p.inventory.version += 1
			local c = World.getChunk(gs.world, o.x // 16, o.z // 16)
			if c then
				c.dirty = true
			end
		else
			p.rejected += 1
		end
	elseif k == C2S.CLOSE_CONTAINER then
		if p.open then
			p.open = nil
			send(gs, p.id, S2C.CONTAINER, false)
		end
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
	elseif k == C2S.ATTACK then
		GameServer._attack(gs, p, m.mob)
	elseif k == C2S.JOIN then
		GameServer._join(gs, p)
	elseif k == C2S.HELLO then
		p.sentInvVersion = -1
		p.sentVitals = ""
	elseif k == C2S.RESPAWN then
		if p.vitals.dead then
			Survival.respawn(p.vitals)
			local x, y, z = GameServer._respawnPoint(gs, p)
			GameServer.teleport(gs, p.id, x, y, z)
			send(gs, p.id, S2C.RESPAWNED, x, y, z)
		end
	elseif k == C2S.USE_START then
		local held = Inventory.held(p.inventory)
		local def = if held then ItemRegistry.get(held.id) else nil
		if held and held.id == 261 and (p.gamemode == "creative" or Inventory.count(p.inventory, 262) > 0) then
			p.drawing = { tick = gs.tickCount, slot = p.inventory.selected }
			p.eating = nil
		elseif def and def.food and p.vitals.food < Survival.MAX_FOOD then
			p.eating = { tick = gs.tickCount, slot = p.inventory.selected }
		else
			p.eating = nil
		end
	elseif k == C2S.USE_FINISH and p.drawing then
		GameServer._releaseBow(gs, p, m.dx, m.dy, m.dz)
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

-- Causes that armour does not reduce (classic).
local UNARMORED: { [string]: boolean } = { fell = true, void = true, starved = true, drowned = true }

function GameServer.damage(gs: GameServer, p: Player, amount: number, cause: string): number
	if p.gamemode == "creative" or p.vitals.dead then
		return 0
	end
	if not UNARMORED[cause] then
		local points = Inventory.armorPoints(p.inventory)
		if points > 0 then
			-- pre-1.9: each defence point blocks 4%; fractional damage carries
			local reduced = amount * (1 - points * 0.04)
			Inventory.wearArmor(p.inventory, amount)
			amount = math.floor(reduced)
			if gs.rng:nextFloat() < reduced - amount then
				amount += 1
			end
			if amount <= 0 then
				return 0
			end
		end
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

-- Block entities -------------------------------------------------------------

-- Keeps block entities consistent with blocks: created when a container
-- block appears, contents dropped when it disappears (any cause).
function GameServer._blockEntityChange(gs: GameServer, x: number, y: number, z: number, oldId: number, newId: number)
	local oldKind, newKind = BlockEntities.kindForBlock(oldId), BlockEntities.kindForBlock(newId)
	if oldKind == newKind then
		return
	end
	local key = Fluids.key(x, y, z)
	if oldKind then
		local e = BlockEntities.get(gs.world, x, y, z)
		if e then
			for _, s in BlockEntities.contents(e) do
				ItemEntities.spawn(gs.items, x + 0.5, y + 0.5, z + 0.5, s, (gs.rng:nextFloat() - 0.5) * 0.3, 0.2, (gs.rng:nextFloat() - 0.5) * 0.3)
			end
			BlockEntities.set(gs.world, x, y, z, nil)
		end
		gs.furnaces[key] = nil
		gs.spawners[key] = nil
	end
	if newKind then
		BlockEntities.set(gs.world, x, y, z, BlockEntities.new(newKind))
		if newKind == "furnace" then
			gs.furnaces[key] = { x, y, z }
		elseif newKind == "spawner" then
			gs.spawners[key] = { x, y, z }
		end
	end
end

function GameServer._openContainer(gs: GameServer, p: Player, x: number, y: number, z: number): boolean
	local e = BlockEntities.get(gs.world, x, y, z)
	if e == nil then
		return false
	end
	p.open = { x = x, y = y, z = z, version = -1 }
	return true
end

local function containerTick(gs: GameServer, p: Player)
	local o = p.open
	if o == nil then
		return
	end
	local e = BlockEntities.get(gs.world, o.x, o.y, o.z)
	if e == nil or not inReach(p, o.x, o.y, o.z) or p.vitals.dead then
		p.open = nil
		Inventory.returnCursor(p.inventory)
		send(gs, p.id, S2C.CONTAINER, false)
		return
	end
	if e.version ~= o.version then
		o.version = e.version
		send(gs, p.id, S2C.CONTAINER, { x = o.x, y = o.y, z = o.z, state = BlockEntities.snapshot(e) })
	end
end

function GameServer._tickFurnaces(gs: GameServer)
	for k, pos in gs.furnaces do
		local x, y, z = pos[1], pos[2], pos[3]
		local e = BlockEntities.get(gs.world, x, y, z)
		if e == nil then
			gs.furnaces[k] = nil
			continue
		end
		local changed, lit = BlockEntities.tickFurnace(e)
		if changed then
			local st = World.getState(gs.world, x, y, z)
			local want = if lit then BlockEntities.LIT_FURNACE else BlockEntities.FURNACE
			if st // 16 ~= want then
				World.setState(gs.world, x, y, z, want * 16 + st % 16)
			end
			local c = World.getChunk(gs.world, x // 16, z // 16)
			if c then
				c.dirty = true
			end
		end
	end
end

-- Mob spawners (classic: active within 16 blocks of a player, 200..799 tick
-- delay, up to 4 mobs per cycle within 4 blocks, at most 6 nearby).
function GameServer._tickSpawners(gs: GameServer)
	for k, pos in gs.spawners do
		local x, y, z = pos[1], pos[2], pos[3]
		local e = BlockEntities.get(gs.world, x, y, z)
		if e == nil or not BlockEntities.isSpawner(e) then
			gs.spawners[k] = nil
			continue
		end
		local active = false
		for _, p in gs.players do
			local dx, dy, dz = p.x - x - 0.5, p.y - y, p.z - z - 0.5
			if dx * dx + dy * dy + dz * dz <= 256 then
				active = true
				break
			end
		end
		if not active then
			continue
		end
		e.cook -= 1
		if e.cook > 0 then
			continue
		end
		local rng = gs.rng
		e.cook = 200 + rng:nextInt(600)
		local okKind, kind = pcall(MobTypes.byName, BlockEntities.spawnerMob(e))
		if not okKind then
			continue
		end
		local nearby = 0
		for _, m in gs.mobs.list do
			if m.kind == kind and math.abs(m.x - x) <= 8 and math.abs(m.y - y) <= 4 and math.abs(m.z - z) <= 8 then
				nearby += 1
			end
		end
		for _ = 1, 4 do
			if nearby >= 6 then
				break
			end
			local sx = x + rng:nextInt(9) - 4
			local sy = y + rng:nextInt(3) - 1
			local sz = z + rng:nextInt(9) - 4
			if World.getId(gs.world, sx, sy, sz) == 0 and World.getId(gs.world, sx, sy + 1, sz) == 0 and BlockRegistry.isSolid(World.getId(gs.world, sx, sy - 1, sz)) then
				Mobs.spawn(gs.mobs, kind, sx + 0.5, sy, sz + 0.5)
				nearby += 1
			end
		end
		local c = World.getChunk(gs.world, x // 16, z // 16)
		if c then
			c.dirty = true
		end
	end
end

-- Beds ---------------------------------------------------------------------

function GameServer.isNight(gs: GameServer): boolean
	local t = gs.worldTime % 24000
	return t >= 12541 and t <= 23458
end

function GameServer._useBed(gs: GameServer, p: Player, x: number, y: number, z: number)
	if gs.dimension == "nether" then
		-- beds explode outside the Overworld (classic)
		World.setState(gs.world, x, y, z, 0)
		GameServer.explode(gs, x + 0.5, y + 0.5, z + 0.5, 5)
		return
	end
	local st = World.getState(gs.world, x, y, z)
	if st % 16 >= 8 then
		-- clicked the head: find the foot
		local d = st % 4
		x -= if d == 3 then 1 elseif d == 1 then -1 else 0
		z -= if d == 0 then 1 elseif d == 2 then -1 else 0
	end
	p.spawn = { x, y, z }
	if not GameServer.isNight(gs) then
		send(gs, p.id, S2C.CHAT, "", "You can only sleep at night")
		return
	end
	for _, mob in gs.mobs.list do
		if mob.kind.hostile and not mob.kind.neutral and math.abs(mob.x - x) < 8 and math.abs(mob.y - y) < 5 and math.abs(mob.z - z) < 8 then
			send(gs, p.id, S2C.CHAT, "", "You may not rest now, there are monsters nearby")
			return
		end
	end
	p.sleeping = { x = x, y = y, z = z, ticks = 0 }
	send(gs, p.id, S2C.SLEEP, true)
end

local function wake(gs: GameServer, p: Player)
	if p.sleeping then
		p.sleeping = nil
		send(gs, p.id, S2C.SLEEP, false)
	end
end

function GameServer._tickSleep(gs: GameServer)
	local any, all = false, true
	for _, p in gs.players do
		local s = p.sleeping
		if s then
			any = true
			s.ticks += 1
			if math.abs(p.x - s.x - 0.5) > 2 or math.abs(p.z - s.z - 0.5) > 2 or World.getId(gs.world, s.x, s.y, s.z) ~= 26 or p.vitals.dead then
				wake(gs, p)
				all = false
			elseif s.ticks < 100 then
				all = false
			end
		elseif p.joined and not p.vitals.dead then
			all = false
		end
	end
	if any and all then
		-- everyone asleep for 5 s: skip to morning
		gs.worldTime = 0
		for _, p in gs.players do
			wake(gs, p)
			send(gs, p.id, S2C.TIME, gs.worldTime)
		end
		count(gs, "nightsSkipped")
	end
end

-- Respawn position: next to the player's bed if it still exists.
function GameServer._respawnPoint(gs: GameServer, p: Player): (number, number, number)
	local s = p.spawn
	if s and World.isLoaded(gs.world, s[1], s[3]) and World.getId(gs.world, s[1], s[2], s[3]) == 26 then
		for _, o in { { 0, 1 }, { 1, 0 }, { 0, -1 }, { -1, 0 }, { 1, 1 }, { -1, -1 } } do
			local x, z = s[1] + o[1], s[3] + o[2]
			if World.getId(gs.world, x, s[2], z) == 0 and World.getId(gs.world, x, s[2] + 1, z) == 0 and BlockRegistry.isSolid(World.getId(gs.world, x, s[2] - 1, z)) then
				return x + 0.5, s[2], z + 0.5
			end
		end
		return s[1] + 0.5, s[2] + 0.5625, s[3] + 0.5
	end
	if s then
		send(gs, p.id, S2C.CHAT, "", "Your home bed was missing or obstructed")
		p.spawn = nil
	end
	return GameServer.spawnPoint(gs)
end

-- Bows (classic charge curve): f = (t^2 + 2t) / 3 with t = seconds drawn, capped at 1;
-- arrow speed 3f blocks/tick; full draw is a critical hit.
function GameServer._releaseBow(gs: GameServer, p: Player, dx: number?, dy: number?, dz: number?)
	local d = p.drawing
	p.drawing = nil
	local held = Inventory.held(p.inventory)
	if d == nil or held == nil or held.id ~= 261 or d.slot ~= p.inventory.selected or dx == nil or dy == nil or dz == nil then
		p.rejected += 1
		return
	end
	local secs = (gs.tickCount - d.tick) / 20
	local f = math.min(1, (secs * secs + secs * 2) / 3)
	if f < 0.1 then
		return
	end
	if p.gamemode == "survival" then
		if Inventory.remove(p.inventory, 262, nil, 1) < 1 then
			return
		end
		local nd = held.damage + 1
		p.inventory.slots[p.inventory.selected] = if nd >= 384 then nil else ItemStack.new(261, 1, 0, nd)
		p.inventory.version += 1
	end
	local arrow = Mobs.spawn(gs.mobs, MobTypes.byName("arrow"), p.x + (dx :: number) * 0.5, p.y + 1.52, p.z + (dz :: number) * 0.5)
	local speed = f * 3
	arrow.vx, arrow.vy, arrow.vz = (dx :: number) * speed, (dy :: number) * speed, (dz :: number) * speed
	arrow.ownerPlayer = p.id
	count(gs, "arrowsShot")
end

-- Mobs & combat -------------------------------------------------------------

function GameServer._mobContext(gs: GameServer): Mobs.Context
	local world, le = gs.world, gs.light
	local views = {}
	for _, p in gs.players do
		if p.joined then
			table.insert(views, { id = p.id, x = p.x, y = p.y, z = p.z, attackable = p.gamemode == "survival" and not p.vitals.dead })
		end
	end
	local darken = Time.skyDarken(gs.worldTime)
	return {
		players = views,
		getState = function(x, y, z)
			return World.getState(world, x, y, z)
		end,
		isLoaded = function(x, z)
			return World.isLoaded(world, math.floor(x), math.floor(z))
		end,
		skyLight = function(x, y, z)
			return LightEngine.sky(le, x, y, z)
		end,
		light = function(x, y, z)
			return LightEngine.light(le, x, y, z, darken)
		end,
		isDay = gs.dimension ~= "nether" and Time.isDay(gs.worldTime),
		spawnList = if gs.dimension == "nether" then { "zombie_pigman" } else nil,
		damagePlayer = function(id, amount, cause)
			local p = gs.players[id]
			if p then
				GameServer.damage(gs, p, amount, cause)
			end
		end,
		explode = function(x, y, z, power)
			GameServer.explode(gs, x, y, z, power)
		end,
		dropItem = function(x, y, z, stack)
			ItemEntities.spawn(gs.items, x, y, z, stack, (gs.rng:nextFloat() - 0.5) * 0.2, 0.2, (gs.rng:nextFloat() - 0.5) * 0.2)
		end,
	}
end

-- Classic-style explosion: blocks within ~power*1.3 with random falloff are
-- destroyed unless blast-proof (obsidian, bedrock, liquids); each destroyed
-- block drops with chance 1/power; players take distance-scaled damage.
function GameServer.explode(gs: GameServer, x: number, y: number, z: number, power: number)
	local r = math.ceil(power * 1.3)
	local rng = gs.rng
	local cx, cy, cz = math.floor(x), math.floor(y), math.floor(z)
	for by = cy - r, cy + r do
		for bz = cz - r, cz + r do
			for bx = cx - r, cx + r do
				local dx, dy, dz = bx + 0.5 - x, by + 0.5 - y, bz + 0.5 - z
				local d = math.sqrt(dx * dx + dy * dy + dz * dz)
				if d > power * (0.7 + rng:nextFloat() * 0.6) then
					continue
				end
				local st = World.getState(gs.world, bx, by, bz)
				local id = st // 16
				local hardness = BlockRegistry.hardness(id)
				if id == 0 or hardness < 0 or hardness >= 50 or BlockRegistry.isLiquid(id) then
					continue
				end
				World.setState(gs.world, bx, by, bz, 0)
				if rng:nextFloat() < 1 / power then
					for _, drop in Mining.drops(st, ItemStack.new(278, 1), rng) do
						ItemEntities.spawn(gs.items, bx + 0.5, by + 0.5, bz + 0.5, drop)
					end
				end
			end
		end
	end
	for _, p in gs.players do
		local dx, dy, dz = p.x - x, p.y + 0.9 - y, p.z - z
		local dist = math.sqrt(dx * dx + dy * dy + dz * dz) / (power * 2)
		if dist <= 1 then
			local impact = 1 - dist
			local dmg = math.floor((impact * impact + impact) / 2 * 7 * power * 2 + 1)
			GameServer.damage(gs, p, dmg, "explosion")
		end
		send(gs, p.id, S2C.EXPLOSION, x, y, z, power)
	end
	count(gs, "explosions")
end

function GameServer._attack(gs: GameServer, p: Player, mobId: number)
	local mob = gs.mobs.list[mobId]
	if mob == nil then
		p.rejected += 1
		return
	end
	local ex, ey, ez = p.x, p.y + 1.62, p.z
	local dx, dy, dz = mob.x - ex, mob.y + mob.kind.height / 2 - ey, mob.z - ez
	local reach = 3 + mob.kind.width / 2 + Config.REACH_TOLERANCE
	if dx * dx + dy * dy + dz * dz > reach * reach then
		p.rejected += 1
		count(gs, "attackOutOfReach")
		return
	end
	local held = Inventory.held(p.inventory)
	local def = if held then ItemRegistry.get(held.id) else nil
	local dmg = if def and def.damage then def.damage else 1
	local _, landed = Mobs.hurt(gs.mobs, mob, dmg, p.x, p.z, GameServer._mobContext(gs), p.id)
	if landed and p.gamemode == "survival" then
		Survival.exhaust(p.vitals, Survival.EXHAUSTION.attack)
		if held and def and def.durability then
			local wear = if def.tool == "sword" then 1 else 2
			local nd = held.damage + wear
			p.inventory.slots[p.inventory.selected] = if nd >= def.durability then nil else ItemStack.new(held.id, 1, held.meta, nd)
			p.inventory.version += 1
		end
	end
end

local function replicateMobs(gs: GameServer, p: Player, ev: Mobs.Events)
	local spawned, moved, removed, hurt = {}, {}, {}, {}
	local r = (gs.viewRadius + 0.5) * 16
	local r2 = r * r
	for id, mob in gs.mobs.list do
		local dx, dz = mob.x - p.x, mob.z - p.z
		local visible = dx * dx + dz * dz <= r2 and p.sent[Coords.chunkKey(math.floor(mob.x) // 16, math.floor(mob.z) // 16)] == true
		if visible and not p.knownMobs[id] then
			p.knownMobs[id] = true
			table.insert(spawned, { id, mob.kind.id, mob.x, mob.y, mob.z, mob.yaw, mob.health })
		elseif not visible and p.knownMobs[id] then
			p.knownMobs[id] = nil
			table.insert(removed, id)
		end
	end
	for _, mob in ev.moved do
		if p.knownMobs[mob.id] and gs.mobs.list[mob.id] then
			table.insert(moved, { mob.id, mob.x, mob.y, mob.z, mob.yaw })
		end
	end
	for _, id in ev.removed do
		if p.knownMobs[id] then
			p.knownMobs[id] = nil
			table.insert(removed, id)
		end
	end
	for _, id in ev.hurt do
		if p.knownMobs[id] then
			table.insert(hurt, id)
		end
	end
	if #spawned + #moved + #removed + #hurt > 0 then
		send(gs, p.id, S2C.MOBS, { spawned = spawned, moved = moved, removed = removed, hurt = hurt })
	end
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
	local byteCap = gs.sendBytesPerTick
	local bytes = 0
	for i = 1, math.min(#cand, gs.sendBudget) do
		if i > 1 and bytes >= byteCap then
			break
		end
		local k = cand[i]
		p.sent[k] = true
		p.sentCount += 1
		local payload = ChunkCodec.encode(gs.world.chunks[k])
		bytes += buffer.len(payload)
		send(gs, p.id, S2C.CHUNK, payload)
		count(gs, "chunksSent")
	end
	gs.stats.bytesSent = (gs.stats.bytesSent or 0) + bytes
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
	GameServer._tickSleep(gs)
	-- survival, portal timers
	for _, p in gs.players do
		GameServer._tickSurvival(gs, p)
		local inPortal = World.getId(gs.world, math.floor(p.x), math.floor(p.y + 0.1), math.floor(p.z)) == Portals.PORTAL
			or World.getId(gs.world, math.floor(p.x), math.floor(p.y + 1.2), math.floor(p.z)) == Portals.PORTAL
		if p.portalCooldown > 0 then
			p.portalCooldown -= 1
			if inPortal then
				p.portalCooldown = math.max(p.portalCooldown, 20) -- stay out until stepping off
			end
			p.portalTicks = 0
		elseif inPortal and not p.vitals.dead then
			p.portalTicks += 1
		else
			p.portalTicks = 0
		end
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
	-- random ticks near players
	if next(gs.players) then
		local near: { [number]: any } = {}
		local r = gs.randomTickRadius
		for _, p in gs.players do
			local pcx, pcz = math.floor(p.x) // 16, math.floor(p.z) // 16
			for dz = -r, r do
				for dx = -r, r do
					local c = World.getChunk(gs.world, pcx + dx, pcz + dz)
					if c then
						near[Coords.chunkKey(c.cx, c.cz)] = c
					end
				end
			end
		end
		BlockUpdates.tickChunks(gs.updates, near)
	end
	-- pressure plates under players and mobs, then redstone
	local pressed: { [number]: { number } } = {}
	local function plateAt(x: number, y: number, z: number)
		local bx, by, bz = math.floor(x), math.floor(y + 0.05), math.floor(z)
		local id = World.getId(gs.world, bx, by, bz)
		if id == 70 or id == 72 then
			pressed[Fluids.key(bx, by, bz)] = { bx, by, bz }
		end
	end
	for _, p in gs.players do
		if not p.vitals.dead then
			plateAt(p.x, p.y, p.z)
		end
	end
	for _, mob in gs.mobs.list do
		if not mob.kind.projectile then
			plateAt(mob.x, mob.y, mob.z)
		end
	end
	for k, pos in pressed do
		if gs.plates[k] == nil then
			Redstone.setPlate(gs.redstone, pos[1], pos[2], pos[3], true)
		end
	end
	for k, pos in gs.plates do
		if pressed[k] == nil then
			Redstone.setPlate(gs.redstone, pos[1], pos[2], pos[3], false)
		end
	end
	gs.plates = pressed
	Redstone.step(gs.redstone)
	-- fluids, furnaces
	Fluids.step(gs.fluids)
	GameServer._tickFurnaces(gs)
	GameServer._tickSpawners(gs)
	-- mobs
	local mctx = GameServer._mobContext(gs)
	Mobs.tick(gs.mobs, mctx)
	if gs.mobsEnabled and gs.tickCount % 10 == 0 then
		Mobs.spawnCycle(gs.mobs, mctx, 12)
	end
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
	local mev = Mobs.takeEvents(gs.mobs)
	for _, p in gs.players do
		if not p.joined then
			continue
		end
		replicateChunks(gs, p)
		replicateMobs(gs, p, mev)
		containerTick(gs, p)
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
