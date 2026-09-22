-- SPDX-License-Identifier: MIT
--
-- One of each engine hook for the whole mod, with subscribers.
--
-- The engine keeps ONE callback per hook per mod, so every file that wants a
-- tick, a chat line, a join or a leave subscribes here, and this file holds
-- the engine's one registration of each. The same shape as the Spindle's
-- hooks.lua, and for the same reason: a second registration from another
-- file would quietly stop the first one running.

local ticks, joins, leaves = {}, {}, {}
local commands = {}

-- The world's clock, in ticks, counted from `dt_ticks`. controller.lua
-- restores it from storage on the first tick and saves it.
wx.now = 0

-- Runs `fn(dt_ticks)` every tick, after everything subscribed before it.
function wx.on_tick(fn)
    ticks[#ticks + 1] = fn
end

-- Runs `fn(uuid, name)` when a player arrives or leaves.
function wx.on_join(fn)
    joins[#joins + 1] = fn
end
function wx.on_leave(fn)
    leaves[#leaves + 1] = fn
end

-- A chat COMMAND, `/name args...`. `fn(player, args)` returns what to tell the
-- speaker, which also stops the line going out as chat.
function wx.on_command(name, fn)
    name = string.lower(name)
    assert(not commands[name], "command registered twice: /" .. name)
    commands[name] = fn
end

-- Each subscriber under a pcall so a failure is LOGGED with its message: the
-- engine disables the mod on a tick error and says only that it happened.
-- The error is re-raised, so the outcome is still the engine's.
local function run(list, what, ...)
    for _, fn in ipairs(list) do
        local ok, err = pcall(fn, ...)
        if not ok then
            game.log("tiamat_weather: " .. what .. " failed: " .. tostring(err))
            error(err, 0)
        end
    end
end

game.register_on_tick(function(dt_ticks)
    wx.now = wx.now + dt_ticks
    run(ticks, "tick", dt_ticks)
end)

game.register_on_player_join(function(event)
    run(joins, "join", event.player, event.name)
end)

game.register_on_player_leave(function(event)
    run(leaves, "leave", event.player, event.name)
end)

-- A line that starts with `/` and names one of this mod's commands runs it.
-- Anything else is left alone (nil), so the Spindle's commands and plain chat
-- still reach whoever they are for.
game.register_on_chat(function(event)
    local name, rest = string.match(event.text, "^%s*/(%S+)%s*(.-)%s*$")
    if name == nil then
        return nil
    end
    local command = commands[string.lower(name)]
    if command == nil then
        return nil
    end
    local args = {}
    for word in string.gmatch(rest, "%S+") do
        args[#args + 1] = word
    end
    local ok, reply = pcall(command, event.player, args)
    if not ok then
        game.log("tiamat_weather: the command `" .. event.text .. "` errored: " .. tostring(reply))
        return "that did not work; the log says why"
    end
    return type(reply) == "string" and reply or "done"
end)

return {}
