--!nonstrict
-- Client bootstrap: receives world data, renders it, maps input to
-- validated requests. Gameplay rules live in ReplicatedStorage.Shared.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Lighting = game:GetService("Lighting")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Protocol = require(Shared.Net.Protocol)
local ClientWorld = require(Shared.Sim.ClientWorld)
local World = require(Shared.Voxel.World)
local RemeshQueue = require(Shared.Streaming.RemeshQueue)
local ItemRegistry = require(Shared.Items.ItemRegistry)
local ChunkRenderer = require(script.Parent.ChunkRenderer)
local Hud = require(script.Parent.Hud)
local Input = require(script.Parent.Input)
local LegacyMenus = require(script.Parent.LegacyMenus)
local MobRenderer = require(script.Parent.MobRenderer)
local ContainerMenu = require(script.Parent.ContainerMenu)
local WeatherFx = require(script.Parent.WeatherFx)
local InventoryScreen = require(script.Parent.InventoryScreen)
local ChatBox = require(script.Parent.ChatBox)

local BS = Config.BLOCK_SIZE
local C2S_KIND, S2C_KIND = Protocol.C2S, Protocol.S2C

local player = Players.LocalPlayer
local C2S: RemoteEvent = ReplicatedStorage:WaitForChild("mclceC2S")
local S2C: RemoteEvent = ReplicatedStorage:WaitForChild("mclceS2C")

player.CameraMode = Enum.CameraMode.LockFirstPerson -- Legacy default is first person

local cw = ClientWorld.new()
-- debug handle for the Studio command bar / MCP: _G.mclceClient.cw
_G.mclceClient = { cw = cw }
local rendererKind = workspace:GetAttribute("mclceRenderer") or Config.RENDERER
local renderer = if rendererKind == "mesh" then require(script.Parent.MeshRenderer).new(cw, workspace) else ChunkRenderer.new(cw, workspace)
_G.mclceClient.renderer = renderer
local mobRenderer = MobRenderer.new(cw, workspace)
local weatherFx = WeatherFx.new(workspace)
local hud = Hud.new(player:WaitForChild("PlayerGui"))
local nearCraftingTable
local chat = ChatBox.new(player:WaitForChild("PlayerGui"), function(text)
	table.insert(cw.outgoing, { C2S_KIND.CHAT, text })
end)
local inventoryScreen = InventoryScreen.new(player:WaitForChild("PlayerGui"), function(slot, button)
	ClientWorld.inventoryClick(cw, slot, button)
end)
local menus = LegacyMenus.new(player.PlayerGui, {
	inventory = function()
		return cw.inventory
	end,
	craft = function(recipeId, grid)
		table.insert(cw.outgoing, { C2S_KIND.CRAFT, recipeId, grid })
	end,
	grid = function()
		local char = player.Character
		local root = char and char:FindFirstChild("HumanoidRootPart")
		if root then
			local p = root.Position / BS
			return if nearCraftingTable(p.X, p.Y, p.Z) then 3 else 2
		end
		return 2
	end,
	event = function(ev)
		if ev == "close:crafting" or ev == "close:inventory" then
			table.insert(cw.outgoing, { C2S_KIND.CLOSE_CONTAINER }) -- returns the cursor stack
		end
		if ev == "open:inventory" then
			inventoryScreen:setOpen(true)
			inventoryScreen:render(cw.inventory)
		elseif ev == "close:inventory" then
			inventoryScreen:setOpen(false)
		end
	end,
})
local containerMenu = ContainerMenu.new(player.PlayerGui, function(slot, button)
	ClientWorld.containerClick(cw, slot, button)
end, function(slot, button)
	ClientWorld.inventoryClick(cw, slot, button)
end)
Input.start()
hud.respawnButton.Activated:Connect(function()
	ClientWorld.requestRespawn(cw)
end)

local seenResets = 0
local helloSent = false
local playerDims = {}
local function applyCharacterVisibility()
	local myDim = cw.dimension
	for _, other in Players:GetPlayers() do
		if other ~= player and other.Character then
			local hidden = playerDims[tostring(other.UserId)] ~= nil and playerDims[tostring(other.UserId)] ~= myDim
			for _, d in other.Character:GetDescendants() do
				if d:IsA("BasePart") then
					d.LocalTransparencyModifier = if hidden then 1 else 0
				end
			end
		end
	end
end

S2C.OnClientEvent:Connect(function(kind, ...)
	if kind == S2C_KIND.DIMS then
		playerDims = (...) or {}
		applyCharacterVisibility()
		return
	end
	ClientWorld.apply(cw, kind, { ... })
	if cw.resets ~= seenResets then
		-- WELCOME: new session or dimension change, drop everything rendered
		seenResets = cw.resets
		renderer:dropAll()
		helloSent = false
		applyCharacterVisibility()
	end
	if kind == S2C_KIND.UNLOAD then
		renderer:dropChunk(...)
	elseif kind == S2C_KIND.INVENTORY then
		menus:onInventoryChanged()
		if inventoryScreen.gui.Enabled then
			inventoryScreen:render(cw.inventory)
		end
	end
	if kind == S2C_KIND.CONTAINER or (kind == S2C_KIND.INVENTORY and cw.container) then
		containerMenu:render(cw.container, cw.inventory)
	end
end)

-- the server sends nothing until it knows this listener exists
C2S:FireServer(C2S_KIND.JOIN)

-- selection outline
local selPart = Instance.new("Part")
selPart.Name = "mclceSelection"
selPart.Anchored = true
selPart.CanCollide = false
selPart.CanQuery = false
selPart.Transparency = 1
selPart.Size = Vector3.new(BS, BS, BS)
selPart.Parent = workspace
local selBox = Instance.new("SelectionBox")
selBox.Adornee = selPart
selBox.LineThickness = 0.03
selBox.Color3 = Color3.new(0, 0, 0)
selBox.Parent = selPart

-- item entities
local itemParts: { [number]: Part } = {}
local function renderItems()
	for id in cw.itemsChanged do
		local e = cw.items[id]
		local p = itemParts[id]
		if e == nil then
			if p then
				p:Destroy()
				itemParts[id] = nil
			end
		else
			if p == nil then
				p = Instance.new("Part")
				p.Size = Vector3.new(BS / 4, BS / 4, BS / 4)
				p.Anchored = true
				p.CanCollide = false
				p.CanQuery = false
				p.Parent = workspace
				itemParts[id] = p
			end
			p.Position = Vector3.new(e.x * BS, (e.y + 0.125) * BS, e.z * BS)
		end
	end
	table.clear(cw.itemsChanged)
end

local placeCooldown = 0

function nearCraftingTable(px: number, py: number, pz: number): boolean
	for y = math.floor(py) - 3, math.floor(py) + 3 do
		for z = math.floor(pz) - 3, math.floor(pz) + 3 do
			for x = math.floor(px) - 3, math.floor(px) + 3 do
				if World.getId(cw.world, x, y, z) == 58 then
					return true
				end
			end
		end
	end
	return false
end

RunService.RenderStepped:Connect(function(dt)
	local cam = workspace.CurrentCamera
	local camPos = cam.CFrame.Position / BS
	renderer:step(Config.MESH_BUDGET_PER_FRAME, camPos)

	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	local hum = char and char:FindFirstChildOfClass("Humanoid")

	-- tell the server we can stand once the ground under us is meshed
	if not helloSent and root and cw.welcome then
		local fx, fz = math.floor(root.Position.X / BS), math.floor(root.Position.Z / BS)
		local cx, cz = fx // 16, fz // 16
		local pending = false
		for si = 0, 15 do
			if cw.remesh.dirty[RemeshQueue.sectionKey(cx, cz, si)] then
				pending = true
			end
		end
		if World.isLoaded(cw.world, fx, fz) and renderer.stats.sectionsBuilt > 0 and not pending then
			helloSent = true
			table.insert(cw.outgoing, { C2S_KIND.HELLO })
		end
	end

	local a = Input.actions
	-- menu input first (an open container takes "back"/crafting keys to close itself)
	for _, act in Input.menuQueue do
		if act == "chat" then
			if menus:isGameplay() and not cw.container then
				chat:open()
			end
			continue
		end
		if chat:isTyping() then
			continue -- keys typed into the chat box are not menu actions
		end
		if cw.container and (act == "back" or act == "crafting") then
			ClientWorld.closeContainer(cw)
		elseif not cw.container then
			local inInventory = not menus:isGameplay() and menus.menu.stack[#menus.menu.stack].name == "inventory"
			if inInventory and (act == "up" or act == "down" or act == "left" or act == "right" or act == "confirm") then
				inventoryScreen:action(act)
				inventoryScreen:render(cw.inventory)
			else
				menus:action(act)
			end
		end
	end
	table.clear(Input.menuQueue)
	a.openInventory = false
	if not menus:isGameplay() or cw.container then
		-- LB/RB drive menu tabs, not the hotbar, while a screen is open
		a.hotbarDelta = 0
		a.hotbarSelect = 0
	end
	-- hotbar
	local inv = cw.inventory
	local sel = inv.selected
	if a.hotbarSelect > 0 then
		sel = a.hotbarSelect
		a.hotbarSelect = 0
	end
	if a.hotbarDelta ~= 0 then
		sel = (sel - 1 + a.hotbarDelta) % 9 + 1
		a.hotbarDelta = 0
	end
	if sel ~= inv.selected then
		inv.selected = sel
		table.insert(cw.outgoing, { C2S_KIND.SELECT_SLOT, sel })
	end

	-- targeting
	local reach = if cw.gamemode == "creative" then Config.REACH_CREATIVE else Config.REACH_SURVIVAL
	local look = cam.CFrame.LookVector
	local menuOpen = not menus:isGameplay() or containerMenu:isOpen()
	local hit = if menuOpen then nil else ClientWorld.target(cw, camPos.X, camPos.Y, camPos.Z, look.X, look.Y, look.Z, reach)
	if hit then
		selPart.CFrame = CFrame.new((hit.x + 0.5) * BS, (hit.y + 0.5) * BS, (hit.z + 0.5) * BS)
		selBox.Visible = true
	else
		selBox.Visible = false
	end
	local onGround = hum ~= nil and hum.FloorMaterial ~= Enum.Material.Air
	-- melee: a click on a mob closer than the targeted block attacks it
	local mob, mobDist = ClientWorld.targetMob(cw, camPos.X, camPos.Y, camPos.Z, look.X, look.Y, look.Z, 3)
	if a.breakPressed and mob and (hit == nil or mobDist < hit.distance) and not menuOpen then
		ClientWorld.attack(cw, mob.id)
		a.breakHeld = false
	end
	a.breakPressed = false
	if a.breakHeld and hit then
		ClientWorld.updateBreaking(cw, hit.x, hit.y, hit.z, dt, onGround, false)
	else
		ClientWorld.updateBreaking(cw, nil, nil, nil, dt, onGround, false)
	end
	placeCooldown -= dt
	local heldNow = ClientWorld.held(cw)
	local entityTool = heldNow ~= nil and (heldNow.id == 359 or heldNow.id == 351)
	if a.placePressed and entityTool and mob and (hit == nil or mobDist < hit.distance) and not menuOpen then
		ClientWorld.interact(cw, mob.id) -- shears / dye on a sheep
		a.placePressed = false
	end
	if hit and hit.face >= 0 and (a.placePressed or (a.placeHeld and placeCooldown <= 0)) then
		table.insert(cw.outgoing, { C2S_KIND.PLACE, hit.x, hit.y, hit.z, hit.face })
		placeCooldown = 0.2 -- classic right-click repeat: 4 ticks
	end
	a.placePressed = false
	-- eating: hold "use" while not aiming at a block
	local usingBow = ClientWorld.held(cw) ~= nil and ClientWorld.held(cw).id == 261
	ClientWorld.updateUsing(cw, a.placeHeld and (hit == nil or usingBow), dt, look.X, look.Y, look.Z)
	local armor = 0
	for slot = 37, 40 do
		local s = cw.inventory.slots[slot]
		local d = s and ItemRegistry.get(s.id)
		armor += if d and d.armor then d.armor else 0
	end
	hud:setVitals(cw.vitals, cw.deathCause, armor)

	for _, m in ClientWorld.takeOutgoing(cw) do
		C2S:FireServer(table.unpack(m))
	end

	renderItems()
	cw.clock += dt
	weatherFx:update(cw.weather, cam.CFrame.Position, cw.dimension)
	chat:render(cw.chat)
	mobRenderer:update()
	mobRenderer:endFrame()
	for _, e in cw.explosions do
		local ex = Instance.new("Explosion")
		ex.Position = Vector3.new(e[1] * BS, e[2] * BS, e[3] * BS)
		ex.BlastRadius = e[4] * BS
		ex.BlastPressure = 0 -- visual only; damage is server-authoritative
		ex.DestroyJointRadiusPercent = 0
		ex.Parent = workspace
	end
	table.clear(cw.explosions)
	-- Legacy/Java time: tick 0 = 06:00; advance locally between server syncs
	cw.worldTime = (cw.worldTime + dt * Config.TICK_RATE) % 24000
	Lighting.ClockTime = (cw.worldTime / 1000 + 6) % 24
	hud:update(inv, ClientWorld.breakProgress(cw), string.format("chunks %d  dirty %d  sections %d  parts %d  build %.1fms  rollbacks %d",
		cw.world.chunkCount, cw.remesh.count, renderer.stats.sectionsBuilt, renderer.stats.parts, renderer.stats.lastBuildMs, cw.stats.rollbacks or 0))
end)

local _ = S2C_KIND
