--!strict
-- Monster rooms ("dungeons"): classic placement — 8 attempts per chunk,
-- room interior 5 high with half-width 3 or 4, valid only when floor and
-- ceiling are fully solid and the walls have 1..5 openings at floor level.
-- Walls cobblestone / mossy cobblestone (floor 75% mossy), a mob spawner in
-- the centre (zombie 1/2, skeleton 1/4, spider 1/4) and up to 2 loot chests.
--
-- Validity reads base terrain only and every write is decided per cell, so a
-- room spanning chunk borders is identical whichever chunk is generated first.
-- APPROXIMATION of the classic algorithm (constants public, details our own).

local Chunk = require("../Voxel/Chunk")
local Hash = require("../Util/Hash")
local JavaRandom = require("../Util/JavaRandom")

export type GetBase = (cx: number, cz: number) -> { chunk: Chunk.Chunk }

local Dungeons = {}

local AIR, COBBLE, MOSSY, SPAWNER, CHEST = 0, 4 * 16, 48 * 16, 52 * 16, 54 * 16
Dungeons.ATTEMPTS = 8

-- loot table: { item id, min, max, weight }
local LOOT: { { number } } = {
	{ 265, 1, 4, 10 }, -- iron ingot
	{ 297, 1, 1, 10 }, -- bread
	{ 296, 1, 4, 10 }, -- wheat
	{ 289, 1, 4, 10 }, -- gunpowder
	{ 287, 1, 4, 10 }, -- string
	{ 325, 1, 1, 10 }, -- bucket
	{ 331, 1, 4, 10 }, -- redstone
	{ 266, 1, 2, 3 }, -- gold ingot
	{ 264, 1, 1, 1 }, -- diamond
}
local LOOT_TOTAL = 0
for _, l in LOOT do
	LOOT_TOTAL += l[4]
end

local function baseState(getBase: GetBase, x: number, y: number, z: number): number
	if y < 0 or y > 255 then
		return 0
	end
	return Chunk.getState(getBase(x // 16, z // 16).chunk, x % 16, y, z % 16)
end

local function solid(st: number): boolean
	local id = st // 16
	return id ~= 0 and id ~= 8 and id ~= 9 and id ~= 10 and id ~= 11 and id ~= 31
end

export type Room = { x: number, y: number, z: number, rx: number, rz: number, rng: JavaRandom.JavaRandom, mob: string }

-- Rooms owned by source chunk (sx, sz).
function Dungeons.rooms(seed: { hi: number, lo: number }, sx: number, sz: number, getBase: GetBase): { Room }
	local out: { Room } = {}
	local rng = JavaRandom.new(Hash.hash(seed.hi, seed.lo, sx, sz, 0xD06E) * 64 + 5)
	for a = 1, Dungeons.ATTEMPTS do
		local x = sx * 16 + rng:nextInt(16)
		local y = rng:nextInt(110) + 6
		local z = sz * 16 + rng:nextInt(16)
		local rx = rng:nextInt(2) + 3
		local rz = rng:nextInt(2) + 3
		local ok = true
		local openings = 0
		for dx = -rx, rx do
			for dz = -rz, rz do
				if not solid(baseState(getBase, x + dx, y - 1, z + dz)) or not solid(baseState(getBase, x + dx, y + 4, z + dz)) then
					ok = false
					break
				end
				local edge = math.abs(dx) == rx or math.abs(dz) == rz
				if edge and baseState(getBase, x + dx, y, z + dz) == AIR and baseState(getBase, x + dx, y + 1, z + dz) == AIR then
					openings += 1
				end
			end
			if not ok then
				break
			end
		end
		if ok and openings >= 1 and openings <= 5 then
			local roomRng = JavaRandom.new(Hash.hash(seed.lo, sx, sz, a, 0xD06E) * 64 + 9)
			local r = roomRng:nextInt(4)
			table.insert(out, { x = x, y = y, z = z, rx = rx, rz = rz, rng = roomRng, mob = if r < 2 then "zombie" elseif r == 2 then "skeleton" else "spider" })
		end
	end
	return out
end

local function lootChest(rng: JavaRandom.JavaRandom): { [number]: any }
	local slots = {}
	for _ = 1, 8 do
		local roll = rng:nextInt(LOOT_TOTAL)
		for _, l in LOOT do
			roll -= l[4]
			if roll < 0 then
				local slot = rng:nextInt(27) + 1
				slots[slot] = { id = l[1], meta = 0, count = l[2] + rng:nextInt(l[3] - l[2] + 1), damage = 0 }
				break
			end
		end
	end
	return slots
end

-- Writes the parts of `room` that fall inside `target`. getBase is used to
-- decide the shell (only where the base terrain is solid, as in the classic room).
function Dungeons.apply(room: Room, target: Chunk.Chunk, getBase: GetBase)
	local bx, bz = target.cx * 16, target.cz * 16
	local x0, x1 = math.max(room.x - room.rx - 1, bx), math.min(room.x + room.rx + 1, bx + 15)
	local z0, z1 = math.max(room.z - room.rz - 1, bz), math.min(room.z + room.rz + 1, bz + 15)
	if x0 > x1 or z0 > z1 then
		return
	end
	for x = x0, x1 do
		for z = z0, z1 do
			local dx, dz = x - room.x, z - room.z
			local shell = math.abs(dx) == room.rx + 1 or math.abs(dz) == room.rz + 1
			for y = room.y - 1, room.y + 4 do
				local cur = Chunk.getState(target, x - bx, y, z - bz)
				local st: number
				-- per-cell variety from a hash (order independent)
				local h = Hash.hash(room.x, room.y, room.z, x * 7 + z * 13, y)
				if y == room.y - 1 then
					st = if h % 4 ~= 0 then MOSSY else COBBLE
				elseif y == room.y + 4 then
					st = COBBLE
				elseif shell then
					if not solid(baseState(getBase, x, y, z)) then
						continue -- keep the openings
					end
					st = COBBLE
				else
					st = AIR
				end
				if cur ~= st then
					Chunk.setState(target, x - bx, y, z - bz, st, false)
				end
			end
		end
	end
	-- spawner and chests (positions from the room's own RNG, written if inside)
	local function put(x: number, y: number, z: number, st: number, entity: any)
		if x >= bx and x <= bx + 15 and z >= bz and z <= bz + 15 then
			Chunk.setState(target, x - bx, y, z - bz, st, false)
			if target.blockEntities == nil then
				target.blockEntities = {}
			end
			(target.blockEntities :: any)[(x - bx) + (z - bz) * 16 + y * 256] = entity
		end
	end
	put(room.x, room.y, room.z, SPAWNER, { kind = "spawner:" .. room.mob, slots = {}, burn = 0, burnTotal = 0, cook = 20, version = 0 })
	local rng = room.rng
	for _ = 1, 2 do
		-- a floor cell next to a wall
		local side = rng:nextInt(4)
		local cx = if side == 0 then room.x - room.rx elseif side == 1 then room.x + room.rx else room.x - room.rx + rng:nextInt(room.rx * 2 + 1)
		local cz = if side == 2 then room.z - room.rz elseif side == 3 then room.z + room.rz else room.z - room.rz + rng:nextInt(room.rz * 2 + 1)
		if cx == room.x and cz == room.z then
			continue
		end
		put(cx, room.y, cz, CHEST + 2, { kind = "chest", slots = lootChest(rng), burn = 0, burnTotal = 0, cook = 0, version = 0 })
	end
end

return Dungeons
