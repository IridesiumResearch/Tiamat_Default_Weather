-- SPDX-FileCopyrightText: Iridesium
-- SPDX-License-Identifier: GPL-3.0-only
--
-- The weather, as one line at the top of the screen. Runs on the CLIENT,
-- once a frame, and sees only what controller.lua sent this player with
-- `game.set_hud`: `weather`, the words, and `row`, where to put them (below
-- the Spindle's biome name when the Spindle is here). Draw, do not compute.
--
-- The canvas is 1080 virtual pixels tall and as wide as the window, and the
-- "top" anchor puts x = 0 in the middle of it.

local SHADOW = { r = 0, g = 0, b = 0 }
local INK = { r = 214, g = 226, b = 240 }
local SIZE = 20

hud.on_draw(function(state)
    local text = state.values.weather
    if type(text) ~= "string" or text == "" then
        return
    end
    local y = state.values.row
    if type(y) ~= "number" then
        y = 44
    end
    -- Twice, the dark copy a pixel down and right: the engine has no outlined
    -- text, and a pale word over a bright sky is unreadable otherwise.
    hud.text{ anchor = "top", x = 1, y = y + 1, text = text, size = SIZE, colour = SHADOW }
    hud.text{ anchor = "top", x = 0, y = y, text = text, size = SIZE, colour = INK }
end)
