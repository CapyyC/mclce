local Protocol = require("../../src/shared/Net/Protocol")
local C = Protocol.C2S

return function(t)
	t.describe("Protocol", function()
		t.test("valid messages decode", function()
			local m = Protocol.decodeC2S(C.START_BREAK, { -5, 64, 1000 })
			t.truthy(m)
			t.eq(m.x, -5); t.eq(m.y, 64); t.eq(m.z, 1000)
			local p = Protocol.decodeC2S(C.PLACE, { 1, 2, 3, 5 })
			t.eq(p.face, 5)
			t.eq(Protocol.decodeC2S(C.CRAFT, { 3, 2 }).recipe, 3)
			t.eq(Protocol.decodeC2S(C.HELLO, {}).kind, C.HELLO)
		end)
		t.test("invalid input is rejected", function()
			local bad = {
				{ C.START_BREAK, { 1, 2 } },
				{ C.START_BREAK, { 1, 2, 3, 4 } },
				{ C.START_BREAK, { 1.5, 2, 3 } },
				{ C.START_BREAK, { 0 / 0, 2, 3 } },
				{ C.START_BREAK, { math.huge, 2, 3 } },
				{ C.START_BREAK, { 1, 256, 3 } },
				{ C.START_BREAK, { 1, -1, 3 } },
				{ C.START_BREAK, { "1", 2, 3 } },
				{ C.START_BREAK, { {}, 2, 3 } },
				{ C.PLACE, { 1, 2, 3, 6 } },
				{ C.PLACE, { 1, 2, 3 } },
				{ C.SELECT_SLOT, { 0 } },
				{ C.SELECT_SLOT, { 10 } },
				{ C.INV_CLICK, { 41, "left" } },
				{ C.INV_CLICK, { 1, "middle" } },
				{ C.CRAFT, { 1, 4 } },
				{ C.CHAT, { "" } },
				{ C.CHAT, { string.rep("a", 201) } },
				{ C.CHAT, { "\255\254" } },
				{ C.HELLO, { 1 } },
				{ 999, {} },
				{ "1", {} },
				{ 1.5, {} },
			}
			for i, b in bad do
				t.eq(Protocol.decodeC2S(b[1], b[2]), nil, "case " .. i)
			end
		end)
		t.test("block change batches round-trip", function()
			local ch = { -100000, 0, 5, 16, 7, 255, -1, 65535, 0, 64, 0, 0 }
			t.deepEq(Protocol.decodeBlockChanges(Protocol.encodeBlockChanges(ch)), ch)
			t.falsy(pcall(Protocol.decodeBlockChanges, buffer.fromstring("\5\1")))
		end)
	end)
end
