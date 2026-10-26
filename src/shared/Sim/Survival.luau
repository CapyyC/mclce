--!strict
-- Health, hunger and fall damage. Constants are the classic (pre-1.9)
-- values Legacy Console followed: exhaustion threshold 4.0, natural regen at
-- food >= 18 every 80 ticks (costs 3.0 exhaustion), starvation every 80
-- ticks at food 0, fall damage = ceil(distance - 3).
-- Difficulty: 0 peaceful, 1 easy, 2 normal, 3 hard.

export type Vitals = {
	health: number, -- 0..20 (half hearts)
	food: number, -- 0..20
	saturation: number, -- 0..food
	exhaustion: number,
	foodTimer: number,
	-- fall tracking
	fallStartY: number?,
	lastY: number,
	dead: boolean,
}

local Survival = {}

Survival.MAX_HEALTH = 20
Survival.MAX_FOOD = 20

Survival.EXHAUSTION = {
	walkPerBlock = 0.01,
	sprintPerBlock = 0.1,
	jump = 0.2,
	sprintJump = 0.8,
	breakBlock = 0.025,
	attack = 0.3,
	damage = 0.3, -- per damage event
	regen = 3.0,
}

function Survival.new(): Vitals
	return { health = 20, food = 20, saturation = 5, exhaustion = 0, foodTimer = 0, fallStartY = nil, lastY = 0, dead = false }
end

function Survival.exhaust(v: Vitals, amount: number)
	v.exhaustion = math.min(v.exhaustion + amount, 40)
end

-- Returns damage dealt (after clamping) and whether this killed the player.
function Survival.damage(v: Vitals, amount: number): (number, boolean)
	if v.dead or amount <= 0 then
		return 0, false
	end
	local dealt = math.min(v.health, amount)
	v.health -= dealt
	Survival.exhaust(v, Survival.EXHAUSTION.damage)
	if v.health <= 0 then
		v.health = 0
		v.dead = true
		return dealt, true
	end
	return dealt, false
end

function Survival.heal(v: Vitals, amount: number)
	if not v.dead then
		v.health = math.min(Survival.MAX_HEALTH, v.health + amount)
	end
end

-- Eating: food points and saturation (= food * modifier * 2), capped by food.
function Survival.eat(v: Vitals, food: number, saturationModifier: number): boolean
	if v.dead or v.food >= Survival.MAX_FOOD then
		return false
	end
	v.food = math.min(Survival.MAX_FOOD, v.food + food)
	v.saturation = math.min(v.food, v.saturation + food * saturationModifier * 2)
	return true
end

-- One simulation tick of the hunger system. Returns damage taken this tick.
function Survival.tickFood(v: Vitals, difficulty: number): number
	if v.dead then
		return 0
	end
	if difficulty == 0 then
		-- peaceful: regenerate health and food
		v.foodTimer += 1
		if v.foodTimer % 20 == 0 then
			Survival.heal(v, 1)
			if v.food < 20 then
				v.food += 1
			end
		end
		return 0
	end
	while v.exhaustion >= 4 do
		v.exhaustion -= 4
		if v.saturation > 0 then
			v.saturation = math.max(0, v.saturation - 1)
		else
			v.food = math.max(0, v.food - 1)
		end
	end
	if v.food >= 18 and v.health < Survival.MAX_HEALTH then
		v.foodTimer += 1
		if v.foodTimer >= 80 then
			Survival.heal(v, 1)
			Survival.exhaust(v, Survival.EXHAUSTION.regen)
			v.foodTimer = 0
		end
	elseif v.food <= 0 then
		v.foodTimer += 1
		if v.foodTimer >= 80 then
			v.foodTimer = 0
			local floor = if difficulty == 1 then 10 elseif difficulty == 2 then 1 else 0
			if v.health > floor then
				local dealt = Survival.damage(v, 1)
				return dealt
			end
		end
	else
		v.foodTimer = 0
	end
	return 0
end

function Survival.fallDamage(distance: number): number
	return math.max(0, math.ceil(distance - 3))
end

-- Tracks falling from successive feet heights. Call once per tick with
-- whether the player is supported by ground, and whether they are in a
-- liquid or on a ladder (which reset the fall). Returns fall damage on landing.
function Survival.trackFall(v: Vitals, y: number, onGround: boolean, inLiquid: boolean): number
	local dmg = 0
	if inLiquid then
		v.fallStartY = nil
	elseif onGround then
		if v.fallStartY then
			dmg = Survival.fallDamage(v.fallStartY - y)
		end
		v.fallStartY = nil
	else
		if v.fallStartY == nil or y > (v.fallStartY :: number) then
			v.fallStartY = y
		end
	end
	v.lastY = y
	return dmg
end

function Survival.respawn(v: Vitals)
	v.health, v.food, v.saturation, v.exhaustion, v.foodTimer = 20, 20, 5, 0, 0
	v.dead = false
	v.fallStartY = nil
end

return Survival
