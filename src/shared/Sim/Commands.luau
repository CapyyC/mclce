--!strict
-- Host/admin chat commands (Legacy hosts had in-game host options; these
-- are also the main tool for manual Studio testing):
--   /gamemode survival|creative|0|1      /time set day|night|<ticks>
--   /weather clear|rain|thunder           /give <item id|name> [count] [meta]
--   /tp <x> <y> <z>                       /kill   /heal
-- Returns a reply string, or nil when the text is not a command.

local ItemRegistry = require("../Items/ItemRegistry")
local ItemStack = require("../Items/ItemStack")
local Inventory = require("../Items/Inventory")

local Commands = {}

export type Api = {
	setGamemode: (mode: string) -> (),
	setTime: (ticks: number) -> (),
	setWeather: (raining: boolean, thundering: boolean) -> (),
	inventory: Inventory.Inventory,
	teleport: (x: number, y: number, z: number) -> (),
	kill: () -> (),
	heal: () -> (),
}

local function words(s: string): { string }
	local out = {}
	for w in string.gmatch(s, "%S+") do
		table.insert(out, w)
	end
	return out
end

function Commands.run(text: string, isAdmin: boolean, api: Api): string?
	if string.sub(text, 1, 1) ~= "/" then
		return nil
	end
	if not isAdmin then
		return "Only the host can use commands"
	end
	local w = words(string.sub(text, 2))
	local cmd = w[1] and string.lower(w[1])
	if cmd == "gamemode" then
		local m = w[2] and string.lower(w[2])
		local mode = if m == "creative" or m == "1" or m == "c" then "creative" elseif m == "survival" or m == "0" or m == "s" then "survival" else nil
		if mode == nil then
			return "Usage: /gamemode survival|creative"
		end
		api.setGamemode(mode)
		return "Game mode set to " .. mode
	elseif cmd == "time" and w[2] == "set" then
		local v = w[3]
		local ticks = if v == "day" then 1000 elseif v == "noon" then 6000 elseif v == "night" then 13000 elseif v == "midnight" then 18000 else tonumber(v)
		if ticks == nil or ticks ~= math.floor(ticks) then
			return "Usage: /time set day|night|<ticks>"
		end
		api.setTime(ticks % 24000)
		return "Time set to " .. ticks % 24000
	elseif cmd == "weather" then
		local v = w[2]
		if v == "clear" then
			api.setWeather(false, false)
		elseif v == "rain" then
			api.setWeather(true, false)
		elseif v == "thunder" then
			api.setWeather(true, true)
		else
			return "Usage: /weather clear|rain|thunder"
		end
		return "Weather: " .. v
	elseif cmd == "give" then
		local item = w[2]
		local def = if item then (ItemRegistry.get(tonumber(item) or -1) or ItemRegistry.byName(item)) else nil
		if def == nil then
			return "Unknown item"
		end
		local count = math.clamp(math.floor(tonumber(w[3]) or 1), 1, 64 * 36)
		local meta = math.clamp(math.floor(tonumber(w[4]) or 0), 0, 15)
		local left = count
		while left > 0 do
			local n = math.min(left, def.maxStack)
			if Inventory.add(api.inventory, ItemStack.new(def.id, n, meta)) > 0 then
				break
			end
			left -= n
		end
		return string.format("Gave %d %s", count - math.max(left, 0), def.name)
	elseif cmd == "tp" then
		local x, y, z = tonumber(w[2]), tonumber(w[3]), tonumber(w[4])
		if x == nil or y == nil or z == nil then
			return "Usage: /tp <x> <y> <z>"
		end
		api.teleport(x, y, z)
		return string.format("Teleported to %g %g %g", x, y, z)
	elseif cmd == "kill" then
		api.kill()
		return "Killed"
	elseif cmd == "heal" then
		api.heal()
		return "Healed"
	end
	return "Unknown command"
end

return Commands
