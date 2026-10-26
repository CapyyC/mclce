--!strict
-- Day/night math (classic): 24000 ticks per day, tick 0 = sunrise (06:00),
-- 6000 = noon, 18000 = midnight. skyDarken is how much sky light is
-- subtracted (0 at noon, 11 at midnight); mobs spawn at effective light <= 7.
local Time = {}

Time.DAY_TICKS = 24000

function Time.celestialAngle(t: number): number
	local f = (t % 24000) / 24000 - 0.25
	if f < 0 then
		f += 1
	end
	if f > 1 then
		f -= 1
	end
	local g = f
	f = 1 - (math.cos(f * math.pi) + 1) / 2
	return g + (f - g) / 3
end

function Time.skyDarken(t: number): number
	local a = Time.celestialAngle(t)
	local b = 1 - math.clamp(math.cos(a * math.pi * 2) * 2 + 0.5, 0, 1)
	return math.floor(b * 11)
end

-- Undead burn and spiders are neutral while the sun is up.
function Time.isDay(t: number): boolean
	return Time.skyDarken(t) < 4
end

-- Roblox Lighting.ClockTime for a world time.
function Time.clockTime(t: number): number
	return (t / 1000 + 6) % 24
end

return Time
