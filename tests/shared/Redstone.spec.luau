local Redstone = require("../../src/shared/Sim/Redstone")
local World = require("../../src/shared/Voxel/World")
local Chunk = require("../../src/shared/Voxel/Chunk")

local I = Redstone.IDS
local STONE = 16

local function setup()
	local w = World.new(1024)
	for cx = -2, 1 do
		for cz = -2, 1 do
			World.putChunk(w, Chunk.new(cx, cz))
		end
	end
	for x = -20, 25 do
		for z = -10, 10 do
			World.setState(w, x, 9, z, STONE)
		end
	end
	local rs = Redstone.new(w)
	World.addListener(w, function(x, y, z, o, n)
		Redstone.onChange(rs, x, y, z, o // 16, n // 16)
	end)
	return w, rs
end

local function run(rs, n)
	for _ = 1, n do
		Redstone.step(rs)
	end
end

local function power(w, x, y, z)
	return World.getState(w, x, y, z) % 16
end

return function(t)
	t.describe("Redstone", function()
		t.test("lever on a block drives a wire line that decays by 1 per block", function()
			local w, rs = setup()
			World.setState(w, 0, 10, 0, STONE)
			World.setState(w, 0, 11, 0, I.LEVER * 16 + 5) -- lever on top of the block
			for x = 1, 17 do
				World.setState(w, x, 10, 0, I.WIRE * 16)
			end
			World.setState(w, 18, 10, 0, I.LAMP * 16)
			run(rs, 2)
			t.eq(power(w, 1, 10, 0), 0, "lever off")
			Redstone.use(rs, 0, 11, 0)
			run(rs, 2)
			t.eq(power(w, 1, 10, 0), 15, "strongly powered block drives wire at 15")
			t.eq(power(w, 5, 10, 0), 11)
			t.eq(power(w, 15, 10, 0), 1)
			t.eq(power(w, 16, 10, 0), 0)
			t.eq(World.getId(w, 18, 10, 0), I.LAMP, "lamp past the 15-block reach stays off")
			-- shorten: a lamp right after wire power >= 1 lights
			World.setState(w, 16, 10, 0, I.LAMP * 16)
			run(rs, 2)
			t.eq(World.getId(w, 16, 10, 0), I.LAMP_ON)
			Redstone.use(rs, 0, 11, 0)
			run(rs, 2)
			t.eq(power(w, 1, 10, 0), 0, "lever off clears the network")
			t.eq(World.getId(w, 16, 10, 0), I.LAMP_ON, "lamp turn-off delay")
			run(rs, 5)
			t.eq(World.getId(w, 16, 10, 0), I.LAMP)
		end)
		t.test("NOT gate: torch on a powered block turns off after 2 ticks", function()
			local w, rs = setup()
			World.setState(w, 0, 10, 0, STONE)
			World.setState(w, -1, 10, 0, I.LEVER * 16 + 2) -- lever attached to block at +x
			World.setState(w, 1, 10, 0, I.TORCH_ON * 16 + 1) -- torch attached to block at -x
			World.setState(w, 2, 10, 0, I.WIRE * 16)
			run(rs, 3)
			t.eq(World.getId(w, 1, 10, 0), I.TORCH_ON)
			t.eq(power(w, 2, 10, 0), 15, "lit torch powers adjacent wire")
			Redstone.use(rs, -1, 10, 0)
			run(rs, 1)
			t.eq(World.getId(w, 1, 10, 0), I.TORCH_ON, "torch delay")
			run(rs, 3)
			t.eq(World.getId(w, 1, 10, 0), I.TORCH_OFF)
			t.eq(power(w, 2, 10, 0), 0)
			Redstone.use(rs, -1, 10, 0)
			run(rs, 4)
			t.eq(World.getId(w, 1, 10, 0), I.TORCH_ON)
		end)
		t.test("wire on top of a block weakly powers it (turns its torch off)", function()
			local w, rs = setup()
			World.setState(w, 5, 10, 0, STONE)
			World.setState(w, 5, 11, 0, I.WIRE * 16)
			World.setState(w, 6, 10, 0, I.TORCH_ON * 16 + 1) -- attached to the block at -x
			World.setState(w, 4, 11, 0, I.RS_BLOCK * 16)
			run(rs, 4)
			t.eq(power(w, 5, 11, 0), 15)
			t.eq(World.getId(w, 6, 10, 0), I.TORCH_OFF)
		end)
		t.test("wire steps up onto blocks and down again", function()
			local w, rs = setup()
			World.setState(w, 0, 10, 0, I.RS_BLOCK * 16)
			World.setState(w, 1, 10, 0, I.WIRE * 16)
			World.setState(w, 2, 10, 0, STONE)
			World.setState(w, 2, 11, 0, I.WIRE * 16) -- one up
			World.setState(w, 3, 10, 0, I.WIRE * 16) -- back down on the other side
			run(rs, 2)
			t.eq(power(w, 1, 10, 0), 15)
			t.eq(power(w, 2, 11, 0), 14)
			t.eq(power(w, 3, 10, 0), 13)
			-- a solid block above the lower wire cuts the step-up
			World.setState(w, 1, 11, 0, STONE)
			run(rs, 2)
			t.eq(power(w, 2, 11, 0), 0)
		end)
		t.test("button pulses for 20 ticks", function()
			local w, rs = setup()
			World.setState(w, 0, 10, 0, STONE)
			World.setState(w, 1, 10, 0, I.BUTTON * 16 + 1) -- attached to block at -x
			World.setState(w, -1, 10, 0, I.WIRE * 16)
			Redstone.use(rs, 1, 10, 0)
			run(rs, 2)
			t.eq(power(w, -1, 10, 0), 15)
			run(rs, 20)
			t.eq(World.getState(w, 1, 10, 0) % 16, 1, "released")
			run(rs, 2)
			t.eq(power(w, -1, 10, 0), 0)
		end)
		t.test("doors open while powered and close after", function()
			local w, rs = setup()
			World.setState(w, 0, 10, 0, I.IRON_DOOR * 16 + 0)
			World.setState(w, 0, 11, 0, I.IRON_DOOR * 16 + 8)
			World.setState(w, 1, 10, 0, I.LEVER * 16 + 5)
			run(rs, 2)
			t.eq(World.getState(w, 0, 10, 0) % 16, 0)
			Redstone.use(rs, 1, 10, 0)
			run(rs, 2)
			t.eq(World.getState(w, 0, 10, 0) % 16, 4, "open")
			Redstone.use(rs, 1, 10, 0)
			run(rs, 2)
			t.eq(World.getState(w, 0, 10, 0) % 16, 0, "closed")
		end)
		t.test("pressure plate powers the block below and adjacent wire", function()
			local w, rs = setup()
			World.setState(w, 0, 10, 0, I.STONE_PLATE * 16)
			World.setState(w, 1, 10, 0, I.WIRE * 16)
			World.setState(w, 0, 8, 0, 0) -- remove floor under (0,9) so (0,9) is the plate's block
			Redstone.setPlate(rs, 0, 10, 0, true)
			run(rs, 2)
			t.eq(power(w, 1, 10, 0), 15)
			t.truthy(Redstone.stronglyPowered(rs, 0, 9, 0))
			Redstone.setPlate(rs, 0, 10, 0, false)
			run(rs, 2)
			t.eq(power(w, 1, 10, 0), 0)
		end)
	end)
end
