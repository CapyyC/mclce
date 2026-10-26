-- Minimal mock of the Roblox runtime for executing src/server + src/client
-- in the Luau CLI. Goals: catch nil/typo/API-misuse errors in glue code and
-- enforce RemoteEvent / DataStore serialisation rules. It is NOT the engine:
-- no physics, rendering, replication latency or real networking.
local Mock = {}

Mock.now = 0
Mock.errors = {}
Mock.log = {}
Mock.remoteTraffic = { toServer = 0, toClient = 0, bytesToClient = 0 }

------------------------------------------------------------------ scheduler
local sleeping = {} -- { co, wake }
local deferred = {}

local function resume(co, ...)
	local ok, err = coroutine.resume(co, ...)
	if not ok then
		table.insert(Mock.errors, debug.traceback(co, tostring(err)))
	end
end

local Task = {}
function Task.spawn(fn, ...)
	local co = if type(fn) == "thread" then fn else coroutine.create(fn)
	resume(co, ...)
	return co
end
function Task.defer(fn, ...)
	local co = if type(fn) == "thread" then fn else coroutine.create(fn)
	table.insert(deferred, { co, table.pack(...) })
	return co
end
function Task.delay(t, fn, ...)
	local args = table.pack(...)
	local co = coroutine.create(function()
		Task.wait(t)
		fn(table.unpack(args, 1, args.n))
	end)
	resume(co)
	return co
end
function Task.desynchronize() end
function Task.synchronize() end
function Task.wait(t)
	local co = coroutine.running()
	local start = Mock.now
	table.insert(sleeping, { co, Mock.now + (t or 0) })
	coroutine.yield()
	return Mock.now - start
end
Mock.task = Task
Mock._sleeping = function()
	return sleeping
end
Mock._takeDeferred = function()
	local d = deferred
	deferred = {}
	return d
end
Mock._resume = resume

----------------------------------------------------------------- datatypes
local Vector3 = {}
Vector3.__index = Vector3
local function v3(x, y, z)
	return setmetatable({ X = x or 0, Y = y or 0, Z = z or 0 }, Vector3)
end
Vector3.new = v3
Vector3.__add = function(a, b)
	return v3(a.X + b.X, a.Y + b.Y, a.Z + b.Z)
end
Vector3.__sub = function(a, b)
	return v3(a.X - b.X, a.Y - b.Y, a.Z - b.Z)
end
Vector3.__mul = function(a, b)
	if type(a) == "number" then
		return v3(b.X * a, b.Y * a, b.Z * a)
	elseif type(b) == "number" then
		return v3(a.X * b, a.Y * b, a.Z * b)
	end
	return v3(a.X * b.X, a.Y * b.Y, a.Z * b.Z)
end
Vector3.__div = function(a, b)
	if type(b) == "number" then
		return v3(a.X / b, a.Y / b, a.Z / b)
	end
	return v3(a.X / b.X, a.Y / b.Y, a.Z / b.Z)
end
Vector3.__eq = function(a, b)
	return a.X == b.X and a.Y == b.Y and a.Z == b.Z
end
Vector3.__tostring = function(a)
	return string.format("%g, %g, %g", a.X, a.Y, a.Z)
end
Mock.Vector3 = { new = v3, zero = v3(0, 0, 0) }

-- CFrame: position + yaw-only rotation is enough for the glue.
local CFrame = {}
CFrame.__index = function(cf, k)
	if k == "Position" or k == "p" then
		return v3(cf.x, cf.y, cf.z)
	elseif k == "LookVector" then
		return cf.look
	elseif k == "X" then
		return cf.x
	elseif k == "Y" then
		return cf.y
	elseif k == "Z" then
		return cf.z
	end
	return CFrame[k]
end
local function cfNew(x, y, z, look)
	return setmetatable({ x = x, y = y, z = z, look = look or v3(0, 0, -1), _cf = true }, CFrame)
end
CFrame.__mul = function(a, b)
	if getmetatable(b) == CFrame then
		return cfNew(a.x + b.x, a.y + b.y, a.z + b.z, a.look)
	end
	return v3(a.x + b.X, a.y + b.Y, a.z + b.Z)
end
Mock.CFrame = {
	new = function(x, y, z, ...)
		if type(x) == "table" and getmetatable(x) == Vector3 then
			local look = nil
			if type(y) == "table" then
				local d = y - x
				local m = math.sqrt(d.X * d.X + d.Y * d.Y + d.Z * d.Z)
				look = if m > 0 then d / m else nil
			end
			return cfNew(x.X, x.Y, x.Z, look)
		end
		assert(type(x) == "number" or x == nil, "CFrame.new: bad argument")
		return cfNew(x or 0, y or 0, z or 0)
	end,
	Angles = function()
		return cfNew(0, 0, 0)
	end,
	lookAt = function(a, b)
		local d = b - a
		local m = math.sqrt(d.X * d.X + d.Y * d.Y + d.Z * d.Z)
		return cfNew(a.X, a.Y, a.Z, d / m)
	end,
}

local function plain(name, fields)
	return function(...)
		local t = { _type = name }
		for i, f in fields do
			t[f] = select(i, ...) or 0
		end
		return t
	end
end
Mock.Color3 = {
	new = plain("Color3", { "R", "G", "B" }),
	fromRGB = function(r, g, b)
		assert(type(r) == "number" and type(g) == "number" and type(b) == "number", "Color3.fromRGB: numbers expected")
		return { _type = "Color3", R = r / 255, G = g / 255, B = b / 255 }
	end,
}
Mock.Vector2 = { new = plain("Vector2", { "X", "Y" }) }
Mock.UDim = { new = plain("UDim", { "Scale", "Offset" }) }
Mock.UDim2 = {
	new = plain("UDim2", { "XScale", "XOffset", "YScale", "YOffset" }),
	fromOffset = function(x, y)
		return { _type = "UDim2", XScale = 0, XOffset = x or 0, YScale = 0, YOffset = y or 0 }
	end,
	fromScale = function(x, y)
		return { _type = "UDim2", XScale = x or 0, XOffset = 0, YScale = y or 0, YOffset = 0 }
	end,
}

--------------------------------------------------------------------- enums
local MATERIALS = {
	"Plastic", "SmoothPlastic", "Neon", "Wood", "WoodPlanks", "Marble", "Basalt", "Slate", "CrackedLava",
	"Concrete", "Limestone", "Granite", "Pavement", "Brick", "Pebble", "Cobblestone", "Rock", "Sandstone",
	"CorrodedMetal", "DiamondPlate", "Foil", "Metal", "Grass", "LeafyGrass", "Sand", "Fabric", "Snow",
	"Mud", "Ground", "Asphalt", "Salt", "Ice", "Glacier", "Glass", "ForceField", "Air", "Water", "Cardboard",
	"Carpet", "CeramicTiles", "ClayRoofTiles", "RoofShingles", "Leather", "Plaster", "Rubber",
}
local strictEnums = { Material = {} }
for _, m in MATERIALS do
	strictEnums.Material[m] = true
end
local enumCache = {}
Mock.Enum = setmetatable({}, {
	__index = function(_, enumType)
		local items = enumCache[enumType]
		if items == nil then
			items = {}
			enumCache[enumType] = items
		end
		return setmetatable({}, {
			__index = function(_, name)
				local strict = strictEnums[enumType]
				if strict and not strict[name] then
					error(tostring(name) .. " is not a valid member of \"Enum." .. enumType .. "\"", 2)
				end
				local item = items[name]
				if item == nil then
					-- EnumItems are unique singletons in Roblox, so == works
					item = { _type = "EnumItem", EnumType = enumType, Name = name }
					items[name] = item
				end
				return item
			end,
		})
	end,
})
local function enumEq(a, b)
	return type(a) == "table" and type(b) == "table" and a.EnumType == b.EnumType and a.Name == b.Name
end
Mock.enumEq = enumEq

------------------------------------------------------------------- signals
local Signal = {}
Signal.__index = Signal
function Signal.new()
	return setmetatable({ handlers = {} }, Signal)
end
function Signal:Connect(fn)
	assert(type(fn) == "function", "Connect expects a function")
	local h = { fn = fn, connected = true }
	table.insert(self.handlers, h)
	if self.queue then
		-- Roblox delivers queued remote invocations to the first listener
		local q = self.queue
		self.queue = nil
		for _, args in q do
			Task.defer(fn, table.unpack(args, 1, args.n))
		end
	end
	return {
		Disconnect = function()
			h.connected = false
		end,
		Connected = true,
	}
end
function Signal:Fire(...)
	if self.queueing and #self.handlers == 0 then
		self.queue = self.queue or {}
		if #self.queue >= 256 then
			table.insert(Mock.log, "[warn] Remote event invocation queue exhausted")
			Mock.remoteTraffic.dropped = (Mock.remoteTraffic.dropped or 0) + 1
			return
		end
		table.insert(self.queue, table.pack(...))
		return
	end
	for _, h in self.handlers do
		if h.connected then
			Task.defer(h.fn, ...)
		end
	end
end
function Signal:FireNow(...)
	for _, h in self.handlers do
		if h.connected then
			Task.spawn(h.fn, ...)
		end
	end
end
function Signal:Wait()
	local co = coroutine.running()
	local conn
	conn = self:Connect(function(...)
		conn.Disconnect()
		resume(co, ...)
	end)
	return coroutine.yield()
end
Mock.Signal = Signal

---------------------------------------------------------------- instances
local Instance = {}
local EVENTS = {
	RemoteEvent = { "OnServerEvent", "OnClientEvent" },
	BindableEvent = { "Event" },
	TextButton = { "Activated", "MouseButton1Click", "MouseButton2Click", "MouseButton1Down", "MouseButton1Up" },
	Player = { "CharacterAdded", "CharacterRemoving" },
}
local DEFAULTS = {
	Anchored = false, CanCollide = true, CanQuery = true, CanTouch = true, CastShadow = true,
	Transparency = 0, Enabled = true, Visible = true, Text = "", Archivable = true,
	BackgroundTransparency = 0, TextScaled = false, ResetOnSpawn = true, IgnoreGuiInset = false,
	LineThickness = 0.15, Thickness = 1, Massless = false, Locked = false,
}

local function isInstance(v)
	return type(v) == "table" and rawget(v, "_isInstance") == true
end
Mock.isInstance = isInstance

local InstanceMeta = {}
local methods = {}

function methods:FindFirstChild(name)
	for _, c in rawget(self, "_children") do
		if rawget(c, "_props").Name == name then
			return c
		end
	end
	return nil
end
function methods:WaitForChild(name, timeout)
	local c = self:FindFirstChild(name)
	local waited = 0
	while c == nil do
		if timeout and waited >= timeout then
			return nil
		end
		if coroutine.running() == nil or not coroutine.isyieldable() then
			error("WaitForChild(" .. name .. ") would yield forever outside a thread")
		end
		waited += Task.wait(0.1)
		if waited > 30 then
			error("Infinite yield possible on WaitForChild(\"" .. name .. "\")")
		end
		c = self:FindFirstChild(name)
	end
	return c
end
function methods:FindFirstChildOfClass(cls)
	for _, c in rawget(self, "_children") do
		if rawget(c, "_class") == cls then
			return c
		end
	end
	return nil
end
function methods:GetChildren()
	return table.clone(rawget(self, "_children"))
end
function methods:GetDescendants()
	local out = {}
	local function walk(i)
		for _, c in rawget(i, "_children") do
			table.insert(out, c)
			walk(c)
		end
	end
	walk(self)
	return out
end
function methods:IsA(cls)
	local c = rawget(self, "_class")
	if c == cls then
		return true
	end
	if cls == "BasePart" then
		return c == "Part" or c == "MeshPart"
	elseif cls == "GuiObject" then
		return c == "Frame" or c == "TextLabel" or c == "TextButton" or c == "ScrollingFrame" or c == "ImageLabel"
	elseif cls == "Instance" then
		return true
	end
	return false
end
function methods:Destroy()
	self.Parent = nil
	rawset(self, "_destroyed", true)
end
function methods:ClearAllChildren()
	for _, c in self:GetChildren() do
		c:Destroy()
	end
end
function methods:IsDescendantOf(other)
	local p = rawget(self, "_props").Parent
	while p do
		if p == other then
			return true
		end
		p = rawget(p, "_props").Parent
	end
	return false
end
function methods:GetActor()
	local p = self
	while p do
		if rawget(p, "_class") == "Actor" then
			return p
		end
		p = rawget(p, "_props").Parent
	end
	return nil
end
function methods:Clone()
	local c = Instance.new(rawget(self, "_class"))
	for k, v in rawget(self, "_props") do
		if k ~= "Parent" then
			rawget(c, "_props")[k] = v
		end
	end
	for _, k in { "_path", "_methods" } do
		rawset(c, k, rawget(self, k))
	end
	for _, child in rawget(self, "_children") do
		child:Clone().Parent = c
	end
	return c
end
function methods:GetAttribute(name)
	local a = rawget(self, "_attributes")
	return a and a[name]
end
function methods:SetAttribute(name, value)
	local a = rawget(self, "_attributes")
	if a == nil then
		a = {}
		rawset(self, "_attributes", a)
	end
	a[name] = value
end
function methods:GetFullName()
	local names = {}
	local i = self
	while i do
		table.insert(names, 1, rawget(i, "_props").Name)
		i = rawget(i, "_props").Parent
	end
	return table.concat(names, ".")
end

InstanceMeta.__index = function(self, k)
	local props = rawget(self, "_props")
	local v = props[k]
	if v ~= nil then
		return v
	end
	local custom = rawget(self, "_methods")
	if custom and custom[k] then
		return custom[k]
	end
	if methods[k] then
		return methods[k]
	end
	local ev = rawget(self, "_events")[k]
	if ev then
		return ev
	end
	local child = methods.FindFirstChild(self, k)
	if child then
		return child
	end
	if k == "Position" and props.CFrame and (rawget(self, "_class") == "Part" or rawget(self, "_class") == "MeshPart") then
		return props.CFrame.Position
	end
	if DEFAULTS[k] ~= nil then
		return DEFAULTS[k]
	end
	if k == "Parent" or k == "Adornee" or k == "Character" or k == "CurrentCamera" then
		return nil
	end
	error(tostring(k) .. " is not a valid member of " .. rawget(self, "_class") .. " \"" .. tostring(props.Name) .. "\"", 2)
end
InstanceMeta.__newindex = function(self, k, v)
	local props = rawget(self, "_props")
	if rawget(self, "_destroyed") and k == "Parent" and v ~= nil then
		error("The Parent property of " .. tostring(props.Name) .. " is locked (destroyed)", 2)
	end
	if k == "Parent" then
		local old = props.Parent
		if old == v then
			return
		end
		if old then
			local list = rawget(old, "_children")
			local i = table.find(list, self)
			if i then
				table.remove(list, i)
			end
		end
		if v ~= nil then
			assert(isInstance(v), "Parent must be an Instance")
			table.insert(rawget(v, "_children"), self)
		end
		props.Parent = v
		if v ~= nil and Mock.onParented then
			Mock.onParented(self, v)
		end
		return
	end
	local isPart = rawget(self, "_class") == "Part" or rawget(self, "_class") == "MeshPart"
	if k == "Position" and isPart then
		assert(type(v) == "table" and getmetatable(v) ~= nil and v.X, "Position expects Vector3")
		props.CFrame = Mock.CFrame.new(v.X, v.Y, v.Z)
		return
	end
	if k == "CFrame" then
		assert(type(v) == "table" and rawget(v, "_cf"), "CFrame property expects a CFrame")
	end
	if k == "Size" and (rawget(self, "_class") == "Part" or rawget(self, "_class") == "MeshPart") then
		assert(type(v) == "table" and v.X and v.X >= 0 and v.Y >= 0 and v.Z >= 0, "Size expects non-negative Vector3")
	end
	props[k] = v
end
InstanceMeta.__tostring = function(self)
	return rawget(self, "_props").Name
end

function Instance.new(cls, parent)
	assert(type(cls) == "string", "Instance.new expects a class name")
	local inst = setmetatable({ _isInstance = true, _class = cls, _props = { Name = cls, ClassName = cls }, _children = {}, _events = {} }, InstanceMeta)
	for _, e in EVENTS[cls] or {} do
		local sig = Signal.new()
		sig.queueing = cls == "RemoteEvent"
		rawget(inst, "_events")[e] = sig
	end
	if cls == "Actor" then
		local handlers = {}
		Mock.addMethods(inst, {
			BindToMessageParallel = function(_, topic, fn)
				handlers[topic] = fn
			end,
			BindToMessage = function(_, topic, fn)
				handlers[topic] = fn
			end,
			SendMessage = function(_, topic, ...)
				local fn = handlers[topic]
				assert(fn, "Actor:SendMessage to an unbound topic " .. tostring(topic))
				local args = table.pack(...)
				local copy = {}
				for i = 1, args.n do
					copy[i] = Mock.remoteCopy(args[i])
				end
				Task.defer(fn, table.unpack(copy, 1, args.n))
			end,
		})
	elseif cls == "BindableEvent" then
		Mock.addMethods(inst, {
			Fire = function(self2, ...)
				local args = table.pack(...)
				local copy = {}
				for i = 1, args.n do
					copy[i] = Mock.remoteCopy(args[i])
				end
				self2.Event:Fire(table.unpack(copy, 1, args.n))
			end,
		})
	end
	if cls == "Part" or cls == "MeshPart" then
		local p = rawget(inst, "_props")
		p.Size = v3(4, 1, 2)
		p.CFrame = Mock.CFrame.new(0, 0, 0)
	end
	if parent then
		inst.Parent = parent
	end
	return inst
end
Mock.Instance = Instance

function Mock.addMethods(inst, tbl)
	local m = rawget(inst, "_methods") or {}
	for k, v in tbl do
		m[k] = v
	end
	rawset(inst, "_methods", m)
end
function Mock.addEvent(inst, name)
	local s = Signal.new()
	rawget(inst, "_events")[name] = s
	return s
end

-------------------------------------------------------- serialisation rules
-- RemoteEvent arguments: no functions/threads, tables must be pure arrays or
-- pure string-keyed dictionaries, no cycles. Values are deep-copied.
local function remoteCopy(v, path, seen)
	local tv = type(v)
	if tv == "function" or tv == "thread" or tv == "userdata" then
		error("cannot send " .. tv .. " over a remote at " .. path, 0)
	elseif tv == "buffer" then
		local b = buffer.create(buffer.len(v))
		buffer.copy(b, 0, v)
		return b
	elseif tv == "number" then
		return v
	elseif tv ~= "table" then
		return v
	end
	if isInstance(v) then
		return v
	end
	if v._type then
		return table.clone(v)
	end
	assert(not seen[v], "cyclic table sent over remote at " .. path)
	seen[v] = true
	local n, hasString, hasNumber = 0, false, false
	for k in v do
		n += 1
		if type(k) == "string" then
			hasString = true
		elseif type(k) == "number" then
			hasNumber = true
		else
			error("unsupported key type " .. type(k) .. " at " .. path, 0)
		end
	end
	if hasString and hasNumber then
		error("mixed table (array + dictionary) sent over remote at " .. path, 0)
	end
	if hasNumber and n ~= #v then
		error("sparse array sent over remote at " .. path .. " (Roblox truncates it)", 0)
	end
	local out = {}
	for k, x in v do
		out[k] = remoteCopy(x, path .. "." .. tostring(k), seen)
	end
	seen[v] = nil
	return out
end
Mock.remoteCopy = function(v)
	return remoteCopy(v, "arg", {})
end

-- DataStore values must be JSON-encodable: strings, numbers, booleans,
-- arrays, string-keyed dictionaries; no buffers, NaN or inf. Max 4 MB.
local function jsonSize(v, path)
	local tv = type(v)
	if tv == "string" then
		assert(utf8.len(v) ~= nil, "invalid UTF-8 string in DataStore value at " .. path)
		return #v + 2
	elseif tv == "number" then
		assert(v == v and v ~= math.huge and v ~= -math.huge, "NaN/inf in DataStore value at " .. path)
		return 24
	elseif tv == "boolean" or tv == "nil" then
		return 5
	elseif tv == "table" then
		local size = 2
		local n, hasS, hasN = 0, false, false
		for k, x in v do
			n += 1
			if type(k) == "string" then
				hasS = true
				size += #k + 3
			elseif type(k) == "number" then
				hasN = true
			else
				error("bad key type in DataStore value at " .. path, 0)
			end
			size += jsonSize(x, path .. "." .. tostring(k)) + 1
		end
		assert(not (hasS and hasN), "mixed table in DataStore value at " .. path)
		assert(not hasN or n == #v, "sparse array in DataStore value at " .. path)
		return size
	end
	error("cannot store " .. tv .. " in a DataStore at " .. path, 0)
end
Mock.jsonSize = jsonSize

-- EditableMesh (validates ids/limits like the engine: 60k verts, 20k tris)
function Mock.newEditableMesh()
	local em = Instance.new("EditableMesh")
	local nv, nt, nc, nu = 0, 0, 0, 0
	Mock.addMethods(em, {
		AddVertex = function(_, p)
			assert(type(p) == "table" and getmetatable(p) ~= nil and p.X, "AddVertex expects Vector3")
			nv += 1
			assert(nv <= 60000, "EditableMesh vertex limit exceeded")
			return nv
		end,
		AddColor = function(_, c, a)
			assert(type(c) == "table" and c._type == "Color3" and type(a) == "number", "AddColor(Color3, alpha)")
			nc += 1
			return nc
		end,
		AddUV = function(_, uv)
			assert(type(uv) == "table" and uv._type == "Vector2", "AddUV expects Vector2")
			nu += 1
			return nu
		end,
		AddTriangle = function(_, a, b, c)
			for _, v in { a, b, c } do
				assert(type(v) == "number" and v >= 1 and v <= nv, "AddTriangle: bad vertex id")
			end
			nt += 1
			assert(nt <= 20000, "EditableMesh triangle limit exceeded")
			return nt
		end,
		SetFaceColors = function(_, f, ids)
			assert(f >= 1 and f <= nt and #ids == 3, "SetFaceColors")
			for _, i in ids do
				assert(i >= 1 and i <= nc, "bad color id")
			end
		end,
		SetFaceUVs = function(_, f, ids)
			assert(f >= 1 and f <= nt and #ids == 3, "SetFaceUVs")
			for _, i in ids do
				assert(i >= 1 and i <= nu, "bad uv id")
			end
		end,
	})
	rawset(em, "_counts", function()
		return nv, nt
	end)
	return em
end

Mock.Content = {
	fromObject = function(obj)
		assert(Mock.isInstance(obj), "Content.fromObject expects an Instance")
		return { _type = "Content", object = obj }
	end,
	fromUri = function(uri)
		return { _type = "Content", uri = uri }
	end,
}

return Mock
