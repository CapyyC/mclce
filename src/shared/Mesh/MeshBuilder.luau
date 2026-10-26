--!strict
--!native
-- Turns SectionMesher quads into triangle-mesh arrays for a runtime mesh
-- (Roblox EditableMesh). Engine-independent and allocation-light.
--
-- Output per batch (split so no batch exceeds maxTriangles / maxVertices):
--   positions: flat x, y, z (section-local block units, 0..16)
--   colors:    flat r, g, b (0..1) per vertex = block colour * face shade
--   uvs:       flat u, v per vertex (atlas tile rect when an atlas is given,
--              else 0..1 per quad)
--   tris:      flat vertex indices (1-based), 2 triangles per quad
--   normals:   one face index (0..5) per triangle
-- Classic directional face shading: top 1.0, bottom 0.5, north/south 0.8,
-- east/west 0.6. Winding is counter-clockwise when viewed from outside the
-- face (configurable for engines with the opposite convention).

local BlockRegistry = require("../Blocks/BlockRegistry")
local TextureIndex = require("./TextureIndex")
local SectionMesher = require("./SectionMesher")
local Colors = require("../Blocks/Colors")

export type Batch = {
	positions: { number },
	colors: { number },
	uvs: { number },
	tris: { number },
	faces: { number },
	vertexCount: number,
	triangleCount: number,
	layer: number,
}

export type Options = {
	maxTriangles: number?,
	maxVertices: number?,
	clockwise: boolean?,
	atlasColumns: number?, -- tiles per atlas row (enables atlas UVs)
	layers: { number }?, -- which render layers to include (default all)
}

local MeshBuilder = {}

MeshBuilder.SHADE = { [0] = 0.6, 0.6, 1.0, 0.5, 0.8, 0.8 }

-- block colour per texture index (first block using that texture wins)
local texColor: { [number]: { number } } = {}
for _, def in BlockRegistry.all() do
	for face = 0, 5 do
		local t = TextureIndex.forFace(def.id, face)
		if t > 0 and texColor[t] == nil then
			texColor[t] = def.color
		end
	end
end
-- grass tops render tinted green, sides keep the dirt-ish colour
do
	local top = TextureIndex.indexOf("grass_top")
	local side = TextureIndex.indexOf("grass_side")
	if top then
		texColor[top] = { 95, 159, 53 }
	end
	if side then
		texColor[side] = { 120, 110, 70 }
	end
end

-- The 4 corners of a quad as flat x,y,z, ordered counter-clockwise seen from
-- outside (right-hand rule normal = face direction), plus each corner's
-- (du, dv) offset in the face plane for UV mapping.
local function corners(face: number, n: number, u: number, v: number, w: number, h: number): ({ number }, { number })
	if face == 0 then -- +X at x = n+1; plane (u = z, v = y)
		local x = n + 1
		return { x, v, u, x, v + h, u, x, v + h, u + w, x, v, u + w }, { 0, 0, 0, h, w, h, w, 0 }
	elseif face == 1 then -- -X at x = n
		local x = n
		return { x, v, u, x, v, u + w, x, v + h, u + w, x, v + h, u }, { 0, 0, w, 0, w, h, 0, h }
	elseif face == 2 then -- +Y at y = n+1; plane (u = x, v = z)
		local y = n + 1
		return { u, y, v, u, y, v + h, u + w, y, v + h, u + w, y, v }, { 0, 0, 0, h, w, h, w, 0 }
	elseif face == 3 then -- -Y at y = n
		local y = n
		return { u, y, v, u + w, y, v, u + w, y, v + h, u, y, v + h }, { 0, 0, w, 0, w, h, 0, h }
	elseif face == 4 then -- +Z at z = n+1; plane (u = x, v = y)
		local z = n + 1
		return { u, v, z, u + w, v, z, u + w, v + h, z, u, v + h, z }, { 0, 0, w, 0, w, h, 0, h }
	else -- -Z at z = n
		local z = n
		return { u, v, z, u, v + h, z, u + w, v + h, z, u + w, v, z }, { 0, 0, 0, h, w, h, w, 0 }
	end
end
MeshBuilder._corners = corners

local function newBatch(layer: number): Batch
	return { positions = {}, colors = {}, uvs = {}, tris = {}, faces = {}, vertexCount = 0, triangleCount = 0, layer = layer }
end

function MeshBuilder.build(mesh: SectionMesher.MeshData, opts: Options?): { Batch }
	local o: Options = opts or {}
	local maxT = o.maxTriangles or 20000
	local maxV = o.maxVertices or 60000
	local cw = o.clockwise == true
	local cols = o.atlasColumns
	local wantLayer: { [number]: boolean }? = nil
	if o.layers then
		wantLayer = {}
		for _, l in o.layers do
			(wantLayer :: any)[l] = true
		end
	end
	local batches: { Batch } = {}
	local current: { [number]: Batch } = {}
	local q = mesh.quads
	local S = SectionMesher.QUAD_STRIDE
	for i = 0, mesh.quadCount - 1 do
		local base = i * S
		local face, n, u, v, w, h, tex, layer = q[base + 1], q[base + 2], q[base + 3], q[base + 4], q[base + 5], q[base + 6], q[base + 7], q[base + 8]
		if wantLayer and not wantLayer[layer] then
			continue
		end
		local b = current[layer]
		if b == nil or b.triangleCount + 2 > maxT or b.vertexCount + 4 > maxV then
			b = newBatch(layer)
			current[layer] = b
			table.insert(batches, b)
		end
		assert(b)
		local c, plane = corners(face, n, u, v, w, h)
		local cs = TextureIndex.coloredState(tex)
		local col = if cs then Colors.forState(cs) else (texColor[tex] or { 255, 0, 255 })
		local shade = MeshBuilder.SHADE[face]
		local r, g, bl = col[1] / 255 * shade, col[2] / 255 * shade, col[3] / 255 * shade
		-- image v grows downward, so plane-v (up) maps to 1 - v
		local tu0, tv0, tsz = 0, 0, 1
		if cols then
			local tile = tex - 1
			tu0, tv0, tsz = (tile % cols) / cols, (tile // cols) / cols, 1 / cols
		end
		local first = b.vertexCount + 1
		for k = 0, 3 do
			local p = b.positions
			local np = #p
			p[np + 1], p[np + 2], p[np + 3] = c[k * 3 + 1], c[k * 3 + 2], c[k * 3 + 3]
			local cc = b.colors
			local nc = #cc
			cc[nc + 1], cc[nc + 2], cc[nc + 3] = r, g, bl
			local uu = b.uvs
			local nu = #uu
			local du, dv = plane[k * 2 + 1], plane[k * 2 + 2]
			if cols then
				-- atlas tiles cannot repeat: non-greedy quads (w = h = 1) map 1:1
				uu[nu + 1], uu[nu + 2] = tu0 + du / w * tsz, tv0 + (1 - dv / h) * tsz
			else
				uu[nu + 1], uu[nu + 2] = du, h - dv
			end
		end
		b.vertexCount += 4
		local t = b.tris
		local nt = #t
		if cw then
			t[nt + 1], t[nt + 2], t[nt + 3] = first, first + 2, first + 1
			t[nt + 4], t[nt + 5], t[nt + 6] = first, first + 3, first + 2
		else
			t[nt + 1], t[nt + 2], t[nt + 3] = first, first + 1, first + 2
			t[nt + 4], t[nt + 5], t[nt + 6] = first, first + 2, first + 3
		end
		b.faces[#b.faces + 1] = face
		b.faces[#b.faces + 1] = face
		b.triangleCount += 2
	end
	return batches
end

return MeshBuilder
