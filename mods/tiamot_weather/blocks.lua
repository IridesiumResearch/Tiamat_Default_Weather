-- SPDX-License-Identifier: MIT
--
-- This mod's materials: fresh snow, and the damp versions of the Spindle's
-- dirt and sand.
--
-- **Fresh snow is its own material, never the Spindle's snow.** A layer
-- that became `tiamot_default_world:snow` would belong to rules that only
-- act inside the Crown and the frost ring and never melt anything, so a
-- drift left in a warm ring would be there for good (plan 5.4).
--
-- Snow grows in whole sub-node LAYERS. The occupancy index is x + 3y + 9z,
-- so one layer (y = 0) is the cells 0-2, 9-11 and 18-20, not a run of low
-- bits.

local M = {}

M.SNOW = "tiamot_weather:snow_layer"

-- The mask of the bottom `n` layers, n = 0..3.
local function layers_mask(n)
    local mask = 0
    for y = 0, n - 1 do
        for z = 0, 2 do
            for x = 0, 2 do
                mask = mask | (1 << (x + 3 * y + 9 * z))
            end
        end
    end
    return mask
end
M.LAYER_MASK = { [0] = 0, layers_mask(1), layers_mask(2), layers_mask(3) }
assert(M.LAYER_MASK[1] == 0x1C0E07 and M.LAYER_MASK[2] == 0xFC7E3F)
assert(M.LAYER_MASK[3] == game.OCCUPANCY_FULL)

-- How many whole layers an occupancy is, or nil for a shape that is not a
-- stack of layers (a player chiselled it).
local LAYERS_OF = {}
for n = 0, 3 do
    LAYERS_OF[M.LAYER_MASK[n]] = n
end
function M.layers_of(occupancy)
    return LAYERS_OF[occupancy]
end

game.register_block{
    id = "snow_layer",
    name = "Fresh snow",
    description = "Snow that fell here. It melts when the weather warms.",
    hardness = 0.1,
    textures = { all = "textures/snow_layer.png" },
    tint = { strength = 0.06, scale = 64 },
}
M.snow_id = game.get_block_id(M.SNOW)

-- Rainwater: the block a full block of the fluid is drawn as, and the fluid.
-- Registered whether or not puddles are switched on, so a world that had
-- them and turned them off still knows what its puddles are.
--
-- **Fluids never mix** (engine 62608bf, 2026-09-16): a block holding one
-- accepts none of another, and a flow into a block of a different fluid is
-- reported through `register_on_fluid_flow` with `meets` naming it. So
-- rainwater running into a river neither merges nor displaces it; ground.lua
-- hears the meeting and lets the rainwater go.
M.RAINWATER = "tiamot_weather:rainwater"
game.register_block{
    id = "rainwater",
    name = "Rainwater",
    description = "Drawn wherever a puddle is. Not something you place.",
    hardness = 0.1,
    transparent = true,
    textures = { all = "textures/rainwater.png" },
}
game.register_fluid{
    id = "rainwater",
    material = "rainwater",
    tick_rate = 2,
    evaporates = wx.config.RAIN_EVAPORATES,
    opacity = 0.35,
    color = { r = 120, g = 150, b = 170 },
}

-- The damp blocks exist only beside the Spindle, whose blocks they stand in
-- for. Hardness and tint are copied by hand from its blocks.lua (MIRRORS).
-- Breaking one yields ITSELF, the ordinary rule: a `drops` override naming
-- the dry block would give a whole block's units for a single chiselled
-- cell. A damp block dropped and placed dries back by its random tick.
M.damp_ids = {}
if wx.climate.name == "spindle" then
    local SOIL = { strength = 0.28, scale = 96 }
    local DAMP = {
        { id = "damp_dirt", name = "Damp dirt", hardness = 0.5 },
        { id = "damp_packed_dirt", name = "Damp packed dirt", hardness = 0.7 },
        { id = "damp_sand", name = "Damp sand", hardness = 0.4 },
    }
    for _, spec in ipairs(DAMP) do
        game.register_block{
            id = spec.id,
            name = spec.name,
            description = "Ground the rain has soaked. It dries when the rain stops.",
            hardness = spec.hardness,
            textures = { all = "textures/" .. spec.id .. ".png" },
            tint = SOIL,
        }
        M.damp_ids[#M.damp_ids + 1] = "tiamot_weather:" .. spec.id
    end
end

return M
