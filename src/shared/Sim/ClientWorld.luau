--!strict
-- Client-side replica: applies server messages to a local World, tracks
-- which sections need re-meshing, mirrors inventory and item entities, and
-- handles optimistic block-break prediction with server rollback.
-- Engine-independent; the Roblox client renders from `remesh` and `items`.

local World = require("../Voxel/World")
local Chunk = require("../Voxel/Chunk")
local ChunkCodec = require("../Persistence/ChunkCodec")
local Protocol = require("../Net/Protocol")
local RemeshQueue = require("../Streaming/RemeshQueue")
local Mining = require("../Items/Mining")
local ItemStack = require("../Items/ItemStack")
local BlockRegistry = require("../Blocks/BlockRegistry")
local VoxelRaycast = require("../Physics/VoxelRaycast")
local ItemRegistry = require("../Items/ItemRegistry")
local MobTypes = require("./MobTypes")

local S2C, C2S = Protocol.S2C, Protocol.C2S

export type MobView = { id: number, type: number, x: number, y: number, z: number, yaw: number, health: number, hurtAt: number }

export type ItemView = { id: number, x: number, y: number, z: number, item: number, meta: number, count: number }

export type ClientWorld = {
	world: World.World,
	remesh: RemeshQueue.RemeshQueue,
	welcome: { [string]: any }?,
	inventory: { slots: { [number]: ItemStack.ItemStack }, selected: number, cursor: ItemStack.ItemStack? },
	items: { [number]: ItemView },
	itemsChanged: { [number]: boolean },
	mobs: { [number]: MobView },
	mobsChanged: { [number]: boolean },
	explosions: { { number } },
	container: { [string]: any }?, -- open container snapshot { x, y, z, state }
	containerChanged: boolean,
	clock: number,
	worldTime: number,
	chat: { { string } },
	gamemode: string,
	vitals: { health: number, food: number, saturation: number, dead: boolean },
	deathCause: string?,
	respawnAt: { number }?, -- set when the server respawned us (adapter moves the camera/character)
	using: { elapsed: number }?,
	-- block break prediction
	breaking: { x: number, y: number, z: number, elapsed: number, need: number }?,
	predicted: { [string]: number }, -- "x,y,z" -> state before prediction
	outgoing: { { any } }, -- { kind, ...args } to send to the server
	stats: { [string]: number },
}

local ClientWorld = {}

function ClientWorld.new(worldSize: number?): ClientWorld
	return {
		world = World.new(worldSize or 5120),
		remesh = RemeshQueue.new(),
		welcome = nil,
		inventory = { slots = {}, selected = 1, cursor = nil },
		items = {},
		itemsChanged = {},
		mobs = {},
		mobsChanged = {},
		explosions = {},
		container = nil,
		containerChanged = false,
		clock = 0,
		worldTime = 0,
		chat = {},
		gamemode = "survival",
		vitals = { health = 20, food = 20, saturation = 5, dead = false },
		deathCause = nil,
		respawnAt = nil,
		using = nil,
		breaking = nil,
		predicted = {},
		outgoing = {},
		stats = { chunks = 0, badMessages = 0 },
	}
end

local function out(cw: ClientWorld, ...: any)
	table.insert(cw.outgoing, { ... })
end

local function setBlock(cw: ClientWorld, x: number, y: number, z: number, state: number)
	if World.setState(cw.world, x, y, z, state) then
		RemeshQueue.markBlock(cw.remesh, x, y, z)
	end
end

-- Applies one server message. Malformed payloads are counted and ignored.
function ClientWorld.apply(cw: ClientWorld, kind: number, args: { any })
	local ok, err = pcall(function()
		if kind == S2C.WELCOME then
			local w = args[1]
			cw.welcome = w
			cw.gamemode = w.gamemode or "survival"
			if type(w.size) == "number" and w.size ~= (cw.world.maxX - cw.world.minX + 1) then
				cw.world = World.new(w.size)
			end
		elseif kind == S2C.CHUNK then
			local chunk = ChunkCodec.decode(args[1])
			World.putChunk(cw.world, chunk)
			-- own sections, plus loaded neighbours whose border faces may change
			-- (never unloaded ones: those would stay dirty forever)
			RemeshQueue.markChunk(cw.remesh, chunk.cx, chunk.cz, false, Chunk.highestSection(chunk))
			for _, d in { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } } do
				local n = World.getChunk(cw.world, chunk.cx + d[1], chunk.cz + d[2])
				if n then
					RemeshQueue.markChunk(cw.remesh, n.cx, n.cz, false, Chunk.highestSection(n))
				end
			end
			cw.stats.chunks += 1
		elseif kind == S2C.UNLOAD then
			local cx, cz = args[1], args[2]
			World.removeChunk(cw.world, cx, cz)
			RemeshQueue.dropChunk(cw.remesh, cx, cz)
			-- neighbours' border faces toward the unloaded chunk now face "missing"
			for _, d in { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } } do
				local n = World.getChunk(cw.world, cx + d[1], cz + d[2])
				if n then
					RemeshQueue.markChunk(cw.remesh, n.cx, n.cz, false, Chunk.highestSection(n))
				end
			end
		elseif kind == S2C.BLOCKS then
			local ch = Protocol.decodeBlockChanges(args[1])
			for i = 1, #ch, 4 do
				local x, y, z, st = ch[i], ch[i + 1], ch[i + 2], ch[i + 3]
				cw.predicted[x .. "," .. y .. "," .. z] = nil
				setBlock(cw, x, y, z, st)
			end
		elseif kind == S2C.BREAK_REJECTED then
			local x, y, z, st = args[1], args[2], args[3], args[4]
			local key = x .. "," .. y .. "," .. z
			cw.predicted[key] = nil
			setBlock(cw, x, y, z, st)
			cw.stats.rollbacks = (cw.stats.rollbacks or 0) + 1
		elseif kind == S2C.INVENTORY then
			local snap = args[1]
			local slots = {}
			for k, s in snap.slots do
				slots[tonumber(k) :: number] = ItemStack.new(s[1], s[3], s[2], s[4])
			end
			cw.inventory.slots = slots
			cw.inventory.selected = snap.selected
			local c = snap.cursor
			cw.inventory.cursor = if c then ItemStack.new(c[1], c[3], c[2], c[4]) else nil
		elseif kind == S2C.ITEMS then
			local ev = args[1]
			for _, s in ev.spawned do
				cw.items[s[1]] = { id = s[1], x = s[2], y = s[3], z = s[4], item = s[5], meta = s[6], count = s[7] }
				cw.itemsChanged[s[1]] = true
			end
			for _, m in ev.moved do
				local e = cw.items[m[1]]
				if e then
					e.x, e.y, e.z = m[2], m[3], m[4]
					cw.itemsChanged[m[1]] = true
				end
			end
			for _, id in ev.removed do
				cw.items[id] = nil
				cw.itemsChanged[id] = true
			end
		elseif kind == S2C.PLAYER then
			local v = args[1]
			cw.vitals = { health = v.health, food = v.food, saturation = v.saturation, dead = v.dead }
			cw.gamemode = v.gamemode or cw.gamemode
		elseif kind == S2C.DIED then
			cw.vitals.dead = true
			cw.deathCause = args[1]
			cw.breaking = nil
			cw.using = nil
		elseif kind == S2C.RESPAWNED then
			cw.vitals.dead = false
			cw.deathCause = nil
			cw.respawnAt = { args[1], args[2], args[3] }
		elseif kind == S2C.MOBS then
			local ev = args[1]
			for _, s in ev.spawned do
				cw.mobs[s[1]] = { id = s[1], type = s[2], x = s[3], y = s[4], z = s[5], yaw = s[6], health = s[7], hurtAt = -1 }
				cw.mobsChanged[s[1]] = true
			end
			for _, m in ev.moved do
				local e = cw.mobs[m[1]]
				if e then
					e.x, e.y, e.z, e.yaw = m[2], m[3], m[4], m[5]
					cw.mobsChanged[m[1]] = true
				end
			end
			for _, id in ev.hurt do
				local e = cw.mobs[id]
				if e then
					e.hurtAt = cw.clock
					cw.mobsChanged[id] = true
				end
			end
			for _, id in ev.removed do
				cw.mobs[id] = nil
				cw.mobsChanged[id] = true
			end
		elseif kind == S2C.CONTAINER then
			cw.container = if args[1] == false then nil else args[1]
			cw.containerChanged = true
		elseif kind == S2C.EXPLOSION then
			table.insert(cw.explosions, { args[1], args[2], args[3], args[4] })
		elseif kind == S2C.TIME then
			cw.worldTime = args[1]
		elseif kind == S2C.CHAT then
			table.insert(cw.chat, { args[1], args[2] })
			if #cw.chat > 50 then
				table.remove(cw.chat, 1)
			end
		end
	end)
	if not ok then
		cw.stats.badMessages += 1
		local _ = err
	end
end

function ClientWorld.held(cw: ClientWorld): ItemStack.ItemStack?
	return cw.inventory.slots[cw.inventory.selected]
end

-- Raycast against the replica. Returns the hit (solid or targetable block).
function ClientWorld.target(cw: ClientWorld, ox: number, oy: number, oz: number, dx: number, dy: number, dz: number, reach: number): VoxelRaycast.Hit?
	local world = cw.world
	return VoxelRaycast.cast(function(x, y, z)
		return World.getState(world, x, y, z)
	end, ox, oy, oz, dx, dy, dz, reach, function(st)
		local id = st // 16
		return id ~= 0 and not BlockRegistry.isLiquid(id)
	end)
end

-- Ray vs mob boxes. Returns the nearest mob hit within `reach` and its distance.
function ClientWorld.targetMob(cw: ClientWorld, ox: number, oy: number, oz: number, dx: number, dy: number, dz: number, reach: number): (MobView?, number)
	local len = math.sqrt(dx * dx + dy * dy + dz * dz)
	if len == 0 then
		return nil, math.huge
	end
	dx, dy, dz = dx / len, dy / len, dz / len
	local best, bestT = nil, math.huge
	for _, m in cw.mobs do
		local kind = MobTypes.get(m.type)
		local hw = if kind then kind.width / 2 else 0.3
		local h = if kind then kind.height else 1.8
		-- slab test against the AABB
		local tmin, tmax = 0, reach
		local ok = true
		for axis = 1, 3 do
			local o = if axis == 1 then ox elseif axis == 2 then oy else oz
			local d = if axis == 1 then dx elseif axis == 2 then dy else dz
			local lo = if axis == 1 then m.x - hw elseif axis == 2 then m.y else m.z - hw
			local hi = if axis == 1 then m.x + hw elseif axis == 2 then m.y + h else m.z + hw
			if math.abs(d) < 1e-9 then
				if o < lo or o > hi then
					ok = false
					break
				end
			else
				local t1, t2 = (lo - o) / d, (hi - o) / d
				if t1 > t2 then
					t1, t2 = t2, t1
				end
				tmin = math.max(tmin, t1)
				tmax = math.min(tmax, t2)
				if tmin > tmax then
					ok = false
					break
				end
			end
		end
		if ok and tmin < bestT then
			best, bestT = m, tmin
		end
	end
	return best, bestT
end

function ClientWorld.containerClick(cw: ClientWorld, slot: number, button: string)
	if cw.container then
		out(cw, C2S.CONTAINER_CLICK, slot, button)
	end
end

function ClientWorld.inventoryClick(cw: ClientWorld, slot: number, button: string)
	out(cw, C2S.INV_CLICK, slot, button)
end

function ClientWorld.closeContainer(cw: ClientWorld)
	out(cw, C2S.CLOSE_CONTAINER)
end

function ClientWorld.attack(cw: ClientWorld, mobId: number)
	out(cw, C2S.ATTACK, mobId)
end

-- Called every frame while the break button is held on block (x,y,z).
-- Sends START/FINISH at the right moments and predicts the removal.
function ClientWorld.updateBreaking(cw: ClientWorld, x: number?, y: number?, z: number?, dt: number, onGround: boolean, inWater: boolean)
	local b = cw.breaking
	if x == nil or y == nil or z == nil then
		if b then
			out(cw, C2S.CANCEL_BREAK)
			cw.breaking = nil
		end
		return
	end
	if b == nil or b.x ~= x or b.y ~= y or b.z ~= z then
		if b then
			out(cw, C2S.CANCEL_BREAK)
		end
		local id = World.getId(cw.world, x, y, z)
		if id == 0 then
			cw.breaking = nil
			return
		end
		local need = if cw.gamemode == "creative" then 0 else Mining.breakTicks(id, ClientWorld.held(cw), onGround, inWater)
		if need == math.huge then
			cw.breaking = nil
			return
		end
		out(cw, C2S.START_BREAK, x, y, z)
		if need == 0 then
			ClientWorld.predictBreak(cw, x, y, z)
			cw.breaking = nil
			return
		end
		cw.breaking = { x = x, y = y, z = z, elapsed = 0, need = need / 20 }
		return
	end
	b.elapsed += dt
	if b.elapsed >= b.need then
		out(cw, C2S.FINISH_BREAK, x, y, z)
		ClientWorld.predictBreak(cw, x, y, z)
		cw.breaking = nil
	end
end

function ClientWorld.breakProgress(cw: ClientWorld): number
	local b = cw.breaking
	if b == nil or b.need <= 0 then
		return 0
	end
	return math.clamp(b.elapsed / b.need, 0, 1)
end

function ClientWorld.predictBreak(cw: ClientWorld, x: number, y: number, z: number)
	local key = x .. "," .. y .. "," .. z
	if cw.predicted[key] == nil then
		cw.predicted[key] = World.getState(cw.world, x, y, z)
	end
	setBlock(cw, x, y, z, 0)
end

ClientWorld.EAT_SECONDS = 1.6

-- Called every frame with whether "use" is held and nothing is targeted.
-- Eating: hold for 1.6 s (32 ticks) with food in hand.
function ClientWorld.updateUsing(cw: ClientWorld, held: boolean, dt: number)
	local item = ClientWorld.held(cw)
	local def = if item then ItemRegistry.get(item.id) else nil
	local canEat = held and def ~= nil and def.food ~= nil and cw.vitals.food < 20 and not cw.vitals.dead
	local u = cw.using
	if not canEat then
		cw.using = nil
		return
	end
	if u == nil then
		cw.using = { elapsed = 0 }
		out(cw, C2S.USE_START)
		return
	end
	u.elapsed += dt
	if u.elapsed >= ClientWorld.EAT_SECONDS then
		out(cw, C2S.USE_FINISH)
		cw.using = nil
	end
end

function ClientWorld.requestRespawn(cw: ClientWorld)
	if cw.vitals.dead then
		out(cw, C2S.RESPAWN)
	end
end

-- Takes queued outgoing messages.
function ClientWorld.takeOutgoing(cw: ClientWorld): { { any } }
	local o = cw.outgoing
	cw.outgoing = {}
	return o
end

return ClientWorld
