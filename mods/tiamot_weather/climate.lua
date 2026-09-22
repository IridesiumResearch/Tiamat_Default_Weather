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
--
-- The adapter is picked once, at load. `config.climate = "plain"` forces the
-- fallback. The Spindle is recognised by one of its blocks being registered:
-- it is an optional dependency, so when it is installed it has loaded first.

local config = wx.config

local function spindle_present()
    local ok, id = pcall(game.get_block_id, "tiamot_default_world:dirt")
    return ok and id ~= nil
end

local adapter
if config.climate ~= "plain" and spindle_present() then
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
    game.log(string.format("tiamot_weather: humidity %s, warmth %s, biomes %s; damp ground %s, puddles %s",
        adapter.sources.humidity, adapter.sources.warmth, adapter.sources.biome,
        config.damp_ground and "on" or "off", config.puddles and "on" or "off"))
end

return adapter
