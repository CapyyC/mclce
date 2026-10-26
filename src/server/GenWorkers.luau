--!nonstrict
-- Pool of parallel generation Actors (see src/workers/GenWorker). Requests are
-- distributed round-robin; results come back through a BindableEvent and are
-- decoded on the main thread. Returns nil (generate in-thread) when the
-- template is missing or workers are disabled.

local ServerStorage = game:GetService("ServerStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ChunkCodec = require(ReplicatedStorage:WaitForChild("Shared").Persistence.ChunkCodec)

local GenWorkers = {}
GenWorkers.__index = GenWorkers

function GenWorkers.start(count: number)
	if count <= 0 then
		return nil
	end
	local folder = ServerStorage:FindFirstChild("mclceWorkers")
	local template = folder and folder:FindFirstChild("GenWorker")
	if template == nil then
		warn("[mclce] no GenWorker template; generating on the main thread")
		return nil
	end
	local self = setmetatable({}, GenWorkers)
	self.done = Instance.new("BindableEvent")
	self.done.Name = "mclceGenDone"
	self.done.Parent = ServerStorage
	self.actors = {}
	local holder = Instance.new("Folder")
	holder.Name = "mclceGenActors"
	holder.Parent = ServerScriptService
	for i = 1, count do
		local a = template:Clone()
		a.Name = "GenWorker" .. i
		a.Parent = holder
		table.insert(self.actors, a)
	end
	self.nextJob = 1
	self.rr = 1
	self.jobs = {}
	self.stats = { requested = 0, completed = 0, failed = 0 }
	self.done.Event:Connect(function(jobId, buf, err)
		local job = self.jobs[jobId]
		self.jobs[jobId] = nil
		if job == nil then
			return
		end
		if buf == nil then
			self.stats.failed += 1
			warn("[mclce] generation failed: " .. tostring(err))
			return
		end
		self.stats.completed += 1
		local ok, chunk = pcall(ChunkCodec.decode, buf)
		if ok and self.handler then
			self.handler(job.dimension, chunk)
		end
	end)
	return self
end

function GenWorkers:onResult(fn)
	self.handler = fn
end

function GenWorkers:request(cx: number, cz: number, dimension: string, seedText: string)
	local id = self.nextJob
	self.nextJob += 1
	self.jobs[id] = { dimension = dimension }
	local actor = self.actors[self.rr]
	self.rr = self.rr % #self.actors + 1
	self.stats.requested += 1
	actor:SendMessage("gen", id, cx, cz, dimension, seedText)
end

return GenWorkers
