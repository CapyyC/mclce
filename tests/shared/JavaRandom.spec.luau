local JavaRandom = require("../../src/shared/Util/JavaRandom")
local F = require("../fixtures/JavaRandomFixture")

return function(t)
	t.describe("JavaRandom (golden JDK fixture)", function()
		for _, case in ipairs(F) do
			t.test("seed " .. tostring(case.seed), function()
				local r = JavaRandom.new(case.seed)
				for i, v in case.ints do
					t.eq(r:nextInt(), v, "nextInt #" .. i)
				end
				for _, b in case.bounded do
					t.eq(r:nextInt(b[1]), b[2], "nextInt(" .. b[1] .. ")")
				end
				for _, d in case.doubles do
					t.near(r:nextDouble(), d, 1e-15)
				end
				for _, f in case.floats do
					t.near(r:nextFloat(), f, 1e-8)
				end
				for _, b in case.bools do
					t.eq(r:nextBoolean(), b)
				end
				local hi, lo = r:nextLongParts()
				t.eq(hi, case.long[1], "long hi")
				t.eq(lo, case.long[2], "long lo")
			end)
		end
		t.test("String.hashCode", function()
			for _, s in F.strings do
				t.eq(JavaRandom.stringHash(s[1]), s[2], s[1])
			end
		end)
		t.test("newFromParts matches new for small seeds", function()
			local a, b = JavaRandom.new(-5), JavaRandom.newFromParts(-1, 4294967291)
			for _ = 1, 10 do
				t.eq(a:nextInt(), b:nextInt())
			end
		end)
	end)
end
