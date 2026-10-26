--!strict
-- Assigns a stable small integer to each texture name referenced by
-- BlockData, and resolves (block id, face) -> texture index.
-- Faces: 0 +X east, 1 -X west, 2 +Y up, 3 -Y down, 4 +Z south, 5 -Z north.

local BlockRegistry = require("../Blocks/BlockRegistry")

local TextureIndex = {}

local names: { string } = {}
local indexOf: { [string]: number } = {}
-- faceTex[id * 6 + face + 1] = texture index (0 = none)
local faceTex: { number } = table.create(4096 * 6, 0)

local function intern(name: string): number
	local i = indexOf[name]
	if i == nil then
		table.insert(names, name)
		i = #names
		indexOf[name] = i
	end
	return i
end

for _, def in BlockRegistry.all() do
	local tex = def.textures
	local all = tex.all
	local side = tex.side or all
	local top = tex.top or all or side
	local bottom = tex.bottom or all or side
	if side == nil then
		side = top
	end
	if top == nil then
		continue
	end
	local base = def.id * 6
	local sideI = intern(side :: string)
	faceTex[base + 1] = sideI
	faceTex[base + 2] = sideI
	faceTex[base + 3] = intern(top :: string)
	faceTex[base + 4] = intern(bottom :: string)
	faceTex[base + 5] = sideI
	faceTex[base + 6] = sideI
end

function TextureIndex.forFace(id: number, face: number): number
	return faceTex[id * 6 + face + 1] or 0
end

function TextureIndex.name(index: number): string?
	return names[index]
end

function TextureIndex.indexOf(name: string): number?
	return indexOf[name]
end

function TextureIndex.count(): number
	return #names
end

TextureIndex._faceTex = faceTex

return TextureIndex
