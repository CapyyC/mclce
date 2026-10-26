--!nonstrict
-- Renders replicated mobs as simple coloured box models (body + head) with a
-- red hurt flash. Placeholder art: no textures/animation yet.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local MobTypes = require(Shared.Sim.MobTypes)
local Colors = require(Shared.Blocks.Colors)

local BS = Config.BLOCK_SIZE

local MobRenderer = {}
MobRenderer.__index = MobRenderer

function MobRenderer.new(cw, parent: Instance)
	local self = setmetatable({}, MobRenderer)
	self.cw = cw
	self.folder = Instance.new("Folder")
	self.folder.Name = "mclceMobs"
	self.folder.Parent = parent
	self.models = {}
	return self
end

local function part(name: string, size: Vector3, color: Color3, parent: Instance): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.Color = color
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.Parent = parent
	return p
end

function MobRenderer:update()
	local cw = self.cw
	for id in cw.mobsChanged do
		local m = cw.mobs[id]
		local model = self.models[id]
		if m == nil then
			if model then
				model.folder:Destroy()
				self.models[id] = nil
			end
			continue
		end
		local kind = MobTypes.get(m.type)
		local w = (if kind then kind.width else 0.6) * BS
		local h = (if kind then kind.height else 1.8) * BS
		if model == nil then
			local f = Instance.new("Folder")
			f.Name = (kind and kind.name or "mob") .. "_" .. id
			f.Parent = self.folder
			local c = kind and kind.color or { 255, 0, 255 }
			local color = Color3.fromRGB(c[1], c[2], c[3])
			local isArrow = kind ~= nil and kind.projectile == true
			local body = part("Body", if isArrow then Vector3.new(BS * 0.6, BS * 0.06, BS * 0.06) else Vector3.new(w, h * 0.75, w), color, f)
			local head = part("Head", if isArrow then Vector3.new(BS * 0.1, BS * 0.1, BS * 0.1) else Vector3.new(w * 0.8, h * 0.25, w * 0.8), color, f)
			model = { folder = f, body = body, head = head, color = color, h = h }
			self.models[id] = model
		end
		local rot = CFrame.Angles(0, -m.yaw, 0)
		model.body.CFrame = CFrame.new(m.x * BS, m.y * BS + model.h * 0.375, m.z * BS) * rot
		model.head.CFrame = CFrame.new(m.x * BS, m.y * BS + model.h * 0.875, m.z * BS) * rot
		local hurt = m.hurtAt >= 0 and cw.clock - m.hurtAt < 0.4
		local base = model.color
		if kind and kind.name == "sheep" then
			-- wool colour; sheared sheep show their pale skin
			local c = if m.sheared then { 220, 190, 170 } else Colors.WOOL[m.color]
			base = Color3.fromRGB(c[1], c[2], c[3])
		end
		local col = if hurt then Color3.fromRGB(255, 60, 60) else base
		model.body.Color = col
		model.head.Color = col
		if hurt then
			-- keep re-evaluating until the flash ends
			cw.mobsChanged[id] = true
		end
	end
end

-- Clears the change set except entries flagged to persist this frame.
function MobRenderer:endFrame()
	local keep = {}
	for id in self.cw.mobsChanged do
		local m = self.cw.mobs[id]
		if m and m.hurtAt >= 0 and self.cw.clock - m.hurtAt < 0.4 then
			keep[id] = true
		end
	end
	self.cw.mobsChanged = keep
end

return MobRenderer
