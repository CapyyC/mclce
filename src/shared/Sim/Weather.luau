--!strict
-- Rain and thunder cycles (classic timing): while clear, rain starts after
-- 12000..179999 ticks and lasts 12000..23999; thunder runs its own cycle but
-- only matters while it rains. Rain darkens the sky by 3, a thunderstorm by
-- 5 more (so monsters can spawn during the day in storms).
local JavaRandom = require("../Util/JavaRandom")

export type Weather = {
	raining: boolean,
	thundering: boolean,
	rainTime: number,
	thunderTime: number,
	rng: JavaRandom.JavaRandom,
}

local Weather = {}

function Weather.new(seed: number): Weather
	local rng = JavaRandom.new(seed)
	return { raining = false, thundering = false, rainTime = 12000 + rng:nextInt(168000), thunderTime = 12000 + rng:nextInt(168000), rng = rng }
end

-- Advances one tick; returns true when the visible state changed.
function Weather.tick(w: Weather): boolean
	local changed = false
	w.rainTime -= 1
	if w.rainTime <= 0 then
		w.raining = not w.raining
		w.rainTime = if w.raining then 12000 + w.rng:nextInt(12000) else 12000 + w.rng:nextInt(168000)
		changed = true
	end
	w.thunderTime -= 1
	if w.thunderTime <= 0 then
		w.thundering = not w.thundering
		w.thunderTime = if w.thundering then 3600 + w.rng:nextInt(12000) else 12000 + w.rng:nextInt(168000)
		if w.raining then
			changed = true
		end
	end
	return changed
end

function Weather.storming(w: Weather): boolean
	return w.raining and w.thundering
end

-- Extra sky darkness from the weather.
function Weather.darken(w: Weather): number
	if not w.raining then
		return 0
	end
	return if w.thundering then 8 else 3
end

function Weather.snapshot(w: Weather): { [string]: any }
	return { raining = w.raining, thundering = w.raining and w.thundering }
end

function Weather.record(w: Weather): { number }
	return { if w.raining then 1 else 0, if w.thundering then 1 else 0, w.rainTime, w.thunderTime }
end

function Weather.load(w: Weather, r: any)
	if type(r) == "table" and #r == 4 then
		w.raining, w.thundering = r[1] == 1, r[2] == 1
		w.rainTime, w.thunderTime = math.max(1, tonumber(r[3]) or 1), math.max(1, tonumber(r[4]) or 1)
	end
end

return Weather
