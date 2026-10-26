local Survival = require("../../src/shared/Sim/Survival")

return function(t)
	t.describe("Survival", function()
		t.test("fall damage = ceil(distance - 3)", function()
			t.eq(Survival.fallDamage(3), 0)
			t.eq(Survival.fallDamage(3.5), 1)
			t.eq(Survival.fallDamage(4), 1)
			t.eq(Survival.fallDamage(23), 20)
		end)
		t.test("fall tracking uses the apex and resets in water", function()
			local v = Survival.new()
			t.eq(Survival.trackFall(v, 70, true, false), 0)
			Survival.trackFall(v, 71, false, false) -- jump
			Survival.trackFall(v, 72, false, false)
			for y = 71, 61, -1 do
				Survival.trackFall(v, y, false, false)
			end
			t.eq(Survival.trackFall(v, 60, true, false), 9) -- fell 12 from apex
			Survival.trackFall(v, 80, false, false)
			Survival.trackFall(v, 65, false, true) -- water
			t.eq(Survival.trackFall(v, 60, true, false), 0)
		end)
		t.test("exhaustion drains saturation before food", function()
			local v = Survival.new()
			v.saturation = 1
			Survival.exhaust(v, 4)
			Survival.tickFood(v, 2)
			t.eq(v.saturation, 0); t.eq(v.food, 20)
			Survival.exhaust(v, 8)
			Survival.tickFood(v, 2)
			t.eq(v.food, 18)
		end)
		t.test("natural regeneration every 80 ticks at food >= 18", function()
			local v = Survival.new()
			v.health = 10
			for _ = 1, 79 do
				Survival.tickFood(v, 2)
			end
			t.eq(v.health, 10)
			Survival.tickFood(v, 2)
			t.eq(v.health, 11)
			t.near(v.exhaustion, 3.0, 1e-9)
		end)
		t.test("starvation floor depends on difficulty", function()
			for diff, floor in { [1] = 10, [2] = 1, [3] = 0 } do
				local v = Survival.new()
				v.food, v.saturation = 0, 0
				for _ = 1, 80 * 30 do
					Survival.tickFood(v, diff)
				end
				t.eq(v.health, floor, "difficulty " .. diff)
				t.eq(v.dead, floor == 0)
			end
		end)
		t.test("eating caps food and saturation", function()
			local v = Survival.new()
			t.falsy(Survival.eat(v, 5, 0.6))
			v.food, v.saturation = 10, 0
			t.truthy(Survival.eat(v, 5, 0.6)) -- bread
			t.eq(v.food, 15); t.near(v.saturation, 6, 1e-9)
			v.food, v.saturation = 19, 19
			Survival.eat(v, 8, 0.8)
			t.eq(v.food, 20); t.eq(v.saturation, 20)
		end)
		t.test("death and respawn", function()
			local v = Survival.new()
			local d, died = Survival.damage(v, 25)
			t.eq(d, 20); t.truthy(died); t.truthy(v.dead)
			t.eq((Survival.damage(v, 5)), 0)
			Survival.respawn(v)
			t.eq(v.health, 20); t.falsy(v.dead)
		end)
	end)
end
