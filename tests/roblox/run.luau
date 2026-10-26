-- Scripted session: boot server, join one player, start the client, stream,
-- mine, place, shut down. Fails on any script error or broken expectation.
local H = require("./Harness")
local Mock = H.Mock
local check = H.check

print("[mock] boot server")
H.runScript("server", "src/server/Main.server.luau")
H.run(1)
local RS = H.services.ReplicatedStorage
check(RS:FindFirstChild("mclceC2S") ~= nil and RS:FindFirstChild("mclceS2C") ~= nil, "server created remotes")

print("[mock] player joins, client starts")
local player = H.addPlayer(1001, "alice")
H.run(0.5)
H.runScript("client", "src/client/Main.client.luau")
H.run(10)

for _, e in Mock.errors do
	print("SCRIPT ERROR (boot): " .. e)
end
local ws = H.services.Workspace
local worldFolder = ws:FindFirstChild("mclceWorld")
check(worldFolder ~= nil, "client created world folder")
local sections, parts = 0, 0
if worldFolder then
	for _, f in worldFolder:GetChildren() do
		sections += 1
		parts += #f:GetChildren()
	end
end
check(sections > 20, "rendered sections: " .. sections)
check(parts > 100, "rendered parts: " .. parts)
local root = player.Character.HumanoidRootPart
check(root.Anchored == false, "character unanchored after client HELLO")
check(player.PlayerGui:FindFirstChild("mclceHud") ~= nil, "HUD created")
check(Mock.enumEq(player.CameraMode, Mock.Enum.CameraMode.LockFirstPerson), "first-person camera")
check((H.trafficByKind[2] or 0) >= 50, "chunks streamed: " .. tostring(H.trafficByKind[2]))

print("[mock] mine the block under the player, then place onto a neighbour")
local BS = 3
local gs = H.sideG.server.mclceServer.gs
local SWorld = H.caches.server["src/shared/Voxel/World.luau"]
local SInventory = H.caches.server["src/shared/Items/Inventory.luau"]
local SItemStack = H.caches.server["src/shared/Items/ItemStack.luau"]
local sp = gs.players[1001]
-- no physics in the mock: declare the character grounded (else mining is 5x slower)
player.Character.Humanoid.FloorMaterial = Mock.Enum.Material.Grass
local bx, by, bz = math.floor(sp.x), math.floor(sp.y), math.floor(sp.z)
SWorld.setState(gs.world, bx, by - 1, bz, 3 * 16) -- dirt under the feet
SWorld.setState(gs.world, bx + 1, by - 1, bz, 1 * 16) -- stone neighbour
SWorld.setState(gs.world, bx + 1, by, bz, 0)
SWorld.setState(gs.world, bx + 1, by + 1, bz, 0)
H.run(0.5)
local eye = Mock.Vector3.new(sp.x * BS, (sp.y + 1.62) * BS, sp.z * BS)
local camera = ws.CurrentCamera
camera.CFrame = Mock.CFrame.new(eye, Mock.Vector3.new(sp.x * BS, (by - 2) * BS, sp.z * BS))
local UIS = H.services.UserInputService
local MB1 = { UserInputType = Mock.Enum.UserInputType.MouseButton1, KeyCode = Mock.Enum.KeyCode.Unknown }
local MB2 = { UserInputType = Mock.Enum.UserInputType.MouseButton2, KeyCode = Mock.Enum.KeyCode.Unknown }
UIS.InputBegan:Fire(MB1, false)
H.run(2) -- dirt by hand: 0.75 s
UIS.InputEnded:Fire(MB1)
H.run(0.5)
check(SWorld.getId(gs.world, bx, by - 1, bz) == 0, "server accepted the timed break")
check(gs.items.count >= 1 or SInventory.count(sp.inventory, 3) >= 1, "dirt dropped")
SInventory.add(sp.inventory, SItemStack.new(4, 3))
sp.inventory.selected = 1
for i = 1, 9 do
	local s = sp.inventory.slots[i]
	if s and s.id == 4 then
		sp.inventory.selected = i
	end
end
sp.inventory.version += 1
H.run(0.3) -- inventory replicates to the client
camera.CFrame = Mock.CFrame.new(eye, Mock.Vector3.new((bx + 1.5) * BS, by * BS, (bz + 0.5) * BS))
UIS.InputBegan:Fire(MB2, false)
H.run(0.1)
UIS.InputEnded:Fire(MB2)
H.run(0.5)
check(SWorld.getId(gs.world, bx + 1, by, bz) == 4, "placed cobblestone on the neighbour's top face")
check(player.PlayerGui.mclceHud.Debug.Text ~= "", "HUD debug text: " .. player.PlayerGui.mclceHud.Debug.Text)

print("[mock] open crafting menu")
UIS.InputBegan:Fire({ UserInputType = Mock.Enum.UserInputType.Keyboard, KeyCode = Mock.Enum.KeyCode.E }, false)
H.run(0.2)
check(player.PlayerGui.mclceCrafting.Enabled == true, "crafting menu opens")
UIS.InputBegan:Fire({ UserInputType = Mock.Enum.UserInputType.Keyboard, KeyCode = Mock.Enum.KeyCode.E }, false)
H.run(0.2)

print("[mock] autosave + shutdown")
H.run(31)
check(H.dsCalls.set > 0, "autosave wrote to DataStore (sets=" .. H.dsCalls.set .. ")")
for _, fn in H.closeHandlers do
	Mock.task.spawn(fn)
end
H.run(5)
local store = H.stores["mclce_world_v1"]
check(store ~= nil and store["default/meta"] ~= nil, "world meta saved")
check(store ~= nil and store["default/p/1001"] ~= nil, "player record saved on shutdown")

for _, l in Mock.log do
	print("  log " .. l)
end
if #Mock.errors > 0 then
	for _, e in Mock.errors do
		print("SCRIPT ERROR: " .. e)
	end
end
print(string.format("[mock] remote msgs to client=%d (%.1f KB buffers), to server=%d; datastore gets=%d sets=%d",
	Mock.remoteTraffic.toClient, Mock.remoteTraffic.bytesToClient / 1024, Mock.remoteTraffic.toServer, H.dsCalls.get, H.dsCalls.set))
local failed = H.failures() + #Mock.errors
print(failed == 0 and "[mock] PASS" or ("[mock] FAILED (" .. failed .. ")"))
if failed > 0 then
	error("roblox mock session failed", 0)
end
