--!strict
--!native
-- Decomposes a section into axis-aligned boxes for a Part-based renderer.
--
-- Every cube-like block with at least one visible face must be covered by a
-- box of its own block id. Fully hidden opaque blocks are "wildcards": a box
-- may extend through them (they can never be seen), which lets terrain
-- collapse into far fewer Parts than per-exposed-block rendering.
--
-- Box record (stride BOX_STRIDE): x, y, z, sx, sy, sz, state  (section-local)

local BlockRegistry = require("../Blocks/BlockRegistry")
local Padded = require("./Padded")
local SectionMesher = require("./SectionMesher")

export type BoxData = {
	boxes: { number },
	boxCount: number,
	coveredCells: number,
}

local BoxMesher = {}
BoxMesher.BOX_STRIDE = 7

local PAD = Padded.new()
-- per cell: 0 = empty/ignored, -1 = wildcard, >0 = required state + 1
local NEED: { number } = table.create(4096, 0)
local DONE: { boolean } = table.create(4096, false)

local NEIGHBOUR = { 1, -1, 324, -324, 18, -18 }
local faceVisible = SectionMesher.faceVisible

local cubeLike: { boolean } = table.create(4096, false)
local occl: { boolean } = table.create(4096, false)
for id = 0, 4095 do
	cubeLike[id + 1] = (BlockRegistry.isFullCube(id) or BlockRegistry.isLiquid(id)) and BlockRegistry.layer(id) ~= 0
	occl[id + 1] = BlockRegistry.occludes(id)
end

local function classify(pad: buffer): number
	local required = 0
	for y = 0, 15 do
		for z = 0, 15 do
			for x = 0, 15 do
				local ci = x + z * 16 + y * 256 + 1
				local pi = (x + 1) + (z + 1) * 18 + (y + 1) * 324
				local st = buffer.readu16(pad, pi * 2)
				local id = st // 16
				DONE[ci] = false
				if st == 0 or not cubeLike[id + 1] then
					NEED[ci] = 0
					continue
				end
				local vis = false
				for f = 1, 6 do
					if faceVisible(id, buffer.readu16(pad, (pi + NEIGHBOUR[f]) * 2) // 16) then
						vis = true
						break
					end
				end
				if vis then
					NEED[ci] = st + 1
					required += 1
				elseif occl[id + 1] then
					NEED[ci] = -1
				else
					NEED[ci] = 0
				end
			end
		end
	end
	return required
end

local function fits(key: number, x0: number, x1: number, y0: number, y1: number, z0: number, z1: number): boolean
	for y = y0, y1 do
		for z = z0, z1 do
			local base = z * 16 + y * 256 + 1
			for x = x0, x1 do
				local n = NEED[x + base]
				if n == -1 then
					continue
				end
				if n ~= key or DONE[x + base] then
					return false
				end
			end
		end
	end
	return true
end

function BoxMesher.meshPadded(pad: buffer): BoxData
	local boxes: { number } = {}
	local count = 0
	if classify(pad) == 0 then
		return { boxes = boxes, boxCount = 0, coveredCells = 0 }
	end
	local covered = 0
	for y = 0, 15 do
		for z = 0, 15 do
			for x = 0, 15 do
				local ci = x + z * 16 + y * 256 + 1
				local key = NEED[ci]
				if key <= 0 or DONE[ci] then
					continue
				end
				local x1 = x
				while x1 < 15 and fits(key, x1 + 1, x1 + 1, y, y, z, z) do
					x1 += 1
				end
				local z1 = z
				while z1 < 15 and fits(key, x, x1, y, y, z1 + 1, z1 + 1) do
					z1 += 1
				end
				local y1 = y
				while y1 < 15 and fits(key, x, x1, y1 + 1, y1 + 1, z, z1) do
					y1 += 1
				end
				-- trim wildcard-only borders so boxes don't grow needlessly
				for yy = y, y1 do
					for zz = z, z1 do
						local base = zz * 16 + yy * 256 + 1
						for xx = x, x1 do
							if NEED[xx + base] == key then
								DONE[xx + base] = true
								covered += 1
							end
						end
					end
				end
				local o = count * 7
				boxes[o + 1] = x
				boxes[o + 2] = y
				boxes[o + 3] = z
				boxes[o + 4] = x1 - x + 1
				boxes[o + 5] = y1 - y + 1
				boxes[o + 6] = z1 - z + 1
				boxes[o + 7] = key - 1
				count += 1
			end
		end
	end
	return { boxes = boxes, boxCount = count, coveredCells = covered }
end

function BoxMesher.mesh(source: Padded.ChunkSource, cx: number, cz: number, si: number): BoxData
	Padded.gather(source, cx, cz, si, PAD)
	return BoxMesher.meshPadded(PAD)
end

-- Exposed for tests: classification of the last meshed section.
BoxMesher._need = NEED

return BoxMesher
