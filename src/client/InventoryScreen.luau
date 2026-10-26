--!nonstrict
-- Legacy-style player inventory screen: armour column, 27 storage slots and
-- the hotbar, navigated with the D-pad (FocusGrid) or clicked with the mouse.
-- A / Enter = take/place stack (left click), X / right click = half / one.
-- Every click is an INV_CLICK request; the server's snapshot is the truth.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local FocusGrid = require(Shared.UI.FocusGrid)
local ItemRegistry = require(Shared.Items.ItemRegistry)

local InventoryScreen = {}
InventoryScreen.__index = InventoryScreen

local SLOT = 56

local function label(s): string
	if s == nil then
		return ""
	end
	local d = ItemRegistry.get(s.id)
	local n = d and d.name or ("#" .. s.id)
	return if s.count > 1 then n .. " x" .. s.count else n
end

function InventoryScreen.new(playerGui: PlayerGui, onClick: (slot: number, button: string) -> ())
	local self = setmetatable({}, InventoryScreen)
	self.grid = FocusGrid.new(FocusGrid.playerLayout())
	FocusGrid.focusId(self.grid, 1)
	self.onClick = onClick
	local gui = Instance.new("ScreenGui")
	gui.Name = "mclceInventory"
	gui.Enabled = false
	gui.ResetOnSpawn = false
	gui.Parent = playerGui
	local frame = Instance.new("Frame")
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	frame.Position = UDim2.fromScale(0.5, 0.5)
	frame.Size = UDim2.fromOffset(9 * (SLOT + 4) + 16, 8 * (SLOT + 4) + 40)
	frame.BackgroundColor3 = Color3.fromRGB(198, 198, 198)
	frame.Parent = gui
	self.cursorLabel = Instance.new("TextLabel")
	self.cursorLabel.Size = UDim2.new(1, 0, 0, 24)
	self.cursorLabel.BackgroundTransparency = 1
	self.cursorLabel.Font = Enum.Font.Arcade
	self.cursorLabel.TextScaled = true
	self.cursorLabel.Text = ""
	self.cursorLabel.Parent = frame
	self.gui, self.buttons = gui, {}
	for i, s in self.grid.slots do
		local b = Instance.new("TextButton")
		b.Name = "Slot" .. tostring(s.id)
		b.Size = UDim2.fromOffset(SLOT, SLOT)
		b.Position = UDim2.fromOffset(8 + s.col * (SLOT + 4), 30 + s.row * (SLOT + 4))
		b.Font = Enum.Font.Arcade
		b.TextScaled = true
		b.TextWrapped = true
		b.Text = ""
		b.BackgroundColor3 = Color3.fromRGB(139, 139, 139)
		b.Parent = frame
		b.Activated:Connect(function()
			self.grid.focus = i
			self.onClick(s.id, "left")
		end)
		b.MouseButton2Click:Connect(function()
			self.grid.focus = i
			self.onClick(s.id, "right")
		end)
		self.buttons[i] = b
	end
	return self
end

function InventoryScreen:setOpen(open: boolean)
	self.gui.Enabled = open
end

-- Menu actions while open: d-pad moves focus, confirm = left click, "crafting"
-- (X) = right click on the focused slot.
function InventoryScreen:action(a: string)
	if a == "up" or a == "down" or a == "left" or a == "right" then
		FocusGrid.move(self.grid, a)
	elseif a == "confirm" then
		local s = FocusGrid.focused(self.grid)
		if s then
			self.onClick(s.id, "left")
		end
	end
end

function InventoryScreen:render(inventory)
	for i, s in self.grid.slots do
		local b = self.buttons[i]
		local st = inventory.slots[s.id]
		local armour = type(s.id) == "number" and s.id >= 37
		b.Text = if st then label(st) else (if armour then ({ "helmet", "chest", "legs", "boots" })[s.id - 36] else "")
		b.BackgroundColor3 = if i == self.grid.focus then Color3.fromRGB(200, 200, 90) else Color3.fromRGB(139, 139, 139)
	end
	self.cursorLabel.Text = if inventory.cursor then "holding " .. label(inventory.cursor) else "Inventory"
end

return InventoryScreen
