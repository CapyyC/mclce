--!nonstrict
-- Adapts a Roblox DataStore to SaveManager's Backend interface
-- ({ get, set } returning (ok, value | err)). Calls yield. Request budgets are
-- checked so we never queue requests Roblox would throttle; when the budget is
-- empty the call fails fast and SaveManager retries later with backoff.
--
-- Falls back to an in-memory backend when DataStores are unavailable
-- (e.g. Studio without "Enable Studio Access to API Services"); that fallback
-- is NOT persistent and is reported loudly.

local DataStoreService = game:GetService("DataStoreService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SaveManager = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Persistence"):WaitForChild("SaveManager"))

local DataStoreBackend = {}

local function budget(kind: Enum.DataStoreRequestType): number
	local ok, n = pcall(function()
		return DataStoreService:GetRequestBudgetForRequestType(kind)
	end)
	return if ok then n else 0
end

function DataStoreBackend.new(storeName: string)
	local okStore, store = pcall(function()
		return DataStoreService:GetDataStore(storeName)
	end)
	-- probe access once
	local usable = okStore and pcall(function()
		return store:GetAsync("__probe")
	end)
	if not usable then
		warn("[mclce] DataStores unavailable; using NON-PERSISTENT memory backend")
		local mem = SaveManager.memoryBackend()
		return mem, false
	end
	local backend = {
		get = function(key: string)
			if budget(Enum.DataStoreRequestType.GetAsync) < 1 then
				return false, "get budget exhausted"
			end
			local ok, v = pcall(function()
				return store:GetAsync(key)
			end)
			return ok, v
		end,
		set = function(key: string, value: any)
			if budget(Enum.DataStoreRequestType.SetIncrementAsync) < 1 then
				return false, "set budget exhausted"
			end
			local ok, err = pcall(function()
				store:SetAsync(key, value)
			end)
			return ok, if ok then nil else tostring(err)
		end,
	}
	return backend, true
end

function DataStoreBackend.setBudget(): number
	return budget(Enum.DataStoreRequestType.SetIncrementAsync)
end

return DataStoreBackend
