--!nonstrict
-- EditableMesh renderer (opt-in, UNVERIFIED in Studio): one MeshPart per
-- section and render layer built from Shared.Mesh.MeshBuilder, plus invisible
-- greedy-box Parts for collision (ChunkRenderer in collisionOnly mode).
-- Any EditableMesh failure (API unavailable, memory budget) falls that section
-- back to the Part renderer, so the world always renders.

local AssetService = game:GetService("AssetService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local SectionMesher = require(Shared.Mesh.SectionMesher)
local MeshBuilder = require(Shared.Mesh.MeshBuilder)
local WorldSource = require(Shared.Mesh.WorldSource)
local RemeshQueue = require(Shared.Streaming.RemeshQueue)
local World = require(Shared.Voxel.World)
local ChunkRenderer = require(script.Parent.ChunkRenderer)

local BS = Config.BLOCK_SIZE
-- Collision boxes are only needed where the local character can touch them.
local COLLISION_RADIUS = 2 -- chunks

local MeshRenderer = {}
MeshRenderer.__index = MeshRenderer

function MeshRenderer.new(cw, parent: Instance)
	local self = setmetatable({}, MeshRenderer)
	self.cw = cw
	self.root = Instance.new("Folder")
	self.root.Name = "mclceMeshWorld"
	self.root.Parent = parent
	self.collision = ChunkRenderer.new(cw, parent, { collisionOnly = true })
	self.fallback = ChunkRenderer.new(cw, parent)
	self.fallback.root.Name = "mclceFallbackWorld"
	self.sections = {}
	self.failures = 0
	self.colBuilt = {} -- section key -> true when collision boxes exist
	self.focusCx, self.focusCz = math.huge, math.huge
	self.stats = { sectionsBuilt = 0, parts = 0, lastBuildMs = 0, meshes = 0, fallbacks = 0, triangles = 0 }
	return self
end

local function buildMeshPart(batch, origin: Vector3): MeshPart?
	local ok, result = pcall(function()
		local em = AssetService:CreateEditableMesh()
		local P, C, U, T = batch.positions, batch.colors, batch.uvs, batch.tris
		local minX, minY, minZ = math.huge, math.huge, math.huge
		local maxX, maxY, maxZ = -math.huge, -math.huge, -math.huge
		for i = 1, #P, 3 do
			minX, maxX = math.min(minX, P[i]), math.max(maxX, P[i])
			minY, maxY = math.min(minY, P[i + 1]), math.max(maxY, P[i + 1])
			minZ, maxZ = math.min(minZ, P[i + 2]), math.max(maxZ, P[i + 2])
		end
		local cx, cy, cz = (minX + maxX) / 2, (minY + maxY) / 2, (minZ + maxZ) / 2
		local verts, colors, uvs = table.create(batch.vertexCount), table.create(batch.vertexCount), table.create(batch.vertexCount)
		for v = 0, batch.vertexCount - 1 do
			-- vertices relative to the bounds centre (MeshPart is centred on its mesh)
			verts[v + 1] = em:AddVertex(Vector3.new((P[v * 3 + 1] - cx) * BS, (P[v * 3 + 2] - cy) * BS, (P[v * 3 + 3] - cz) * BS))
			colors[v + 1] = em:AddColor(Color3.new(C[v * 3 + 1], C[v * 3 + 2], C[v * 3 + 3]), 1)
			uvs[v + 1] = em:AddUV(Vector2.new(U[v * 2 + 1], U[v * 2 + 2]))
		end
		for t = 0, batch.triangleCount - 1 do
			local a, b, c = T[t * 3 + 1], T[t * 3 + 2], T[t * 3 + 3]
			local f = em:AddTriangle(verts[a], verts[b], verts[c])
			em:SetFaceColors(f, { colors[a], colors[b], colors[c] })
			em:SetFaceUVs(f, { uvs[a], uvs[b], uvs[c] })
		end
		local mp = AssetService:CreateMeshPartAsync(Content.fromObject(em))
		mp.Anchored = true
		mp.CanCollide = false
		mp.CanQuery = false
		mp.CanTouch = false
		mp.CFrame = CFrame.new(origin.X + cx * BS, origin.Y + cy * BS, origin.Z + cz * BS)
		if batch.layer == 3 then
			mp.Transparency = 0.4
		end
		if Config.ATLAS_ASSET ~= "" then
			mp.TextureID = Config.ATLAS_ASSET
		end
		return mp
	end)
	if ok then
		return result
	end
	warn("[mclce] EditableMesh failed, using Part fallback: " .. tostring(result))
	return nil
end

function MeshRenderer:dropSection(key: number)
	local s = self.sections[key]
	if s then
		for _, mp in s.meshes do
			mp:Destroy()
		end
		self.sections[key] = nil
	end
	self.collision:dropSection(key)
	self.colBuilt[key] = nil
	self.fallback:dropSection(key)
end

function MeshRenderer:dropAll()
	local keys = {}
	for k in self.sections do
		table.insert(keys, k)
	end
	for _, k in keys do
		self:dropSection(k)
	end
	self.collision:dropAll()
	self.fallback:dropAll()
end

function MeshRenderer:dropChunk(cx: number, cz: number)
	for si = 0, 15 do
		self:dropSection(RemeshQueue.sectionKey(cx, cz, si))
	end
end

function MeshRenderer:buildSection(cx: number, cz: number, si: number)
	local t0 = os.clock()
	local key = RemeshQueue.sectionKey(cx, cz, si)
	local world = self.cw.world
	if World.getChunk(world, cx, cz) == nil then
		self:dropSection(key)
		return
	end
	if self.failures >= 3 then
		-- EditableMesh unavailable on this device: stay on Parts for good
		self.fallback:buildSection(cx, cz, si)
		self.stats.sectionsBuilt += 1
		self.stats.parts = self.fallback.stats.parts
		return
	end
	local textured = Config.ATLAS_ASSET ~= ""
	local mesh = SectionMesher.mesh(WorldSource.new(world), cx, cz, si, not textured)
	local batches = MeshBuilder.build(mesh, { clockwise = Config.MESH_CLOCKWISE, atlasColumns = if textured then Config.ATLAS_COLUMNS else nil })
	local origin = Vector3.new(cx * 16 * BS, si * 16 * BS, cz * 16 * BS)
	local meshes = {}
	local failed = false
	for _, b in batches do
		local mp = buildMeshPart(b, origin)
		if mp == nil then
			failed = true
			break
		end
		mp.Parent = self.root
		table.insert(meshes, mp)
		self.stats.triangles += b.triangleCount
	end
	local old = self.sections[key]
	if old then
		for _, mp in old.meshes do
			mp:Destroy()
		end
	end
	if failed then
		for _, mp in meshes do
			mp:Destroy()
		end
		meshes = {}
		self.failures += 1
		self.stats.fallbacks += 1
		self.fallback:buildSection(cx, cz, si)
	else
		self.fallback:dropSection(key)
		if math.max(math.abs(cx - self.focusCx), math.abs(cz - self.focusCz)) <= COLLISION_RADIUS then
			self.collision:buildSection(cx, cz, si)
			self.colBuilt[key] = true
		else
			self.collision:dropSection(key)
			self.colBuilt[key] = nil
		end
	end
	self.sections[key] = { meshes = meshes }
	self.stats.meshes += #meshes
	self.stats.sectionsBuilt += 1
	self.stats.parts = self.collision.stats.parts + self.fallback.stats.parts
	self.stats.lastBuildMs = (os.clock() - t0) * 1000
end

-- Adds collision near the focus chunk and drops it elsewhere (bounded work).
function MeshRenderer:_updateCollision(fcx: number, fcz: number, budget: number)
	local done = 0
	for key, s in self.sections do
		if done >= budget then
			break
		end
		if #s.meshes == 0 then
			continue -- fallback Parts already collide
		end
		local cx, cz, si = RemeshQueue.unpack(key)
		local near = math.max(math.abs(cx - fcx), math.abs(cz - fcz)) <= COLLISION_RADIUS
		if near and not self.colBuilt[key] then
			self.collision:buildSection(cx, cz, si)
			self.colBuilt[key] = true
			done += 1
		elseif not near and self.colBuilt[key] then
			self.collision:dropSection(key)
			self.colBuilt[key] = nil
			done += 1
		end
	end
	return done
end

function MeshRenderer:step(budget: number, focusBlock: Vector3)
	local cw = self.cw
	local fcx, fcz, fsi = math.floor(focusBlock.X) // 16, math.floor(focusBlock.Z) // 16, math.clamp(math.floor(focusBlock.Y) // 16, 0, 15)
	if fcx ~= self.focusCx or fcz ~= self.focusCz or self.collisionPending then
		self.focusCx, self.focusCz = fcx, fcz
		self.collisionPending = self:_updateCollision(fcx, fcz, 16) >= 16
	end
	local keys = RemeshQueue.pop(cw.remesh, budget, fcx, fcz, fsi, function(cx, cz)
		return World.getChunk(cw.world, cx, cz) ~= nil
	end)
	for _, k in keys do
		local cx, cz, si = RemeshQueue.unpack(k)
		self:buildSection(cx, cz, si)
	end
	return #keys
end

return MeshRenderer
