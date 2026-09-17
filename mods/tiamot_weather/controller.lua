-- SPDX-License-Identifier: MIT
--
-- Weather is a function:
--
--   weather(x, y, z, tick) -> kind, intensity        (intensity in permille)
--
-- Only the clock is persisted. So two players standing together agree with
-- nothing synchronised, a restart resumes the same storm, and a forecast is
-- the same function asked about later ticks.
--
-- Every float operation here is + - * /, math.floor, or a Density:at read:
-- all inside the deterministic subset.
--
-- The function is EVALUATED once every EVAL_TICKS for each occupied SQUARE
-- (SQUARE blocks on a side), at the square's centre, and the result is EASED
-- per square: the applied intensity moves at most EASE a step, and a change
-- of family (rain to snow, rain to clear) fades the old one out before the
-- new one fades in. The easing is keyed by square, not by player, so
-- everybody in a square sees the same thing whenever they arrived.

local config = wx.config
local climate = wx.climate

local M = {}

-- ------------------------------------------------------------ kinds

M.KINDS = {
    clear     = { family = "dry",  precip = false, label = "" },
    cloudy    = { family = "dry",  precip = false, label = "Cloudy" },
    rain      = { family = "rain", precip = true,  label = "Rain", light = "Light rain" },
    storm     = { family = "rain", precip = true,  label = "Storm" },
    snow      = { family = "snow", precip = true,  label = "Snow", light = "Light snow" },
    blizzard  = { family = "snow", precip = true,  label = "Blizzard" },
    ash       = { family = "ash",  precip = true,  label = "Ashfall", light = "Light ashfall" },
    ash_storm = { family = "ash",  precip = true,  label = "Ash storm" },
    dust      = { family = "dust", precip = true,  label = "Dust storm", light = "Blowing dust" },
}
local LIGHT_BELOW = 350

-- What a HUD says for an applied kind and intensity.
function M.label(kind, intensity)
    local k = M.KINDS[kind]
    if k == nil then
        return ""
    end
    if k.precip and intensity <= 0 then
        return "Cloudy"
    end
    if k.light and intensity < LIGHT_BELOW then
        return k.light
    end
    return k.label
end

-- ------------------------------------------------------------ the front

-- A slow 3D noise read with the CLOCK in place of y, so a front swells,
-- drifts and dissolves without anything being moved. Its own stream name:
-- never a Spindle one.
local FRONT = game.density{
    op = "clamp", low = -0.5, high = 0.5,
    a = { op = "noise", stream = "wx_front", frequency = config.FRONT_FREQUENCY,
          octaves = config.FRONT_OCTAVES, amplitude = 1.0 },
}

function M.front(x, z, tick)
    local drift = tick // config.DRIFT_TICKS              -- integer blocks
    return FRONT:at(x - drift, tick / config.TICKS_PER_Y, z, game.world_seed)
end

local function floor(v)
    return math.floor(v)
end

-- The weather the function gives at a place and tick, ignoring overrides.
-- `ground` is the climate's reading of the ground there (nil, "ash",
-- "dust" or "sea"); the caller passes it because reading it costs blocks.
function M.target(x, y, z, tick, ground)
    local f = M.front(x, z, tick)
    if ground == "dust" then
        -- Dry sand ignores moisture: a strong front alone lifts it.
        if f >= config.DUST_AT then
            local over = (f - config.DUST_AT) / (0.5 - config.DUST_AT)
            return "dust", 300 + floor(700 * math.min(1.0, over))
        end
        return f >= config.CLOUDY_AT and "cloudy" or "clear", 0
    end
    local wet = f + climate.moisture(x, y, z)
    if wet < config.CLOUDY_AT then
        return "clear", 0
    elseif wet < config.RAIN_AT then
        return "cloudy", 0
    end
    local storm = wet >= config.STORM_AT
    local intensity = 1000
    if not storm then
        intensity = 200 + floor(800 * (wet - config.RAIN_AT) / (config.STORM_AT - config.RAIN_AT))
    end
    if ground == "ash" then
        return storm and "ash_storm" or "ash", intensity
    elseif climate.freezing(x, y, z) then
        return storm and "blizzard" or "snow", intensity
    end
    return storm and "storm" or "rain", intensity
end

-- ------------------------------------------------------------ squares

local SQUARE = config.SQUARE

function M.square_of(x, z)
    return floor(x) // SQUARE, floor(z) // SQUARE
end

local function key_of(cx, cz)
    return cx .. ":" .. cz
end
M.key_of = key_of

function M.centre_of(cx, cz)
    return cx * SQUARE + SQUARE // 2, cz * SQUARE + SQUARE // 2
end

-- ------------------------------------------------------------ overrides

-- `/weather set` stores `override:<cx>:<cz>` = "kind,intensity,until_tick" in
-- this mod's storage, mirrored here so a random tick does not read storage.
local overrides = {}
local overrides_loaded = false

local function load_overrides()
    overrides_loaded = true
    for _, key in ipairs(game.storage.keys()) do
        local square = string.match(key, "^override:(%-?%d+:%-?%d+)$")
        if square then
            local kind, intensity, until_tick = string.match(tostring(game.storage.get(key)), "^(%a[%w_]*),(%d+),(%d+)$")
            if kind and M.KINDS[kind] then
                overrides[square] = { kind = kind, intensity = tonumber(intensity), until_tick = tonumber(until_tick) }
            else
                game.storage.set(key, nil)
            end
        end
    end
end

function M.set_override(cx, cz, kind, intensity, until_tick)
    local key = key_of(cx, cz)
    overrides[key] = { kind = kind, intensity = intensity, until_tick = until_tick }
    game.storage.set("override:" .. key, string.format("%s,%d,%d", kind, intensity, until_tick))
end

function M.clear_override(cx, cz)
    local key = key_of(cx, cz)
    local had = overrides[key] ~= nil
    overrides[key] = nil
    game.storage.set("override:" .. key, nil)
    return had
end

-- The override in force at a square and tick, or nil. Expired ones are
-- pruned when they are found, from memory and from storage.
function M.override_at(cx, cz, tick)
    local key = key_of(cx, cz)
    local o = overrides[key]
    if o == nil then
        return nil
    end
    if o.until_tick <= tick then
        -- Gone by `tick`. Only forget it if it is gone NOW: a forecast asks
        -- about later ticks, and the override still holds until then.
        if o.until_tick <= wx.now then
            M.clear_override(cx, cz)
        end
        return nil
    end
    return o
end

-- ------------------------------------------------------------ the function

-- weather(x, y, z, tick) with the ground read and the override applied:
-- what a random tick or a forecast asks.
function M.weather(x, y, z, tick, ground)
    local cx, cz = M.square_of(x, z)
    local o = M.override_at(cx, cz, tick)
    if o then
        return o.kind, o.intensity
    end
    return M.target(x, y, z, tick, ground)
end

-- ------------------------------------------------------------ players

local players = {}          -- uuid -> name
local order = {}            -- sorted uuids: every "first player" is the same on every machine

local function rebuild_order()
    order = {}
    for uuid in pairs(players) do
        order[#order + 1] = uuid
    end
    table.sort(order)
end

wx.on_join(function(uuid, name)
    players[uuid] = name
    rebuild_order()
end)

wx.on_leave(function(uuid)
    players[uuid] = nil
    rebuild_order()
end)

-- The players here, in UUID order. Do not modify.
function M.players()
    return order
end

-- Where a player's feet are, looked up each time (entity ids are
-- per-session and a player's changes every join). Nil if not here.
function M.position(uuid)
    local body = game.player_entity(uuid)
    local me = body and game.entity(body)
    return me and me.pos or nil
end

-- ------------------------------------------------------------ evaluation

-- key -> { cx, cz, kind, intensity, target, members, rep, ground,
--          seen, last_rain, last_snow }
M.squares = {}
-- uuid -> { x, y, z, key }, from the last evaluation
M.where = {}
local hud_sent = {}          -- uuid -> the label last sent

local evaluated = {}
-- Runs `fn()` after every evaluation pass, when M.squares and M.where are fresh.
function M.on_evaluated(fn)
    evaluated[#evaluated + 1] = fn
end

local function step_towards(from, to)
    if from < to then
        return math.min(to, from + config.EASE)
    end
    return math.max(to, from - config.EASE)
end

local function ease(square, kind, intensity)
    if square.kind == nil then
        -- New to us, or the first evaluation since a restart: fade in from zero.
        square.kind, square.intensity = kind, 0
    end
    if M.KINDS[square.kind].family == M.KINDS[kind].family then
        square.kind = kind
        square.intensity = step_towards(square.intensity, intensity)
    elseif square.intensity > 0 then
        square.intensity = step_towards(square.intensity, 0)
    else
        square.kind = kind
        square.intensity = step_towards(0, intensity)
    end
end

local function evaluate()
    local tick = wx.now
    M.where = {}
    for _, square in pairs(M.squares) do
        square.members = {}
    end
    for _, uuid in ipairs(order) do
        local pos = M.position(uuid)
        if pos then
            local cx, cz = M.square_of(pos.x, pos.z)
            local key = key_of(cx, cz)
            local square = M.squares[key]
            if square == nil then
                square = { cx = cx, cz = cz, members = {}, last_rain = -1e9, last_snow = -1e9 }
                M.squares[key] = square
            end
            square.members[#square.members + 1] = uuid
            M.where[uuid] = { x = pos.x, y = pos.y, z = pos.z, key = key }
        end
    end

    for key, square in pairs(M.squares) do
        if #square.members == 0 then
            if tick - (square.seen or tick) > config.FORGET_SQUARE_TICKS then
                M.squares[key] = nil
            end
        else
            square.seen = tick
            -- The square's representative is its first player in UUID
            -- order: whose height decides rain or snow, and whose ground
            -- decides ash, dust or sea, for everyone in the square.
            local rep = M.where[square.members[1]]
            square.rep = rep
            local x, z = M.centre_of(square.cx, square.cz)
            square.ground = climate.override(rep.x, rep.y, rep.z)
            local kind, intensity
            local o = M.override_at(square.cx, square.cz, tick)
            if o then
                kind, intensity = o.kind, o.intensity
            else
                kind, intensity = M.target(x, rep.y, z, tick, square.ground)
            end
            square.target, square.target_intensity = kind, intensity
            ease(square, kind, intensity)
            local family = M.KINDS[square.kind].family
            if square.intensity > 0 then
                if family == "rain" then square.last_rain = tick end
                if family == "snow" then square.last_snow = tick end
            end
        end
    end

    for _, uuid in ipairs(order) do
        local where = M.where[uuid]
        local label = ""
        if where then
            local square = M.squares[where.key]
            label = M.label(square.kind, square.intensity)
        end
        if hud_sent[uuid] ~= label then
            hud_sent[uuid] = label
            if label == "" then
                game.set_hud(uuid, {})
            else
                game.set_hud(uuid, { weather = label, row = climate.hud_row })
            end
        end
    end

    for _, fn in ipairs(evaluated) do
        fn()
    end
end

wx.on_leave(function(uuid)
    hud_sent[uuid] = nil
    M.where[uuid] = nil
end)

-- ------------------------------------------------------------ the clock

local restored = false
local since_save = 0
local since_eval = 0

wx.on_tick(function(dt_ticks)
    if not restored then
        restored = true
        local saved = game.storage.get("tick")
        if type(saved) == "number" then
            wx.now = math.floor(saved) + wx.now
        end
        load_overrides()
    end
    since_save = since_save + dt_ticks
    if since_save >= config.CLOCK_SAVE_EVERY then
        since_save = 0
        game.storage.set("tick", wx.now)
    end
    since_eval = since_eval + dt_ticks
    if since_eval >= config.EVAL_TICKS and game.world_seed ~= nil then
        since_eval = 0
        evaluate()
    end
end)

-- Whether overrides have been read from storage yet (the first tick does it).
function M.ready()
    return overrides_loaded
end

return M
