--!strict
-- Block breaking rules: break time, harvestability and drops.
-- Formula (classic, publicly documented): per tick the block takes
--   speed / hardness / (canHarvest and 30 or 100)
-- damage; it breaks when accumulated damage >= 1. speed = tool speed when
-- the tool type matches the block, x0.2 when in water or airborne each.

local BlockRegistry = require("../Blocks/BlockRegistry")
local ItemRegistry = require("./ItemRegistry")
local ItemStack = require("./ItemStack")
local JavaRandom = require("../Util/JavaRandom")

export type ItemStack = ItemStack.ItemStack

local Mining = {}

local function toolOf(held: ItemStack?): (string?, number, number)
	if held == nil then
		return nil, -1, 1
	end
	local d = ItemRegistry.get(held.id)
	if d == nil or d.tool == nil then
		return nil, -1, 1
	end
	return d.tool, d.tier or 0, d.speed or 1
end

function Mining.canHarvest(blockId: number, held: ItemStack?): boolean
	local def = BlockRegistry.get(blockId)
	if def == nil then
		return false
	end
	if not def.needsTool then
		return true
	end
	local tool, tier = toolOf(held)
	return tool ~= nil and tool == def.tool and tier >= def.harvest
end

-- Mining speed multiplier of `held` against the block.
function Mining.speed(blockId: number, held: ItemStack?): number
	local def = BlockRegistry.get(blockId)
	local tool, _, speed = toolOf(held)
	if def == nil or tool == nil then
		return 1
	end
	if tool == def.tool then
		return speed
	end
	if tool == "sword" and blockId == 30 then
		return 15 -- cobweb
	end
	if tool == "sword" and (def.layer == "cutout" and def.flammable) then
		return 1.5 -- leaves, plants
	end
	return 1
end

-- Ticks (1/20 s) to break; 0 = instant; math.huge = unbreakable.
function Mining.breakTicks(blockId: number, held: ItemStack?, onGround: boolean?, inWater: boolean?): number
	local hardness = BlockRegistry.hardness(blockId)
	if hardness < 0 then
		return math.huge
	end
	if hardness == 0 then
		return 0
	end
	local speed = Mining.speed(blockId, held)
	if inWater then
		speed /= 5
	end
	if onGround == false then
		speed /= 5
	end
	local perTick = speed / hardness / (if Mining.canHarvest(blockId, held) then 30 else 100)
	if perTick > 1 then
		return 0
	end
	return math.ceil(1 / perTick - 1e-9)
end

function Mining.breakSeconds(blockId: number, held: ItemStack?, onGround: boolean?, inWater: boolean?): number
	return Mining.breakTicks(blockId, held, onGround, inWater) / 20
end

-- Items dropped when a block state is broken by `held`. rng drives chance drops.
function Mining.drops(state: number, held: ItemStack?, rng: JavaRandom.JavaRandom): { ItemStack }
	local id, meta = state // 16, state % 16
	local def = BlockRegistry.get(id)
	if def == nil or not Mining.canHarvest(id, held) then
		return {}
	end
	local tool = toolOf(held)
	local name = def.name
	if name == "coal_ore" then
		return { ItemStack.new(263, 1) }
	elseif name == "diamond_ore" then
		return { ItemStack.new(264, 1) }
	elseif name == "emerald_ore" then
		return { ItemStack.new(388, 1) }
	elseif name == "redstone_ore" then
		return { ItemStack.new(331, 4 + rng:nextInt(2)) }
	elseif name == "lapis_ore" then
		return { ItemStack.new(351, 4 + rng:nextInt(5), 4) }
	elseif name == "gravel" then
		if rng:nextInt(10) == 0 then
			return { ItemStack.new(318, 1) }
		end
		return { ItemStack.new(13, 1) }
	elseif name == "clay" then
		return { ItemStack.new(337, 4) }
	elseif name == "glowstone" then
		return { ItemStack.new(348, 2 + rng:nextInt(3)) }
	elseif name == "leaves" or name == "leaves2" then
		if tool == "shears" then
			return { ItemStack.new(id, 1, meta % 4) }
		end
		local out = {}
		if rng:nextInt(20) == 0 then
			table.insert(out, ItemStack.new(6, 1, meta % 4))
		end
		if name == "leaves" and meta % 4 == 0 and rng:nextInt(200) == 0 then
			table.insert(out, ItemStack.new(260, 1))
		end
		return out
	elseif name == "tallgrass" or name == "double_plant" then
		if tool == "shears" then
			return { ItemStack.new(id, 1, meta) }
		end
		if rng:nextInt(8) == 0 then
			return { ItemStack.new(295, 1) }
		end
		return {}
	elseif name == "deadbush" then
		return if tool == "shears" then { ItemStack.new(id, 1) } else {}
	elseif name == "reeds" then
		return { ItemStack.new(338, 1) }
	elseif name == "snow_layer" then
		return { ItemStack.new(332, 1) }
	elseif name == "snow" then
		return { ItemStack.new(332, 4) }
	end
	local dropId = if def.drops ~= nil then def.drops else id
	if dropId == 0 then
		return {}
	end
	-- metadata that encodes orientation is not kept; variant metadata is
	local keepMeta = name == "wool" or name == "planks" or name == "sapling" or name == "stone" or name == "log" or name == "log2" or name == "stained_hardened_clay" or name == "sandstone" or name == "stonebrick"
	local dropMeta = if keepMeta then (if name == "log" or name == "log2" then meta % 4 else meta) else 0
	if dropId == 4 then
		dropMeta = 0 -- stone variants drop cobblestone
	end
	if ItemRegistry.get(dropId) == nil then
		return {}
	end
	return { ItemStack.new(dropId, 1, dropMeta) }
end

return Mining
