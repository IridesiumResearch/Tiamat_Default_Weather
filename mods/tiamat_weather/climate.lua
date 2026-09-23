-- SPDX-License-Identifier: MIT
--
-- The climate adapter: everything outside climate_*.lua asks only this.
--
--   name                  "spindle" | "plain"
--   warmth(x, y, z)       integer 0..1000
--   freezing(x, y, z)     boolean
--   moisture(x, y, z)     noise units, about -0.5..0.5 (more over wet belts)
--   override(x, y, z)     nil | "ash" | "dust" | "sea", read from the ground at feet (x, y, z)
--   wind(x, z, tick)      a direction { x, z }, |x| + |z| = 1, no square root
--   damp                  dry block id (string) -> damp block id (string)
--   canopy                numeric material -> true: leaves, under which it is still outdoors
--   covered               numeric material -> true: ground snow never settles on
--   hud_row               where hud.lua draws the weather line
--   fuel                  numeric material -> { catch, burn, residue, kind }: what burns (fire.lua)
--   scorch                numeric material -> block id: turf a plant fire blackens
--   hot_blocks            numeric material -> true: solids that light what stands beside them
--   hot_fluids            fluid id (string) -> true: fluids that do, when they flow
--   bare                  block id (string) or nil: what scorched ground heals to
--   unlock_scorched()     asks the Spindle to treat scorched ground as dirt; true if taken
--   surface_y(x, z)       the ground the clouds float over: the dome, or sea level
--   cloud_lift(x, y, z)   blocks the cloud floor stands higher at a place: mountains
--
-- The adapter is picked once, at load. `config.climate = "plain"` forces the
-- fallback. The Spindle is recognised by one of its blocks being registered:
-- it is an optional dependency, so when it is installed it has loaded first.

local config = wx.config

local SPINDLE_ID = "tiamat_default_world"

local function spindle_id()
    local ok, block = pcall(game.get_block_id, SPINDLE_ID .. ":dirt")
    if ok and block ~= nil then
        return SPINDLE_ID
    end
    return nil
end

-- The id the Spindle is installed under, or nil. Read by climate_spindle.
wx.spindle_id = spindle_id()

local adapter
if config.climate ~= "plain" and wx.spindle_id ~= nil then
    adapter = require("climate_spindle")
else
    adapter = require("climate_plain")
end

-- Shared by both adapters.
function adapter.freezing(x, y, z)
    return adapter.warmth(x, y, z) < config.FREEZE
end

-- "auto" switches: on when the world mod has said it can take them.
local function resolve(value, unlock)
    if value == "auto" then
        return unlock ~= nil and unlock() or false
    end
    return value == true
end
config.damp_ground = resolve(config.damp_ground, adapter.unlock_damp)
config.puddles = resolve(config.puddles, adapter.unlock_puddles)
if adapter.sources then
    game.log(string.format("tiamat_weather: humidity %s, warmth %s, biomes %s; damp ground %s, puddles %s",
        adapter.sources.humidity, adapter.sources.warmth, adapter.sources.biome,
        config.damp_ground and "on" or "off", config.puddles and "on" or "off"))
end

return adapter
