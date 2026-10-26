--!strict
-- Mob simulation: physics (gravity 0.08/tick, drag 0.98, ground friction),
-- simple AI (passive wander/flee, hostile chase/attack, creeper fuse,
-- daylight burning), damage/knockback/invulnerability, drops, natural
-- spawning and despawning. Engine-independent; GameServer supplies context.

local Collision = require("../Physics/Collision")
local MobTypes = require("./MobTypes")
local ItemStack = require("../Items/ItemStack")
local JavaRandom = require("../Util/JavaRandom")
local BlockRegistry = require("../Blocks/BlockRegistry")
local VoxelRaycast = require("../Physics/VoxelRaycast")

export type Mob = {
	id: number,
	kind: MobTypes.MobType,
	x: number,
	y: number,
	z: number,
	vx: number,
	vy: number,
	vz: number,
	yaw: number,
	health: number,
	onGround: boolean,
	hurtTicks: number, -- invulnerability countdown
	attackCooldown: number,
	fuse: number, -- creeper ignition ticks (-1 = idle)
	burnTicks: number,
	wanderX: number?,
	wanderZ: number?,
	wanderTicks: number,
	panicTicks: number,
	targetId: number?,
	age: number,
	persistent: boolean,
	wantJump: boolean,
	angryAt: number?, -- neutral mobs: player id that hurt them
	ownerPlayer: number?, -- arrows shot by a player
}

export type PlayerView = { id: number, x: number, y: number, z: number, attackable: boolean }

export type Context = {
	players: { PlayerView },
	getState: (number, number, number) -> number,
	isLoaded: (number, number) -> boolean,
	skyLight: (number, number, number) -> number, -- raw sky light 0..15
	light: (number, number, number) -> number, -- effective light incl. time of day
	isDay: boolean,
	damagePlayer: (id: number, amount: number, cause: string, fromX: number, fromZ: number) -> (),
	explode: (x: number, y: number, z: number, power: number) -> (),
	dropItem: (x: number, y: number, z: number, stack: ItemStack.ItemStack) -> (),
	spawnList: { string }?, -- hostile spawn list for this dimension (default overworld)
}

export type Events = { spawned: { Mob }, moved: { Mob }, removed: { number }, hurt: { number } }

export type Mobs = {
	list: { [number]: Mob },
	count: number,
	hostileCount: number,
	passiveCount: number,
	nextId: number,
	rng: JavaRandom.JavaRandom,
	events: Events,
}

local Mobs = {}

Mobs.GRAVITY = 0.08
Mobs.AIR_DRAG = 0.98
Mobs.GROUND_FRICTION = 0.546 -- 0.91 * 0.6
Mobs.JUMP_VELOCITY = 0.42
Mobs.ATTACK_REACH = 2.0
Mobs.CHASE_RANGE = 16
Mobs.CREEPER_FUSE = 30
Mobs.CREEPER_RANGE = 3
Mobs.DESPAWN_FAR = 128

function Mobs.new(seed: number): Mobs
	return {
		list = {},
		count = 0,
		hostileCount = 0,
		passiveCount = 0,
		nextId = 1,
		rng = JavaRandom.new(seed),
		events = { spawned = {}, moved = {}, removed = {}, hurt = {} },
	}
end

function Mobs.spawn(m: Mobs, kind: MobTypes.MobType, x: number, y: number, z: number, persistent: boolean?): Mob
	local mob: Mob = {
		id = m.nextId,
		kind = kind,
		x = x,
		y = y,
		z = z,
		vx = 0,
		vy = 0,
		vz = 0,
		yaw = m.rng:nextFloat() * math.pi * 2,
		health = kind.health,
		onGround = false,
		hurtTicks = 0,
		attackCooldown = 0,
		fuse = -1,
		burnTicks = 0,
		wanderX = nil,
		wanderZ = nil,
		wanderTicks = 0,
		panicTicks = 0,
		targetId = nil,
		age = 0,
		persistent = persistent == true,
		wantJump = false,
	}
	m.nextId += 1
	m.list[mob.id] = mob
	m.count += 1
	if kind.projectile then
		-- not counted against mob caps
	elseif kind.hostile then
		m.hostileCount += 1
	else
		m.passiveCount += 1
	end
	table.insert(m.events.spawned, mob)
	return mob
end

function Mobs.remove(m: Mobs, id: number)
	local mob = m.list[id]
	if mob then
		m.list[id] = nil
		m.count -= 1
		if mob.kind.projectile then
			-- not counted
		elseif mob.kind.hostile then
			m.hostileCount -= 1
		else
			m.passiveCount -= 1
		end
		table.insert(m.events.removed, id)
	end
end

local function nearestPlayer(ctx: Context, x: number, y: number, z: number): (PlayerView?, number)
	local best, bestD = nil, math.huge
	for _, p in ctx.players do
		local dx, dy, dz = p.x - x, p.y - y, p.z - z
		local d = dx * dx + dy * dy + dz * dz
		if d < bestD then
			best, bestD = p, d
		end
	end
	return best, math.sqrt(bestD)
end

local function die(m: Mobs, mob: Mob, ctx: Context)
	for _, d in mob.kind.drops do
		local n = d.min + m.rng:nextInt(d.max - d.min + 1)
		if n > 0 then
			ctx.dropItem(mob.x, mob.y + 0.5, mob.z, ItemStack.new(d.id, n, d.meta))
		end
	end
	Mobs.remove(m, mob.id)
end

-- Applies damage with knockback away from (fromX, fromZ). `attackerId`
-- angers neutral mobs at that player. Returns (died, landed);
-- hits during the invulnerability window don't land.
function Mobs.hurt(m: Mobs, mob: Mob, amount: number, fromX: number, fromZ: number, ctx: Context, attackerId: number?): (boolean, boolean)
	if mob.hurtTicks > 0 then
		return false, false
	end
	if attackerId and mob.kind.neutral then
		-- the whole nearby group joins in (classic pigman behaviour)
		for _, other in m.list do
			if other.kind == mob.kind and math.abs(other.x - mob.x) < 16 and math.abs(other.z - mob.z) < 16 then
				other.angryAt = attackerId
			end
		end
	end
	mob.health -= amount
	mob.hurtTicks = 10
	local dx, dz = mob.x - fromX, mob.z - fromZ
	local d = math.sqrt(dx * dx + dz * dz)
	if d > 1e-4 then
		mob.vx += dx / d * 0.4
		mob.vz += dz / d * 0.4
	end
	mob.vy = math.max(mob.vy, 0.36)
	mob.panicTicks = if mob.kind.hostile then 0 else 60
	table.insert(m.events.hurt, mob.id)
	if mob.health <= 0 then
		die(m, mob, ctx)
		return true, true
	end
	return false, true
end

local function moveToward(mob: Mob, tx: number, tz: number, speed: number)
	local dx, dz = tx - mob.x, tz - mob.z
	local d = math.sqrt(dx * dx + dz * dz)
	if d < 0.2 then
		return
	end
	mob.yaw = math.atan2(dz, dx)
	-- accelerate toward the desired velocity (ground control)
	local f = if mob.onGround then 0.25 else 0.05
	mob.vx += (dx / d * speed - mob.vx) * f * 4
	mob.vz += (dz / d * speed - mob.vz) * f * 4
end

local function think(m: Mobs, mob: Mob, ctx: Context)
	local kind = mob.kind
	local rng = m.rng
	if kind.hostile then
		local p, dist = nearestPlayer(ctx, mob.x, mob.y, mob.z)
		local canChase = p ~= nil and p.attackable and dist <= Mobs.CHASE_RANGE
		if kind.neutral then
			canChase = canChase and p ~= nil and mob.angryAt == p.id
		end
		-- spiders are neutral in daylight
		if kind.name == "spider" and ctx.isDay and mob.hurtTicks == 0 then
			canChase = false
		end
		if canChase and p then
			mob.targetId = p.id
			if kind.name == "creeper" then
				if dist <= Mobs.CREEPER_RANGE then
					if mob.fuse < 0 then
						mob.fuse = 0
					end
				elseif dist > Mobs.CREEPER_RANGE + 4 then
					mob.fuse = -1 -- defuse when the player escapes
				end
				if mob.fuse < 0 then
					moveToward(mob, p.x, p.z, kind.speed)
				end
			elseif kind.ranged then
				-- keep some distance and shoot when there is a clear line of sight
				if dist > 8 then
					moveToward(mob, p.x, p.z, kind.speed)
				end
				if dist <= 15 and mob.attackCooldown <= 0 and Mobs.lineOfSight(ctx, mob.x, mob.y + 1.6, mob.z, p.x, p.y + 1.5, p.z) then
					Mobs.shootArrow(m, mob, p)
					mob.attackCooldown = 40 + rng:nextInt(20)
				end
			else
				moveToward(mob, p.x, p.z, kind.speed)
				if dist <= Mobs.ATTACK_REACH and math.abs(p.y - mob.y) < 1.5 and mob.attackCooldown <= 0 then
					ctx.damagePlayer(p.id, kind.attack, kind.name, mob.x, mob.z)
					mob.attackCooldown = 20
				end
			end
			return
		end
		mob.targetId = nil
		mob.fuse = -1
	end
	-- wander / panic
	if mob.panicTicks > 0 then
		mob.panicTicks -= 1
		if mob.wanderX == nil or rng:nextInt(10) == 0 then
			mob.wanderX = mob.x + rng:nextInt(11) - 5
			mob.wanderZ = mob.z + rng:nextInt(11) - 5
		end
		moveToward(mob, mob.wanderX :: number, mob.wanderZ :: number, kind.speed * 1.5)
		return
	end
	mob.wanderTicks -= 1
	if mob.wanderTicks <= 0 then
		mob.wanderTicks = 80 + rng:nextInt(120)
		if rng:nextInt(3) ~= 0 then
			mob.wanderX = mob.x + rng:nextInt(21) - 10
			mob.wanderZ = mob.z + rng:nextInt(21) - 10
		else
			mob.wanderX = nil
		end
	end
	if mob.wanderX then
		moveToward(mob, mob.wanderX :: number, mob.wanderZ :: number, kind.speed * 0.6)
	end
end

function Mobs.lineOfSight(ctx: Context, ax: number, ay: number, az: number, bx: number, by: number, bz: number): boolean
	local dx, dy, dz = bx - ax, by - ay, bz - az
	local dist = math.sqrt(dx * dx + dy * dy + dz * dz)
	local hit = VoxelRaycast.cast(ctx.getState, ax, ay, az, dx, dy, dz, dist, function(st)
		local id = st // 16
		return id ~= 0 and BlockRegistry.occludes(id)
	end)
	return hit == nil
end

Mobs.ARROW_SPEED = 1.6
Mobs.ARROW_GRAVITY = 0.05
Mobs.ARROW_DRAG = 0.99

function Mobs.shootArrow(m: Mobs, shooter: Mob, target: PlayerView)
	local arrow = Mobs.spawn(m, MobTypes.byName("arrow"), shooter.x, shooter.y + 1.5, shooter.z)
	local dx, dz = target.x - shooter.x, target.z - shooter.z
	local horiz = math.sqrt(dx * dx + dz * dz)
	local dy = (target.y + 0.6) - (shooter.y + 1.5) + horiz * 0.2 -- classic: aim at 1/3 height, lob by 0.2 per block
	local len = math.sqrt(dx * dx + dy * dy + dz * dz)
	if len < 1e-6 then
		len = 1
	end
	local spread = 0.0075 * 6 -- normal difficulty inaccuracy
	local rng = m.rng
	arrow.vx = (dx / len + (rng:nextFloat() - 0.5) * spread) * Mobs.ARROW_SPEED
	arrow.vy = (dy / len + (rng:nextFloat() - 0.5) * spread) * Mobs.ARROW_SPEED
	arrow.vz = (dz / len + (rng:nextFloat() - 0.5) * spread) * Mobs.ARROW_SPEED
	arrow.targetId = shooter.id -- owner
	arrow.yaw = math.atan2(dz, dx)
end

-- Arrow flight: sub-stepped so fast arrows don't tunnel through players or blocks.
local function tickArrow(m: Mobs, a: Mob, ctx: Context)
	if a.age > 1200 or a.fuse >= 0 then
		-- stuck arrows linger briefly then vanish
		if a.fuse >= 0 then
			a.fuse += 1
		end
		if a.age > 1200 or a.fuse > 20 then
			Mobs.remove(m, a.id)
		end
		return
	end
	local steps = 4
	for _ = 1, steps do
		local nx, ny, nz = a.x + a.vx / steps, a.y + a.vy / steps, a.z + a.vz / steps
		if a.ownerPlayer then
			for _, mob in m.list do
				local k = mob.kind
				if not k.projectile and nx > mob.x - k.width / 2 and nx < mob.x + k.width / 2 and nz > mob.z - k.width / 2 and nz < mob.z + k.width / 2 and ny > mob.y and ny < mob.y + k.height then
					local speed = math.sqrt(a.vx * a.vx + a.vy * a.vy + a.vz * a.vz)
					Mobs.hurt(m, mob, math.ceil(speed * 2), a.x, a.z, ctx, a.ownerPlayer)
					Mobs.remove(m, a.id)
					return
				end
			end
		end
		for _, p in ctx.players do
			if a.ownerPlayer == p.id and a.age < 5 then
				continue -- don't hit the shooter right after release
			end
			if nx > p.x - 0.3 and nx < p.x + 0.3 and nz > p.z - 0.3 and nz < p.z + 0.3 and ny > p.y and ny < p.y + 1.8 then
				local speed = math.sqrt(a.vx * a.vx + a.vy * a.vy + a.vz * a.vz)
				if p.attackable then
					ctx.damagePlayer(p.id, math.ceil(speed * 2), "arrow", a.x, a.z)
				end
				Mobs.remove(m, a.id)
				return
			end
		end
		local st = ctx.getState(math.floor(nx), math.floor(ny), math.floor(nz))
		if BlockRegistry.isSolid(st // 16) then
			a.vx, a.vy, a.vz = 0, 0, 0
			a.fuse = 0
			table.insert(m.events.moved, a)
			return
		end
		a.x, a.y, a.z = nx, ny, nz
	end
	a.vx *= Mobs.ARROW_DRAG
	a.vy = a.vy * Mobs.ARROW_DRAG - Mobs.ARROW_GRAVITY
	a.vz *= Mobs.ARROW_DRAG
	a.yaw = math.atan2(a.vz, a.vx)
	table.insert(m.events.moved, a)
	if a.y < -64 then
		Mobs.remove(m, a.id)
	end
end

local function physics(mob: Mob, ctx: Context)
	local kind = mob.kind
	-- classic order: move with the current velocity, then apply gravity/drag
	-- (gives the classic 1.25-block jump apex from 0.42 initial velocity)
	if mob.wantJump and mob.onGround then
		mob.vy = Mobs.JUMP_VELOCITY
	end
	mob.wantJump = false
	local box = Collision.box(mob.x, mob.y, mob.z, kind.width / 2, kind.height)
	local dx, dy, dz, hitX, hitY, hitZ = Collision.move(ctx.getState, box, mob.vx, mob.vy, mob.vz)
	mob.x += dx
	mob.y += dy
	mob.z += dz
	mob.onGround = hitY and mob.vy < 0
	if hitY then
		mob.vy = 0
	end
	-- step up one block by jumping (next tick) when walking into a wall
	if (hitX or hitZ) and mob.onGround then
		mob.wantJump = true
	end
	if hitX then
		mob.vx = 0
	end
	if hitZ then
		mob.vz = 0
	end
	-- in water: buoyancy
	local inWater = BlockRegistry.isLiquid(ctx.getState(math.floor(mob.x), math.floor(mob.y + 0.3), math.floor(mob.z)) // 16)
	if inWater then
		mob.vy = math.max(mob.vy, 0.04)
		mob.vx *= 0.8
		mob.vz *= 0.8
	end
	local friction = if mob.onGround then Mobs.GROUND_FRICTION else 0.91
	mob.vx *= friction
	mob.vz *= friction
	mob.vy = (mob.vy - Mobs.GRAVITY) * Mobs.AIR_DRAG
end

function Mobs.tick(m: Mobs, ctx: Context)
	for id, mob in m.list do
		if not ctx.isLoaded(mob.x, mob.z) then
			continue
		end
		mob.age += 1
		if mob.kind.projectile then
			tickArrow(m, mob, ctx)
			continue
		end
		if mob.hurtTicks > 0 then
			mob.hurtTicks -= 1
		end
		if mob.attackCooldown > 0 then
			mob.attackCooldown -= 1
		end
		-- despawn far hostiles
		if mob.kind.hostile and not mob.persistent then
			local _, dist = nearestPlayer(ctx, mob.x, mob.y, mob.z)
			if dist > Mobs.DESPAWN_FAR or (dist > 32 and mob.age > 600 and m.rng:nextInt(800) == 0) then
				Mobs.remove(m, id)
				continue
			end
		end
		think(m, mob, ctx)
		if m.list[id] == nil then
			continue
		end
		-- creeper fuse
		if mob.fuse >= 0 then
			mob.fuse += 1
			if mob.fuse >= Mobs.CREEPER_FUSE then
				Mobs.remove(m, id)
				ctx.explode(mob.x, mob.y + 0.85, mob.z, 3)
				continue
			end
		end
		-- daylight burning (undead under open sky)
		if mob.kind.burnsInDaylight and ctx.isDay then
			if ctx.skyLight(math.floor(mob.x), math.floor(mob.y + mob.kind.height), math.floor(mob.z)) >= 15 then
				mob.burnTicks += 1
				if mob.burnTicks % 20 == 0 then
					local p = mob.hurtTicks
					mob.hurtTicks = 0
					Mobs.hurt(m, mob, 1, mob.x, mob.z, ctx)
					if m.list[id] then
						mob.hurtTicks = math.max(p, mob.hurtTicks)
					end
				end
			end
		end
		if m.list[id] == nil then
			continue
		end
		local ox, oy, oz = mob.x, mob.y, mob.z
		physics(mob, ctx)
		if mob.y < -64 then
			Mobs.remove(m, id)
			continue
		end
		if math.abs(mob.x - ox) + math.abs(mob.y - oy) + math.abs(mob.z - oz) > 1e-3 then
			table.insert(m.events.moved, mob)
		end
	end
end

-- Attempts natural spawns around players. Returns number spawned.
-- Hostiles: light <= 7, solid ground, 2 free blocks, 24..64 blocks from players.
-- Passives: on grass in sky light >= 9 (approximation of classic rules).
function Mobs.spawnCycle(m: Mobs, ctx: Context, attempts: number): number
	local rng = m.rng
	local spawned = 0
	if #ctx.players == 0 then
		return 0
	end
	for _ = 1, attempts do
		local p = ctx.players[rng:nextInt(#ctx.players) + 1]
		local x = math.floor(p.x) + rng:nextInt(97) - 48
		local z = math.floor(p.z) + rng:nextInt(97) - 48
		if not ctx.isLoaded(x, z) then
			continue
		end
		local y = math.floor(p.y) + rng:nextInt(33) - 16
		if y < 1 or y > 250 then
			continue
		end
		local _, dist = nearestPlayer(ctx, x + 0.5, y, z + 0.5)
		if dist < 24 then
			continue
		end
		local below = ctx.getState(x, y - 1, z) // 16
		if not (BlockRegistry.isSolid(below) and BlockRegistry.occludes(below)) then
			continue
		end
		if ctx.getState(x, y, z) ~= 0 or ctx.getState(x, y + 1, z) ~= 0 then
			continue
		end
		local hostileTurn = rng:nextInt(4) ~= 0
		if hostileTurn and m.hostileCount < MobTypes.HOSTILE_CAP then
			if ctx.light(x, y, z) <= 7 then
				local kind
				if ctx.spawnList then
					kind = MobTypes.byName(ctx.spawnList[rng:nextInt(#ctx.spawnList) + 1])
				else
					local r = rng:nextInt(100)
					kind = if r < 35 then MobTypes.byName("zombie") elseif r < 60 then MobTypes.byName("skeleton") elseif r < 80 then MobTypes.byName("creeper") else MobTypes.byName("spider")
				end
				Mobs.spawn(m, kind, x + 0.5, y, z + 0.5)
				spawned += 1
			end
		elseif not hostileTurn and m.passiveCount < MobTypes.PASSIVE_CAP and ctx.isDay then
			if below == 2 and ctx.skyLight(x, y, z) >= 9 and rng:nextInt(20) == 0 then
				local names = { "pig", "cow", "sheep", "chicken" }
				local kind = MobTypes.byName(names[rng:nextInt(4) + 1])
				-- small herd
				for i = 0, rng:nextInt(3) do
					if m.passiveCount < MobTypes.PASSIVE_CAP then
						Mobs.spawn(m, kind, x + 0.5 + (i % 2), y, z + 0.5 + (i // 2))
						spawned += 1
					end
				end
			end
		end
	end
	return spawned
end

function Mobs.takeEvents(m: Mobs): Events
	local e = m.events
	m.events = { spawned = {}, moved = {}, removed = {}, hurt = {} }
	return e
end

return Mobs
