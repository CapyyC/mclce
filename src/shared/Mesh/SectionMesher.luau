--!strict
--!native
-- Converts one 16^3 section into render-neutral quad data.
--
-- * Only faces adjacent to a non-occluding neighbour are emitted.
-- * Coplanar faces with the same texture/layer are merged greedily (optional:
--   atlas-based renderers that cannot tile UVs pass greedy = false).
-- * Non-cubic blocks (plants, torches, slabs...) are emitted into `specials`
--   for a shape-specific render path.
--
-- Quad record (stride QUAD_STRIDE in `quads`):
--   face, n, u, v, w, h, tex, layer
-- where n is the section-local slice along the face normal, (u, v) the
-- section-local origin in the face plane and (w, h) its extent.
--   faces 0/1 (+X/-X): n = x, u = z, v = y
--   faces 2/3 (+Y/-Y): n = y, u = x, v = z
--   faces 4/5 (+Z/-Z): n = z, u = x, v = y
-- The geometric plane of a positive face is n + 1, of a negative face n.

local BlockRegistry = require("../Blocks/BlockRegistry")
local TextureIndex = require("./TextureIndex")
local Padded = require("./Padded")

export type ChunkSource = Padded.ChunkSource

export type MeshData = {
	quads: { number },
	quadCount: number,
	-- x, y, z, state per special block
	specials: { number },
	specialCount: number,
	-- work counters for instrumentation
	visibleFaces: number,
	solidCells: number,
}

local SectionMesher = {}
SectionMesher.QUAD_STRIDE = 8

local layerArr = BlockRegistry._layer
local fullCube = BlockRegistry._fullCube
local cullSameArr = BlockRegistry._cullSame
local faceTex = TextureIndex._faceTex
local stateTex = TextureIndex._stateTex

local PAD = Padded.new()
local MASK: { number } = table.create(256, 0)

-- Offsets in padded index space for faces 0..5.
local NEIGHBOUR = { [0] = 1, -1, 324, -324, 18, -18 }

local isCubeLike: { boolean } = table.create(4096, false)
local occl: { boolean } = table.create(4096, false)
local group: { number } = table.create(4096, 0)
for id = 0, 4095 do
	local i = id + 1
	isCubeLike[i] = fullCube[i] == true or BlockRegistry.isLiquid(id)
	occl[i] = BlockRegistry.occludes(id)
	group[i] = BlockRegistry.fluidGroup(id)
end

local function faceVisible(id: number, nid: number): boolean
	if occl[nid + 1] then
		return false
	end
	if cullSameArr[id + 1] and group[id + 1] == group[nid + 1] then
		return false
	end
	return true
end
SectionMesher.faceVisible = faceVisible

-- padded index of cell (n, u, v) for each face orientation
local function cellIndex(face: number, n: number, u: number, v: number): number
	if face <= 1 then
		return (n + 1) + (u + 1) * 18 + (v + 1) * 324
	elseif face <= 3 then
		return (u + 1) + (v + 1) * 18 + (n + 1) * 324
	else
		return (u + 1) + (n + 1) * 18 + (v + 1) * 324
	end
end

function SectionMesher.meshPadded(pad: buffer, greedy: boolean): MeshData
	local quads: { number } = {}
	local specials: { number } = {}
	local quadCount, specialCount, visible, solid = 0, 0, 0, 0
	local nq = 0

	-- specials pass
	for y = 0, 15 do
		for z = 0, 15 do
			local row = (z + 1) * 18 + (y + 1) * 324 + 1
			for x = 0, 15 do
				local st = buffer.readu16(pad, (row + x) * 2)
				if st ~= 0 then
					local id = st // 16
					if layerArr[id + 1] ~= 0 then
						if isCubeLike[id + 1] then
							solid += 1
						else
							specials[specialCount * 4 + 1] = x
							specials[specialCount * 4 + 2] = y
							specials[specialCount * 4 + 3] = z
							specials[specialCount * 4 + 4] = st
							specialCount += 1
						end
					end
				end
			end
		end
	end

	if solid > 0 then
		for face = 0, 5 do
			local off = NEIGHBOUR[face]
			for n = 0, 15 do
				-- build mask
				local any = false
				for v = 0, 15 do
					for u = 0, 15 do
						local pi = cellIndex(face, n, u, v)
						local st = buffer.readu16(pad, pi * 2)
						local key = 0
						if st ~= 0 then
							local id = st // 16
							if isCubeLike[id + 1] and layerArr[id + 1] ~= 0 then
								local nid = buffer.readu16(pad, (pi + off) * 2) // 16
								if faceVisible(id, nid) then
									key = (stateTex[st + 1] or faceTex[id * 6 + face + 1]) * 4 + layerArr[id + 1]
									visible += 1
									any = true
								end
							end
						end
						MASK[u + v * 16 + 1] = key
					end
				end
				if not any then
					continue
				end
				-- emit quads
				for v = 0, 15 do
					local u = 0
					while u < 16 do
						local key = MASK[u + v * 16 + 1]
						if key == 0 then
							u += 1
							continue
						end
						local w = 1
						if greedy then
							while u + w < 16 and MASK[u + w + v * 16 + 1] == key do
								w += 1
							end
						end
						local h = 1
						if greedy then
							while v + h < 16 do
								local ok = true
								local base = (v + h) * 16 + 1
								for k = u, u + w - 1 do
									if MASK[k + base] ~= key then
										ok = false
										break
									end
								end
								if not ok then
									break
								end
								h += 1
							end
						end
						for dv = 0, h - 1 do
							local base = (v + dv) * 16 + 1
							for k = u, u + w - 1 do
								MASK[k + base] = 0
							end
						end
						quads[nq + 1] = face
						quads[nq + 2] = n
						quads[nq + 3] = u
						quads[nq + 4] = v
						quads[nq + 5] = w
						quads[nq + 6] = h
						quads[nq + 7] = key // 4
						quads[nq + 8] = key % 4
						nq += 8
						quadCount += 1
						u += w
					end
				end
			end
		end
	end

	return {
		quads = quads,
		quadCount = quadCount,
		specials = specials,
		specialCount = specialCount,
		visibleFaces = visible,
		solidCells = solid,
	}
end

-- Meshes section si of chunk (cx, cz). Not re-entrant (shared scratch buffer).
function SectionMesher.mesh(source: ChunkSource, cx: number, cz: number, si: number, greedy: boolean?): MeshData
	Padded.gather(source, cx, cz, si, PAD)
	return SectionMesher.meshPadded(PAD, greedy ~= false)
end

SectionMesher._pad = PAD

return SectionMesher
