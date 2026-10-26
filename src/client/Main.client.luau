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
local CraftingMenu = require(script.Parent.CraftingMenu)
local MobRenderer = require(script.Parent.MobRenderer)
local ContainerMenu = require(script.Parent.ContainerMenu)

local BS = Config.BLOCK_SIZE
local C2S_KIND, S2C_KIND = Protocol.C2S, Protocol.S2C

local player = Players.LocalPlayer
local C2S: RemoteEvent = ReplicatedStorage:WaitForChild("mclceC2S")
local S2C: RemoteEvent = ReplicatedStorage:WaitForChild("mclceS2C")

player.CameraMode = Enum.CameraMode.LockFirstPerson -- Legacy default is first person

local cw = ClientWorld.new()
-- debug handle for the Studio command bar / MCP: _G.mclceClient.cw
_G.mclceClient = { cw = cw }
local renderer = ChunkRenderer.new(cw, workspace)
_G.mclceClient.renderer = renderer
local mobRenderer = MobRenderer.new(cw, workspace)
local hud = Hud.new(player:WaitForChild("PlayerGui"))
local crafting = CraftingMenu.new(player.PlayerGui, function(recipeId, grid)
	table.insert(cw.outgoing, { C2S_KIND.CRAFT, recipeId, grid })
end)
local containerMenu = ContainerMenu.new(player.PlayerGui, function(slot, button)
	ClientWorld.containerClick(cw, slot, button)
end, function(slot, button)
	ClientWorld.inventoryClick(cw, slot, button)
end)
Input.start()
hud.respawnButton.Activated:Connect(function()
	ClientWorld.requestRespawn(cw)
end)

S2C.OnClientEvent:Connect(function(kind, ...)
	ClientWorld.apply(cw, kind, { ... })
	if kind == S2C_KIND.UNLOAD then
		renderer:dropChunk(...)
	elseif kind == S2C_KIND.INVENTORY and crafting:isOpen() then
		crafting:refresh(cw.inventory, crafting.grid)
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

local helloSent = false
local placeCooldown = 0

local function nearCraftingTable(px: number, py: number, pz: number): boolean
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
	if a.openInventory and cw.container then
		-- E closes an open container
		a.openInventory = false
		ClientWorld.closeContainer(cw)
	end
	if a.openInventory then
		a.openInventory = false
		local open = not crafting:isOpen()
		crafting:setOpen(open)
		if open and root then
			local p = root.Position / BS
			crafting:refresh(inv, if nearCraftingTable(p.X, p.Y, p.Z) then 3 else 2)
		else
			table.insert(cw.outgoing, { C2S_KIND.CLOSE_CONTAINER })
		end
	end

	-- targeting
	local reach = if cw.gamemode == "creative" then Config.REACH_CREATIVE else Config.REACH_SURVIVAL
	local look = cam.CFrame.LookVector
	local menuOpen = crafting:isOpen() or containerMenu:isOpen()
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
	if a.breakPressed and mob and (hit == nil or mobDist < hit.distance) and not crafting:isOpen() then
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
	if hit and hit.face >= 0 and (a.placePressed or (a.placeHeld and placeCooldown <= 0)) then
		table.insert(cw.outgoing, { C2S_KIND.PLACE, hit.x, hit.y, hit.z, hit.face })
		placeCooldown = 0.2 -- classic right-click repeat: 4 ticks
	end
	a.placePressed = false
	-- eating: hold "use" while not aiming at a block
	ClientWorld.updateUsing(cw, a.placeHeld and hit == nil, dt)
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
