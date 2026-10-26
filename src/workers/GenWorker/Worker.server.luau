--!nonstrict
-- Parallel world-generation worker. Lives in ServerStorage as a template
-- (scripts do not run there); the server clones it into ServerScriptService
-- once per worker. Each clone is an Actor with its own Luau VM, so it has its
-- own generator caches. Generation runs in the parallel phase; the encoded
-- chunk is handed back in the serial phase through a BindableEvent.

local actor = script:GetActor()
if actor == nil or not script:IsDescendantOf(game:GetService("ServerScriptService")) then
	return -- template copy
end
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local WorldGenerator = require(Shared.WorldGen.WorldGenerator)
local WorldSeed = require(Shared.WorldGen.WorldSeed)
local ChunkCodec = require(Shared.Persistence.ChunkCodec)
local done: BindableEvent = ServerStorage:WaitForChild("mclceGenDone")

local generators = {}

actor:BindToMessageParallel("gen", function(jobId: number, cx: number, cz: number, dimension: string, seedText: string)
	local key = dimension .. "|" .. seedText
	local g = generators[key]
	if g == nil then
		g = WorldGenerator.new(WorldSeed.fromString(seedText), { cacheCapacity = 96, dimension = dimension })
		generators[key] = g
	end
	local ok, result = pcall(function()
		return ChunkCodec.encode(WorldGenerator.generate(g, cx, cz))
	end)
	task.synchronize()
	done:Fire(jobId, if ok then result else nil, if ok then nil else tostring(result))
end)
