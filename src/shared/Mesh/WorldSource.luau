--!strict
-- Adapts a World into a mesher ChunkSource. Unloaded chunks inside the world
-- border are treated as solid (their shared faces are re-meshed when they
-- load); beyond the border is air so the world edge renders closed.
local World = require("../Voxel/World")
local Padded = require("./Padded")

local WorldSource = {}

local OCCLUDER = 1 * 16 -- stone

function WorldSource.new(world: World.World): Padded.ChunkSource
	return {
		getChunk = function(cx: number, cz: number)
			return World.getChunk(world, cx, cz)
		end,
		missingState = function(cx: number, cz: number): number
			if World.chunkInBorder(world, cx, cz) then
				return OCCLUDER
			end
			return 0
		end,
	}
end

return WorldSource
