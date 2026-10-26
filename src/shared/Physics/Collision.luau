--!strict
--!native
-- Axis-aligned box vs voxel collision in block units, resolved one axis at a
-- time (Y, then X, then Z) like the classic entity mover. Used for item
-- entities and mobs simulated on the server, and for placement checks.

local BlockRegistry = require("../Blocks/BlockRegistry")

export type Box = { minX: number, minY: number, minZ: number, maxX: number, maxY: number, maxZ: number }
export type GetState = (number, number, number) -> number

local Collision = {}

local EPS = 1e-7

function Collision.box(x: number, y: number, z: number, halfWidth: number, height: number): Box
	return { minX = x - halfWidth, minY = y, minZ = z - halfWidth, maxX = x + halfWidth, maxY = y + height, maxZ = z + halfWidth }
end

-- Collision height of a block state in [0, 1] (0 = passable).
local function solidHeight(state: number): number
	local id = state // 16
	if id == 64 or id == 71 then
		-- doors collide while closed (approximation: full cell, lower half's open bit)
		local meta = state % 16
		return if meta < 8 and meta >= 4 then 0 else 1
	end
	if not BlockRegistry.isSolid(id) then
		return 0
	end
	local def = BlockRegistry.get(id)
	if def and def.shape == "slab" and state % 16 < 8 then
		return 0.5
	end
	return 1
end
Collision.solidHeight = solidHeight

function Collision.intersectsBlocks(getState: GetState, b: Box): boolean
	for y = math.floor(b.minY), math.floor(b.maxY - EPS) do
		for z = math.floor(b.minZ), math.floor(b.maxZ - EPS) do
			for x = math.floor(b.minX), math.floor(b.maxX - EPS) do
				local h = solidHeight(getState(x, y, z))
				if h > 0 and b.minY < y + h then
					return true
				end
			end
		end
	end
	return false
end

-- Moves `b` by (dx, dy, dz), stopping at solid blocks. Mutates b. Returns the
-- actual movement and whether each axis collided.
function Collision.move(getState: GetState, b: Box, dx: number, dy: number, dz: number): (number, number, number, boolean, boolean, boolean)
	local hitX, hitY, hitZ = false, false, false
	-- Y
	if dy ~= 0 then
		local x0, x1 = math.floor(b.minX), math.floor(b.maxX - EPS)
		local z0, z1 = math.floor(b.minZ), math.floor(b.maxZ - EPS)
		if dy < 0 then
			local limit = b.minY + dy
			for y = math.floor(b.minY - EPS), math.floor(limit), -1 do
				local top = -math.huge
				for z = z0, z1 do
					for x = x0, x1 do
						local h = solidHeight(getState(x, y, z))
						if h > 0 then
							top = math.max(top, y + h)
						end
					end
				end
				if top > limit and top <= b.minY + EPS then
					dy = top - b.minY
					hitY = true
					break
				end
			end
		else
			local limit = b.maxY + dy
			for y = math.floor(b.maxY), math.floor(limit - EPS) do
				local blocked = false
				for z = z0, z1 do
					for x = x0, x1 do
						if solidHeight(getState(x, y, z)) > 0 then
							blocked = true
						end
					end
				end
				if blocked then
					dy = y - b.maxY
					hitY = true
					break
				end
			end
		end
		b.minY += dy
		b.maxY += dy
	end
	-- X and Z
	for axis = 1, 2 do
		local d = if axis == 1 then dx else dz
		if d == 0 then
			continue
		end
		local lo = if axis == 1 then b.minX else b.minZ
		local hi = if axis == 1 then b.maxX else b.maxZ
		local o0 = if axis == 1 then b.minZ else b.minX
		local o1 = if axis == 1 then b.maxZ else b.maxX
		local y0, y1 = math.floor(b.minY), math.floor(b.maxY - EPS)
		local hit = false
		local startC = if d > 0 then math.floor(hi) else math.floor(lo - EPS)
		local endC = if d > 0 then math.floor(hi + d - EPS) else math.floor(lo + d)
		local step = if d > 0 then 1 else -1
		for c = startC, endC, step do
			local blocked = false
			for y = y0, y1 do
				for o = math.floor(o0), math.floor(o1 - EPS) do
					local st = if axis == 1 then getState(c, y, o) else getState(o, y, c)
					local h = solidHeight(st)
					if h > 0 and b.minY < y + h - EPS then
						blocked = true
					end
				end
			end
			if blocked then
				d = if d > 0 then c - hi else (c + 1) - lo
				hit = true
				break
			end
		end
		if axis == 1 then
			b.minX += d
			b.maxX += d
			dx = d
			hitX = hit
		else
			b.minZ += d
			b.maxZ += d
			dz = d
			hitZ = hit
		end
	end
	return dx, dy, dz, hitX, hitY, hitZ
end

return Collision
