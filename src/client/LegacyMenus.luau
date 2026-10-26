--!nonstrict
-- Legacy Console style menus drawn from the pure UI models:
--  * crafting: category tab bar (LB/RB or Q/R), recipe strip (D-pad / arrows),
--    ingredient panel, A / Enter crafts (server re-validates);
--  * pause: Resume / Settings / How to Play / Save & Quit with focus.
-- Placeholder visuals (flat panels, Arcade font) until original/licensed art exists.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local MenuModel = require(Shared.UI.MenuModel)
local CraftingModel = require(Shared.UI.CraftingModel)
local ItemRegistry = require(Shared.Items.ItemRegistry)
local Inventory = require(Shared.Items.Inventory)

local LegacyMenus = {}
LegacyMenus.__index = LegacyMenus

local PANEL = Color3.fromRGB(198, 198, 198)
local DARK = Color3.fromRGB(85, 85, 85)

local function text(parent, name, str, size, pos)
	local l = Instance.new("TextLabel")
	l.Name = name
	l.BackgroundTransparency = 1
	l.Font = Enum.Font.Arcade
	l.TextScaled = true
	l.TextColor3 = Color3.fromRGB(64, 64, 64)
	l.Text = str
	l.Size = size
	l.Position = pos
	l.Parent = parent
	return l
end

local function itemName(id: number): string
	local d = ItemRegistry.get(id)
	return if d then d.name else ("#" .. id)
end

function LegacyMenus.new(playerGui: PlayerGui, callbacks)
	local self = setmetatable({}, LegacyMenus)
	self.menu = MenuModel.new()
	self.craft = CraftingModel.new(2)
	self.callbacks = callbacks
	local gui = Instance.new("ScreenGui")
	gui.Name = "mclceLegacyMenus"
	gui.ResetOnSpawn = false
	gui.Parent = playerGui
	self.gui = gui

	-- crafting panel
	local cp = Instance.new("Frame")
	cp.Name = "Crafting"
	cp.AnchorPoint = Vector2.new(0.5, 0.5)
	cp.Position = UDim2.fromScale(0.5, 0.5)
	cp.Size = UDim2.fromOffset(720, 360)
	cp.BackgroundColor3 = PANEL
	cp.Visible = false
	cp.Parent = gui
	self.craftPanel = cp
	self.tabLabels = {}
	for i, name in CraftingModel.TABS do
		local l = text(cp, "Tab" .. i, name, UDim2.fromOffset(96, 28), UDim2.fromOffset(8 + (i - 1) * 101, 8))
		self.tabLabels[i] = l
	end
	self.recipeLabels = {}
	for i = 1, 7 do
		local f = Instance.new("TextLabel")
		f.Name = "Recipe" .. i
		f.Size = UDim2.fromOffset(92, 92)
		f.Position = UDim2.fromOffset(16 + (i - 1) * 100, 60)
		f.Font = Enum.Font.Arcade
		f.TextScaled = true
		f.TextWrapped = true
		f.BackgroundColor3 = DARK
		f.Parent = cp
		self.recipeLabels[i] = f
	end
	self.recipeTitle = text(cp, "Title", "", UDim2.fromOffset(700, 32), UDim2.fromOffset(10, 170))
	self.ingredients = text(cp, "Ingredients", "", UDim2.fromOffset(700, 120), UDim2.fromOffset(10, 210))

	-- pause panel
	local pp = Instance.new("Frame")
	pp.Name = "Pause"
	pp.AnchorPoint = Vector2.new(0.5, 0.5)
	pp.Position = UDim2.fromScale(0.5, 0.5)
	pp.Size = UDim2.fromOffset(360, 260)
	pp.BackgroundColor3 = PANEL
	pp.Visible = false
	pp.Parent = gui
	self.pausePanel = pp
	self.pauseLabels = {}
	local names = { resume = "Resume Game", settings = "Settings", how_to_play = "How To Play", save_and_quit = "Save & Exit" }
	for i, item in MenuModel.PAUSE_ITEMS do
		local b = Instance.new("TextButton")
		b.Name = item
		b.Size = UDim2.fromOffset(320, 48)
		b.Position = UDim2.fromOffset(20, 16 + (i - 1) * 58)
		b.Font = Enum.Font.Arcade
		b.TextScaled = true
		b.Text = names[item]
		b.Parent = pp
		b.Activated:Connect(function()
			self.menu.stack[#self.menu.stack].focus = i
			self:action("confirm")
		end)
		self.pauseLabels[i] = b
	end
	return self
end

function LegacyMenus:isGameplay(): boolean
	return MenuModel.isGameplay(self.menu)
end

function LegacyMenus:setGrid(grid: number)
	self.craft.grid = grid
end

function LegacyMenus:action(a: string)
	local top = MenuModel.top(self.menu).name
	local inv = self.callbacks.inventory()
	if top == "crafting" and (a == "left" or a == "right" or a == "tabNext" or a == "tabPrev") then
		CraftingModel.input(self.craft, a, inv)
	elseif top == "crafting" and a == "confirm" then
		local e = CraftingModel.selected(self.craft)
		if e and e.craftable then
			self.callbacks.craft(e.recipe.id, self.craft.grid)
		end
	else
		local result = MenuModel.input(self.menu, a)
		if result == "save_and_quit" then
			Players.LocalPlayer:Kick("Game saved.")
		end
	end
	for _, ev in MenuModel.takeEvents(self.menu) do
		if ev == "open:crafting" then
			self.craft.grid = self.callbacks.grid()
			CraftingModel.refresh(self.craft, inv)
		end
		self.callbacks.event(ev)
	end
	self:render()
end

function LegacyMenus:onInventoryChanged()
	if MenuModel.top(self.menu).name == "crafting" then
		CraftingModel.refresh(self.craft, self.callbacks.inventory())
		self:render()
	end
end

function LegacyMenus:render()
	local top = MenuModel.top(self.menu)
	self.craftPanel.Visible = top.name == "crafting"
	self.pausePanel.Visible = top.name == "pause"
	if top.name == "crafting" then
		local m = self.craft
		for i, l in self.tabLabels do
			l.TextColor3 = if i == m.tab then Color3.new(1, 1, 1) else Color3.fromRGB(64, 64, 64)
		end
		local n = #m.entries
		for slot = 1, 7 do
			local l = self.recipeLabels[slot]
			local idx = m.index + slot - 4
			local e = if n > 0 and idx >= 1 and idx <= n then m.entries[idx] else nil
			if e then
				l.Visible = true
				l.Text = itemName(e.recipe.output.id) .. (if e.recipe.output.count > 1 then " x" .. e.recipe.output.count else "")
				l.TextColor3 = if e.craftable then Color3.new(1, 1, 1) else Color3.fromRGB(140, 140, 140)
				l.BackgroundColor3 = if slot == 4 then Color3.fromRGB(140, 140, 40) else DARK
			else
				l.Visible = false
			end
		end
		local sel = CraftingModel.selected(m)
		if sel then
			self.recipeTitle.Text = itemName(sel.recipe.output.id) .. (if sel.craftable then "" else "  (missing ingredients)")
			local inv = self.callbacks.inventory()
			local parts = {}
			for _, ing in sel.recipe.inputs do
				table.insert(parts, string.format("%s %d/%d", itemName(ing.id), Inventory.count(inv, ing.id, ing.meta), ing.count))
			end
			self.ingredients.Text = table.concat(parts, "   ")
		else
			self.recipeTitle.Text = "(no recipes)"
			self.ingredients.Text = ""
		end
	elseif top.name == "pause" then
		for i, b in self.pauseLabels do
			b.BackgroundColor3 = if i == top.focus then Color3.fromRGB(140, 140, 40) else DARK
		end
	end
end

return LegacyMenus
