--!strict
-- The 16 classic dye/wool colours by data value (0 white .. 15 black) and
-- the per-state colour lookup renderers use for metadata-coloured blocks.
local BlockRegistry = require("./BlockRegistry")

local Colors = {}

Colors.NAMES = {
	[0] = "white", "orange", "magenta", "light_blue", "yellow", "lime", "pink", "gray",
	"silver", "cyan", "purple", "blue", "brown", "green", "red", "black",
}

-- wool tints (approximate RGB of the classic textures)
Colors.WOOL = {
	[0] = { 234, 236, 237 }, { 240, 118, 19 }, { 189, 68, 179 }, { 58, 175, 217 },
	{ 248, 198, 39 }, { 112, 185, 25 }, { 237, 141, 172 }, { 62, 68, 71 },
	{ 142, 142, 134 }, { 21, 137, 145 }, { 121, 42, 172 }, { 53, 57, 157 },
	{ 114, 71, 40 }, { 84, 109, 27 }, { 161, 39, 34 }, { 20, 21, 25 },
}

-- Dye item (351) data value -> wool colour data value (dye meta d colours wool 15 - d).
function Colors.woolFromDye(dyeMeta: number): number
	return 15 - dyeMeta
end

local COLORED: { [number]: boolean } = { [35] = true, [159] = true }

-- RGB for a block state, honouring metadata colours.
function Colors.forState(state: number): { number }
	local id, meta = state // 16, state % 16
	if COLORED[id] then
		local c = Colors.WOOL[meta]
		if id == 159 then
			-- stained clay is a darker, muted version
			return { math.floor(c[1] * 0.62 + 40), math.floor(c[2] * 0.55 + 30), math.floor(c[3] * 0.5 + 25) }
		end
		return c
	end
	local d = BlockRegistry.get(id)
	return if d then d.color else { 255, 0, 255 }
end

function Colors.isColored(id: number): boolean
	return COLORED[id] == true
end

return Colors
