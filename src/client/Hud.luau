--!nonstrict
-- Minimal HUD: crosshair, 9-slot hotbar with counts, block-break progress and
-- a debug line. Legacy Console styling (textures, fonts, tooltips) is TODO.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local ItemRegistry = require(Shared.Items.ItemRegistry)
local BlockRegistry = require(Shared.Blocks.BlockRegistry)

local Hud = {}
Hud.__index = Hud

local function label(parent, name, text, size, pos, anchor)
	local l = Instance.new("TextLabel")
	l.Name = name
	l.BackgroundTransparency = 1
	l.Text = text
	l.TextColor3 = Color3.new(1, 1, 1)
	l.TextStrokeTransparency = 0.3
	l.Font = Enum.Font.Arcade
	l.TextScaled = true
	l.Size = size
	l.Position = pos
	l.AnchorPoint = anchor or Vector2.new(0, 0)
	l.Parent = parent
	return l
end

function Hud.new(playerGui: PlayerGui)
	local self = setmetatable({}, Hud)
	local gui = Instance.new("ScreenGui")
	gui.Name = "mclceHud"
	gui.IgnoreGuiInset = true
	gui.ResetOnSpawn = false
	gui.Parent = playerGui
	self.gui = gui
	label(gui, "Crosshair", "+", UDim2.fromOffset(24, 24), UDim2.fromScale(0.5, 0.5), Vector2.new(0.5, 0.5))
	local bar = Instance.new("Frame")
	bar.Name = "Hotbar"
	bar.AnchorPoint = Vector2.new(0.5, 1)
	bar.Position = UDim2.new(0.5, 0, 1, -12)
	bar.Size = UDim2.fromOffset(9 * 52, 52)
	bar.BackgroundTransparency = 1
	bar.Parent = gui
	self.slots = {}
	for i = 1, 9 do
		local f = Instance.new("Frame")
		f.Name = "Slot" .. i
		f.Size = UDim2.fromOffset(48, 48)
		f.Position = UDim2.fromOffset((i - 1) * 52 + 2, 2)
		f.BackgroundColor3 = Color3.fromRGB(40, 40, 40)
		f.BackgroundTransparency = 0.35
		f.BorderSizePixel = 0
		f.Parent = bar
		local stroke = Instance.new("UIStroke")
		stroke.Thickness = 2
		stroke.Color = Color3.fromRGB(120, 120, 120)
		stroke.Parent = f
		local swatch = Instance.new("Frame")
		swatch.Name = "Swatch"
		swatch.Size = UDim2.fromScale(0.6, 0.6)
		swatch.Position = UDim2.fromScale(0.2, 0.12)
		swatch.BorderSizePixel = 0
		swatch.Visible = false
		swatch.Parent = f
		local count = label(f, "Count", "", UDim2.fromScale(0.5, 0.4), UDim2.fromScale(1, 1), Vector2.new(1, 1))
		local name = label(f, "Name", "", UDim2.fromScale(1, 0.3), UDim2.fromScale(0, 0.7))
		self.slots[i] = { frame = f, stroke = stroke, swatch = swatch, count = count, name = name }
	end
	local prog = Instance.new("Frame")
	prog.Name = "BreakProgress"
	prog.AnchorPoint = Vector2.new(0.5, 0)
	prog.Position = UDim2.new(0.5, 0, 0.5, 20)
	prog.Size = UDim2.fromOffset(0, 6)
	prog.BackgroundColor3 = Color3.new(1, 1, 1)
	prog.BorderSizePixel = 0
	prog.Parent = gui
	self.progress = prog
	self.debug = label(gui, "Debug", "", UDim2.fromOffset(600, 18), UDim2.fromOffset(8, 8))
	self.debug.TextXAlignment = Enum.TextXAlignment.Left
	return self
end

function Hud:update(inventory, progress: number, debugText: string)
	for i = 1, 9 do
		local s = inventory.slots[i]
		local ui = self.slots[i]
		ui.stroke.Color = if i == inventory.selected then Color3.new(1, 1, 1) else Color3.fromRGB(120, 120, 120)
		ui.stroke.Thickness = if i == inventory.selected then 3 else 2
		if s then
			local def = ItemRegistry.get(s.id)
			local block = def and def.block and BlockRegistry.get(def.block)
			ui.swatch.Visible = true
			ui.swatch.BackgroundColor3 = if block then Color3.fromRGB(block.color[1], block.color[2], block.color[3]) else Color3.fromRGB(200, 200, 200)
			ui.count.Text = if s.count > 1 then tostring(s.count) else ""
			ui.name.Text = def and def.name or ("#" .. s.id)
		else
			ui.swatch.Visible = false
			ui.count.Text = ""
			ui.name.Text = ""
		end
	end
	self.progress.Size = UDim2.fromOffset(math.floor(progress * 120), 6)
	self.debug.Text = debugText
end

return Hud
