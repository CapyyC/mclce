local Time = require("../../src/shared/Sim/Time")
return function(t)
	t.describe("Time", function()
		t.test("sky darkness over a day", function()
			t.eq(Time.skyDarken(6000), 0, "noon")
			t.eq(Time.skyDarken(18000), 11, "midnight")
			t.eq(Time.skyDarken(0), 0, "sunrise is still fully lit")
			t.truthy(Time.skyDarken(13000) >= 4, "dusk")
			t.truthy(Time.isDay(1000) and Time.isDay(11000))
			t.falsy(Time.isDay(15000))
			-- monotone darkening from noon to midnight
			local prev = -1
			for tick = 6000, 18000, 500 do
				local d = Time.skyDarken(tick)
				t.truthy(d >= prev)
				prev = d
			end
		end)
		t.test("clock time mapping", function()
			t.eq(Time.clockTime(0), 6)
			t.eq(Time.clockTime(6000), 12)
			t.eq(Time.clockTime(18000), 0)
		end)
	end)
end
