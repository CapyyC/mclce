--!nonstrict
-- Client-side rain/storm presentation: a particle curtain that follows the
-- camera and dimmer lighting while it rains. Placeholder particles (no assets).
local Lighting = game:GetService("Lighting")

local WeatherFx = {}
WeatherFx.__index = WeatherFx

function WeatherFx.new(parent: Instance)
	local self = setmetatable({}, WeatherFx)
	local p = Instance.new("Part")
	p.Name = "mclceRain"
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.Transparency = 1
	p.Size = Vector3.new(60, 1, 60)
	p.Parent = parent
	local e = Instance.new("ParticleEmitter")
	e.Rate = 0
	e.Lifetime = NumberRange.new(1.2)
	e.Speed = NumberRange.new(60)
	e.EmissionDirection = Enum.NormalId.Bottom
	e.Color = ColorSequence.new(Color3.fromRGB(150, 170, 220))
	e.Transparency = NumberSequence.new(0.4)
	e.Size = NumberSequence.new(0.15)
	e.Parent = p
	self.part, self.emitter = p, e
	self.baseBrightness = Lighting.Brightness
	return self
end

function WeatherFx:update(weather, cameraPos: Vector3, dimension: string)
	local raining = weather.raining and dimension ~= "nether"
	self.emitter.Rate = if raining then (if weather.thundering then 900 else 500) else 0
	self.part.CFrame = CFrame.new(cameraPos.X, cameraPos.Y + 25, cameraPos.Z)
	Lighting.Brightness = if raining then self.baseBrightness * (if weather.thundering then 0.45 else 0.7) else self.baseBrightness
end

return WeatherFx
