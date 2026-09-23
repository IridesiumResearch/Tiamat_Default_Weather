-- SPDX-License-Identifier: MIT
--
-- What this mod offers other mods, through `game.export` (engine 482958a).
--
-- A mod that names `tiamat_weather` in its `depends` or `optional_depends`
-- reads this with `game.exports("tiamat_weather")`, which is nil when weather
-- is not installed or has been disabled. Survival (tiamat_default_life) is
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
-- Fire (2026-09-23; the version stays 1, since nothing above changed):
--
--   fire_at(x, y, z)            boolean: is the block there alight
--   flammable(x, y, z)          boolean: could it be (fuel fire.lua knows, holding no fluid)
--   ignite(x, y, z)             boolean: light it, by the NATURAL rules — the caps,
--                               the square's rest and the spacing between blazes
--                               all apply, but no odds are rolled
--   extinguish(x, y, z)         boolean: put that one block out
--   fires()                     blocks alight, blazes alight
--   on_lightning(fn)            boolean: `fn(x, y, z)` after every bolt, grounded or
--                               not, at the block the flash was centred on: the
--                               ground + 1, or STRIKE_ABOVE over the player when no
--                               column under the bolt answered (a point in the air)
--
-- Coordinates are world blocks and are floored, so an entity's position may
-- be passed as it is.
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
    game.log("tiamat_weather: this engine has no game.export; nothing is published to other mods")
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
            game.log("tiamat_weather: export `" .. name .. "` failed: " .. tostring(result[2]))
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

-- The block a point is in. Callers pass whatever they have — an entity's
-- feet, a dig event's cell already divided — and fire.lua wants integers.
local function block_of(x, y, z)
    return { x = math.floor(x), y = math.floor(y), z = math.floor(z) }
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

    -- Fire. Every answer is a plain boolean or a pair of counts; the WHY of a
    -- refusal stays on our side, because a reader that branched on the
    -- reason strings would be coupled to fire.lua's wording.
    fire_at = guarded("fire_at", function(x, y, z)
        if not coords(x, y, z) then
            return nil
        end
        return wx.fire.burning_at(block_of(x, y, z)) == true
    end),

    flammable = guarded("flammable", function(x, y, z)
        if not coords(x, y, z) then
            return nil
        end
        return wx.fire.fuel_at(block_of(x, y, z)) ~= nil
    end),

    ignite = guarded("ignite", function(x, y, z)
        if not coords(x, y, z) then
            return nil
        end
        local ok = wx.fire.ignite(block_of(x, y, z), "export")
        return ok == true
    end),

    extinguish = guarded("extinguish", function(x, y, z)
        if not coords(x, y, z) then
            return nil
        end
        return wx.fire.extinguish(block_of(x, y, z)) == true
    end),

    fires = guarded("fires", function()
        return wx.fire.count(), #wx.fire.blazes()
    end),

    -- The callback runs in the CALLER's sandbox when fx.lua calls it, so a
    -- fault in it lands on them and never on the storm (fx pcalls its side
    -- too). Nothing is unregistered: a mod that is disabled stops answering
    -- by the engine's own rule.
    on_lightning = guarded("on_lightning", function(fn)
        if type(fn) ~= "function" then
            return false
        end
        wx.fx.on_strike(fn)
        return true
    end),
}

return {}
