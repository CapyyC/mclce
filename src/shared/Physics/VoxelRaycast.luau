--!strict
--!native
-- Amanatides–Woo voxel traversal. Returns the first block for which
-- `isHit(state)` is true within maxDistance, with the face that was entered.

local Physics = {}

export type Hit = {
	x: number,
	y: number,
	z: number,
	state: number,
	face: number, -- face of the hit block that the ray entered through (0..5, see Mesh/Faces)
	distance: number,
}

-- getState(x, y, z) -> state; isHit(state) -> boolean
function Physics.cast(
	getState: (number, number, number) -> number,
	ox: number, oy: number, oz: number,
	dx: number, dy: number, dz: number,
	maxDistance: number,
	isHit: (number) -> boolean
): Hit?
	local len = math.sqrt(dx * dx + dy * dy + dz * dz)
	if len == 0 then
		return nil
	end
	dx, dy, dz = dx / len, dy / len, dz / len
	local x, y, z = math.floor(ox), math.floor(oy), math.floor(oz)
	local stepX = if dx > 0 then 1 elseif dx < 0 then -1 else 0
	local stepY = if dy > 0 then 1 elseif dy < 0 then -1 else 0
	local stepZ = if dz > 0 then 1 elseif dz < 0 then -1 else 0
	local inf = math.huge
	local tDeltaX = if stepX ~= 0 then math.abs(1 / dx) else inf
	local tDeltaY = if stepY ~= 0 then math.abs(1 / dy) else inf
	local tDeltaZ = if stepZ ~= 0 then math.abs(1 / dz) else inf
	local tMaxX = if stepX > 0 then (x + 1 - ox) * tDeltaX elseif stepX < 0 then (ox - x) * tDeltaX else inf
	local tMaxY = if stepY > 0 then (y + 1 - oy) * tDeltaY elseif stepY < 0 then (oy - y) * tDeltaY else inf
	local tMaxZ = if stepZ > 0 then (z + 1 - oz) * tDeltaZ elseif stepZ < 0 then (oz - z) * tDeltaZ else inf
	local face = -1
	local t = 0
	-- the origin block itself counts (face -1) so a player inside a block can't build through it
	local st = getState(x, y, z)
	if isHit(st) then
		return { x = x, y = y, z = z, state = st, face = -1, distance = 0 }
	end
	while true do
		if tMaxX < tMaxY and tMaxX < tMaxZ then
			x += stepX
			t = tMaxX
			tMaxX += tDeltaX
			face = if stepX > 0 then 1 else 0 -- moving +X enters through the block's -X face
		elseif tMaxY < tMaxZ then
			y += stepY
			t = tMaxY
			tMaxY += tDeltaY
			face = if stepY > 0 then 3 else 2
		else
			z += stepZ
			t = tMaxZ
			tMaxZ += tDeltaZ
			face = if stepZ > 0 then 5 else 4
		end
		if t > maxDistance then
			return nil
		end
		st = getState(x, y, z)
		if isHit(st) then
			return { x = x, y = y, z = z, state = st, face = face, distance = t }
		end
	end
end

return Physics
