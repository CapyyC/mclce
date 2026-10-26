local Weather = require("../../src/shared/Sim/Weather")
return function(t)
	t.describe("Weather", function()
		t.test("rain starts and stops within classic bounds", function()
			local w = Weather.new(5)
			local first = w.rainTime
			t.truthy(first >= 12000 and first < 180000)
			for _ = 1, first do
				Weather.tick(w)
			end
			t.truthy(w.raining)
			t.truthy(w.rainTime >= 12000 and w.rainTime < 24000, "rain lasts " .. w.rainTime)
			t.eq(Weather.darken(w), if w.thundering then 8 else 3)
		end)
		t.test("records round-trip", function()
			local a = Weather.new(1)
			a.raining, a.thundering, a.rainTime = true, true, 42
			local b = Weather.new(2)
			Weather.load(b, Weather.record(a))
			t.truthy(b.raining and b.thundering)
			t.eq(b.rainTime, 42)
			t.truthy(Weather.storming(b))
		end)
	end)
end
