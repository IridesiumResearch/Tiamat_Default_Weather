-- SPDX-FileCopyrightText: Iridesium
-- SPDX-License-Identifier: GPL-3.0-only
--
-- Tiamat Weather. This file only decides the load order.
--
-- Every file below is loaded exactly once and hangs what it exports off the
-- `wx` global, which the sandbox shares between a mod's own files. The
-- engine's `require` is confined to this directory and does not cache, so a
-- file required twice would run twice, which is why nothing but this file
-- calls it.
--
-- Weather is a FUNCTION the server evaluates at a handful of points
-- (controller.lua); everything a player sees or hears is presentation sent
-- from those points (fx.lua, hud.lua), and the only world state it writes is
-- the ground (ground.lua) and fire (fire.lua), through a paced queue
-- (queue.lua).

wx = {}

-- The host reports a failed load as "errored in init.lua" and nothing more,
-- so say which file and what the error was before letting it through.
local function load(name)
    local ok, result = pcall(require, name)
    if not ok then
        game.log(string.format("tiamat_weather: %s.lua failed: %s", name, tostring(result)))
        error(result, 0)
    end
    return result
end

wx.config = load("config")
-- `wx_overrides`, if something set it before this file ran (the native
-- checks do), replaces config entries by name.
if type(wx_overrides) == "table" then
    for key, value in pairs(wx_overrides) do
        wx.config[key] = value
    end
end
load("hooks")                    -- one tick, one chat, one join and one leave hook; many subscribers
wx.climate = load("climate")     -- picks the Spindle or the plain adapter
wx.blocks = load("blocks")       -- snow_layer, rainwater, fire and its leavings, and the damp blocks when the Spindle is here
wx.controller = load("controller")
wx.queue = load("queue")
wx.ground = load("ground")
wx.fire = load("fire")           -- blazes: lit by lightning, lava, a command or an export; capped; rained out
wx.fx = load("fx")
wx.commands = load("commands")
load("exports")                  -- what other mods may read: game.exports("tiamat_weather")

game.register_hud_script("hud.lua")

game.log(string.format("tiamat_weather ready: climate %s, damp ground %s, puddles %s, fires %s",
    wx.climate.name, wx.config.damp_ground and "on" or "off", wx.config.puddles and "on" or "off",
    wx.fire.enabled and "on" or "off"))
