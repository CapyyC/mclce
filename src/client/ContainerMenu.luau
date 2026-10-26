--!nonstrict
-- Functional container screen (chest 27 slots / furnace input-fuel-output)
-- above the player's 36 inventory slots. Clicking sends validated requests;
-- the server's snapshot is the only source of truth for what is shown.
-- Legacy Console layout/art is TODO (see ROADMAP "Legacy UI").

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local ItemRegistry = require(Shared.Items.ItemRegistry)

local ContainerMenu = {}
ContainerMenu.__index = ContainerMenu

local function itemText(s): string
	if s == nil then
		return ""
	end
	local id, count = s[1] or s.id, s[3] or s.count
	local def = ItemRegistry.get(id)
	local name = def and def.name or ("#" .. tostring(id))
	return if count and count > 1 then name .. " x" .. count else name
end

function ContainerMenu.new(playerGui: PlayerGui, onContainerClick, onInventoryClick)
	local self = setmetatable({}, ContainerMenu)
	local gui = Instance.new("ScreenGui")
	gui.Name = "mclceContainer"
	gui.Enabled = false
	gui.ResetOnSpawn = false
	gui.Parent = playerGui
	local frame = Instance.new("Frame")
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	frame.Position = UDim2.fromScale(0.5, 0.5)
	frame.Size = UDim2.fromOffset(9 * 70 + 20, 8 * 40 + 60)
	frame.BackgroundColor3 = Color3.fromRGB(198, 198, 198)
	frame.Parent = gui
	self.title = Instance.new("TextLabel")
	self.title.Size = UDim2.new(1, 0, 0, 24)
	self.title.BackgroundTransparency = 1
	self.title.Font = Enum.Font.Arcade
	self.title.TextScaled = true
	self.title.Text = ""
	self.title.Parent = frame
	self.gui, self.frame = gui, frame
	self.containerButtons, self.inventoryButtons = {}, {}
	local function button(x, y, onClick)
		local b = Instance.new("TextButton")
		b.Size = UDim2.fromOffset(66, 36)
		b.Position = UDim2.fromOffset(10 + x * 70, 30 + y * 40)
		b.Font = Enum.Font.Arcade
		b.TextScaled = true
		b.Text = ""
		b.Parent = frame
		b.Activated:Connect(function()
			onClick("left")
		end)
		b.MouseButton2Click:Connect(function()
			onClick("right")
		end)
		return b
	end
	for i = 1, 27 do
		self.containerButtons[i] = button((i - 1) % 9, (i - 1) // 9, function(btn)
			onContainerClick(i, btn)
		end)
	end
	-- inventory: storage rows 10..36 then hotbar 1..9
	for i = 1, 36 do
		local row = if i <= 9 then 7 else 4 + (i - 10) // 9
		local col = if i <= 9 then i - 1 else (i - 10) % 9
		self.inventoryButtons[i] = button(col, row, function(btn)
			onInventoryClick(i, btn)
		end)
	end
	return self
end

function ContainerMenu:isOpen(): boolean
	return self.gui.Enabled
end

function ContainerMenu:render(container, inventory)
	if container == nil then
		self.gui.Enabled = false
		return
	end
	self.gui.Enabled = true
	local st = container.state
	local size = if st.kind == "chest" then 27 else 3
	local labels = { "input", "fuel", "output" }
	for i = 1, 27 do
		local b = self.containerButtons[i]
		b.Visible = i <= size
		if i <= size then
			local text = itemText(st.slots[tostring(i)])
			if st.kind == "furnace" and text == "" then
				text = "(" .. labels[i] .. ")"
			end
			b.Text = text
		end
	end
	if st.kind == "furnace" then
		self.title.Text = string.format("Furnace  burn %d/%d  cook %d/200", st.burn, st.burnTotal, st.cook)
	else
		self.title.Text = "Chest"
	end
	for i = 1, 36 do
		self.inventoryButtons[i].Text = itemText(inventory.slots[i])
	end
	if inventory.cursor then
		self.title.Text ..= "   [holding " .. itemText(inventory.cursor) .. "]"
	end
end

return ContainerMenu
