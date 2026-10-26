--!strict
-- Block entities (chests, furnaces). They live in their chunk
-- (`chunk.blockEntities[localIndex]`, localIndex = x + z*16 + y*256) so they
-- load, unload and persist with it. Furnace logic follows classic values:
-- 200 ticks per item, fuel burn times from Recipes.fuelTicks, the block swaps
-- between furnace (61) and lit_furnace (62) keeping its orientation meta.

local Chunk = require("../Voxel/Chunk")
local World = require("../Voxel/World")
local ItemStack = require("../Items/ItemStack")
local Recipes = require("../Items/Recipes")
local SlotClick = require("../Items/SlotClick")

export type Entity = {
	kind: string, -- "chest" | "furnace"
	slots: { [number]: ItemStack.ItemStack? },
	burn: number, -- furnace: remaining burn ticks
	burnTotal: number,
	cook: number, -- furnace: progress ticks on the current item
	version: number,
}

local BlockEntities = {}

BlockEntities.CHEST = 54
BlockEntities.FURNACE = 61
BlockEntities.LIT_FURNACE = 62
BlockEntities.COOK_TICKS = 200
BlockEntities.SIZES = { chest = 27, furnace = 3, spawner = 0 } -- furnace: 1 input, 2 fuel, 3 output

function BlockEntities.kindForBlock(id: number): string?
	if id == 54 then
		return "chest"
	elseif id == 61 or id == 62 then
		return "furnace"
	elseif id == 52 then
		return "spawner"
	end
	return nil
end

function BlockEntities.new(kind: string): Entity
	if kind == "spawner" then
		kind = "spawner:pig" -- a placed spawner without data (creative) spawns pigs
	end
	return { kind = kind, slots = {}, burn = 0, burnTotal = 0, cook = 20, version = 0 }
end

function BlockEntities.isSpawner(e: Entity): boolean
	return string.sub(e.kind, 1, 8) == "spawner:"
end

function BlockEntities.spawnerMob(e: Entity): string
	return string.sub(e.kind, 9)
end

local function localIndex(x: number, y: number, z: number): number
	return (x % 16) + (z % 16) * 16 + y * 256
end
BlockEntities.localIndex = localIndex

function BlockEntities.get(world: World.World, x: number, y: number, z: number): Entity?
	local c = World.getChunk(world, x // 16, z // 16)
	if c == nil or c.blockEntities == nil then
		return nil
	end
	return (c.blockEntities :: any)[localIndex(x, y, z)]
end

function BlockEntities.set(world: World.World, x: number, y: number, z: number, e: Entity?)
	local c = World.getChunk(world, x // 16, z // 16)
	if c == nil then
		return
	end
	if c.blockEntities == nil then
		if e == nil then
			return
		end
		c.blockEntities = {}
	end
	(c.blockEntities :: any)[localIndex(x, y, z)] = e
	c.dirty = true
end

-- All stacks held by an entity (for dropping on break).
function BlockEntities.contents(e: Entity): { ItemStack.ItemStack }
	local out = {}
	for i = 1, BlockEntities.SIZES[e.kind] or 0 do
		local s = e.slots[i]
		if s then
			table.insert(out, s)
		end
	end
	return out
end

local function furnaceRules(slot: number): SlotClick.Rules?
	if slot == 2 then
		return {
			canPlace = function(s: ItemStack.ItemStack): boolean
				return Recipes.fuelTicks(s.id) > 0
			end,
		}
	elseif slot == 3 then
		return { takeOnly = true }
	end
	return nil
end

-- Click on a container slot with the player's cursor. Returns (ok, newCursor).
function BlockEntities.click(e: Entity, slot: number, cursor: ItemStack.ItemStack?, button: string): (boolean, ItemStack.ItemStack?)
	local size = BlockEntities.SIZES[e.kind]
	if size == nil or type(slot) ~= "number" or slot ~= math.floor(slot) or slot < 1 or slot > size then
		return false, cursor
	end
	local rules = if e.kind == "furnace" then furnaceRules(slot) else nil
	local ok, ns, nc = SlotClick.click(e.slots[slot], cursor, button, rules)
	if not ok then
		return false, cursor
	end
	e.slots[slot] = ns
	e.version += 1
	return true, nc
end

local function canSmelt(e: Entity): Recipes.Smelt?
	local input = e.slots[1]
	if input == nil then
		return nil
	end
	local r = Recipes.smeltResult(input.id, input.meta)
	if r == nil then
		return nil
	end
	local out = e.slots[3]
	if out == nil then
		return r
	end
	if out.id ~= r.output or out.meta ~= r.outputMeta or out.count >= ItemStack.maxStack(out) then
		return nil
	end
	return r
end

-- One furnace tick. Returns (changed, lit) so the caller can swap the block.
function BlockEntities.tickFurnace(e: Entity): (boolean, boolean)
	local changed = false
	local wasLit = e.burn > 0
	if e.burn > 0 then
		e.burn -= 1
		changed = true
	end
	local recipe = canSmelt(e)
	if e.burn == 0 and recipe then
		local fuel = e.slots[2]
		if fuel then
			local t = Recipes.fuelTicks(fuel.id)
			if t > 0 then
				e.burn, e.burnTotal = t, t
				e.slots[2] = if fuel.count > 1 then ItemStack.copy(fuel, fuel.count - 1) else (if fuel.id == 327 then ItemStack.new(325, 1) else nil)
				changed = true
			end
		end
	end
	if e.burn > 0 and recipe then
		e.cook += 1
		changed = true
		if e.cook >= BlockEntities.COOK_TICKS then
			e.cook = 0
			local input = e.slots[1] :: ItemStack.ItemStack
			e.slots[1] = if input.count > 1 then ItemStack.copy(input, input.count - 1) else nil
			local out = e.slots[3]
			e.slots[3] = if out then ItemStack.copy(out, out.count + 1) else ItemStack.new(recipe.output, 1, recipe.outputMeta)
		end
	elseif e.cook > 0 then
		-- cooling down without heat (classic: progress decays by 2 per tick)
		e.cook = math.max(0, e.cook - 2)
		changed = true
	end
	if changed then
		e.version += 1
	end
	local lit = e.burn > 0
	return changed or wasLit ~= lit, lit
end

-- Serialisable snapshot for the network.
function BlockEntities.snapshot(e: Entity): { [string]: any }
	local slots = {}
	for i = 1, BlockEntities.SIZES[e.kind] or 0 do
		local s = e.slots[i]
		if s then
			slots[tostring(i)] = { s.id, s.meta, s.count, s.damage }
		end
	end
	return { kind = e.kind, slots = slots, burn = e.burn, burnTotal = e.burnTotal, cook = e.cook }
end

local _ = Chunk
return BlockEntities
