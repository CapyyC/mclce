--!nonstrict
-- Simplified Legacy-style crafting screen: a scrolling list of the recipes
-- craftable right now (2x2, or 3x3 when a crafting table is within reach).
-- Selecting one asks the server to craft it; the server re-validates.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Crafting = require(Shared.Items.Crafting)
local ItemRegistry = require(Shared.Items.ItemRegistry)

local CraftingMenu = {}
CraftingMenu.__index = CraftingMenu

function CraftingMenu.new(playerGui: PlayerGui, onCraft: (recipeId: number, grid: number) -> ())
	local self = setmetatable({}, CraftingMenu)
	local gui = Instance.new("ScreenGui")
	gui.Name = "mclceCrafting"
	gui.Enabled = false
	gui.ResetOnSpawn = false
	gui.Parent = playerGui
	local frame = Instance.new("ScrollingFrame")
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	frame.Position = UDim2.fromScale(0.5, 0.5)
	frame.Size = UDim2.fromScale(0.4, 0.6)
	frame.BackgroundColor3 = Color3.fromRGB(198, 198, 198)
	frame.CanvasSize = UDim2.new()
	frame.AutomaticCanvasSize = Enum.AutomaticSize.Y
	frame.Parent = gui
	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 4)
	layout.Parent = frame
	self.gui, self.frame, self.onCraft = gui, frame, onCraft
	self.grid = 2
	return self
end

function CraftingMenu:setOpen(open: boolean)
	self.gui.Enabled = open
end

function CraftingMenu:isOpen(): boolean
	return self.gui.Enabled
end

function CraftingMenu:refresh(inventory, grid: number)
	self.grid = grid
	for _, c in self.frame:GetChildren() do
		if c:IsA("TextButton") then
			c:Destroy()
		end
	end
	for _, r in Crafting.available(inventory, grid) do
		local out = ItemRegistry.get(r.output.id)
		local b = Instance.new("TextButton")
		b.Size = UDim2.new(1, -8, 0, 32)
		b.Font = Enum.Font.Arcade
		b.TextScaled = true
		b.Text = string.format("%s x%d  [%s]", out and out.name or r.name, r.output.count, r.category)
		b.Parent = self.frame
		b.Activated:Connect(function()
			self.onCraft(r.id, grid)
		end)
	end
end

return CraftingMenu
