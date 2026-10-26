--!strict
-- In-game screen stack for the Legacy Console UI. Screens: "hud" (base),
-- "pause", "inventory", "crafting", "container", "death", "settings".
-- Gamepad mapping (Legacy): Options/Start = pause, Y/Triangle = inventory,
-- X/Square = crafting, B/Circle = back. The model only tracks state; renderers
-- draw it and the client sends network requests on transitions.

export type Screen = { name: string, focus: number }
export type Model = { stack: { Screen }, events: { string } }

local MenuModel = {}

MenuModel.PAUSE_ITEMS = { "resume", "settings", "how_to_play", "save_and_quit" }

function MenuModel.new(): Model
	return { stack = { { name = "hud", focus = 1 } }, events = {} }
end

function MenuModel.top(m: Model): Screen
	return m.stack[#m.stack]
end

function MenuModel.isGameplay(m: Model): boolean
	return MenuModel.top(m).name == "hud"
end

local function push(m: Model, name: string)
	table.insert(m.stack, { name = name, focus = 1 })
	table.insert(m.events, "open:" .. name)
end

local function pop(m: Model)
	if #m.stack > 1 then
		local s = table.remove(m.stack) :: Screen
		table.insert(m.events, "close:" .. s.name)
	end
end

-- Server-driven screens (death, container) replace whatever is open.
function MenuModel.force(m: Model, name: string?)
	while #m.stack > 1 do
		pop(m)
	end
	if name then
		push(m, name)
	end
end

-- Actions: "pause", "inventory", "crafting", "back", "up", "down", "confirm".
-- Returns the confirmed item name on "confirm" in list screens.
function MenuModel.input(m: Model, action: string): string?
	local top = MenuModel.top(m)
	if top.name == "death" then
		if action == "confirm" then
			return "respawn"
		end
		return nil
	end
	if action == "pause" then
		if top.name == "hud" then
			push(m, "pause")
		elseif top.name == "pause" then
			pop(m)
		end
	elseif action == "inventory" or action == "crafting" then
		if top.name == "hud" then
			push(m, action)
		elseif top.name == action then
			pop(m)
		end
	elseif action == "back" then
		pop(m)
	elseif top.name == "pause" then
		local n = #MenuModel.PAUSE_ITEMS
		if action == "up" then
			top.focus = (top.focus - 2) % n + 1
		elseif action == "down" then
			top.focus = top.focus % n + 1
		elseif action == "confirm" then
			local item = MenuModel.PAUSE_ITEMS[top.focus]
			if item == "resume" then
				pop(m)
			elseif item == "settings" then
				push(m, "settings")
			end
			return item
		end
	end
	return nil
end

function MenuModel.takeEvents(m: Model): { string }
	local e = m.events
	m.events = {}
	return e
end

return MenuModel
