--!nonstrict
-- Minimal chat: T opens a text box, Enter sends (commands start with "/"),
-- the last 8 lines are shown above the hotbar. Uses our own remote so host
-- commands are validated by the server like any other request.
local ChatBox = {}
ChatBox.__index = ChatBox

function ChatBox.new(playerGui: PlayerGui, onSend: (text: string) -> ())
	local self = setmetatable({}, ChatBox)
	local gui = Instance.new("ScreenGui")
	gui.Name = "mclceChat"
	gui.ResetOnSpawn = false
	gui.Parent = playerGui
	local log = Instance.new("TextLabel")
	log.Name = "Log"
	log.BackgroundTransparency = 1
	log.Position = UDim2.new(0, 8, 1, -260)
	log.Size = UDim2.fromOffset(520, 160)
	log.Font = Enum.Font.Arcade
	log.TextSize = 18
	log.TextXAlignment = Enum.TextXAlignment.Left
	log.TextYAlignment = Enum.TextYAlignment.Bottom
	log.TextColor3 = Color3.new(1, 1, 1)
	log.TextStrokeTransparency = 0.4
	log.Text = ""
	log.Parent = gui
	local box = Instance.new("TextBox")
	box.Name = "Input"
	box.Position = UDim2.new(0, 8, 1, -96)
	box.Size = UDim2.fromOffset(520, 28)
	box.Font = Enum.Font.Arcade
	box.TextSize = 18
	box.Text = ""
	box.PlaceholderText = "Type a message or /command"
	box.ClearTextOnFocus = true
	box.Visible = false
	box.Parent = gui
	box.FocusLost:Connect(function(enterPressed)
		local text = box.Text
		box.Visible = false
		if enterPressed and #text > 0 then
			onSend(string.sub(text, 1, 200))
		end
	end)
	self.gui, self.log, self.box = gui, log, box
	self.shown = 0
	return self
end

function ChatBox:open()
	self.box.Visible = true
	self.box:CaptureFocus()
end

function ChatBox:isTyping(): boolean
	return self.box.Visible
end

function ChatBox:render(lines: { { string } })
	if #lines == self.shown then
		return
	end
	self.shown = #lines
	local out = {}
	for i = math.max(1, #lines - 7), #lines do
		local l = lines[i]
		table.insert(out, if l[1] == "" then l[2] else "<" .. l[1] .. "> " .. l[2])
	end
	self.log.Text = table.concat(out, "\n")
end

return ChatBox
