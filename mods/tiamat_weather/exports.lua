-- SPDX-FileCopyrightText: Iridesium
-- SPDX-License-Identifier: GPL-3.0-only
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
--   on_lightning(fn)            boolean: `fn(x, y, z)` after every bolt, at the block
--                               over the ground it struck (since 2026-09-28 a bolt
--                               only lands on ground under open sky; there is no
--                               bolt in the air any more)
--   fires_near(x, y, z, r)      list of { x, y, z }: the blocks alight within r
--                               (a sphere, r up to 64), by x, y, z (Science Wx-S4)
--
-- Sibling asks answered 2026-09-30 (the version stays 1: nothing changed shape):
--
--   wind(x, z)                  x, z, strength: the wind there, a direction of
--                               length about 1 (|x| + |z| on the Spindle) and a
--                               strength 0..1 from the weather over it — 0.2 on a
--                               clear day to 1 in a blizzard or a mega storm
--                               (Science Wx-S1: windmills and kites)
--   add_overlay(player, source, spec | nil)
--                               boolean: a sky modifier of your own, laid over the
--                               weather's rather than fighting it for the one
--                               `set_sky_modifier` a player has (Magic Wx-M1,
--                               Science Wx-S2). `source` names yours (a string,
--                               up to 64 bytes; one overlay per source a player);
--                               spec { intensity?, sky?, sky_mix?, saturation?,
--                               ease_ticks? }, the engine's ranges; nil removes it.
--                               Sent at once. Stays until removed or the player
--                               leaves, underground and off the overworld too.
--
-- And weather stands aside off the overworld (Science Wx-S3): a player in any
-- other domain gets no rain, sky, loop, clouds or HUD label from it, and
-- `weather_for` / `falling_on` answer nil for them.
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
    if type(player) ~= "string" or not controller.in_overworld(player) then
        return nil
    end
    return controller.position(player)
end

-- How hard the wind blows over each kind, 0..1. A precipitating kind eases
-- from the cloudy figure to its own with its intensity, as its sky does, and
-- a mega storm pushes any of them towards 1.
local WIND_STRENGTH = { clear = 0.2, cloudy = 0.35, rain = 0.5, storm = 0.85, snow = 0.4,
    blizzard = 1.0, ash = 0.4, ash_storm = 0.85, dust = 0.9 }

local function in_range(v, low, high)
    return is_number(v) and v >= low and v <= high
end

local MAX_OVERLAYS = 16
local function overlay_of(spec)
    if type(spec) ~= "table" then
        return nil
    end
    local o = { intensity = spec.intensity or 1.0, saturation = spec.saturation or 1.0,
        sky_mix = spec.sky_mix or 0.0, sky = { 0.0, 0.0, 0.0 } }
    if not (in_range(o.intensity, 0, 2) and in_range(o.saturation, 0, 4) and in_range(o.sky_mix, 0, 1)) then
        return nil
    end
    local sky = spec.sky
    if sky ~= nil then
        if type(sky) ~= "table" then
            return nil
        end
        local r, g, b = sky[1] or sky.r, sky[2] or sky.g, sky[3] or sky.b
        if not (in_range(r, 0, 2) and in_range(g, 0, 2) and in_range(b, 0, 2)) then
            return nil
        end
        o.sky = { r, g, b }
    elseif o.sky_mix > 0 then
        return nil
    end
    local ease = spec.ease_ticks
    if ease ~= nil and not (in_range(ease, 0, 2400)) then
        return nil
    end
    return o, ease and math.floor(ease) or nil
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

    fires_near = guarded("fires_near", function(x, y, z, r)
        if not coords(x, y, z) or not in_range(r, 0, 64) then
            return nil
        end
        return wx.fire.near(block_of(x, y, z), r)
    end),

    wind = guarded("wind", function(x, z)
        if not (is_number(x) and is_number(z)) or game.world_seed == nil then
            return nil
        end
        local w = climate.wind(x, z, wx.now)
        local y = climate.surface_y(x, z) + 1
        local kind, intensity, mega = weather_at(x, y, z)
        local strength = WIND_STRENGTH.clear
        if kind ~= nil then
            local own = WIND_STRENGTH[kind] or WIND_STRENGTH.cloudy
            if controller.KINDS[kind].precip then
                strength = WIND_STRENGTH.cloudy + (own - WIND_STRENGTH.cloudy) * intensity / 1000
            else
                strength = own
            end
            strength = strength + (1 - strength) * (mega or 0) / 1000
        end
        return w.x, w.z, strength
    end),

    add_overlay = guarded("add_overlay", function(player, source, spec)
        if type(player) ~= "string" or type(source) ~= "string" or #source == 0 or #source > 64 then
            return false
        end
        if spec == nil then
            return wx.fx.set_overlay(player, source, nil)
        end
        local o, ease = overlay_of(spec)
        if o == nil then
            return false
        end
        local layers = wx.fx.overlays[player]
        if layers and layers[source] == nil then
            local n = 0
            for _ in pairs(layers) do n = n + 1 end
            if n >= MAX_OVERLAYS then
                return false
            end
        end
        return wx.fx.set_overlay(player, source, o, ease)
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
