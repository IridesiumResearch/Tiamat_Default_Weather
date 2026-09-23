-- SPDX-License-Identifier: MIT
--
-- The plain adapter, for any world this mod knows nothing about: moisture
-- is this mod's own noise, warmth falls with height above `config.sea_level`,
-- there are no overrides, and the wind turns slowly. A plain world gets rain
-- and snow that ignore biomes, which is honest for a world nobody described.

local config = wx.config

local M = { name = "plain", hud_row = config.HUD_ROW_PLAIN }

-- This mod's own stream. **Never a Spindle name**: a field silently equal to
-- somebody else's is the hardest worldgen bug to see.
local MOISTURE = game.density{
    op = "clamp", low = -0.5, high = 0.5,
    a = { op = "noise", stream = "wx_moisture", frequency = 1 / 6000, octaves = 2,
          amplitude = 1.0, stretch = { y = 1000 } },
}

local SEA_WARMTH = 600

function M.moisture(x, y, z)
    return MOISTURE:at(x, y, z, game.world_seed)
end

function M.warmth(_x, y, _z)
    local value = math.floor(SEA_WARMTH - config.BAND * (y - config.sea_level) / config.CLIMATE_LAPSE)
    if value < 0 then return 0 end
    if value > 1000 then return 1000 end
    return value
end

-- Sixteen directions round the compass, |x| + |z| = 1, written out rather
-- than computed: no trig in a mod.
local COMPASS = {}
do
    local quarter = { { 1.0, 0.0 }, { 0.75, 0.25 }, { 0.5, 0.5 }, { 0.25, 0.75 } }
    local signs = { { 1, 1 }, { -1, 1 }, { -1, -1 }, { 1, -1 } }
    for q = 1, 4 do
        for _, d in ipairs(quarter) do
            -- rotate each quadrant by swapping into the next
            local ax, az = d[1], d[2]
            if q % 2 == 0 then ax, az = az, ax end
            COMPASS[#COMPASS + 1] = { x = ax * signs[q][1], z = az * signs[q][2] }
        end
    end
end
local WIND_TURN_TICKS = 12000    -- ten minutes per sixteenth of a turn

function M.wind(_x, _z, tick)
    return COMPASS[(tick // WIND_TURN_TICKS) % #COMPASS + 1]
end

-- The ground the clouds float over: sea level, for a world nobody described.
function M.surface_y()
    return config.sea_level
end

function M.override()
    return nil
end

M.covered = {}
M.canopy = {}
-- Nil: any whole block of one material may hold a puddle.
M.puddle_ground = nil
M.hot_fluids = {}
M.damp = {}

-- Nothing this mod knows of burns on a plain world, so fire there exists
-- only when another mod's export lights something it also registered.
M.fuel = {}
M.scorch = {}
M.hot_blocks = {}
M.bare = nil
function M.unlock_scorched()
    return false
end

return M
