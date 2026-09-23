-- SPDX-License-Identifier: MIT
--
-- /weather, and what it can be asked (plan 6).
--
--   /weather                          what it is doing where you stand, and why
--   /weather set <kind> [minutes]     force a kind on your square (default 10 minutes)
--   /weather clear                    remove the force
--   /weather forecast                 the next ten minutes at your square
--   /weather mega                     the next mega storms to pass over you
--   /weather drift                    compare the mirrored humidity with the ground
--   /weather stats                    the sampler's and queue's counts, to the log
--   /weather fires                    what is burning, world-wide, and how it started
--   /weather fire                     set alight what you are looking at
--   /weather fire at <x> <y> <z>      set alight the block at those coordinates
--   /weather fire out                 put every fire out
--   /weather strike                   a bolt where you are looking, or just ahead
--
-- `set`, `clear`, `fire` and `strike` are for operators (`config.commands`),
-- by the server's own list. The fire replies are asserted word for word by
-- the native checks (tests/native), so change them there too.

local config = wx.config
local climate = wx.climate
local controller = wx.controller

local M = {}

local SET_INTENSITY = { rain = 700, storm = 1000, snow = 700, blizzard = 1000, ash = 700,
    ash_storm = 1000, dust = 900, cloudy = 0, clear = 0 }
local FORECAST_MINUTES = 10
local FORECAST_STEP_TICKS = 1200     -- one line a minute
local STRIKE_AHEAD = 6               -- blocks along the facing /weather strike aims when nothing is looked at
local FIRE_USAGE = "usage: /weather fire [at <x> <y> <z> | out]"

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
    local kind, intensity, mega = controller.weather(pos.x, pos.y, pos.z, tick, ground)
    local applied = square and square.kind
        and string.format("%s at %d (easing to %s at %d)", square.kind, square.intensity, kind, intensity)
        or string.format("%s at %d (not yet evaluated)", kind, intensity)
    if (mega or 0) > 0 or (square and (square.mega or 0) > 0) then
        applied = applied .. string.format(", mega storm %d (easing to %d)", square and square.mega or 0, mega or 0)
    end
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

-- Whether this player may force the weather. Nil when they may, and what to
-- tell them when they may not.
local function refused(player)
    if config.commands == false then
        return "weather commands are switched off on this server"
    end
    if config.commands == "operators" and type(game.is_operator) == "function"
        and not game.is_operator(player) then
        return "only an operator can change the weather"
    end
    return nil
end

local function set(player, args)
    local no = refused(player)
    if no then
        return no
    end
    local kind = args[2] and string.lower(args[2])
    if kind == nil or (controller.KINDS[kind] == nil and kind ~= "mega") then
        local names = { "mega" }
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
    controller.set_override(cx, cz, kind, SET_INTENSITY[kind] or 1000, wx.now + ticks)
    return string.format("%s over square %d:%d for %s minutes; it eases in over about forty seconds",
        kind, cx, cz, tostring(minutes))
end

local function clear(player)
    local no = refused(player)
    if no then
        return no
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
        local kind, intensity, mega = controller.weather(x, pos.y, z, tick, ground)
        local label = controller.label(kind, intensity, mega)
        if label == "" then label = "Clear" end
        if label ~= last then
            lines[#lines + 1] = (minute == 0 and "now" or ("in " .. minute .. " min")) .. ": " .. label
            last = label
        end
    end
    return table.concat(lines, "; ")
end

-- When the next mega storms pass over you, in in-game days, and how strong
-- they get where you stand; `/weather mega <years>` counts them too.
local function mega(player, args)
    local pos = here(player)
    if pos == nil or game.world_seed == nil then
        return "you are not anywhere the weather can find"
    end
    local years = tonumber(args[2] or "2")
    if years == nil or years <= 0 or years > 100 then
        return "usage: /weather mega [years], up to 100"
    end
    local day = config.DAY_TICKS
    local slots = math.ceil(years * config.MEGA_PER_YEAR)
    local ahead = controller.mega_ahead(pos.x, pos.z, wx.now, slots)
    local horizon = wx.now + math.floor(years * controller.YEAR_TICKS)
    local count, full, next_one = 0, 0, nil
    for _, e in ipairs(ahead) do
        if e.start > wx.now and e.start <= horizon then
            count = count + 1
            if e.peak >= config.MEGA_LABEL_AT then
                full = full + 1
            end
            next_one = next_one or e
        end
    end
    local lines = {}
    local now = controller.mega(pos.x, pos.z, wx.now)
    if now > 0 then
        lines[#lines + 1] = string.format("a mega storm is over you now, at %d", now)
    end
    lines[#lines + 1] = string.format("%d mega storms pass over you in the next %s years, %d of them strong here",
        count, tostring(years), full)
    if next_one then
        lines[#lines + 1] = string.format("the next in %.1f days, up to %d", (next_one.start - wx.now) / day, next_one.peak)
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
        game.log("tiamat_weather: drift check: " .. line)
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
    game.log("tiamat_weather: drift check: " .. line)
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
    return string.format("cover %.2f, darkness %.2f, floor at y %d (%d blocks over you); %s; %s; cloud detail is your own graphics setting",
        was.cover, was.darkness, was.base, was.base - math.floor(pos.y),
        was.stratocumulus and string.format("stratocumulus %.2f, altocumulus %.2f, cumulonimbus %.2f",
            was.stratocumulus, was.altocumulus, was.cumulonimbus) or "no cloud genera on this engine",
        was.storms and string.format("%d of the %d squares around you are stormy", was.storms,
            config.CLOUD_MAP_SIZE * config.CLOUD_MAP_SIZE) or "no cover map on this engine")
end

-- ------------------------------------------------------------ fire

-- What is burning, for anyone: the live counts from fire.lua and its
-- lifetime figures. A world that switched fires off says so instead, since
-- every number would be zero and the zeros would read as "nothing yet".
local function fires()
    if not wx.fire.enabled then
        return "fires are switched off in this world"
    end
    local s = wx.fire.stats
    return string.format(
        "%d blazes alight, %d blocks burning; lit %d, spread %d, burnt %d, doused %d, scorched %d; by lightning %d, by lava %d",
        #wx.fire.blazes(), wx.fire.count(), s.ignited, s.spread, s.burnt, s.doused, s.scorched, s.lightning, s.lava)
end

-- A whole number from a command word, or nil: block coordinates are
-- integers, and "3.5" is a mistake rather than a block.
local function integer_arg(word)
    local n = tonumber(word)
    if n == nil then
        return nil
    end
    return math.tointeger(n)
end

-- The block under a player's crosshair, or nil. `looking_at` answers CELLS,
-- three to a block, and `//` floors, so a negative coordinate lands in the
-- right block too.
local function looked_at(player)
    local at = game.looking_at(player)
    if at == nil then
        return nil
    end
    return { x = at.x // 3, y = at.y // 3, z = at.z // 3 }
end

local function light(block)
    local ok, why = wx.fire.ignite(block, "command", { force = true })
    if ok then
        return string.format("lit at %d,%d,%d", block.x, block.y, block.z)
    end
    return string.format("nothing lit at %d,%d,%d: %s", block.x, block.y, block.z, tostring(why))
end

-- `force` skips the square's rest and the spacing between blazes, which are
-- rules about NATURAL fire; the caps still hold, because an operator who
-- lights a fifth blaze has found the cap, not a way round it.
local function fire(player, args)
    local no = refused(player)
    if no then
        return no
    end
    local what = args[2] and string.lower(args[2])
    if what == nil then
        local block = looked_at(player)
        if block == nil then
            return "look at something to set it alight"
        end
        return light(block)
    elseif what == "at" then
        local x, y, z = integer_arg(args[3]), integer_arg(args[4]), integer_arg(args[5])
        if x == nil or y == nil or z == nil then
            return FIRE_USAGE
        end
        return light({ x = x, y = y, z = z })
    elseif what == "out" then
        return string.format("%d burning blocks put out", wx.fire.extinguish_all())
    end
    return FIRE_USAGE
end

-- A bolt on demand: at the column under the crosshair, or, looking at
-- nothing, STRIKE_AHEAD blocks along the facing. `facing` is the engine's
-- unit vector, so the arithmetic is a multiply and a floor, no trig. The
-- thunder's gain and the mega odds come from the player's own square when it
-- has been evaluated; a fresh square gets a full storm's, which is what an
-- operator testing lightning wants to hear.
local function strike(player)
    local no = refused(player)
    if no then
        return no
    end
    local body = game.player_entity(player)
    local me = body and game.entity(body)
    if me == nil then
        return "you are not anywhere the weather can find"
    end
    if game.world_seed == nil then
        return "the world is not open yet"
    end
    local pos = me.pos
    local x, z
    local block = looked_at(player)
    if block then
        x, z = block.x, block.z
    else
        -- A body that reports no facing (an engine older than the field, or
        -- a test rig's) gets the bolt on its own column.
        local facing = me.facing or { x = 0, z = 0 }
        x = math.floor(pos.x + facing.x * STRIKE_AHEAD)
        z = math.floor(pos.z + facing.z * STRIKE_AHEAD)
    end
    local cx, cz = controller.square_of(pos.x, pos.z)
    local square = controller.squares[controller.key_of(cx, cz)]
    if not (square and square.kind and square.rep) then
        square = { rep = pos, intensity = 1000, mega = 0, cx = cx, cz = cz }
    end
    wx.fx.strike_at(x, z, square)
    return string.format("a bolt at %d,%d", x, z)
end

-- ------------------------------------------------------------ stats

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
    add("fire", wx.fire.stats)
    game.log("tiamat_weather stats: " .. table.concat(parts, " ") .. " waiting=" .. wx.queue.waiting())
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
    elseif sub == "mega" then
        return mega(player, args)
    elseif sub == "drift" then
        return drift(player)
    elseif sub == "clouds" then
        return clouds(player)
    elseif sub == "stats" then
        return stats()
    elseif sub == "fires" then
        return fires()
    elseif sub == "fire" then
        return fire(player, args)
    elseif sub == "strike" then
        return strike(player)
    end
    return "usage: /weather [set <kind> [minutes] | clear | forecast | mega | drift | clouds | stats | fires | fire [at x y z | out] | strike]"
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
