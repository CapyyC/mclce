--!strict
-- Wire protocol between client and server (one RemoteEvent per direction).
-- Every client->server message is validated here before any game logic sees
-- it: type tags, argument counts, finite numbers, integer coordinates and
-- ranges. Invalid messages decode to nil and are dropped (and counted).

local ByteStream = require("../Util/ByteStream")

local Protocol = {}

Protocol.C2S = {
	HELLO = 1,
	START_BREAK = 2, -- x, y, z
	FINISH_BREAK = 3, -- x, y, z
	CANCEL_BREAK = 4,
	PLACE = 5, -- x, y, z, face (target block + clicked face)
	SELECT_SLOT = 6, -- index 1..9
	INV_CLICK = 7, -- slot, button ("left"|"right")
	INV_QUICK_MOVE = 8, -- slot
	CRAFT = 9, -- recipeId, grid (2|3)
	CLOSE_CONTAINER = 10,
	RESPAWN = 11,
	CHAT = 12, -- text
	USE_START = 13, -- begin using held item (eating)
	USE_FINISH = 14,
	JOIN = 15, -- client listener is connected; server may start sending
	ATTACK = 16, -- mobId
	CONTAINER_CLICK = 17, -- slot (1..27), button
	INTERACT = 18, -- mobId ("use" on an entity: shears, dye)
	CREATIVE_TAKE = 19, -- itemId, meta (creative only)
}

Protocol.S2C = {
	WELCOME = 1, -- table: seed string, world size, spawn
	CHUNK = 2, -- buffer (ChunkCodec)
	UNLOAD = 3, -- cx, cz
	BLOCKS = 4, -- buffer of block changes
	INVENTORY = 5, -- table snapshot
	PLAYER = 6, -- health, food, saturation, gamemode
	TIME = 7, -- worldTime ticks
	BREAK_REJECTED = 8, -- x, y, z, current state
	CHAT = 9, -- name, text
	DIED = 11, -- cause
	RESPAWNED = 12, -- x, y, z
	MOBS = 13, -- { spawned = {{id,type,x,y,z,yaw,health}}, moved = {{id,x,y,z,yaw}}, removed = {id}, hurt = {id} }
	EXPLOSION = 14, -- x, y, z, power
	SLEEP = 17, -- boolean sleeping
	WEATHER = 18, -- { raining, thundering }
	DIMS = 16, -- { [tostring(userId)] = dimension } for hiding players in other dimensions
	CONTAINER = 15, -- { x, y, z, state = BlockEntities.snapshot } or false when closed
	ITEMS = 10, -- { spawned = {{id,x,y,z,item,meta,count}}, moved = {{id,x,y,z}}, removed = {id} }
}

export type Message = { kind: number, [string]: any }

local function isInt(v: any, lo: number, hi: number): boolean
	return type(v) == "number" and v == v and v == math.floor(v) and v >= lo and v <= hi
end

local COORD = 2 ^ 24

local function blockPos(a: { any }): (boolean, number, number, number)
	local x, y, z = a[1], a[2], a[3]
	if isInt(x, -COORD, COORD) and isInt(y, 0, 255) and isInt(z, -COORD, COORD) then
		return true, x, y, z
	end
	return false, 0, 0, 0
end

-- Decodes (kind, ...args) from a client. Returns nil if invalid.
function Protocol.decodeC2S(kind: any, args: { any }): Message?
	if not isInt(kind, 1, 64) or #args > 8 then
		return nil
	end
	local C = Protocol.C2S
	if kind == C.USE_FINISH and #args == 3 then
		-- optional aim direction (bows)
		local x, y, z = args[1], args[2], args[3]
		for _, v in { x, y, z } do
			if type(v) ~= "number" or v ~= v or math.abs(v) > 1.01 then
				return nil
			end
		end
		local len = math.sqrt(x * x + y * y + z * z)
		if len < 0.9 or len > 1.1 then
			return nil
		end
		return { kind = kind, dx = x / len, dy = y / len, dz = z / len }
	end
	if kind == C.HELLO or kind == C.CANCEL_BREAK or kind == C.CLOSE_CONTAINER or kind == C.RESPAWN or kind == C.USE_START or kind == C.USE_FINISH or kind == C.JOIN then
		return if #args == 0 then { kind = kind } else nil
	elseif kind == C.START_BREAK or kind == C.FINISH_BREAK then
		local ok, x, y, z = blockPos(args)
		if ok and #args == 3 then
			return { kind = kind, x = x, y = y, z = z }
		end
	elseif kind == C.PLACE then
		local ok, x, y, z = blockPos(args)
		if ok and #args == 4 and isInt(args[4], 0, 5) then
			return { kind = kind, x = x, y = y, z = z, face = args[4] }
		end
	elseif kind == C.SELECT_SLOT then
		if #args == 1 and isInt(args[1], 1, 9) then
			return { kind = kind, index = args[1] }
		end
	elseif kind == C.INV_CLICK then
		if #args == 2 and isInt(args[1], 1, 40) and (args[2] == "left" or args[2] == "right") then
			return { kind = kind, slot = args[1], button = args[2] }
		end
	elseif kind == C.INV_QUICK_MOVE then
		if #args == 1 and isInt(args[1], 1, 36) then
			return { kind = kind, slot = args[1] }
		end
	elseif kind == C.CRAFT then
		if #args == 2 and isInt(args[1], 1, 100000) and (args[2] == 2 or args[2] == 3) then
			return { kind = kind, recipe = args[1], grid = args[2] }
		end
	elseif kind == C.ATTACK or kind == C.INTERACT then
		if #args == 1 and isInt(args[1], 1, 2 ^ 31) then
			return { kind = kind, mob = args[1] }
		end
	elseif kind == C.CONTAINER_CLICK then
		if #args == 2 and isInt(args[1], 1, 27) and (args[2] == "left" or args[2] == "right") then
			return { kind = kind, slot = args[1], button = args[2] }
		end
	elseif kind == C.CREATIVE_TAKE then
		if #args == 2 and isInt(args[1], 1, 4095) and isInt(args[2], 0, 15) then
			return { kind = kind, item = args[1], meta = args[2] }
		end
	elseif kind == C.CHAT then
		local text = args[1]
		if #args == 1 and type(text) == "string" and #text >= 1 and #text <= 200 and utf8.len(text) ~= nil then
			return { kind = kind, text = text }
		end
	end
	return nil
end

-- Block change batch: count varint, then per change i32 x, u8 y, i32 z, u16 state.
function Protocol.encodeBlockChanges(changes: { number }): buffer
	-- changes: flat x, y, z, state
	local n = #changes // 4
	local w = ByteStream.writer(4 + n * 11)
	ByteStream.varint(w, n)
	for i = 0, n - 1 do
		ByteStream.i32(w, changes[i * 4 + 1])
		ByteStream.u8(w, changes[i * 4 + 2])
		ByteStream.i32(w, changes[i * 4 + 3])
		ByteStream.u16(w, changes[i * 4 + 4])
	end
	return ByteStream.finish(w)
end

function Protocol.decodeBlockChanges(b: buffer): { number }
	local r = ByteStream.reader(b)
	local n = ByteStream.rvarint(r)
	if n > 65536 then
		error("too many block changes", 0)
	end
	local out: { number } = {}
	for i = 0, n - 1 do
		out[i * 4 + 1] = ByteStream.ri32(r)
		out[i * 4 + 2] = ByteStream.ru8(r)
		out[i * 4 + 3] = ByteStream.ri32(r)
		out[i * 4 + 4] = ByteStream.ru16(r)
	end
	return out
end

return Protocol
