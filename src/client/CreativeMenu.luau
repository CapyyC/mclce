--!nonstrict
-- Creative item palette (replaces the inventory screen while in creative).
-- Tabs with LB/RB (Q/R), D-pad / arrows move the cursor, A / Enter or a
-- click puts a full stack of the item into the selected hotbar slot. The
-- server only honours CREATIVE_TAKE for creative players.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local CreativeModel = require(Shared.UI.CreativeModel)
local ItemRegistry = require(Shared.Items.ItemRegistry)

local CreativeMenu = {}
CreativeMenu.__index = CreativeMenu

local SLOT = 56
local COLS, ROWS = 9, 5

local function itemName(e): string
	local d = ItemRegistry.get(e.id)
	local n = d and d.name or ("#" .. e.id)
	return if e.meta ~= 0 then n .. ":" .. e.meta else n
end

function CreativeMenu.new(playerGui: PlayerGui, onTake: (id: number, meta: number) -> ())
	local self = setmetatable({}, CreativeMenu)
	self.model = CreativeModel.new()
	self.onTake = onTake
	self.page = 0
	local gui = Instance.new("ScreenGui")
	gui.Name = "mclceCreative"
	gui.Enabled = false
	gui.ResetOnSpawn = false
	gui.Parent = playerGui
	local frame = Instance.new("Frame")
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	frame.Position = UDim2.fromScale(0.5, 0.5)
	frame.Size = UDim2.fromOffset(COLS * (SLOT + 4) + 16, ROWS * (SLOT + 4) + 64)
	frame.BackgroundColor3 = Color3.fromRGB(198, 198, 198)
	frame.Parent = gui
	self.tabLabels = {}
	local tabW = (COLS * (SLOT + 4)) / #self.model.tabs
	for i, t in self.model.tabs do
		local b = Instance.new("TextButton")
		b.Name = "Tab" .. i
		b.Size = UDim2.fromOffset(tabW - 4, 24)
		b.Position = UDim2.fromOffset(8 + (i - 1) * tabW, 4)
		b.Font = Enum.Font.Arcade
		b.TextScaled = true
		b.Text = t.name
		b.BackgroundColor3 = Color3.fromRGB(139, 139, 139)
		b.Parent = frame
		b.Activated:Connect(function()
			self.model.tab, self.model.index = i, 1
			self:render()
		end)
		self.tabLabels[i] = b
	end
	self.title = Instance.new("TextLabel")
	self.title.Size = UDim2.new(1, 0, 0, 24)
	self.title.Position = UDim2.fromOffset(0, ROWS * (SLOT + 4) + 36)
	self.title.BackgroundTransparency = 1
	self.title.Font = Enum.Font.Arcade
	self.title.TextScaled = true
	self.title.Text = ""
	self.title.Parent = frame
	self.gui, self.buttons = gui, {}
	for cell = 1, COLS * ROWS do
		local b = Instance.new("TextButton")
		b.Name = "Cell" .. cell
		b.Size = UDim2.fromOffset(SLOT, SLOT)
		b.Position = UDim2.fromOffset(8 + ((cell - 1) % COLS) * (SLOT + 4), 32 + ((cell - 1) // COLS) * (SLOT + 4))
		b.Font = Enum.Font.Arcade
		b.TextScaled = true
		b.TextWrapped = true
		b.Text = ""
		b.BackgroundColor3 = Color3.fromRGB(139, 139, 139)
		b.Parent = frame
		b.Activated:Connect(function()
			local index = self.page * COLS * ROWS + cell
			if self.model.tabs[self.model.tab].items[index] then
				self.model.index = index
				self:take()
				self:render()
			end
		end)
		self.buttons[cell] = b
	end
	return self
end

function CreativeMenu:setOpen(open: boolean)
	self.gui.Enabled = open
	if open then
		self:render()
	end
end

function CreativeMenu:take()
	local e = CreativeModel.selected(self.model)
	if e then
		self.onTake(e.id, e.meta)
	end
end

-- Menu actions while open; returns true when the action was consumed.
function CreativeMenu:action(a: string): boolean
	if a == "confirm" then
		self:take()
		return true
	end
	if CreativeModel.input(self.model, a) then
		self:render()
		return true
	end
	return a == "up" or a == "down" or a == "left" or a == "right"
end

function CreativeMenu:render()
	local m = self.model
	local items = m.tabs[m.tab].items
	local per = COLS * ROWS
	self.page = (m.index - 1) // per
	for i, l in self.tabLabels do
		l.BackgroundColor3 = if i == m.tab then Color3.fromRGB(200, 200, 90) else Color3.fromRGB(139, 139, 139)
	end
	for cell, b in self.buttons do
		local index = self.page * per + cell
		local e = items[index]
		b.Text = if e then itemName(e) else ""
		b.BackgroundColor3 = if index == m.index and e then Color3.fromRGB(200, 200, 90) else Color3.fromRGB(139, 139, 139)
	end
	local sel = CreativeModel.selected(m)
	local pages = math.max(1, math.ceil(#items / per))
	self.title.Text = string.format("%s  %s  (%d/%d)", m.tabs[m.tab].name, if sel then itemName(sel) else "", self.page + 1, pages)
end

return CreativeMenu
