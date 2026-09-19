-- SPDX-License-Identifier: MIT
--
-- What a player sees and hears. Presentation only; nothing here changes the
-- world.
--
-- **Rewritten 2026-09-17** onto the engine's weather calls (asks W1, W3, W4,
-- W5). What each player is under is now a handful of standing settings, sent
-- when they change rather than streamed:
--
--   set_precipitation  the rain itself: a shape the client spawns around its
--                      own camera at `rate` a second, eased, with a quarter of
--                      its particle budget kept free for everything else
--   set_sky_modifier   the storm's own daylight: intensity, horizon colour,
--                      how close the distance fog comes, saturation. This is
--                      the fog; the particle haze it replaces is gone
--   play_loop          rain or wind, to that player, its gain MOVED rather
--                      than restarted, so a storm can be nudged every tick
--   flash              lightning, with the thunder delayed by its distance
--
--   register_clouds    the cloud deck, once; the client marches it
--   set_clouds         how much of it a player is under, how grey, and where
--                      its floor is (following the Spindle's dome)
--
-- Nothing here emits particles any more.

local config = wx.config
local climate = wx.climate
local controller = wx.controller

local M = {}

local TICKS_PER_SECOND = 20

-- ------------------------------------------------------------ the tables

-- `live` is how many particles are in the air at once; the engine takes a
-- rate, which is live / lifetime. These are the counts the storm's "three
-- times harder to see through" was measured at: a client emitter spawns
-- exactly `live` particles round the camera, where the old bucket bursts
-- overlapped by two to four, so the same numbers now mean what they say. `area` is half extents, `above` is how far
-- over the camera the box sits, `wind` is blocks a second along the climate's
-- wind direction.
M.PRECIP = {
    rain = { live = 1100, size = 0.06, life = 1.0, vy = -22, gravity = 0, wind = 2,
        area = { 16, 3, 16 }, above = 18, colour = { 0.7, 0.75, 0.85, 0.55 } },
    storm = { live = 1365, size = 0.12, life = 0.8, vy = -30, gravity = 0, wind = 5,
        area = { 16, 3, 16 }, above = 18, colour = { 0.55, 0.6, 0.68, 0.65 } },
    snow = { live = 1400, size = 0.15, life = 5.0, vy = -2.5, gravity = 0.3, wind = 1.5, spread = 0.6,
        area = { 16, 4, 16 }, above = 14, colour = { 1, 1, 1, 0.9 } },
    blizzard = { live = 1400, size = 0.24, life = 3.0, vy = -3, gravity = 0, wind = 10,
        area = { 16, 6, 16 }, above = 8, colour = { 1, 1, 1, 0.85 } },
    -- Ash falls on the Ember Ridge, whose fumaroles share the client's budget.
    ash = { live = 700, size = 0.18, life = 7.0, vy = -1.5, gravity = 0.2, wind = 1,
        area = { 16, 4, 16 }, above = 14, colour = { 0.3, 0.3, 0.3, 0.8 } },
    ash_storm = { live = 840, size = 0.44, life = 7.0, vy = -1.5, gravity = 0.2, wind = 6,
        area = { 16, 4, 16 }, above = 14, colour = { 0.28, 0.27, 0.27, 0.85 } },
    dust = { live = 1400, size = 0.48, life = 2.0, vy = 0, gravity = 0, wind = 12, collide = false,
        area = { 16, 3, 16 }, above = 3, colour = { 0.85, 0.7, 0.5, 0.4 } },
}

-- The sky a kind is seen under, at full intensity: multipliers, and a colour
-- the horizon and the fog move towards. Every field is the identity at
-- intensity 0, so a storm darkens the sky as it eases in.
M.SKY = {
    cloudy    = { intensity = 0.90, sky = { 0.72, 0.75, 0.80 }, sky_mix = 0.35, fog = 0.85, saturation = 0.90 },
    rain      = { intensity = 0.72, sky = { 0.60, 0.64, 0.70 }, sky_mix = 0.55, fog = 0.60, saturation = 0.80 },
    storm     = { intensity = 0.45, sky = { 0.45, 0.48, 0.55 }, sky_mix = 0.80, fog = 0.35, saturation = 0.65 },
    snow      = { intensity = 0.80, sky = { 0.85, 0.88, 0.92 }, sky_mix = 0.50, fog = 0.50, saturation = 0.85 },
    blizzard  = { intensity = 0.60, sky = { 0.90, 0.93, 0.96 }, sky_mix = 0.85, fog = 0.22, saturation = 0.50 },
    ash       = { intensity = 0.65, sky = { 0.35, 0.33, 0.32 }, sky_mix = 0.60, fog = 0.50, saturation = 0.70 },
    ash_storm = { intensity = 0.40, sky = { 0.25, 0.23, 0.22 }, sky_mix = 0.85, fog = 0.28, saturation = 0.50 },
    dust      = { intensity = 0.70, sky = { 0.85, 0.70, 0.45 }, sky_mix = 0.80, fog = 0.30, saturation = 0.80 },
}

-- A mega storm at full strength: every kind's own sky pushed this far
-- further, so a mega blizzard is a whiter-out blizzard and a mega storm a
-- blacker storm.
M.MEGA_SKY = { intensity = 0.55, sky_mix = 1.0, fog = 0.5, saturation = 0.7 }
-- And its rain: this many times the particles (up to the engine's cap), this
-- much bigger, and this much harder in the wind.
M.MEGA_PRECIP = { rate = 2.2, size = 1.35, wind = 2.0, fall = 1.4 }

local MAX_RATE = 4000
for kind, row in pairs(M.PRECIP) do
    local rate = row.live / row.life
    assert(rate <= MAX_RATE, string.format("precipitation `%s` asks for %d a second, over the engine's %d",
        kind, math.floor(rate), MAX_RATE))
    row.rate = rate
end

-- ------------------------------------------------------------ registration

game.register_sound{ id = "rain", file = "sounds/rain.wav", gain = 0.8 }
game.register_sound{ id = "wind", file = "sounds/wind.wav", gain = 0.7 }
game.register_sound{ id = "thunder", file = "sounds/thunder.wav", gain = 1.0, pitch_variance = 0.15 }

-- Options index from zero: 2 is "full".
game.register_setting{
    id = "particles",
    name = "Weather particles",
    description = "Rain and snow drawn around you. The sky and the clouds are not affected; clouds have their own graphics setting.",
    options = { "off", "low", "full" },
    default = 2,
}
local SETTING = "tiamot_weather:particles"
local SHARE = { off = 0, low = 1, full = 2 }

M.stats = { precipitation = 0, sky = 0, loops = 0, flashes = 0, thunder = 0, clouds = 0, underground = 0 }

-- ------------------------------------------------------------ one player's weather

-- What each player was last sent, so nothing is built twice. The engine also
-- sends only on change; this saves making the tables.
local sent = {}

local function share_of(uuid)
    return SHARE[game.setting(uuid, SETTING)] or 2
end

-- How far a square is into a mega storm, 0 to 1.
local function mega_of(square)
    return (square.mega or 0) / 1000
end
M.mega_of = mega_of

local function precipitation_for(uuid, square, share, wind, was)
    local row = M.PRECIP[square.kind]
    local wanted = row ~= nil and square.intensity > 0 and share > 0
    if not wanted then
        if was.precip then
            was.precip = nil
            game.set_precipitation(uuid, nil)
        end
        return
    end
    local up = mega_of(square)
    local more = 1 + (M.MEGA_PRECIP.rate - 1) * up
    local rate = math.min(MAX_RATE, math.floor(row.rate * more) * square.intensity // 1000)
    if share == 1 then
        rate = rate // 2
    end
    local size = row.size * (1 + (M.MEGA_PRECIP.size - 1) * up)
    local blow = row.wind * (1 + (M.MEGA_PRECIP.wind - 1) * up)
    local fall = row.vy * (1 + (M.MEGA_PRECIP.fall - 1) * up)
    local key = string.format("%s:%d:%d", square.kind, rate, math.floor(up * 20))
    if was.precip == key then
        return
    end
    was.precip = key
    game.set_precipitation(uuid, {
        rate = rate,
        size = size,
        colour = { r = row.colour[1], g = row.colour[2], b = row.colour[3], a = row.colour[4] },
        lifetime = row.life,
        velocity = { x = wind.x * blow, y = fall, z = wind.z * blow },
        spread = row.spread or 0,
        gravity = row.gravity,
        collide = row.collide ~= false,
        area = { x = row.area[1], y = row.area[2], z = row.area[3] },
        above = row.above,
        ease_ticks = config.EASE_TICKS,
    })
    M.stats.precipitation = M.stats.precipitation + 1
end

-- Towards the kind's sky by how far it has eased in, and by how much of the
-- sky the player is under: the engine pulls a modifier's fog in everywhere,
-- so a blizzard's fog would follow them down a cave. The particles setting
-- does not touch this: the weather's own daylight is not a particle.
local function sky_for(uuid, square, exposure, was)
    local row = M.SKY[square.kind]
    local far = square.intensity * exposure // 15 / 1000
    if row == nil or far <= 0 then
        if was.sky then
            was.sky = nil
            game.set_sky_modifier(uuid, nil)
        end
        return
    end
    local function towards(one, other)
        return one + (other - one) * far
    end
    -- A mega storm pushes each number further by the same share: darker,
    -- closer, greyer. Scaled by exposure too, so a cave is still a refuge.
    local up = mega_of(square) * exposure / 15
    local function further(value, by)
        return value * (1 - (1 - by) * up)
    end
    local key = string.format("%s:%.3f:%.2f", square.kind, far, up)
    if was.sky == key then
        return
    end
    was.sky = key
    game.set_sky_modifier(uuid, {
        intensity = further(towards(1.0, row.intensity), M.MEGA_SKY.intensity),
        sky = row.sky,
        sky_mix = math.min(1.0, towards(0.0, row.sky_mix) + (M.MEGA_SKY.sky_mix - row.sky_mix) * up),
        fog_distance = further(towards(1.0, row.fog), M.MEGA_SKY.fog),
        saturation = further(towards(1.0, row.saturation), M.MEGA_SKY.saturation),
        ease_ticks = config.EASE_TICKS,
    })
    M.stats.sky = M.stats.sky + 1
end

-- One ambience loop per player: the gain MOVES rather than restarting, so a
-- storm can be nudged as often as it is evaluated (engine 2026-09-17).
local LOOP_SOUND = { rain = "rain", storm = "rain", blizzard = "wind", dust = "wind", ash_storm = "wind" }
local LOOP_GAIN = { rain = 0.8, storm = 1.0, blizzard = 1.0, dust = 0.9, ash_storm = 0.8 }
local LOOP_ID = "weather"

-- Heard as far as the sky reaches: fading into a cave mouth, and gone under
-- the ground, where an `everywhere` loop would otherwise play at full storm.
local function loop_for(uuid, square, exposure, was)
    local heard = square.intensity * exposure // 15
    local sound = heard > 0 and LOOP_SOUND[square.kind] or nil
    if sound == nil then
        if was.loop then
            was.loop = nil
            game.stop_loop{ id = LOOP_ID, player = uuid, fade_ticks = config.EASE_TICKS }
        end
        return
    end
    -- Quarter steps: a nudge every evaluation is cheap, but the table is not.
    local step = math.max(1, (heard + 125) // 250)
    -- A mega storm is louder, by up to half again.
    local loud = 1 + 0.5 * mega_of(square) * exposure / 15
    step = step + math.floor((loud - 1) * 4 + 0.5)
    local key = sound .. ":" .. step
    if was.loop == key then
        return
    end
    was.loop = key
    game.play_loop{
        id = LOOP_ID,
        sound = sound,
        player = uuid,
        everywhere = true,
        gain = LOOP_GAIN[square.kind] * step / 4,
        fade_ticks = config.EASE_TICKS,
    }
    M.stats.loops = M.stats.loops + 1
end

-- ------------------------------------------------------------ lightning

-- The flash is seen at once and the thunder arrives at the speed of sound:
-- about 19 blocks a tick, a yard to the block.
local BLOCKS_PER_TICK = 19
local pending = {}

local function strike(square, tick)
    local rng = game.rng_stream({ x = square.cx, y = tick % (1 << 30), z = square.cz,
        seed = game.world_seed }, "wx_thunder")
    local up = mega_of(square)
    local odds = math.floor(config.THUNDER_ODDS + (config.MEGA_THUNDER_ODDS - config.THUNDER_ODDS) * up + 0.5)
    if rng:below(math.max(1, odds)) ~= 0 then
        return
    end
    local rep = square.rep
    local dx = rng:below(2 * config.STRIKE_REACH + 1) - config.STRIKE_REACH
    local dz = rng:below(2 * config.STRIKE_REACH + 1) - config.STRIKE_REACH
    local at = { x = rep.x + dx, y = rep.y + config.STRIKE_ABOVE, z = rep.z + dz }
    game.flash{
        pos = at,
        radius = config.STRIKE_SEEN,
        intensity = 1.0,
        colour = { 0.9, 0.92, 1.0 },
        attack_ticks = 1,
        decay_ticks = 6,
    }
    M.stats.flashes = M.stats.flashes + 1
    -- Thunder, once the sound has had time to travel from there to here.
    local far = math.max(math.abs(dx), math.abs(dz))
    pending[#pending + 1] = { at = at, when = tick + far // BLOCKS_PER_TICK,
        gain = 0.5 + square.intensity / 2000 + 0.5 * up }
end

local function thunder(tick)
    if #pending == 0 then
        return
    end
    local keep = {}
    for _, clap in ipairs(pending) do
        if tick >= clap.when then
            game.play_sound{ sound = "thunder", pos = clap.at, radius = config.STRIKE_HEARD, gain = clap.gain }
            M.stats.thunder = M.stats.thunder + 1
        else
            keep[#keep + 1] = clap
        end
    end
    pending = keep
end

-- ------------------------------------------------------------ clouds

-- **The deck** (engine `register_clouds`, ask W2, 2026-09-18). The client
-- marches a ray through a cloud FIELD and draws the cubes it hits, so the
-- deck reaches the horizon, drifts and changes shape at no cost to rebuild.
-- Shaped after the designer's references (docs/reference/): cubes of `cell`
-- blocks whose surfaces break into smaller ones, flat bases, heaped tops,
-- some towers, a blue-violet shade on the unlit side. The player's graphics
-- settings decide how fine it is drawn, or whether at all.
--
-- It drifts with the weather fronts, which move along +x one block every
-- DRIFT_TICKS, so the sky and the rain under it travel together.
--
-- On an engine older than the clouds (engine 57d9ec2), there are none.
local HAS_CLOUDS = type(game.register_clouds) == "function" and type(game.set_clouds) == "function"
M.has_clouds = HAS_CLOUDS

-- The floor, in world y: CLOUD_ABOVE over the ground the climate knows, in
-- steps of CLOUD_BASE_STEP so walking does not nudge the whole sky. On the
-- Spindle the ground is a dome falling 2.5 km from the axis to the rim, so
-- the floor is sent per player, from the dome under them.
local function floor_at(x, z)
    local ground = climate.surface_y(x, z)
    local step = config.CLOUD_BASE_STEP
    return (math.floor(ground + config.CLOUD_ABOVE) // step) * step
end
M.floor_at = floor_at

if HAS_CLOUDS then
    game.register_clouds{
        base = floor_at(0, 0),
        thickness = config.CLOUD_THICKNESS,
        cell = config.CLOUD_CELL,
        detail = config.CLOUD_DETAIL,
        frequency = config.CLOUD_FREQUENCY,
        octaves = config.CLOUD_OCTAVES,
        towers = config.CLOUD_TOWERS,
        drift = { x = TICKS_PER_SECOND / config.DRIFT_TICKS, z = 0 },
        evolve = config.CLOUD_EVOLVE,
        colour = { 1.0, 1.0, 1.0 },
        shade = { 0.42, 0.44, 0.58 },
    }
end

-- How much of the sky each kind covers, and how grey. A precipitating kind
-- eases from a cloudy sky to its own as its intensity rises, so the deck
-- thickens and darkens as the rain arrives.
M.CLOUDS = {
    clear     = { cover = 0.15, darkness = 0.0 },
    cloudy    = { cover = 0.55, darkness = 0.05 },
    rain      = { cover = 0.80, darkness = 0.45 },
    storm     = { cover = 1.00, darkness = 0.90 },
    snow      = { cover = 0.80, darkness = 0.25 },
    blizzard  = { cover = 1.00, darkness = 0.50 },
    ash       = { cover = 0.75, darkness = 0.70 },
    ash_storm = { cover = 1.00, darkness = 1.00 },
    dust      = { cover = 0.30, darkness = 0.20 },
}

-- What each player was last sent, for /weather clouds.
M.clouds_sent = {}

local function clouds_for(uuid, where, square, was)
    local row = M.CLOUDS[square.kind] or M.CLOUDS.clear
    local cover, darkness = row.cover, row.darkness
    if controller.KINDS[square.kind].precip then
        local far = square.intensity / 1000
        local from = M.CLOUDS.cloudy
        cover = from.cover + (row.cover - from.cover) * far
        darkness = from.darkness + (row.darkness - from.darkness) * far
    end
    -- A mega storm closes the sky and blackens it.
    local up = mega_of(square)
    cover = cover + (1 - cover) * up
    darkness = darkness + (1 - darkness) * up
    local base = floor_at(where.x, where.z)
    local key = string.format("%.2f:%.2f:%d", cover, darkness, base)
    if was.clouds == key then
        return
    end
    -- A player's first sky is there at once: easing it in from nothing would
    -- show a newcomer a clear sky for the first half minute. Only a change of
    -- weather is eased.
    local first = was.clouds == nil
    was.clouds = key
    game.set_clouds(uuid, {
        cover = cover,
        darkness = darkness,
        base = base,
        ease_ticks = first and 0 or config.CLOUD_EASE_TICKS,
    })
    M.clouds_sent[uuid] = { cover = cover, darkness = darkness, base = base }
    M.stats.clouds = M.stats.clouds + 1
end

-- ------------------------------------------------------------ the tick

-- Everything a player stands under, set when the weather is evaluated.
controller.on_evaluated(function()
    local tick = wx.now
    for _, uuid in ipairs(controller.players()) do
        local where = controller.where[uuid]
        local square = where and controller.squares[where.key]
        local was = sent[uuid]
        if was == nil then
            was = {}
            sent[uuid] = was
        end
        if square and square.kind then
            local share = share_of(uuid)
            local wind = climate.wind(where.x, where.z, tick)
            -- Rain a player cannot see costs them nothing.
            local head = { x = math.floor(where.x), y = math.floor(where.y + 1.6), z = math.floor(where.z) }
            -- 15 is open sky; less is a cave mouth, an overhang or a doorway.
            local exposure = math.max(0, math.min(15, game.get_light(head).sun))
            if exposure > 0 then
                precipitation_for(uuid, square, share, wind, was)
            else
                M.stats.underground = M.stats.underground + 1
                if was.precip then
                    was.precip = nil
                    game.set_precipitation(uuid, nil)
                end
            end
            sky_for(uuid, square, exposure, was)
            loop_for(uuid, square, exposure, was)
            if HAS_CLOUDS then
                clouds_for(uuid, where, square, was)
            end
            -- Storms strike, and so does anything a mega storm has hold of:
            -- thundersnow in a mega blizzard, lightning in the ash.
            if square.intensity > 0 and (square.kind == "storm" or (square.mega or 0) > 0) then
                strike(square, tick)
            end
        end
    end
end)

wx.on_tick(function()
    thunder(wx.now)
end)

-- A player who leaves takes their settings with them; one who rejoins is on
-- the plain sky until their first evaluation.
wx.on_leave(function(uuid)
    sent[uuid] = nil
    M.clouds_sent[uuid] = nil
end)

return M
