--!nonstrict
-- Device-independent action state. Gameplay code reads `actions` only; the
-- bindings below map keyboard/mouse, gamepad (Legacy layout: RT break,
-- LT use/place, RB/LB hotbar) and touch buttons onto them.

local UserInputService = game:GetService("UserInputService")
local ContextActionService = game:GetService("ContextActionService")

local Input = {}

Input.actions = {
	breakHeld = false,
	breakPressed = false, -- edge-triggered, consumed (attacks)
	placePressed = false, -- edge-triggered, consumed by the client loop
	placeHeld = false,
	hotbarDelta = 0, -- consumed
	hotbarSelect = 0, -- 1..9, consumed
	openInventory = false, -- consumed
}

-- Menu actions queued for the UI layer (MenuModel / CraftingModel action names).
Input.menuQueue = {}

local MENU_KEYS = {
	[Enum.KeyCode.ButtonStart] = "pause", [Enum.KeyCode.P] = "pause",
	[Enum.KeyCode.ButtonY] = "inventory", [Enum.KeyCode.I] = "inventory",
	[Enum.KeyCode.ButtonX] = "crafting", [Enum.KeyCode.C] = "crafting", [Enum.KeyCode.E] = "crafting",
	[Enum.KeyCode.ButtonB] = "back", [Enum.KeyCode.Backspace] = "back",
	[Enum.KeyCode.DPadLeft] = "left", [Enum.KeyCode.Left] = "left",
	[Enum.KeyCode.DPadRight] = "right", [Enum.KeyCode.Right] = "right",
	[Enum.KeyCode.DPadUp] = "up", [Enum.KeyCode.Up] = "up",
	[Enum.KeyCode.DPadDown] = "down", [Enum.KeyCode.Down] = "down",
	[Enum.KeyCode.ButtonA] = "confirm", [Enum.KeyCode.Return] = "confirm",
	[Enum.KeyCode.ButtonL1] = "tabPrev", [Enum.KeyCode.Q] = "tabPrev",
	[Enum.KeyCode.ButtonR1] = "tabNext", [Enum.KeyCode.R] = "tabNext",
}

local KEYS = {
	[Enum.KeyCode.One] = 1, [Enum.KeyCode.Two] = 2, [Enum.KeyCode.Three] = 3,
	[Enum.KeyCode.Four] = 4, [Enum.KeyCode.Five] = 5, [Enum.KeyCode.Six] = 6,
	[Enum.KeyCode.Seven] = 7, [Enum.KeyCode.Eight] = 8, [Enum.KeyCode.Nine] = 9,
}

function Input.start()
	local a = Input.actions
	UserInputService.InputBegan:Connect(function(io, processed)
		if processed then
			return
		end
		local t, k = io.UserInputType, io.KeyCode
		local menuAction = MENU_KEYS[k]
		if menuAction then
			table.insert(Input.menuQueue, menuAction)
		end
		if t == Enum.UserInputType.MouseButton1 or k == Enum.KeyCode.ButtonR2 then
			a.breakHeld = true
			a.breakPressed = true
		elseif t == Enum.UserInputType.MouseButton2 or k == Enum.KeyCode.ButtonL2 then
			a.placePressed = true
			a.placeHeld = true
		elseif k == Enum.KeyCode.ButtonR1 then
			a.hotbarDelta += 1
		elseif k == Enum.KeyCode.ButtonL1 then
			a.hotbarDelta -= 1
		elseif k == Enum.KeyCode.ButtonY then
			a.openInventory = true
		elseif KEYS[k] then
			a.hotbarSelect = KEYS[k]
		end
	end)
	UserInputService.InputEnded:Connect(function(io)
		local t, k = io.UserInputType, io.KeyCode
		if t == Enum.UserInputType.MouseButton1 or k == Enum.KeyCode.ButtonR2 then
			a.breakHeld = false
		elseif t == Enum.UserInputType.MouseButton2 or k == Enum.KeyCode.ButtonL2 then
			a.placeHeld = false
		end
	end)
	UserInputService.InputChanged:Connect(function(io, processed)
		if not processed and io.UserInputType == Enum.UserInputType.MouseWheel then
			a.hotbarDelta += if io.Position.Z > 0 then -1 else 1
		end
	end)
	-- touch: on-screen buttons
	if UserInputService.TouchEnabled then
		ContextActionService:BindAction("mclceBreak", function(_, state)
			a.breakHeld = state == Enum.UserInputState.Begin
			return Enum.ContextActionResult.Sink
		end, true)
		ContextActionService:SetTitle("mclceBreak", "Mine")
		ContextActionService:BindAction("mclcePlace", function(_, state)
			if state == Enum.UserInputState.Begin then
				a.placePressed = true
			end
			return Enum.ContextActionResult.Sink
		end, true)
		ContextActionService:SetTitle("mclcePlace", "Place")
	end
end

return Input
