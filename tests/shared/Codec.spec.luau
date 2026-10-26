local Chunk = require("../../src/shared/Voxel/Chunk")
local ChunkCodec = require("../../src/shared/Persistence/ChunkCodec")
local Base64 = require("../../src/shared/Util/Base64")
local ByteStream = require("../../src/shared/Util/ByteStream")
local WorldGenerator = require("../../src/shared/WorldGen/WorldGenerator")
local WorldSeed = require("../../src/shared/WorldGen/WorldSeed")

local function same(t, a, b)
	t.eq(a.cx, b.cx); t.eq(a.cz, b.cz)
	for y = 0, 255 do
		for z = 0, 15 do
			for x = 0, 15 do
				if Chunk.getState(a, x, y, z) ~= Chunk.getState(b, x, y, z) then
					t.eq(Chunk.getState(b, x, y, z), Chunk.getState(a, x, y, z), string.format("at %d,%d,%d", x, y, z))
				end
			end
		end
		end
	for z = 0, 15 do
		for x = 0, 15 do
			t.eq(Chunk.height(b, x, z), Chunk.height(a, x, z))
		end
	end
end

return function(t)
	t.describe("Base64", function()
		t.test("RFC 4648 test vectors", function()
			local vec = { { "", "" }, { "f", "Zg==" }, { "fo", "Zm8=" }, { "foo", "Zm9v" }, { "foob", "Zm9vYg==" }, { "fooba", "Zm9vYmE=" }, { "foobar", "Zm9vYmFy" } }
			for _, v in vec do
				t.eq(Base64.encode(buffer.fromstring(v[1])), v[2])
				local d = Base64.decode(v[2])
				t.truthy(d)
				t.eq(buffer.tostring(d :: buffer), v[1])
			end
		end)
		t.test("all byte values round-trip; malformed input rejected", function()
			local b = buffer.create(256)
			for i = 0, 255 do
				buffer.writeu8(b, i, i)
			end
			t.eq(buffer.tostring(Base64.decode(Base64.encode(b)) :: buffer), buffer.tostring(b))
			t.eq(Base64.decode("abc"), nil)
			t.eq(Base64.decode("ab!d"), nil)
		end)
	end)
	t.describe("ByteStream", function()
		t.test("varint boundaries", function()
			local w = ByteStream.writer(1)
			local vals = { 0, 1, 127, 128, 16383, 16384, 2 ^ 32, 2 ^ 52 }
			for _, v in vals do
				ByteStream.varint(w, v)
			end
			local r = ByteStream.reader(ByteStream.finish(w))
			for _, v in vals do
				t.eq(ByteStream.rvarint(r), v)
			end
			t.truthy(ByteStream.atEnd(r))
			t.throws(function()
				ByteStream.ru8(r)
			end, "truncated")
		end)
	end)
	t.describe("ChunkCodec", function()
		t.test("empty chunk round-trip is tiny", function()
			local c = Chunk.new(-5, 7)
			local b = ChunkCodec.encode(c)
			t.truthy(buffer.len(b) <= 12)
			same(t, c, ChunkCodec.decode(b))
		end)
		t.test("generated terrain round-trips and compresses", function()
			local c = WorldGenerator.generate(WorldGenerator.new(WorldSeed.fromNumber(3)), -2, 1)
			local b = ChunkCodec.encode(c)
			local d = ChunkCodec.decode(b)
			same(t, c, d)
			t.truthy(buffer.len(b) < 40000, "size " .. buffer.len(b))
			-- through base64 too
			same(t, c, ChunkCodec.decode(Base64.decode(Base64.encode(b)) :: buffer))
		end)
		t.test("random noise worst case round-trips (incl. unknown ids, max state)", function()
			local c = Chunk.new(1048575, -1048576)
			local seed = 5
			for i = 0, 8191 do
				seed = (seed * 1103515245 + 12345) % 2147483648
				Chunk.setState(c, i % 16, (i // 16) % 256, (i // 4096) % 16 + 0, seed % 65536)
			end
			Chunk.setState(c, 0, 255, 0, 65535)
			same(t, c, ChunkCodec.decode(ChunkCodec.encode(c)))
		end)
		t.test("corrupted or truncated data raises instead of producing garbage", function()
			local c = WorldGenerator.generate(WorldGenerator.new(WorldSeed.fromNumber(3)), 0, 0)
			local b = ChunkCodec.encode(c)
			for _, cut in { 1, 5, 11, buffer.len(b) // 2, buffer.len(b) - 1 } do
				local tb = buffer.create(cut)
				buffer.copy(tb, 0, b, 0, cut)
				t.falsy(pcall(ChunkCodec.decode, tb), "truncated at " .. cut)
			end
			local bad = buffer.create(buffer.len(b))
			buffer.copy(bad, 0, b)
			buffer.writeu8(bad, 0, 99)
			t.falsy(pcall(ChunkCodec.decode, bad))
			-- random fuzz must never crash with a non-error or hang
			local seed = 1
			for _ = 1, 200 do
				local f = buffer.create(64)
				for i = 0, 63 do
					seed = (seed * 1103515245 + 12345) % 2147483648
					buffer.writeu8(f, i, seed % 256)
				end
				buffer.writeu8(f, 0, 1)
				pcall(ChunkCodec.decode, f)
			end
		end)
	end)
end
