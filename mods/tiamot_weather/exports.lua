-- SPDX-License-Identifier: MIT
--
-- What this mod offers other mods, through `game.export` (engine 482958a).
--
-- A mod that names `tiamot_weather` in its `depends` or `optional_depends`
-- reads this with `game.exports("tiamot_weather")`, which is nil when weather
-- is not installed or has been disabled. Survival (tiamot_default_life) is
-- the obvious reader: whether it is raining on somebody, and how cold it is.
--
--   version = 1
--   kinds                       kind -> { family, precip, label }
--   climate                     "spindle" | "plain"
--   weather_at(x, y, z)         kind, intensity, mega (permille): what a player there sees
--   weather_for(player)         kind, intensity, label, mega: at that player, by UUID
--                               (`mega` is how far into a mega storm, 0..1000; added
--                               2026-09-19, so a caller that ignores it is unaffected)
--   falling_on(player)          "rain" | "snow" | "ash" | "dust" | nil: only under open sky
--   warmth(x, y, z)             integer 0..1000
--   freezing(x, y, z)           boolean
--
-- **The fault rules, from this side.** A function called through an export
-- runs in THIS mod's sandbox, so an error in one would disable weather for
-- the session, and the caller would get nil. So every function here checks
-- its arguments and runs under a pcall: a bad call from outside answers nil
-- and costs nothing, and a bug of ours is logged (once per function)
-- instead of taking the weather down. Everything handed out is read-only to
-- the reader, so `kinds` is a plain copy, and changing it is an error on
-- their side, not ours.

-- An engine older than 482958a has no exports; there is nothing to publish
-- to, and calling a nil field would disable this mod.
if type(game.export) ~= "function" then
    game.log("tiamot_weather: this engine has no game.export; nothing is published to other mods")
    return {}
end

local controller = wx.controller
local climate = wx.climate

local logged = {}

-- `fn` under a pcall, answering nil on any error and logging the first one.
local function guarded(name, fn)
    return function(...)
        local result = table.pack(pcall(fn, ...))
        if result[1] then
            return table.unpack(result, 2, result.n)
        end
        if not logged[name] then
            logged[name] = true
            game.log("tiamot_weather: export `" .. name .. "` failed: " .. tostring(result[2]))
        end
        return nil
    end
end

local function is_number(v)
    return type(v) == "number" and v == v and v > -1e9 and v < 1e9
end

local function coords(x, y, z)
    return is_number(x) and is_number(y) and is_number(z)
end

-- The weather a player standing at (x, y, z) sees: the eased state of that
-- square if somebody is there, and the function itself if nobody is.
local function weather_at(x, y, z)
    if not coords(x, y, z) or game.world_seed == nil then
        return nil
    end
    local cx, cz = controller.square_of(x, z)
    local square = controller.squares[controller.key_of(cx, cz)]
    if square and square.kind then
        return square.kind, square.intensity, square.mega or 0
    end
    return controller.weather(x, y, z, wx.now, climate.override(x, y, z))
end

local function position_of(player)
    if type(player) ~= "string" then
        return nil
    end
    return controller.position(player)
end

local kinds = {}
for kind, k in pairs(controller.KINDS) do
    kinds[kind] = { family = k.family, precip = k.precip, label = k.label }
end

game.export{
    version = 1,
    kinds = kinds,
    climate = climate.name,

    weather_at = guarded("weather_at", weather_at),

    weather_for = guarded("weather_for", function(player)
        local pos = position_of(player)
        if pos == nil then
            return nil
        end
        local kind, intensity, mega = weather_at(pos.x, pos.y, pos.z)
        if kind == nil then
            return nil
        end
        return kind, intensity, controller.label(kind, intensity, mega), mega or 0
    end),

    falling_on = guarded("falling_on", function(player)
        local pos = position_of(player)
        if pos == nil then
            return nil
        end
        local kind, intensity = weather_at(pos.x, pos.y, pos.z)
        if kind == nil or intensity <= 0 or not controller.KINDS[kind].precip then
            return nil
        end
        local head = { x = math.floor(pos.x), y = math.floor(pos.y + 1.6), z = math.floor(pos.z) }
        if game.get_light(head).sun ~= 15 then
            return nil
        end
        return controller.KINDS[kind].family
    end),

    warmth = guarded("warmth", function(x, y, z)
        if not coords(x, y, z) then
            return nil
        end
        return climate.warmth(x, y, z)
    end),

    freezing = guarded("freezing", function(x, y, z)
        if not coords(x, y, z) then
            return nil
        end
        return climate.freezing(x, y, z)
    end),
}

return {}
