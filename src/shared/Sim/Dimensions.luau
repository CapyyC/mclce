--!strict
-- Runs the Overworld and the Nether as two GameServer instances and moves
-- players between them through portals. The Roblox adapter talks only to
-- this module. Both worlds persist under separate world ids.
--
-- Nether coordinate scale is configurable (Config.NETHER_SCALE). Legacy
-- Console used a smaller Nether than Java's 1:8 for small worlds; the exact
-- PS4 1.95 value is UNKNOWN here (see COMPATIBILITY.md).

local Config = require("../Config")
local GameServer = require("./GameServer")
local World = require("../Voxel/World")
local ChunkScheduler = require("../Streaming/ChunkScheduler")
local Portals = require("./Portals")
local SaveManager = require("../Persistence/SaveManager")
local Protocol = require("../Net/Protocol")

export type Dimensions = {
	worlds: { [string]: GameServer.GameServer },
	where: { [number]: string }, -- player id -> dimension
	names: { [number]: string },
	scale: number,
	stats: { transfers: number },
}

local Dimensions = {}

Dimensions.PORTAL_TICKS = 80 -- 4 s standing in a portal (survival)

function Dimensions.new(opts: GameServer.Options, scale: number?): Dimensions
	local s = scale or Config.NETHER_SCALE
	local size = opts.worldSize or Config.WORLD_SIZE
	local netherSize = math.max(128, math.ceil(size / s / 16) * 16)
	local overworld = GameServer.new(opts)
	local nopts = table.clone(opts)
	nopts.dimension = "nether"
	nopts.worldSize = netherSize
	nopts.worldId = (opts.worldId or "world") .. "_nether"
	local nether = GameServer.new(nopts)
	return { worlds = { overworld = overworld, nether = nether }, where = {}, names = {}, scale = s, stats = { transfers = 0 } }
end

function Dimensions.open(d: Dimensions): (boolean, string?)
	local ok, err = GameServer.open(d.worlds.overworld)
	if not ok then
		return false, err
	end
	-- the Nether shares the overworld's seed
	d.worlds.nether.seedText = d.worlds.overworld.seedText
	ok, err = GameServer.open(d.worlds.nether)
	return ok, err
end

function Dimensions.serverOf(d: Dimensions, pid: number): GameServer.GameServer?
	local dim = d.where[pid]
	return if dim then d.worlds[dim] else nil
end

function Dimensions.addPlayer(d: Dimensions, pid: number, name: string, record: { [string]: any }?, waitForJoin: boolean?)
	local dim = if record and record.dimension == "nether" then "nether" else "overworld"
	d.where[pid] = dim
	d.names[pid] = name
	GameServer.addPlayer(d.worlds[dim], pid, name, record, waitForJoin)
end

function Dimensions.removePlayer(d: Dimensions, pid: number): { [string]: any }?
	local gs = Dimensions.serverOf(d, pid)
	if gs == nil then
		return nil
	end
	local rec = GameServer.removePlayer(gs, pid)
	if rec then
		rec.dimension = d.where[pid]
	end
	d.where[pid] = nil
	d.names[pid] = nil
	return rec
end

local function ensureLoaded(gs: GameServer.GameServer, cx: number, cz: number)
	for dz = -1, 1 do
		for dx = -1, 1 do
			if World.chunkInBorder(gs.world, cx + dx, cz + dz) and not World.getChunk(gs.world, cx + dx, cz + dz) then
				GameServer._loadChunk(gs, cx + dx, cz + dz)
				if World.getChunk(gs.world, cx + dx, cz + dz) then
					ChunkScheduler.markLoaded(gs.scheduler, cx + dx, cz + dz)
				end
			end
		end
	end
end

-- Moves a player through a portal into the other dimension.
function Dimensions.transfer(d: Dimensions, pid: number)
	local from = d.where[pid]
	if from == nil then
		return
	end
	local src = d.worlds[from]
	local p = src.players[pid]
	if p == nil then
		return
	end
	local to = if from == "overworld" then "nether" else "overworld"
	local dst = d.worlds[to]
	local f = if to == "nether" then 1 / d.scale else d.scale
	local tx = math.clamp(math.floor(p.x * f), dst.world.minX + 4, dst.world.maxX - 4)
	local tz = math.clamp(math.floor(p.z * f), dst.world.minZ + 4, dst.world.maxZ - 4)
	local rec = GameServer.removePlayer(src, pid)
	if rec == nil then
		return
	end
	ensureLoaded(dst, tx // 16, tz // 16)
	local maxY = if to == "nether" then 120 else 250
	local px, py, pz = Portals.find(dst.world, tx, tz, 16, maxY)
	if px == nil then
		px, py, pz = Portals.create(dst.world, tx, tz, if to == "nether" then 33 else 64, maxY)
	end
	assert(px and py and pz)
	rec.pos = { px + 0.5, py, pz + 0.5 }
	rec.dimension = to
	d.where[pid] = to
	GameServer.addPlayer(dst, pid, d.names[pid], rec, false)
	local np = dst.players[pid]
	np.portalCooldown = 100
	d.stats.transfers += 1
end

function Dimensions.handle(d: Dimensions, pid: number, kind: any, args: { any })
	local gs = Dimensions.serverOf(d, pid)
	if gs == nil then
		return
	end
	-- dying in the Nether respawns you in the Overworld (classic)
	if kind == Protocol.C2S.RESPAWN and d.where[pid] == "nether" then
		local p = gs.players[pid]
		if p and p.vitals.dead then
			local rec = GameServer.removePlayer(gs, pid)
			if rec then
				rec.pos = nil
				rec.dimension = "overworld"
				d.where[pid] = "overworld"
				GameServer.addPlayer(d.worlds.overworld, pid, d.names[pid], rec, false)
				d.stats.transfers += 1
			end
			return
		end
	end
	GameServer.handle(gs, pid, kind, args)
end

function Dimensions.setPlayerPosition(d: Dimensions, pid: number, x: number, y: number, z: number)
	local gs = Dimensions.serverOf(d, pid)
	if gs then
		GameServer.setPlayerPosition(gs, pid, x, y, z)
	end
end

function Dimensions.tick(d: Dimensions)
	for _, gs in d.worlds do
		GameServer.tick(gs)
	end
	-- portal transfers after the tick (timers updated inside GameServer.tick)
	local moving: { number } = {}
	for pid: number, dim in d.where do
		local p = d.worlds[dim].players[pid]
		if p and p.portalTicks >= (if p.gamemode == "creative" then 1 else Dimensions.PORTAL_TICKS) then
			table.insert(moving, pid)
		end
	end
	table.sort(moving)
	for _, pid in moving do
		Dimensions.transfer(d, pid)
	end
end

function Dimensions.takeOutbox(d: Dimensions, pid: number): { GameServer.Outgoing }
	local out = {}
	-- a transfer leaves the old world's last messages unread: drain both
	for _, gs in d.worlds do
		for _, m in GameServer.takeOutbox(gs, pid) do
			table.insert(out, m)
		end
	end
	return out
end

function Dimensions.autosave(d: Dimensions, budget: number): number
	local n = 0
	for _, gs in d.worlds do
		n += GameServer.autosave(gs, budget)
	end
	return n
end

function Dimensions.dirtyCount(d: Dimensions): number
	local n = 0
	for _, gs in d.worlds do
		if gs.save then
			n += SaveManager.dirtyCount(gs.save)
		end
	end
	return n
end

function Dimensions.flush(d: Dimensions, budget: number)
	for _, gs in d.worlds do
		if gs.save then
			SaveManager.flush(gs.save, budget)
		end
	end
end

local _ = Protocol
return Dimensions
