--!strict
-- Mob definitions. Health/damage/speeds/drops are classic (pre-1.9) values;
-- caps and spawn weights are approximations (see COMPATIBILITY.md).
export type Drop = { id: number, min: number, max: number, meta: number? }
export type MobType = {
	id: number,
	name: string,
	hostile: boolean,
	health: number,
	speed: number, -- blocks per tick walking
	width: number,
	height: number,
	attack: number, -- melee damage (normal difficulty)
	drops: { Drop },
	burnsInDaylight: boolean,
	color: { number },
	ranged: boolean?, -- shoots arrows instead of melee
	projectile: boolean?, -- not a living mob (arrows)
}

local MobTypes = {}

local list: { MobType } = {
	{ id = 90, name = "pig", hostile = false, health = 10, speed = 0.1, width = 0.9, height = 0.9, attack = 0, drops = { { id = 319, min = 1, max = 3 } }, burnsInDaylight = false, color = { 240, 160, 160 } },
	{ id = 92, name = "cow", hostile = false, health = 10, speed = 0.1, width = 0.9, height = 1.3, attack = 0, drops = { { id = 363, min = 1, max = 3 } }, burnsInDaylight = false, color = { 80, 60, 45 } },
	{ id = 91, name = "sheep", hostile = false, health = 8, speed = 0.1, width = 0.9, height = 1.3, attack = 0, drops = { { id = 35, min = 1, max = 1 } }, burnsInDaylight = false, color = { 235, 235, 235 } },
	{ id = 93, name = "chicken", hostile = false, health = 4, speed = 0.1, width = 0.4, height = 0.7, attack = 0, drops = { { id = 288, min = 0, max = 2 } }, burnsInDaylight = false, color = { 250, 250, 250 } },
	{ id = 54, name = "zombie", hostile = true, health = 20, speed = 0.115, width = 0.6, height = 1.95, attack = 3, drops = { { id = 367, min = 0, max = 2 } }, burnsInDaylight = true, color = { 70, 120, 70 } },
	{ id = 50, name = "creeper", hostile = true, health = 20, speed = 0.1, width = 0.6, height = 1.7, attack = 0, drops = { { id = 289, min = 0, max = 2 } }, burnsInDaylight = false, color = { 90, 170, 80 } },
	{ id = 52, name = "spider", hostile = true, health = 16, speed = 0.15, width = 1.4, height = 0.9, attack = 2, drops = { { id = 287, min = 0, max = 2 } }, burnsInDaylight = false, color = { 50, 40, 35 } },
	{ id = 51, name = "skeleton", hostile = true, health = 20, speed = 0.1, width = 0.6, height = 1.99, attack = 3, drops = { { id = 262, min = 0, max = 2 }, { id = 352, min = 0, max = 2 } }, burnsInDaylight = true, color = { 200, 200, 200 }, ranged = true },
	{ id = 10, name = "arrow", hostile = false, health = 1, speed = 0, width = 0.5, height = 0.5, attack = 2, drops = {}, burnsInDaylight = false, color = { 120, 90, 60 }, projectile = true },
}

local byId: { [number]: MobType } = {}
local byName: { [string]: MobType } = {}
for _, m in list do
	byId[m.id] = m
	byName[m.name] = m
end

MobTypes.HOSTILE_CAP = 30
MobTypes.PASSIVE_CAP = 20

function MobTypes.get(id: number): MobType?
	return byId[id]
end

function MobTypes.byName(name: string): MobType
	local m = byName[name]
	assert(m, "unknown mob " .. name)
	return m
end

function MobTypes.all(): { MobType }
	return list
end

return MobTypes
