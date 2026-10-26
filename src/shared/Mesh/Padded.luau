--!strict
--!native
-- Copies one 16^3 section plus a one-block border (18^3) into a reusable
-- u16 buffer so meshers can sample neighbours without per-block chunk lookups.
-- Padded index = (x+1) + (z+1)*18 + (y+1)*324 for x,y,z in [-1, 16].

local Chunk = require("../Voxel/Chunk")

export type ChunkSource = {
	getChunk: (cx: number, cz: number) -> Chunk.Chunk?,
	-- State to assume for blocks in a neighbour chunk that is not loaded.
	-- Returning an occluding state (e.g. stone) suppresses faces that would be
	-- rebuilt anyway once the neighbour arrives; return 0 at the world border.
	missingState: (cx: number, cz: number) -> number,
}

local Padded = {}

Padded.SIZE = 18
Padded.VOLUME = 18 * 18 * 18
-- Below the world floor faces are never visible.
Padded.BELOW_WORLD_STATE = 7 * 16 -- bedrock

function Padded.new(): buffer
	return buffer.create(Padded.VOLUME * 2)
end

function Padded.index(x: number, y: number, z: number): number
	return (x + 1) + (z + 1) * 18 + (y + 1) * 324
end

-- Fills `out` for section `si` of chunk (cx, cz).
function Padded.gather(source: ChunkSource, cx: number, cz: number, si: number, out: buffer)
	local baseY = si * 16
	-- 3x3 neighbourhood, index (dx+1) + (dz+1)*3
	local chunks: { Chunk.Chunk | false } = table.create(9, false)
	local fills: { number } = table.create(9, 0)
	for dz = -1, 1 do
		for dx = -1, 1 do
			local c = source.getChunk(cx + dx, cz + dz)
			local k = (dx + 1) + (dz + 1) * 3 + 1
			if c then
				chunks[k] = c
			else
				fills[k] = source.missingState(cx + dx, cz + dz)
			end
		end
	end
	for pz = 0, 17 do
		local lz = pz - 1
		local dz = if lz < 0 then -1 elseif lz > 15 then 1 else 0
		local cz2 = lz - dz * 16
		for px = 0, 17 do
			local lx = px - 1
			local dx = if lx < 0 then -1 elseif lx > 15 then 1 else 0
			local cx2 = lx - dx * 16
			local k = (dx + 1) + (dz + 1) * 3 + 1
			local c = chunks[k]
			local col = px + pz * 18
			if c == false then
				local f = fills[k]
				for py = 0, 17 do
					local wy = baseY + py - 1
					local v = if wy < 0 then Padded.BELOW_WORLD_STATE elseif wy > 255 then 0 else f
					buffer.writeu16(out, (col + py * 324) * 2, v)
				end
			else
				local colOff = (cx2 + cz2 * 16) * 2
				local sections = c.sections
				for py = 0, 17 do
					local wy = baseY + py - 1
					local v = 0
					if wy < 0 then
						v = Padded.BELOW_WORLD_STATE
					elseif wy <= 255 then
						local s = sections[wy // 16]
						if s then
							v = buffer.readu16(s.states, colOff + (wy % 16) * 512)
						end
					end
					buffer.writeu16(out, (col + py * 324) * 2, v)
				end
			end
		end
	end
end

return Padded
