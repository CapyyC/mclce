--!nonstrict
-- Server bootstrap: owns the authoritative GameServer, bridges RemoteEvents,
-- feeds character positions, runs the 20 Hz tick, autosaves and saves on
-- shutdown. All game rules live in ReplicatedStorage.Shared (CLI-tested).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local GameServer = require(Shared.Sim.GameServer)
local SaveManager = require(Shared.Persistence.SaveManager)
local Protocol = require(Shared.Net.Protocol)
local DataStoreBackend = require(script.Parent.DataStoreBackend)

local BS = Config.BLOCK_SIZE
local TICK = 1 / Config.TICK_RATE

local function remote(name: string): RemoteEvent
	local r = ReplicatedStorage:FindFirstChild(name)
	if not r then
		r = Instance.new("RemoteEvent")
		r.Name = name
		r.Parent = ReplicatedStorage
	end
	return r
end
local C2S = remote("mclceC2S")
local S2C = remote("mclceS2C")

local backend, persistent = DataStoreBackend.new("mclce_world_v1")
local gs = GameServer.new({
	seed = Config.DEFAULT_SEED,
	worldSize = Config.WORLD_SIZE,
	worldId = "default",
	backend = backend,
	clock = os.clock,
})

-- Opening must succeed before anyone can edit, or saved edits could be lost.
do
	local delay = 1
	while true do
		local ok, err = GameServer.open(gs)
		if ok then
			break
		end
		warn("[mclce] world open failed (" .. tostring(err) .. "), retrying in " .. delay .. "s")
		task.wait(delay)
		delay = math.min(delay * 2, 30)
	end
end
-- debug handle for the Studio command bar / MCP: _G.mclceServer.gs
_G.mclceServer = { gs = gs }
print(string.format("[mclce] world ready seed=%s persistent=%s", gs.seedText, tostring(persistent)))

local ready: { [number]: boolean } = {}

local function placeCharacter(player: Player)
	local char = player.Character
	local p = gs.players[player.UserId]
	if not char or not p then
		return
	end
	local root = char:WaitForChild("HumanoidRootPart", 10)
	local hum = char:FindFirstChildOfClass("Humanoid")
	if not root or not hum then
		return
	end
	local feetToRoot = root.Size.Y / 2 + hum.HipHeight
	root.CFrame = CFrame.new(p.x * BS, p.y * BS + feetToRoot + 0.5, p.z * BS)
	-- frozen until the client has meshed the ground under it
	root.Anchored = not ready[player.UserId]
end

Players.PlayerAdded:Connect(function(player)
	local ok, record = SaveManager.loadPlayer(gs.save, player.UserId)
	if not ok then
		warn("[mclce] player load failed for " .. player.UserId .. ": " .. tostring(record))
		-- Refuse to start with empty data that would overwrite their save later.
		player:Kick("Could not load your data, please rejoin.")
		return
	end
	GameServer.addPlayer(gs, player.UserId, player.Name, record, true)
	player.CharacterAdded:Connect(function()
		task.defer(placeCharacter, player)
	end)
	if player.Character then
		task.defer(placeCharacter, player)
	end
end)

local function savePlayer(player: Player)
	local rec = GameServer.removePlayer(gs, player.UserId)
	ready[player.UserId] = nil
	if rec then
		for attempt = 1, 3 do
			local ok = SaveManager.savePlayer(gs.save, player.UserId, rec)
			if ok then
				break
			end
			task.wait(attempt)
		end
	end
end
Players.PlayerRemoving:Connect(savePlayer)

C2S.OnServerEvent:Connect(function(player, kind, ...)
	local args = table.pack(...)
	if args.n > 8 then
		return
	end
	args.n = nil
	if kind == Protocol.C2S.HELLO and gs.players[player.UserId] then
		ready[player.UserId] = true
		local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
		if root then
			root.Anchored = false
		end
	end
	GameServer.handle(gs, player.UserId, kind, args)
end)

local function syncPositions()
	for _, player in Players:GetPlayers() do
		local char = player.Character
		local root = char and char:FindFirstChild("HumanoidRootPart")
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		if root and hum and ready[player.UserId] then
			local feet = root.Position.Y - root.Size.Y / 2 - hum.HipHeight
			GameServer.setPlayerPosition(gs, player.UserId, root.Position.X / BS, feet / BS, root.Position.Z / BS)
		end
	end
end

local function flush()
	for _, player in Players:GetPlayers() do
		for _, m in GameServer.takeOutbox(gs, player.UserId) do
			S2C:FireClient(player, m.kind, table.unpack(m.args))
			if m.kind == Protocol.S2C.RESPAWNED then
				task.defer(placeCharacter, player)
			end
		end
	end
end

local lastSave = os.clock()
local saving = false
task.spawn(function()
	local acc, last = 0, os.clock()
	while true do
		task.wait()
		local now = os.clock()
		acc += now - last
		last = now
		local steps = 0
		while acc >= TICK and steps < 4 do
			acc -= TICK
			steps += 1
			syncPositions()
			GameServer.tick(gs)
			flush()
		end
		if acc > 0.5 then
			acc = 0 -- don't spiral after a long stall
		end
		if now - lastSave > 30 and not saving then
			lastSave = now
			saving = true
			task.spawn(function()
				-- leave headroom in the budget for player saves
				local budget = math.max(0, math.min(8, DataStoreBackend.setBudget() - 4))
				local ok, err = pcall(GameServer.autosave, gs, budget)
				if not ok then
					warn("[mclce] autosave error: " .. tostring(err))
				end
				saving = false
			end)
		end
	end
end)

game:BindToClose(function()
	for _, player in Players:GetPlayers() do
		savePlayer(player)
	end
	local deadline = os.clock() + 25
	GameServer.autosave(gs, 0)
	while SaveManager.dirtyCount(gs.save) > 0 and os.clock() < deadline do
		SaveManager.flush(gs.save, 4)
		task.wait(0.5)
	end
	if SaveManager.dirtyCount(gs.save) > 0 then
		warn("[mclce] shutdown with " .. SaveManager.dirtyCount(gs.save) .. " unsaved records")
	end
end)
