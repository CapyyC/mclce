--!strict
-- Nether portals: frame detection/ignition (obsidian rectangle, interior
-- 2..21 wide and 3..21 tall, corners optional), portal support rules, and
-- finding/creating an exit portal in the destination world.

local World = require("../Voxel/World")
local BlockRegistry = require("../Blocks/BlockRegistry")

local Portals = {}

local OBSIDIAN, PORTAL = 49, 90
Portals.PORTAL = PORTAL

local function idAt(w: World.World, x: number, y: number, z: number): number
	return World.getId(w, x, y, z)
end

local function isFrame(id: number): boolean
	return id == OBSIDIAN
end

local function isInterior(id: number): boolean
	return id == 0 or id == 51 -- air or fire
end

-- Tries to light a portal whose interior contains (x, y, z). Returns true on success.
function Portals.tryIgnite(w: World.World, x: number, y: number, z: number): boolean
	if not isInterior(idAt(w, x, y, z)) then
		return false
	end
	for axis = 1, 2 do
		local ax, az = if axis == 1 then 1 else 0, if axis == 1 then 0 else 1
		-- drop to the bottom row
		local by = y
		while by > 0 and isInterior(idAt(w, x, by - 1, z)) and y - by < 21 do
			by -= 1
		end
		if not isFrame(idAt(w, x, by - 1, z)) then
			continue
		end
		-- extent along the axis
		local lo = 0
		while lo < 21 and isInterior(idAt(w, x - ax * (lo + 1), by, z - az * (lo + 1))) do
			lo += 1
		end
		local hi = 0
		while hi < 21 and isInterior(idAt(w, x + ax * (hi + 1), by, z + az * (hi + 1))) do
			hi += 1
		end
		local width = lo + hi + 1
		local sx, sz = x - ax * lo, z - az * lo
		if width < 2 or width > 21 or not isFrame(idAt(w, sx - ax, by, sz - az)) or not isFrame(idAt(w, sx + ax * width, by, sz + az * width)) then
			continue
		end
		-- height from the first column
		local height = 0
		while height < 21 and isInterior(idAt(w, sx, by + height, sz)) do
			height += 1
		end
		if height < 3 then
			continue
		end
		-- verify the whole rectangle
		local ok = true
		for i = 0, width - 1 do
			local cx, cz = sx + ax * i, sz + az * i
			if not isFrame(idAt(w, cx, by - 1, cz)) or not isFrame(idAt(w, cx, by + height, cz)) then
				ok = false
				break
			end
			for j = 0, height - 1 do
				if not isInterior(idAt(w, cx, by + j, cz)) then
					ok = false
					break
				end
			end
			if not ok then
				break
			end
		end
		if ok then
			for j = 0, height - 1 do
				if not isFrame(idAt(w, sx - ax, by + j, sz - az)) or not isFrame(idAt(w, sx + ax * width, by + j, sz + az * width)) then
					ok = false
					break
				end
			end
		end
		if not ok then
			continue
		end
		local changes: { number } = {}
		for i = 0, width - 1 do
			for j = 0, height - 1 do
				local n = #changes
				changes[n + 1], changes[n + 2], changes[n + 3], changes[n + 4] = sx + ax * i, by + j, sz + az * i, PORTAL * 16 + axis
			end
		end
		World.setStates(w, changes) -- all at once: each cell is only supported by its neighbours
		return true
	end
	return false
end

-- A portal block needs portal/obsidian above, below and along its axis.
function Portals.supported(w: World.World, x: number, y: number, z: number, meta: number): boolean
	local ax, az = if meta == 2 then 0 else 1, if meta == 2 then 1 else 0
	local function ok(id: number): boolean
		return id == PORTAL or id == OBSIDIAN
	end
	return ok(idAt(w, x, y + 1, z)) and ok(idAt(w, x, y - 1, z)) and ok(idAt(w, x + ax, y, z + az)) and ok(idAt(w, x - ax, y, z - az))
end

-- Nearest portal block (lowest cell of its column) within `radius` of (x, z).
function Portals.find(w: World.World, x: number, z: number, radius: number, maxY: number): (number?, number?, number?)
	local best, bx, by, bz = math.huge, nil, nil, nil
	for dz = -radius, radius do
		for dx = -radius, radius do
			local cx, cz = x + dx, z + dz
			if not World.isLoaded(w, cx, cz) then
				continue
			end
			for y = 1, maxY do
				if idAt(w, cx, y, cz) == PORTAL and idAt(w, cx, y - 1, cz) ~= PORTAL then
					local d = dx * dx + dz * dz
					if d < best then
						best, bx, by, bz = d, cx, y, cz
					end
					break
				end
			end
		end
	end
	return bx, by, bz
end

-- Builds a 2x3 portal with a frame and a small obsidian platform at the best
-- free spot near (x, z), carving space if needed. Returns the interior bottom cell.
function Portals.create(w: World.World, x: number, z: number, minY: number, maxY: number): (number, number, number)
	local y = nil
	for ty = minY, maxY - 5 do
		local solidBelow = BlockRegistry.isSolid(idAt(w, x, ty - 1, z)) and BlockRegistry.isSolid(idAt(w, x + 1, ty - 1, z))
		local free = true
		for j = 0, 3 do
			for i = -1, 2 do
				if idAt(w, x + i, ty + j, z) ~= 0 then
					free = false
				end
			end
		end
		if solidBelow and free then
			y = ty
			break
		end
	end
	local py = y or math.floor((minY + maxY) / 2)
	-- platform and clearance
	for i = -1, 2 do
		for k = -1, 1 do
			World.setState(w, x + i, py - 1, z + k, OBSIDIAN * 16)
			for j = 0, 3 do
				World.setState(w, x + i, py + j, z + k, 0)
			end
		end
	end
	-- frame (x axis) and portal
	for i = -1, 2 do
		World.setState(w, x + i, py - 1, z, OBSIDIAN * 16)
		World.setState(w, x + i, py + 3, z, OBSIDIAN * 16)
	end
	for j = 0, 2 do
		World.setState(w, x - 1, py + j, z, OBSIDIAN * 16)
		World.setState(w, x + 2, py + j, z, OBSIDIAN * 16)
	end
	local changes: { number } = {}
	for i = 0, 1 do
		for j = 0, 2 do
			local n = #changes
			changes[n + 1], changes[n + 2], changes[n + 3], changes[n + 4] = x + i, py + j, z, PORTAL * 16 + 1
		end
	end
	World.setStates(w, changes)
	return x, py, z
end

return Portals
