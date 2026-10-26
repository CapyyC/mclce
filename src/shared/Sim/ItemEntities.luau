--!strict
-- Dropped item entities: gravity, drag, voxel collision, pickup delay,
-- merging and despawn. Constants are the classic per-tick values
-- (gravity 0.04, drag 0.98, pickup delay 10 ticks, despawn after 6000 ticks).

local Collision = require("../Physics/Collision")
local ItemStack = require("../Items/ItemStack")

export type ItemEntity = {
	id: number,
	x: number,
	y: number,
	z: number,
	vx: number,
	vy: number,
	vz: number,
	stack: ItemStack.ItemStack,
	age: number,
	pickupDelay: number,
	onGround: boolean,
}

export type Events = {
	spawned: { ItemEntity },
	removed: { number },
	moved: { ItemEntity },
}

export type ItemEntities = {
	list: { [number]: ItemEntity },
	count: number,
	nextId: number,
	events: Events,
	maxEntities: number,
}

local ItemEntities = {}

ItemEntities.GRAVITY = 0.04
ItemEntities.DRAG = 0.98
ItemEntities.DESPAWN_TICKS = 6000
ItemEntities.PICKUP_DELAY = 10
ItemEntities.HALF = 0.125

function ItemEntities.new(maxEntities: number?): ItemEntities
	return {
		list = {},
		count = 0,
		nextId = 1,
		events = { spawned = {}, removed = {}, moved = {} },
		maxEntities = maxEntities or 512,
	}
end

function ItemEntities.spawn(ie: ItemEntities, x: number, y: number, z: number, stack: ItemStack.ItemStack, vx: number?, vy: number?, vz: number?): ItemEntity?
	if ie.count >= ie.maxEntities then
		return nil
	end
	local e: ItemEntity = {
		id = ie.nextId,
		x = x,
		y = y,
		z = z,
		vx = vx or 0,
		vy = vy or 0.2,
		vz = vz or 0,
		stack = stack,
		age = 0,
		pickupDelay = ItemEntities.PICKUP_DELAY,
		onGround = false,
	}
	ie.nextId += 1
	ie.list[e.id] = e
	ie.count += 1
	table.insert(ie.events.spawned, e)
	return e
end

function ItemEntities.remove(ie: ItemEntities, id: number)
	if ie.list[id] then
		ie.list[id] = nil
		ie.count -= 1
		table.insert(ie.events.removed, id)
	end
end

-- Steps all entities one tick. isLoaded(x, z) prevents simulating entities in
-- unloaded chunks (they freeze in place, like the classic game).
function ItemEntities.tick(ie: ItemEntities, getState: Collision.GetState, isLoaded: (number, number) -> boolean)
	local H = ItemEntities.HALF
	for id, e in ie.list do
		e.age += 1
		if e.pickupDelay > 0 then
			e.pickupDelay -= 1
		end
		if e.age >= ItemEntities.DESPAWN_TICKS or e.y < -64 then
			ItemEntities.remove(ie, id)
			continue
		end
		if not isLoaded(e.x, e.z) then
			continue
		end
		local wasResting = e.onGround and math.abs(e.vx) < 1e-3 and math.abs(e.vz) < 1e-3
		e.vy -= ItemEntities.GRAVITY
		local box = Collision.box(e.x, e.y, e.z, H, H * 2)
		-- pushed out of solid blocks (e.g. a block was placed on it)
		if Collision.intersectsBlocks(getState, box) then
			e.y = math.floor(e.y) + 1
			e.vy = 0.1
			table.insert(ie.events.moved, e)
			continue
		end
		local dx, dy, dz, hitX, hitY, hitZ = Collision.move(getState, box, e.vx, e.vy, e.vz)
		e.x += dx
		e.y += dy
		e.z += dz
		e.onGround = hitY and e.vy < 0
		if hitY then
			e.vy = 0
		end
		if hitX then
			e.vx = 0
		end
		if hitZ then
			e.vz = 0
		end
		local friction = if e.onGround then 0.6 * ItemEntities.DRAG else ItemEntities.DRAG
		e.vx *= friction
		e.vz *= friction
		e.vy *= ItemEntities.DRAG
		if not (wasResting and e.onGround and math.abs(dx) + math.abs(dz) < 1e-4) then
			table.insert(ie.events.moved, e)
		end
	end
end

-- Merges same-item entities closer than 0.5 blocks (bounded work: only
-- entities sharing a block cell are compared).
function ItemEntities.merge(ie: ItemEntities)
	local cells: { [string]: { ItemEntity } } = {}
	for _, e in ie.list do
		local k = math.floor(e.x) .. "," .. math.floor(e.y) .. "," .. math.floor(e.z)
		local c = cells[k]
		if c == nil then
			c = {}
			cells[k] = c
		end
		table.insert(c :: { ItemEntity }, e)
	end
	for _, c in cells do
		for i = 1, #c do
			local a = c[i]
			if ie.list[a.id] == nil then
				continue
			end
			for j = i + 1, #c do
				local b = c[j]
				if ie.list[b.id] and ItemStack.canMerge(a.stack, b.stack) then
					local max = ItemStack.maxStack(a.stack)
					if a.stack.count + b.stack.count <= max then
						a.stack = ItemStack.copy(a.stack, a.stack.count + b.stack.count)
						a.age = math.min(a.age, b.age)
						ItemEntities.remove(ie, b.id)
					end
				end
			end
		end
	end
end

-- Entities within pickup range of a player's box (feet at x,y,z).
function ItemEntities.inPickupRange(ie: ItemEntities, x: number, y: number, z: number): { ItemEntity }
	local out = {}
	for _, e in ie.list do
		if e.pickupDelay <= 0 and math.abs(e.x - x) <= 1.3 and math.abs(e.z - z) <= 1.3 and e.y >= y - 0.5 and e.y <= y + 2.3 then
			table.insert(out, e)
		end
	end
	table.sort(out, function(a: ItemEntity, b: ItemEntity): boolean
		return a.id < b.id
	end)
	return out
end

function ItemEntities.takeEvents(ie: ItemEntities): Events
	local ev = ie.events
	ie.events = { spawned = {}, removed = {}, moved = {} }
	return ev
end

return ItemEntities
