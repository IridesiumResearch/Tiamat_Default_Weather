-- SPDX-License-Identifier: MIT
--
-- /weather, and what it can be asked (plan 6).
--
--   /weather                          what it is doing where you stand, and why
--   /weather set <kind> [minutes]     force a kind on your square (default 10 minutes)
--   /weather clear                    remove the force
--   /weather forecast                 the next ten minutes at your square
--   /weather drift                    compare the mirrored humidity with the ground
--   /weather stats                    the sampler's and queue's counts, to the log
--
-- `set` and `clear` are gated by `config.commands` until the engine has
-- operators.

local config = wx.config
local climate = wx.climate
local controller = wx.controller

local M = {}

local SET_INTENSITY = { rain = 700, storm = 1000, snow = 700, blizzard = 1000, ash = 700,
    ash_storm = 1000, dust = 900, cloudy = 0, clear = 0 }
local FORECAST_MINUTES = 10
local FORECAST_STEP_TICKS = 1200     -- one line a minute

local function here(player)
    local pos = controller.position(player)
    if pos == nil then
        return nil
    end
    return pos
end

local function describe(player)
    local pos = here(player)
    if pos == nil then
        return "you are not anywhere the weather can find"
    end
    if game.world_seed == nil then
        return "the world is not open yet"
    end
    local cx, cz = controller.square_of(pos.x, pos.z)
    local square = controller.squares[controller.key_of(cx, cz)]
    local tick = wx.now
    local ground = climate.override(pos.x, pos.y, pos.z)
    local kind, intensity = controller.weather(pos.x, pos.y, pos.z, tick, ground)
    local applied = square and square.kind
        and string.format("%s at %d (easing to %s at %d)", square.kind, square.intensity, kind, intensity)
        or string.format("%s at %d (not yet evaluated)", kind, intensity)
    local forced = controller.override_at(cx, cz, tick)
    return string.format(
        "%s; warmth %d%s, moisture %.4f, front %.6f; ground %s; square %d:%d%s; climate %s%s; damp ground %s, puddles %s",
        applied,
        climate.warmth(pos.x, pos.y, pos.z),
        climate.freezing(pos.x, pos.y, pos.z) and " (freezing)" or "",
        climate.moisture(pos.x, pos.y, pos.z),
        controller.front(pos.x, pos.z, tick),
        ground or "plain",
        cx, cz,
        forced and string.format(", forced for %d s more", (forced.until_tick - tick) // 20) or "",
        climate.name,
        climate.sources and string.format(" (humidity %s, warmth %s, biomes %s)",
            climate.sources.humidity, climate.sources.warmth, climate.sources.biome) or "",
        config.damp_ground and "on" or "off", config.puddles and "on" or "off")
end

local function set(player, args)
    if not config.commands then
        return "weather commands are switched off on this server"
    end
    local kind = args[2] and string.lower(args[2])
    if kind == nil or controller.KINDS[kind] == nil then
        local names = {}
        for name in pairs(controller.KINDS) do
            names[#names + 1] = name
        end
        table.sort(names)
        return "usage: /weather set <kind> [minutes], where kind is one of: " .. table.concat(names, ", ")
    end
    local minutes = tonumber(args[3] or "10")
    if minutes == nil or minutes <= 0 then
        return "minutes must be a positive number"
    end
    local pos = here(player)
    if pos == nil then
        return "you are not anywhere the weather can find"
    end
    local cx, cz = controller.square_of(pos.x, pos.z)
    local ticks = math.floor(minutes * 60 * 20)
    controller.set_override(cx, cz, kind, SET_INTENSITY[kind], wx.now + ticks)
    return string.format("%s over square %d:%d for %s minutes; it eases in over about forty seconds",
        kind, cx, cz, tostring(minutes))
end

local function clear(player)
    if not config.commands then
        return "weather commands are switched off on this server"
    end
    local pos = here(player)
    if pos == nil then
        return "you are not anywhere the weather can find"
    end
    local cx, cz = controller.square_of(pos.x, pos.z)
    if controller.clear_override(cx, cz) then
        return string.format("square %d:%d is back to its own weather", cx, cz)
    end
    return string.format("nothing was forced on square %d:%d", cx, cz)
end

local function forecast(player)
    local pos = here(player)
    if pos == nil or game.world_seed == nil then
        return "you are not anywhere the weather can find"
    end
    local cx, cz = controller.square_of(pos.x, pos.z)
    local x, z = controller.centre_of(cx, cz)
    local ground = climate.override(pos.x, pos.y, pos.z)
    local lines, last = {}, nil
    for minute = 0, FORECAST_MINUTES do
        local tick = wx.now + minute * FORECAST_STEP_TICKS
        local kind, intensity = controller.weather(x, pos.y, z, tick, ground)
        local label = controller.label(kind, intensity)
        if label == "" then label = "Clear" end
        if label ~= last then
            lines[#lines + 1] = (minute == 0 and "now" or ("in " .. minute .. " min")) .. ": " .. label
            last = label
        end
    end
    return table.concat(lines, "; ")
end

local function drift(player)
    if climate.drift_check == nil then
        return "the plain climate mirrors nothing, so there is nothing to drift"
    end
    local pos = here(player)
    if pos == nil or game.world_seed == nil then
        return "you are not anywhere the weather can find"
    end
    return M.report_drift(pos)
end

-- Plan 3.4: logged, never fatal.
function M.report_drift(pos)
    -- With the fields exported, compare them with the mirror directly.
    if climate.has_exported_fields and climate.has_exported_fields() then
        local agreed, disagreed, judged, worst = climate.field_check(pos.x, pos.y, pos.z)
        local line
        if disagreed > 0 then
            line = string.format(
                "the mirror no longer matches the Spindle's exported fields: %d of %d points differ (%s)",
                disagreed, judged, worst)
        else
            line = string.format("the mirror matches the Spindle's exported fields at all %d points (%s)",
                agreed, worst)
        end
        game.log("tiamot_weather: drift check: " .. line)
        return line
    end
    local agreed, disagreed, judged = climate.drift_check(pos.x, pos.y, pos.z)
    local line
    if judged == 0 then
        line = "no loaded ground near here says wet or dry; try the temperate ring"
    elseif disagreed * 4 > judged then
        line = string.format("the Spindle's humidity no longer matches the mirror: %d of %d points disagree",
            disagreed, judged)
    else
        line = string.format("the mirror matches the ground: %d of %d points agree", agreed, judged)
    end
    game.log("tiamot_weather: drift check: " .. line)
    return line
end

-- The cloud deck over the player: what they were last sent.
local function clouds(player)
    if not wx.fx.has_clouds then
        return "this engine draws no clouds (it predates register_clouds)"
    end
    local pos = here(player)
    local was = wx.fx.clouds_sent[player]
    if pos == nil or was == nil then
        return "no clouds sent to you yet; they follow the first weather evaluation"
    end
    return string.format("cover %.2f, darkness %.2f, floor at y %d (%d blocks over you); cloud detail is your own graphics setting",
        was.cover, was.darkness, was.base, was.base - math.floor(pos.y))
end

local function stats()
    local parts = {}
    local function add(name, t)
        local keys = {}
        for k in pairs(t) do keys[#keys + 1] = k end
        table.sort(keys)
        for _, k in ipairs(keys) do parts[#parts + 1] = name .. "." .. k .. "=" .. tostring(t[k]) end
    end
    add("ground", wx.ground.stats)
    add("queue", wx.queue.stats)
    add("fx", wx.fx.stats)
    game.log("tiamot_weather stats: " .. table.concat(parts, " ") .. " waiting=" .. wx.queue.waiting())
    return "the weather's figures are in the server log"
end

wx.on_command("weather", function(player, args)
    local sub = args[1] and string.lower(args[1])
    if sub == nil then
        return describe(player)
    elseif sub == "set" then
        return set(player, args)
    elseif sub == "clear" then
        return clear(player)
    elseif sub == "forecast" then
        return forecast(player)
    elseif sub == "drift" then
        return drift(player)
    elseif sub == "clouds" then
        return clouds(player)
    elseif sub == "stats" then
        return stats()
    end
    return "usage: /weather [set <kind> [minutes] | clear | forecast | drift | clouds | stats]"
end)

-- The drift check once per session, when the first player has joined and
-- the ground around them has had a while to load.
local DRIFT_DELAY_TICKS = 600
local drift_due = nil
wx.on_join(function()
    if drift_due == nil then
        drift_due = wx.now + DRIFT_DELAY_TICKS
    end
end)
wx.on_tick(function()
    if drift_due == nil or drift_due == false or wx.now < drift_due then
        return
    end
    drift_due = false
    if climate.drift_check == nil or game.world_seed == nil then
        return
    end
    local first = controller.players()[1]
    local pos = first and controller.position(first)
    if pos then
        M.report_drift(pos)
    end
end)

return M
