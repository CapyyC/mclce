local Mobs = require("../../src/shared/Sim/Mobs")
local MobTypes = require("../../src/shared/Sim/MobTypes")

local STONE, GRASS = 16, 32

-- infinite flat world: solid at y <= 9 (grass on top), optional roof at y = 14
local function ctxFor(players, opts)
	opts = opts or {}
	local log = { damage = {}, explosions = {}, drops = {} }
	local ctx = {
		players = players,
		getState = function(x, y, z)
			if y == 9 then
				return GRASS
			elseif y < 9 then
				return STONE
			elseif opts.roof and y == 14 then
				return STONE
			elseif opts.walls and opts.walls[x .. "," .. z] and y < 12 then
				return STONE
			end
			return 0
		end,
		isLoaded = function()
			return true
		end,
		skyLight = function(_, y)
			if opts.roof and y < 14 then
				return 0
			end
			return 15
		end,
		light = function()
			return opts.light or 0
		end,
		isDay = opts.day == true,
		damagePlayer = function(id, amount, cause)
			table.insert(log.damage, { id, amount, cause })
		end,
		explode = function(x, y, z, power)
			table.insert(log.explosions, { x, y, z, power })
		end,
		dropItem = function(_, _, _, stack)
			table.insert(log.drops, stack)
		end,
	}
	return ctx, log
end

local function run(m, ctx, n)
	for _ = 1, n do
		Mobs.tick(m, ctx)
	end
end

return function(t)
	t.describe("Mobs", function()
		t.test("gravity: a mob dropped from y=20 lands on the floor at y=10", function()
			local m = Mobs.new(1)
			local ctx = ctxFor({})
			local pig = Mobs.spawn(m, MobTypes.byName("pig"), 0.5, 20, 0.5)
			run(m, ctx, 60)
			t.near(pig.y, 10, 1e-6)
			t.truthy(pig.onGround)
		end)
		t.test("zombie chases and hits the player once per second", function()
			local m = Mobs.new(2)
			local player = { id = 7, x = 8.5, y = 10, z = 0.5, attackable = true }
			local ctx, log = ctxFor({ player })
			Mobs.spawn(m, MobTypes.byName("zombie"), 0.5, 10, 0.5)
			run(m, ctx, 200)
			t.truthy(#log.damage >= 3, "hits: " .. #log.damage)
			t.eq(log.damage[1][1], 7); t.eq(log.damage[1][2], 3); t.eq(log.damage[1][3], "zombie")
			t.truthy(#log.damage <= 10, "cooldown limits hits")
		end)
		t.test("non-attackable (creative) players are ignored", function()
			local m = Mobs.new(3)
			local ctx, log = ctxFor({ { id = 1, x = 2.5, y = 10, z = 0.5, attackable = false } })
			Mobs.spawn(m, MobTypes.byName("zombie"), 0.5, 10, 0.5)
			run(m, ctx, 100)
			t.eq(#log.damage, 0)
		end)
		t.test("creeper explodes after its fuse; escaping defuses", function()
			local m = Mobs.new(4)
			local player = { id = 1, x = 2.5, y = 10, z = 0.5, attackable = true }
			local ctx, log = ctxFor({ player })
			Mobs.spawn(m, MobTypes.byName("creeper"), 0.5, 10, 0.5)
			run(m, ctx, 29)
			t.eq(#log.explosions, 0)
			run(m, ctx, 5)
			t.eq(#log.explosions, 1)
			t.eq(log.explosions[1][4], 3)
			t.eq(m.count, 0)
			-- defuse
			local m2 = Mobs.new(5)
			local p2 = { id = 1, x = 2.5, y = 10, z = 0.5, attackable = true }
			local ctx2, log2 = ctxFor({ p2 })
			local c = Mobs.spawn(m2, MobTypes.byName("creeper"), 0.5, 10, 0.5)
			run(m2, ctx2, 10)
			t.truthy(c.fuse > 0)
			p2.x = 40
			run(m2, ctx2, 5)
			t.eq(c.fuse, -1)
			run(m2, ctx2, 60)
			t.eq(#log2.explosions, 0)
		end)
		t.test("damage, invulnerability frames, death drops", function()
			local m = Mobs.new(6)
			local ctx, log = ctxFor({})
			local cow = Mobs.spawn(m, MobTypes.byName("cow"), 0.5, 10, 0.5)
			t.falsy(Mobs.hurt(m, cow, 4, -1, 0.5, ctx))
			t.eq(cow.health, 6)
			t.falsy(Mobs.hurt(m, cow, 4, -1, 0.5, ctx)) -- ignored: invulnerable
			t.eq(cow.health, 6)
			t.truthy(cow.vx > 0, "knocked back away from attacker")
			t.truthy(cow.panicTicks > 0)
			run(m, ctx, 10)
			t.truthy(Mobs.hurt(m, cow, 10, 0, 0, ctx))
			t.eq(m.count, 0)
			t.truthy(#log.drops >= 1)
			t.eq(log.drops[1].id, 363)
		end)
		t.test("undead burn in daylight only under open sky", function()
			local m = Mobs.new(7)
			local ctx = ctxFor({}, { day = true })
			local z = Mobs.spawn(m, MobTypes.byName("zombie"), 0.5, 10, 0.5)
			run(m, ctx, 20 * 25)
			t.eq(m.count, 0, "burned to death")
			local m2 = Mobs.new(8)
			local ctx2 = ctxFor({}, { day = true, roof = true })
			local z2 = Mobs.spawn(m2, MobTypes.byName("zombie"), 0.5, 10, 0.5)
			run(m2, ctx2, 200)
			t.eq(z2.health, 20)
			local _ = z
		end)
		t.test("spawning respects light, distance and caps", function()
			local m = Mobs.new(9)
			local player = { id = 1, x = 0.5, y = 10, z = 0.5, attackable = true }
			local dark = ctxFor({ player }, { light = 0 })
			local n = Mobs.spawnCycle(m, dark, 2000)
			t.truthy(n > 0)
			t.eq(m.hostileCount, MobTypes.HOSTILE_CAP)
			for _, mob in m.list do
				local d = math.sqrt((mob.x - 0.5) ^ 2 + (mob.z - 0.5) ^ 2)
				t.truthy(d >= 24 - 1, "too close: " .. d)
				t.near(mob.y, 10, 1e-9)
			end
			local m2 = Mobs.new(10)
			local bright = ctxFor({ player }, { light = 12 })
			Mobs.spawnCycle(m2, bright, 2000)
			t.eq(m2.hostileCount, 0)
		end)
		t.test("far hostiles despawn", function()
			local m = Mobs.new(11)
			local ctx = ctxFor({ { id = 1, x = 0, y = 10, z = 0, attackable = true } })
			Mobs.spawn(m, MobTypes.byName("zombie"), 200.5, 10, 0.5)
			Mobs.spawn(m, MobTypes.byName("pig"), 200.5, 10, 0.5)
			run(m, ctx, 1)
			t.eq(m.hostileCount, 0)
			t.eq(m.passiveCount, 1)
		end)
		t.test("jump apex from 0.42 velocity is ~1.25 blocks", function()
			local m = Mobs.new(13)
			local ctx = ctxFor({})
			local pig = Mobs.spawn(m, MobTypes.byName("pig"), 0.5, 10, 0.5)
			run(m, ctx, 5)
			pig.wantJump = true
			pig.wanderTicks = 1000
			pig.wanderX = nil
			local apex = 0
			for _ = 1, 20 do
				Mobs.tick(m, ctx)
				apex = math.max(apex, pig.y - 10)
			end
			t.near(apex, 1.2522, 0.01)
		end)
		t.test("mobs step up one-block ledges", function()
			local m = Mobs.new(12)
			local walls = {}
			for z = -5, 5 do
				walls["3," .. z] = true -- y 10..11 solid... too high; use single step
			end
			local ctx = ctxFor({ { id = 1, x = 10.5, y = 11, z = 0.5, attackable = true } })
			local base = ctx.getState
			ctx.getState = function(x, y, z)
				if x >= 3 and y == 10 then
					return 16
				end
				return base(x, y, z)
			end
			local zb = Mobs.spawn(m, MobTypes.byName("zombie"), 0.5, 10, 0.5)
			run(m, ctx, 200)
			t.truthy(zb.x > 3, "climbed: x=" .. zb.x)
			t.near(zb.y, 11, 1e-6)
			local _ = walls
		end)
	end)
end
