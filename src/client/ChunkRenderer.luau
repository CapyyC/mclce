--!nonstrict
-- Part-based voxel renderer (fallback renderer, works on every device).
--
-- Each 16^3 section is turned into greedy boxes by Shared.Mesh.BoxMesher and
-- each box becomes one anchored Part (hidden interiors merge across block
-- types, so terrain needs far fewer Parts than blocks). Parts are pooled and
-- reused between rebuilds. Non-cubic blocks (plants, torches) get small
-- non-colliding Parts. Colours/materials come from BlockData; textures are
-- not applied by this renderer (see ADR 0002 for the EditableMesh path).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local BlockRegistry = require(Shared.Blocks.BlockRegistry)
local BoxMesher = require(Shared.Mesh.BoxMesher)
local SectionMesher = require(Shared.Mesh.SectionMesher)
local WorldSource = require(Shared.Mesh.WorldSource)
local RemeshQueue = require(Shared.Streaming.RemeshQueue)
local World = require(Shared.Voxel.World)

local BS = Config.BLOCK_SIZE

local ChunkRenderer = {}
ChunkRenderer.__index = ChunkRenderer

type Style = { color: Color3, material: Enum.Material, transparency: number, collide: boolean }

local styles: { [number]: Style } = {}
local function styleOf(id: number): Style
	local s = styles[id]
	if s then
		return s
	end
	local def = BlockRegistry.get(id)
	local color = if def then Color3.fromRGB(def.color[1], def.color[2], def.color[3]) else Color3.new(1, 0, 1)
	local okMat, mat = pcall(function()
		return Enum.Material[def and def.material or "SmoothPlastic"]
	end)
	local transparency = 0
	if def and def.layer == "translucent" then
		transparency = 0.45
	elseif def and def.name == "glass" then
		transparency = 0.7
	end
	s = {
		color = color,
		material = if okMat then mat else Enum.Material.SmoothPlastic,
		transparency = transparency,
		collide = def ~= nil and def.solid,
	}
	styles[id] = s
	return s
end

-- opts.collisionOnly: invisible boxes for physics only (used under the mesh renderer)
function ChunkRenderer.new(cw, parent: Instance, opts)
	local self = setmetatable({}, ChunkRenderer)
	self.cw = cw
	self.collisionOnly = opts ~= nil and opts.collisionOnly == true
	self.root = Instance.new("Folder")
	self.root.Name = "mclceWorld"
	self.root.Parent = parent
	self.sections = {} -- section key -> { parts = { Part } }
	self.pool = {} -- spare Parts
	self.stats = { sectionsBuilt = 0, parts = 0, lastBuildMs = 0 }
	return self
end

function ChunkRenderer:_take(): Part
	local p = table.remove(self.pool)
	if p then
		return p
	end
	p = Instance.new("Part")
	p.Anchored = true
	p.CanTouch = false
	p.CanQuery = false
	p.CastShadow = true
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	self.stats.parts += 1
	return p
end

function ChunkRenderer:_release(parts: { Part })
	for _, p in parts do
		p.Parent = nil
		table.insert(self.pool, p)
	end
end

function ChunkRenderer:dropSection(key: number)
	local s = self.sections[key]
	if s then
		self:_release(s.parts)
		if s.folder then
			s.folder:Destroy()
		end
		self.sections[key] = nil
	end
end

function ChunkRenderer:dropChunk(cx: number, cz: number)
	for si = 0, 15 do
		self:dropSection(RemeshQueue.sectionKey(cx, cz, si))
	end
end

function ChunkRenderer:buildSection(cx: number, cz: number, si: number)
	local t0 = os.clock()
	local key = RemeshQueue.sectionKey(cx, cz, si)
	local world = self.cw.world
	local chunk = World.getChunk(world, cx, cz)
	if chunk == nil then
		self:dropSection(key)
		return
	end
	local source = WorldSource.new(world)
	local boxes = BoxMesher.mesh(source, cx, cz, si)
	local mesh = SectionMesher.mesh(source, cx, cz, si) -- for specials
	local old = self.sections[key]
	local parts = {}
	local folder = old and old.folder
	if folder == nil then
		folder = Instance.new("Folder")
		folder.Name = cx .. "," .. cz .. "," .. si
	end
	local bx, by, bz = cx * 16, si * 16, cz * 16
	local data = boxes.boxes
	for b = 0, boxes.boxCount - 1 do
		local o = b * BoxMesher.BOX_STRIDE
		local x, y, z, sx, sy, sz, st = data[o + 1], data[o + 2], data[o + 3], data[o + 4], data[o + 5], data[o + 6], data[o + 7]
		local style = styleOf(st // 16)
		if self.collisionOnly and not style.collide then
			continue
		end
		local p = self:_take()
		p.Size = Vector3.new(sx * BS, sy * BS, sz * BS)
		p.CFrame = CFrame.new((bx + x + sx / 2) * BS, (by + y + sy / 2) * BS, (bz + z + sz / 2) * BS)
		p.Color = style.color
		p.Material = style.material
		p.Transparency = if self.collisionOnly then 1 else style.transparency
		p.CastShadow = not self.collisionOnly
		p.CanCollide = style.collide
		p.Parent = folder
		table.insert(parts, p)
	end
	for i = 0, if self.collisionOnly then -1 else mesh.specialCount - 1 do
		local o = i * 4
		local x, y, z, st = mesh.specials[o + 1], mesh.specials[o + 2], mesh.specials[o + 3], mesh.specials[o + 4]
		local id = st // 16
		local def = BlockRegistry.get(id)
		local style = styleOf(id)
		local p = self:_take()
		local shape = def and def.shape or "cross"
		local cxw, cyw, czw = (bx + x + 0.5) * BS, (by + y) * BS, (bz + z + 0.5) * BS
		if shape == "slab" then
			local top = st % 16 >= 8
			p.Size = Vector3.new(BS, BS / 2, BS)
			p.CFrame = CFrame.new(cxw, cyw + (if top then 0.75 else 0.25) * BS, czw)
		elseif shape == "flat" then
			p.Size = Vector3.new(BS, BS / 8, BS)
			p.CFrame = CFrame.new(cxw, cyw + BS / 16, czw)
		elseif shape == "torch" then
			p.Size = Vector3.new(BS / 8, BS * 0.6, BS / 8)
			p.CFrame = CFrame.new(cxw, cyw + 0.3 * BS, czw)
		else
			p.Size = Vector3.new(BS * 0.7, BS * 0.8, BS * 0.05)
			p.CFrame = CFrame.new(cxw, cyw + 0.4 * BS, czw) * CFrame.Angles(0, math.rad(45), 0)
		end
		p.Color = style.color
		p.Material = style.material
		p.Transparency = 0
		p.CanCollide = shape == "slab"
		p.Parent = folder
		table.insert(parts, p)
	end
	if old then
		self:_release(old.parts)
	end
	folder.Parent = if #parts > 0 then self.root else nil
	self.sections[key] = { parts = parts, folder = folder, version = chunk.sectionVersion[si + 1] }
	self.stats.sectionsBuilt += 1
	self.stats.lastBuildMs = (os.clock() - t0) * 1000
end

-- Rebuilds up to `budget` dirty sections nearest to the camera position.
function ChunkRenderer:step(budget: number, focusBlock: Vector3)
	local cw = self.cw
	local fcx, fcz, fsi = math.floor(focusBlock.X) // 16, math.floor(focusBlock.Z) // 16, math.clamp(math.floor(focusBlock.Y) // 16, 0, 15)
	local keys = RemeshQueue.pop(cw.remesh, budget, fcx, fcz, fsi, function(cx, cz)
		return World.getChunk(cw.world, cx, cz) ~= nil
	end)
	for _, k in keys do
		local cx, cz, si = RemeshQueue.unpack(k)
		self:buildSection(cx, cz, si)
	end
	return #keys
end

return ChunkRenderer
