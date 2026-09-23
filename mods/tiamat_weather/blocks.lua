-- SPDX-License-Identifier: MIT
--
-- This mod's materials: fresh snow, rainwater, fire and what fire leaves,
-- and the damp versions of the Spindle's dirt and sand.
--
-- **Fresh snow is its own material, never the Spindle's snow.** A layer
-- that became `tiamat_default_world:snow` would belong to rules that only
-- act inside the Crown and the frost ring and never melt anything, so a
-- drift left in a warm ring would be there for good (plan 5.4).
--
-- Snow grows in whole sub-node LAYERS. The occupancy index is x + 3y + 9z,
-- so one layer (y = 0) is the cells 0-2, 9-11 and 18-20, not a run of low
-- bits.

local M = {}

M.SNOW = "tiamat_weather:snow_layer"

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
M.RAINWATER = "tiamat_weather:rainwater"
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
    -- Rain does not strip a meadow (engine 2f9b036, ask W14). A puddle
    -- spreads a few cells into whatever is beside it, and a plant that
    -- declared `washes_away` would go with it — which is a flood's business,
    -- not a shower's.
    washes = false,
}

-- Fire, and what it leaves (plan 5.12). Registered on every world, fuel or
-- no fuel: a world that had fires and turned them off still has to know
-- what its charred trunks are, and another mod's export may light something
-- on a plain world one day.
--
-- **Fire is a plant, as far as the engine knows.** A billboard cross, so it
-- reads as flames rather than a glowing cube; `passable`, so a body walks
-- through it (and burns, once fire.lua has told Life about this block, see
-- docs/exports-contract.md); `sway`, so it flickers; `washes_away`, so a
-- flood or a bucket puts it out without fire.lua having to hear about it;
-- and `drops = {}`, so digging one yields nothing. fire.lua decides when it
-- is placed and when it goes, and the fire's own random tick only clears a
-- block fire.lua has never heard of.
M.FIRE = "tiamat_weather:fire"
game.register_block{
    id = "fire",
    name = "Fire",
    description = "Something is burning. Rain puts it out.",
    hardness = 0.05,
    billboard = "cross",
    passable = true,
    sway = true,
    washes_away = true,
    light_emit = { r = 15, g = 9, b = 2 },
    textures = { all = "textures/fire.png" },
    drops = {},
}
M.fire_id = game.get_block_id(M.FIRE)

-- A trunk burns to this, so a burnt wood is standing black trunks.
M.CHARRED = "tiamat_weather:charred_log"
game.register_block{
    id = "charred_log",
    name = "Charred wood",
    description = "What is left of a trunk after a fire.",
    hardness = 0.6,
    textures = { all = "textures/charred_log.png" },
    tint = { strength = 0.08, scale = 64 },
}
M.charred_id = game.get_block_id(M.CHARRED)

-- Turf a plant fire went over. fire.lua asks the Spindle to treat it as
-- dirt (`add_soil_alias`, once this block exists), so its grass grows back
-- over it, and its own random tick heals it to bare ground as well.
M.SCORCHED = "tiamat_weather:scorched_ground"
game.register_block{
    id = "scorched_ground",
    name = "Scorched ground",
    description = "Turf a fire went over. It heals.",
    hardness = 0.5,
    textures = { all = "textures/scorched_ground.png" },
    tint = { strength = 0.2, scale = 96 },
}
M.scorched_id = game.get_block_id(M.SCORCHED)

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
        M.damp_ids[#M.damp_ids + 1] = "tiamat_weather:" .. spec.id
    end
end

return M
