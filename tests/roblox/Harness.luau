-- Builds a mock DataModel from the source bundle and provides the frame loop.
local Mock = require("./MockRoblox")
local bundle = require("./_bundle")

local failures = 0
local function check(cond, msg)
	if cond then
		print("  ok   " .. msg)
	else
		failures += 1
		print("  FAIL " .. msg)
	end
end

---------------------------------------------------------------- DataModel
local Instance = Mock.Instance
local game = Instance.new("DataModel")
game.Name = "Game"
local services = {}
local function service(name, cls)
	local s = Instance.new(cls or name)
	s.Name = name
	s.Parent = game
	services[name] = s
	return s
end
local Workspace = service("Workspace")
local ReplicatedStorage = service("ReplicatedStorage")
local ServerScriptService = service("ServerScriptService")
local StarterPlayer = service("StarterPlayer")
local Players = service("Players")
local RunService = service("RunService")
local Lighting = service("Lighting")
local DataStoreService = service("DataStoreService")
local UserInputService = service("UserInputService")
local ContextActionService = service("ContextActionService")
local AssetService = service("AssetService")
local meshStats = { meshes = 0, triangles = 0 }
Mock.addMethods(AssetService, {
	CreateEditableMesh = function()
		return Mock.newEditableMesh()
	end,
	CreateMeshPartAsync = function(_, content)
		assert(type(content) == "table" and content._type == "Content", "CreateMeshPartAsync expects Content")
		Mock.task.wait(0)
		local _, nt = rawget(content.object, "_counts")()
		meshStats.meshes += 1
		meshStats.triangles += nt
		return Mock.Instance.new("MeshPart")
	end,
})
Lighting.ClockTime = 14
UserInputService.TouchEnabled = false
local camera = Instance.new("Camera", Workspace)
camera.CFrame = Mock.CFrame.new(0, 100, 0)
Workspace.CurrentCamera = camera

local closeHandlers = {}
Mock.addMethods(game, {
	GetService = function(_, name)
		return services[name] or error("unknown service " .. tostring(name))
	end,
	BindToClose = function(_, fn)
		table.insert(closeHandlers, fn)
	end,
})
for _, n in { "Heartbeat", "RenderStepped", "Stepped" } do
	Mock.addEvent(RunService, n)
end
for _, n in { "InputBegan", "InputEnded", "InputChanged" } do
	Mock.addEvent(UserInputService, n)
end
Mock.addMethods(ContextActionService, { BindAction = function() end, SetTitle = function() end, UnbindAction = function() end })

-- DataStores ---------------------------------------------------------------
local stores = {}
local dsCalls = { get = 0, set = 0, bytes = 0 }
Mock.addMethods(DataStoreService, {
	GetDataStore = function(_, name)
		local data = stores[name] or {}
		stores[name] = data
		local ds = Instance.new("DataStore")
		Mock.addMethods(ds, {
			GetAsync = function(_, key)
				assert(type(key) == "string" and #key <= 50, "DataStore key must be a string of <= 50 chars: " .. tostring(key))
				dsCalls.get += 1
				Mock.task.wait(0.05)
				local v = data[key]
				return if v == nil then nil else Mock.remoteCopy(v)
			end,
			SetAsync = function(_, key, value)
				assert(type(key) == "string" and #key <= 50, "DataStore key must be a string of <= 50 chars: " .. tostring(key))
				local size = Mock.jsonSize(value, key)
				assert(size <= 4194304, "DataStore value too large: " .. size)
				dsCalls.set += 1
				dsCalls.bytes += size
				Mock.task.wait(0.05)
				data[key] = Mock.remoteCopy(value)
			end,
		})
		return ds
	end,
	GetRequestBudgetForRequestType = function()
		return 60
	end,
})

-- Remotes: decorate RemoteEvents created by the glue ------------------------
local trafficByKind = {}
local players = {}
local originalNew = Instance.new
Mock.Instance.new = function(cls, parent)
	local inst = originalNew(cls, parent)
	if cls == "RemoteEvent" then
		Mock.addMethods(inst, {
			FireClient = function(self, player, ...)
				assert(Mock.isInstance(player) and player.ClassName == "Player", "FireClient expects a Player first")
				local args = table.pack(...)
				local copy = {}
				for i = 1, args.n do
					copy[i] = Mock.remoteCopy(args[i])
					if type(args[i]) == "buffer" then
						Mock.remoteTraffic.bytesToClient += buffer.len(args[i])
					end
				end
				Mock.remoteTraffic.toClient += 1
				trafficByKind[args[1]] = (trafficByKind[args[1]] or 0) + 1
				self.OnClientEvent:Fire(table.unpack(copy, 1, args.n))
			end,
			FireServer = function(self, ...)
				local args = table.pack(...)
				local copy = {}
				for i = 1, args.n do
					copy[i] = Mock.remoteCopy(args[i])
				end
				Mock.remoteTraffic.toServer += 1
				self.OnServerEvent:Fire(players[1], table.unpack(copy, 1, args.n))
			end,
		})
	end
	return inst
end

-- Players -------------------------------------------------------------------
local playerAdded = Mock.addEvent(Players, "PlayerAdded")
Mock.addEvent(Players, "PlayerRemoving")
Mock.addMethods(Players, {
	GetPlayers = function()
		return table.clone(players)
	end,
})

local function makeCharacter(player)
	local char = Instance.new("Model")
	char.Name = player.Name
	local root = Instance.new("Part", char)
	root.Name = "HumanoidRootPart"
	root.Size = Mock.Vector3.new(2, 2, 1)
	local hum = Instance.new("Humanoid", char)
	hum.HipHeight = 2
	hum.FloorMaterial = Mock.Enum.Material.Air
	hum.Health = 100
	char.Parent = Workspace
	return char
end

local function addPlayer(id, name)
	local p = Instance.new("Player")
	p.Name = name
	p.UserId = id
	p.CameraMode = Mock.Enum.CameraMode.Classic
	local gui = Instance.new("PlayerGui", p)
	gui.Name = "PlayerGui"
	Mock.addMethods(p, {
		Kick = function(self, msg)
			self.Kicked = msg or true
		end,
	})
	p.Parent = Players
	table.insert(players, p)
	Players.LocalPlayer = p
	playerAdded:Fire(p)
	local char = makeCharacter(p)
	p.Character = char
	p.CharacterAdded:Fire(char)
	return p
end

-- Script tree from the bundle (mirrors default.project.json) ----------------
local MAP = {
	{ "src/shared/", ReplicatedStorage, "Shared" },
	{ "src/server/", ServerScriptService, "Server" },
	{ "src/client/", StarterPlayer, "StarterPlayerScripts/Client" },
}
local byPath = {}
local function ensureFolder(parent, name)
	local f = parent:FindFirstChild(name)
	if f == nil then
		f = originalNew("Folder", parent)
		f.Name = name
	end
	return f
end
local paths = {}
for path in bundle do
	table.insert(paths, path)
end
table.sort(paths)
for _, path in paths do
	for _, m in MAP do
		if string.sub(path, 1, #m[1]) == m[1] then
			local parent = m[2]
			for seg in string.gmatch(m[3], "[^/]+") do
				parent = ensureFolder(parent, seg)
			end
			local rel = string.sub(path, #m[1] + 1)
			local segs = string.split(rel, "/")
			for i = 1, #segs - 1 do
				parent = ensureFolder(parent, segs[i])
			end
			local file = segs[#segs]
			local cls, name = "ModuleScript", string.gsub(file, "%.luau$", "")
			if string.match(file, "%.server%.luau$") then
				cls, name = "Script", string.gsub(file, "%.server%.luau$", "")
			elseif string.match(file, "%.client%.luau$") then
				cls, name = "LocalScript", string.gsub(file, "%.client%.luau$", "")
			end
			local inst = originalNew(cls, parent)
			inst.Name = name
			rawset(inst, "_path", path)
			byPath[path] = inst
		end
	end
end

-- Module system with a separate cache per VM side ---------------------------
local caches = { server = {}, client = {} }
-- Roblox's _G is a plain table shared by all scripts of one VM side
local sideG = { server = {}, client = {} }
local loadModule

local function dirname(p)
	return string.match(p, "^(.*)/[^/]*$") or ""
end
local function resolve(fromPath, req)
	local parts = string.split(dirname(fromPath), "/")
	for _, seg in string.split(req, "/") do
		if seg == "." then
			continue
		elseif seg == ".." then
			table.remove(parts)
		else
			table.insert(parts, seg)
		end
	end
	return table.concat(parts, "/") .. ".luau"
end

local function makeEnv(side, scriptInst)
	local env = {
		_G = sideG[side],
		game = game,
		workspace = Workspace,
		script = scriptInst,
		Instance = Mock.Instance,
		Vector3 = Mock.Vector3,
		Vector2 = Mock.Vector2,
		CFrame = Mock.CFrame,
		Color3 = Mock.Color3,
		UDim = Mock.UDim,
		UDim2 = Mock.UDim2,
		Enum = Mock.Enum,
		Content = Mock.Content,
		task = Mock.task,
		os = setmetatable({ clock = function()
			return Mock.now
		end, time = function()
			return math.floor(Mock.now)
		end }, { __index = os }),
		warn = function(...)
			table.insert(Mock.log, "[warn " .. side .. "] " .. table.concat({ ... }, " "))
		end,
		print = function(...)
			local parts = {}
			for i = 1, select("#", ...) do
				parts[i] = tostring((select(i, ...)))
			end
			table.insert(Mock.log, "[" .. side .. "] " .. table.concat(parts, " "))
		end,
	}
	env.require = function(target)
		local path
		if Mock.isInstance(target) then
			path = rawget(target, "_path") or error("require: instance is not a ModuleScript: " .. tostring(target))
			assert(target.ClassName == "ModuleScript", "require of non-ModuleScript " .. tostring(target))
		elseif type(target) == "string" then
			path = resolve(rawget(scriptInst, "_path"), target)
		else
			error("require: bad argument")
		end
		return loadModule(side, path)
	end
	return setmetatable(env, { __index = _G })
end

function loadModule(side, path)
	local cache = caches[side]
	if cache[path] ~= nil then
		return cache[path]
	end
	local src = bundle[path] or error("module not found: " .. path)
	local f, err = loadstring(src, "=" .. path)
	assert(f, err)
	setfenv(f, makeEnv(side, byPath[path]))
	local result = f()
	assert(result ~= nil, "module " .. path .. " returned nil")
	cache[path] = result
	return result
end

local function runScript(side, path)
	local src = bundle[path]
	local f, err = loadstring(src, "=" .. path)
	assert(f, err)
	setfenv(f, makeEnv(side, byPath[path]))
	Mock.task.spawn(f)
end

---------------------------------------------------------------- frame loop
local function step(dt)
	Mock.now += dt
	for _ = 1, 50 do
		-- wake sleepers
		local due = {}
		local sleeping = Mock._sleeping()
		for i = #sleeping, 1, -1 do
			local s = sleeping[i]
			if s[2] <= Mock.now then
				table.remove(sleeping, i)
				table.insert(due, 1, s[1])
			end
		end
		local d = Mock._takeDeferred()
		if #due == 0 and #d == 0 then
			break
		end
		for _, co in due do
			Mock._resume(co)
		end
		for _, e in d do
			Mock._resume(e[1], table.unpack(e[2], 1, e[2].n))
		end
	end
	RunService.Heartbeat:Fire(dt)
	RunService.RenderStepped:Fire(dt)
end

local function run(seconds, fps)
	local dt = 1 / (fps or 30)
	for _ = 1, math.floor(seconds / dt) do
		step(dt)
	end
end

return {
	Mock = Mock,
	game = game,
	services = services,
	addPlayer = addPlayer,
	runScript = runScript,
	run = run,
	step = step,
	check = check,
	failures = function()
		return failures
	end,
	closeHandlers = closeHandlers,
	stores = stores,
	dsCalls = dsCalls,
	trafficByKind = trafficByKind,
	caches = caches,
	sideG = sideG,
	meshStats = meshStats,
}
