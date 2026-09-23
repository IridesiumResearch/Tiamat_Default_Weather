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
-- **Lightning lands** (2026-09-23). A bolt used to be a flash forty blocks
-- over the player at a random offset that touched nothing. It now finds the
-- ground under the highest of a few candidate columns (`surface_at`, one call
-- a column), flashes a block over it, throws sparks there, tells anyone who
-- asked (`M.on_strike`), and hands the ground to fire.lua: fuel may catch,
-- bare turf may be scorched. The odds of a strike at all are unchanged.
--
-- **Fire is seen and heard from here**, and only from here: fire.lua owns
-- the state and says what changed through `wx.fire.on_change`; this file
-- turns that into a crackle loop per blaze, smoke and embers over it every
-- turn, and a hiss when rain puts a block out. Bursts are the only particles
-- this file emits: rain is still the client's own emitter. Smoke and embers
-- are world bursts near a place, not rain round a camera, so the particles
-- setting does not gate them; they are kept small instead.

local config = wx.config
local climate = wx.climate
local controller = wx.controller

local M = {}

local TICKS_PER_SECOND = 20
local Y_WRAP = 1 << 30          -- rng_stream takes y as a 32-bit integer

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
-- A blaze's crackle is a LOOP (its loudness follows how much is alight), and
-- a douse is a one-shot hiss. A missing file disables that one sound and
-- nothing else, so a server without the WAVs still has its fire.
game.register_sound{ id = "fire", file = "sounds/fire.wav", gain = 0.9 }
game.register_sound{ id = "douse", file = "sounds/douse.wav", gain = 0.7, pitch_variance = 0.1 }

-- Options index from zero: 2 is "full".
game.register_setting{
    id = "particles",
    name = "Weather particles",
    description = "Rain and snow drawn around you. The sky and the clouds are not affected; clouds have their own graphics setting.",
    options = { "off", "low", "full" },
    default = 2,
}
local SETTING = "tiamat_weather:particles"
local SHARE = { off = 0, low = 1, full = 2 }

M.stats = {
    precipitation = 0, sky = 0, loops = 0, flashes = 0, thunder = 0, clouds = 0, underground = 0, canopy = 0,
    -- Lightning that found ground, and what it did there.
    strikes_grounded = 0, ignitions = 0, scorches = 0, set_alight = 0,
    -- Fire, presented.
    fire_loops = 0, smoke = 0,
}

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

-- Where the ground under a bolt is looked for: from this far over the
-- player's feet, this far down. A canopy or a tower stands well over the
-- player; a valley floor lies well under a player on its rim.
local STRIKE_SCAN_ABOVE = 64
local STRIKE_SCAN = 128
-- Sparks at the point of impact: what shows a strike by day, when the flash
-- does not (the renderer caps the sun at daylight).
local SPARKS = { count = 24, colour = { r = 1, g = 0.95, b = 0.7, a = 0.9 }, size = 0.12,
    lifetime = 0.6, rise = 6, spread = 5, gravity = 12, seen = 128 }

-- Who wants to know where a bolt landed: `fn(x, y, z)`, the block the flash
-- was centred on. exports.lua hands this to other mods as `on_lightning`,
-- which is how Survival can hurt whoever stands beside a strike. Each runs
-- under a pcall: a listener's failure is logged once and never stops the
-- storm. (A function another mod passed in runs in ITS sandbox, so its
-- error lands on it and answers nil here; the pcall is for our own side.)
local listeners = {}

function M.on_strike(fn)
    listeners[#listeners + 1] = { fn = fn, failed = false }
end

local function tell_listeners(x, y, z)
    for _, l in ipairs(listeners) do
        local ok, err = pcall(l.fn, x, y, z)
        if not ok and not l.failed then
            l.failed = true
            game.log("tiamat_weather: a lightning listener failed: " .. tostring(err))
        end
    end
end

-- One bolt at column (x, z), from the square's storm. `top` is the ground
-- there as `surface_at` answered it: nil to look it up here, false when the
-- caller already looked and found nothing, in which case the flash goes
-- where it always went — STRIKE_ABOVE over the player — and touches nothing.
-- `rng` carries on the caller's stream, so the odds below stay on the one
-- deterministic draw per strike.
local function bolt(square, tick, x, z, rng, top)
    local rep = square.rep
    local up = mega_of(square)
    if top == nil then
        top = game.surface_at{ x = x, z = z, from = math.floor(rep.y) + STRIKE_SCAN_ABOVE, depth = STRIKE_SCAN }
    end
    local at
    if top then
        at = { x = x, y = top.y + 1, z = z }
        M.stats.strikes_grounded = M.stats.strikes_grounded + 1
    else
        at = { x = x, y = math.floor(rep.y) + config.STRIKE_ABOVE, z = z }
    end
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
    local far = math.max(math.abs(x - math.floor(rep.x)), math.abs(z - math.floor(rep.z)))
    pending[#pending + 1] = { at = at, when = tick + far // BLOCKS_PER_TICK,
        gain = 0.5 + square.intensity / 2000 + 0.5 * up }
    if top then
        game.emit_particles{
            pos = { x = x + 0.5, y = top.y + 1.2, z = z + 0.5 },
            count = SPARKS.count,
            colour = SPARKS.colour,
            size = SPARKS.size,
            lifetime = SPARKS.lifetime,
            velocity = { y = SPARKS.rise },
            spread = SPARKS.spread,
            gravity = SPARKS.gravity,
            collide = true,
            radius = SPARKS.seen,
        }
        -- What the bolt did to the ground it hit. Fuel may catch, on the
        -- lightning odds (fire.lua rolls no odds of its own: the caller
        -- knows what kind of spark this is). Bare turf that is not fuel may
        -- be scorched instead — only while fires are on: `scorch_mark`
        -- refuses otherwise, since a world that turned wildfires off wants
        -- its ground left alone. Neither is a fire's business to refuse
        -- loudly, so a false from either is simply a bolt that left nothing.
        local ground = { x = x, y = top.y, z = z }
        if wx.fire.enabled and wx.fire.fuel_at(ground) then
            if rng:below(math.max(1, config.FIRE_LIGHTNING_ODDS)) == 0
                and wx.fire.ignite(ground, "lightning") then
                M.stats.ignitions = M.stats.ignitions + 1
            end
        elseif top.occupancy == game.OCCUPANCY_FULL and climate.scorch[top.material] then
            if rng:below(math.max(1, config.STRIKE_SCORCH_ODDS)) == 0
                and wx.fire.scorch_mark(ground) then
                M.stats.scorches = M.stats.scorches + 1
            end
        end
    end
    -- Whoever stands beside a landed bolt burns, through Life (fire.lua's
    -- `set_alight`; false without Life). A player's body carries its owner's
    -- UUID, and Life wants the UUID for a player and the id for a creature.
    if top then
        for _, id in ipairs(game.entities_in_radius(at, config.STRIKE_ALIGHT_RADIUS)) do
            local body = game.entity(id)
            if body ~= nil and wx.fire.set_alight(body.owner or id, config.STRIKE_ALIGHT_TICKS) then
                M.stats.set_alight = M.stats.set_alight + 1
            end
        end
    end
    tell_listeners(at.x, at.y, at.z)
end

-- A storm's own strike: one in THUNDER_ODDS evaluations, and then the
-- highest ground under STRIKE_CANDIDATES columns within STRIKE_REACH of the
-- square's representative — lightning finds the tallest thing. One
-- `surface_at` a candidate, which is the whole cost of landing it.
local function strike(square, tick)
    local rng = game.rng_stream({ x = square.cx, y = tick % Y_WRAP, z = square.cz,
        seed = game.world_seed }, "wx_thunder")
    local up = mega_of(square)
    local odds = math.floor(config.THUNDER_ODDS + (config.MEGA_THUNDER_ODDS - config.THUNDER_ODDS) * up + 0.5)
    if rng:below(math.max(1, odds)) ~= 0 then
        return
    end
    local rep = square.rep
    local rx, rz = math.floor(rep.x), math.floor(rep.z)
    local from = math.floor(rep.y) + STRIKE_SCAN_ABOVE
    local best, bx, bz = nil, nil, nil
    for _ = 1, config.STRIKE_CANDIDATES do
        local x = rx + rng:below(2 * config.STRIKE_REACH + 1) - config.STRIKE_REACH
        local z = rz + rng:below(2 * config.STRIKE_REACH + 1) - config.STRIKE_REACH
        if bx == nil then
            -- The first candidate is where the bolt goes if no column answers.
            bx, bz = x, z
        end
        local top = game.surface_at{ x = x, z = z, from = from, depth = STRIKE_SCAN }
        if top and (best == nil or top.y > best.y) then
            best, bx, bz = top, x, z
        end
    end
    bolt(square, tick, bx, bz, rng, best or false)
end

-- A bolt aimed at a column, for /weather strike. `square` is the caller's:
-- any table with `rep`, `intensity` and `mega` serves, since those are all
-- the thunder's gain and the mega odds read.
function M.strike_at(x, z, square)
    x, z = math.floor(x), math.floor(z)
    local rng = game.rng_stream({ x = x, y = wx.now % Y_WRAP, z = z, seed = game.world_seed }, "wx_thunder")
    bolt(square, wx.now, x, z, rng, nil)
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

-- ------------------------------------------------------------ fire, seen and heard

-- fire.lua keeps the state; what a blaze looks and sounds like is decided
-- here, from its events and from `wx.fire.blazes()` once a turn. One crackle
-- loop per blaze, at the middle of what it has burnt, its gain following how
-- much is alight (a running loop MOVES, so nudging it every turn is one
-- message and no restart); smoke rising from the top of it, leaning with
-- the wind; embers falling back; and a hiss when rain puts a block out, at
-- most one a blaze a turn so a downpour is not a hundred hisses at once.
--
-- The loop id is `fire_<id>`: an id holding a `:` is read as a namespace
-- and refused (plan 10).
local FIRE_HEARD = 48                -- blocks a blaze's crackle carries
local FIRE_GAIN_LOW = 0.3            -- one block alight
local FIRE_GAIN_FULL_AT = 24         -- this many alight is as loud as it gets
local FIRE_LOOP_FADE = 40            -- ticks a nudge of the loop takes
local FIRE_LOOP_OUT = 60             -- ticks the crackle takes to die with the blaze
local DOUSE = { heard = 24, gain = 0.6 }
local SMOKE = { colour = { r = 0.25, g = 0.24, b = 0.23, a = 0.55 }, size = 1.4, lifetime = 7,
    rise = 1.4, lean = 0.8, spread = 0.5, gravity = -0.25, seen = 128 }
local EMBERS = { colour = { r = 1, g = 0.55, b = 0.15, a = 0.9 }, size = 0.1, lifetime = 1.2,
    rise = 2.5, spread = 2, gravity = 3, seen = 96 }

local function loop_id(blaze)
    return "fire_" .. blaze.id
end

-- Where a blaze is, for the ear: the middle of the box its fires have
-- reached, and the top of it for the smoke. A record straight from a
-- `blaze_start` event has no box yet and may carry its origin as
-- `ox, oy, oz` (fire.lua's own record) or `x, y, z` (a `blazes()` copy), so
-- both are read and the origin stands in for the box.
local function centre_of(blaze)
    local lo, hi = blaze.min, blaze.max
    if lo == nil or hi == nil then
        local x, y, z = blaze.ox or blaze.x, blaze.oy or blaze.y, blaze.oz or blaze.z
        return x, y, z, y + 1, 0, 0
    end
    return (lo.x + hi.x) / 2, (lo.y + hi.y) / 2, (lo.z + hi.z) / 2, hi.y + 1,
        math.max(1, (hi.x - lo.x) / 2), math.max(1, (hi.z - lo.z) / 2)
end

local function fire_loop(blaze, count)
    local cx, cy, cz = centre_of(blaze)
    game.play_loop{
        id = loop_id(blaze),
        sound = "fire",
        pos = { x = cx + 0.5, y = cy + 0.5, z = cz + 0.5 },
        radius = FIRE_HEARD,
        gain = FIRE_GAIN_LOW + (1 - FIRE_GAIN_LOW) * math.min(1, count / FIRE_GAIN_FULL_AT),
        fade_ticks = FIRE_LOOP_FADE,
    }
    M.stats.fire_loops = M.stats.fire_loops + 1
end

-- Smoke and embers over one blaze, from what it holds this turn.
local function fire_seen(blaze, tick)
    local cx, _, cz, top, half_x, half_z = centre_of(blaze)
    local count = blaze.count or 0
    local wind = climate.wind(cx, cz, tick)
    local pos = { x = cx + 0.5, y = top + 0.5, z = cz + 0.5 }
    local area = { x = half_x, y = 1, z = half_z }
    game.emit_particles{
        pos = pos,
        count = math.min(32, 6 + count),
        colour = SMOKE.colour,
        size = SMOKE.size,
        lifetime = SMOKE.lifetime,
        velocity = { x = wind.x * SMOKE.lean, y = SMOKE.rise, z = wind.z * SMOKE.lean },
        spread = SMOKE.spread,
        area = area,
        gravity = SMOKE.gravity,
        collide = false,
        radius = SMOKE.seen,
    }
    M.stats.smoke = M.stats.smoke + 1
    game.emit_particles{
        pos = pos,
        count = math.min(16, 2 + count // 3),
        colour = EMBERS.colour,
        size = EMBERS.size,
        lifetime = EMBERS.lifetime,
        velocity = { y = EMBERS.rise },
        spread = EMBERS.spread,
        area = area,
        gravity = EMBERS.gravity,
        collide = true,
        radius = EMBERS.seen,
    }
end

local last_douse = {}            -- blaze id -> the tick its last hiss played

wx.fire.on_change(function(event)
    local blaze = event.blaze
    if event.kind == "blaze_start" then
        fire_loop(blaze, 1)
    elseif event.kind == "blaze_end" then
        game.stop_loop{ id = loop_id(blaze), fade_ticks = FIRE_LOOP_OUT }
        last_douse[blaze.id] = nil
    elseif event.kind == "doused" and blaze and last_douse[blaze.id] ~= wx.now then
        last_douse[blaze.id] = wx.now
        local p = event.pos
        game.play_sound{ sound = "douse", pos = { x = p.x + 0.5, y = p.y + 0.5, z = p.z + 0.5 },
            radius = DOUSE.heard, gain = DOUSE.gain }
    end
end)

-- Every FIRE_TURN_TICKS, on fire.lua's own cadence, while anything is alight.
local since_fire_turn = 0
local function fires_seen(dt_ticks)
    since_fire_turn = since_fire_turn + dt_ticks
    if since_fire_turn < config.FIRE_TURN_TICKS then
        return
    end
    since_fire_turn = 0
    if wx.fire.count() == 0 then
        return
    end
    for _, blaze in ipairs(wx.fire.blazes()) do
        fire_loop(blaze, blaze.count or 0)
        fire_seen(blaze, wx.now)
    end
end

-- A player who joins is not told about running loops: start every blaze's
-- again. The same sound under the same id is a MOVE for everybody already
-- hearing it, so nobody else's crackle restarts.
wx.on_join(function()
    for _, blaze in ipairs(wx.fire.blazes()) do
        fire_loop(blaze, blaze.count or 0)
    end
end)

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
-- Lifted where the ground stands high (the climate's `cloud_lift`, by
-- biome on the Spindle): the Crown's mountains stand up to 0.9 km over the
-- dome, and a floor CLOUD_ABOVE over the dome sat mid-mountain there. Still
-- stepped, and still a floor a player can climb above on the highest peaks.
local function floor_at(x, y, z)
    local ground = climate.surface_y(x, z) + climate.cloud_lift(x, y, z)
    local step = config.CLOUD_BASE_STEP
    return (math.floor(ground + config.CLOUD_ABOVE) // step) * step
end
M.floor_at = floor_at

if HAS_CLOUDS then
    game.register_clouds{
        base = floor_at(0, 0, 0),
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

-- The sky over each kind: how much of it each GENUS covers, and how grey.
-- Four genera since engine d587fb6 (ask W13, 2026-09-23), a share each:
-- `cover` is cumulus, the heaps; `strato` a low sheet of rolls with grooves
-- of sky between; `alto` a mid-level mackerel layer; `nimbus` towers under
-- anvils, supercells at 1. Plan 10.10: clear is a few cumulus and some
-- altocumulus; cloudy all three low and mid genera; rain and snow a thick
-- stratocumulus sheet; a storm and a blizzard stratocumulus under
-- cumulonimbus; a mega storm cumulonimbus 1. A precipitating kind eases from
-- the cloudy sky to its own as its intensity rises, so the sheet closes and
-- the towers rise as the rain arrives. The supercell sky costs the client
-- about three cumulus decks (the engine's own figure), which is why only a
-- mega storm asks for it.
M.CLOUDS = {
    clear     = { cover = 0.15, strato = 0.00, alto = 0.25, nimbus = 0.00, darkness = 0.0 },
    cloudy    = { cover = 0.55, strato = 0.40, alto = 0.30, nimbus = 0.00, darkness = 0.05 },
    rain      = { cover = 0.30, strato = 0.85, alto = 0.10, nimbus = 0.00, darkness = 0.45 },
    storm     = { cover = 0.40, strato = 0.70, alto = 0.00, nimbus = 0.60, darkness = 0.90 },
    snow      = { cover = 0.30, strato = 0.85, alto = 0.10, nimbus = 0.00, darkness = 0.25 },
    blizzard  = { cover = 0.40, strato = 0.70, alto = 0.00, nimbus = 0.50, darkness = 0.50 },
    ash       = { cover = 0.30, strato = 0.70, alto = 0.00, nimbus = 0.00, darkness = 0.70 },
    ash_storm = { cover = 0.40, strato = 0.80, alto = 0.00, nimbus = 0.50, darkness = 1.00 },
    dust      = { cover = 0.20, strato = 0.00, alto = 0.20, nimbus = 0.00, darkness = 0.20 },
}
local GENERA = { "cover", "strato", "alto", "nimbus", "darkness" }
-- The engine's spelling of the three new ones.
local GENUS_FIELD = { strato = "stratocumulus", alto = "altocumulus", nimbus = "cumulonimbus" }

-- What each player was last sent, for /weather clouds.
M.clouds_sent = {}

-- The sky over one kind of weather: a table of the five shares, 0 to 1.
local function sky_of(kind, intensity, mega)
    local row = M.CLOUDS[kind] or M.CLOUDS.clear
    local sky = {}
    local k = controller.KINDS[kind]
    if k and k.precip then
        local far = intensity / 1000
        local from = M.CLOUDS.cloudy
        for _, g in ipairs(GENERA) do
            sky[g] = from[g] + (row[g] - from[g]) * far
        end
    else
        for _, g in ipairs(GENERA) do
            sky[g] = row[g]
        end
    end
    -- A mega storm is the supercell sky, black to the base: cumulonimbus and
    -- darkness both go to 1. The cumulus and the sheet are left as the kind
    -- had them, since a supercell over a full cumulus deck would be the two
    -- costliest genera at once for nothing the eye could tell apart.
    local up = (mega or 0) / 1000
    sky.nimbus = sky.nimbus + (1 - sky.nimbus) * up
    sky.darkness = sky.darkness + (1 - sky.darkness) * up
    return sky
end
M.sky_of = sky_of

-- **The cover map** (engine `set_clouds{ map }`, ask W10, 8929ca1): the
-- weather over the squares around a player, so a storm over the next valley
-- is seen from the clear one and a front can be watched coming. One cell per
-- SQUARE, the resolution the weather itself has. A square somebody is in
-- answers with its eased state, so the cell overhead is the sky overhead;
-- one nobody is in is asked of the weather function at its centre, over its
-- own ground height, and kept a while, since the fronts move slowly and
-- every player near it shares the answer.
local HAS_MAP = true
local map_cells, map_kept = {}, 0

-- **Every cell is eased, and all of them the same way.** Inside the grid
-- the client draws a cell's shares in place of the player's own, and it
-- applies a new map at once: so the easing the player's square does for the
-- rain and the sky never reached the clouds overhead, and a cell that
-- answered its square's eased state beside cells answering the weather
-- function's own value drew a lighter box round the player for the forty
-- seconds a front took to arrive. Now each cell keeps a TARGET (its square's
-- target where somebody is standing, refreshed every evaluation for
-- nothing; the function's answer where nobody is, asked again every
-- CLOUD_MAP_TICKS) and an EASED value that moves CLOUD_MAP_EASE of the way
-- toward it per evaluation, the pace the square's own intensity moves. The
-- map is re-sent while anything moves, so the client's snap is a step of a
-- twentieth. A cell not visited for a while snaps to its target rather than
-- easing from a stale value, and a cell first seen starts at its target: a
-- newcomer's sky is there at once. The seam between two cells whose weather
-- differs is the engine's (ask W18): the map is read nearest-cell.
local GENUS_KEYS = { "cover", "darkness", "strato", "alto", "nimbus" }
local STALE_EVALS = 4

local function towards(from, to, by)
    if from < to then
        return math.min(to, from + by)
    end
    return math.max(to, from - by)
end

local function cell_sky(cx, cz, tick)
    local key = controller.key_of(cx, cz)
    local square = controller.squares[key]
    local c = map_cells[key]
    local target = nil
    if square and square.kind and square.members and #square.members > 0 and square.target then
        target = sky_of(square.target, square.target_intensity, square.target_mega)
    elseif c == nil or tick - c.tick >= config.CLOUD_MAP_TICKS then
        local x, z = controller.centre_of(cx, cz)
        local kind, intensity, mega = controller.weather(x, climate.surface_y(x, z) + 1, z, tick, nil)
        target = sky_of(kind, intensity, mega)
    end
    if c == nil then
        if map_kept > 8192 then
            map_cells, map_kept = {}, 0
        end
        map_kept = map_kept + 1
        local eased = {}
        for _, g in ipairs(GENUS_KEYS) do
            eased[g] = target[g]
        end
        c = { tick = tick, stepped = tick, target = target, eased = eased }
        map_cells[key] = c
        return eased
    end
    if target ~= nil then
        c.target, c.tick = target, tick
    end
    if tick - c.stepped >= config.EVAL_TICKS then
        local by = config.CLOUD_MAP_EASE
        if tick - c.stepped > STALE_EVALS * config.EVAL_TICKS then
            by = 1.0
        end
        c.stepped = tick
        for _, g in ipairs(GENUS_KEYS) do
            c.eased[g] = towards(c.eased[g], c.target[g], by)
        end
    end
    return c.eased
end

-- A cell with towers over it: what /weather clouds counts as stormy. A quarter
-- is a storm about forty percent eased in, or a blizzard at half strength.
local STORMY_TOWERS = 0.25

-- An engine older than W16 (before aa7ab21) takes a map of cover and
-- darkness alone; the first refusal drops the three arrays, once and for good.
local HAS_MAP_GENERA = true

local function byte_of(share)
    return string.char(math.floor(share * 255 + 0.5))
end

-- The map around a square, and a key that changes when any byte of it does.
-- **Five shares a cell since W16** (engine aa7ab21, protocol v74): the
-- genera ride beside the cover and the darkness, so a storm over the next
-- valley has its anvil and a front is watched coming as the front it is.
-- Inside the grid the cell's shares replace the player's own, so the cell
-- overhead is exactly the sky `clouds_for` sends.
local function map_around(square, tick)
    local size = config.CLOUD_MAP_SIZE
    local half = size // 2
    local covers, darks, stratos, altos, nimbi, bytes = {}, {}, {}, {}, {}, {}
    local storms = 0
    for j = 0, size - 1 do
        for i = 0, size - 1 do
            local sky = cell_sky(square.cx - half + i, square.cz - half + j, tick)
            local n = #covers + 1
            covers[n], darks[n] = sky.cover, sky.darkness
            stratos[n], altos[n], nimbi[n] = sky.strato, sky.alto, sky.nimbus
            bytes[n] = byte_of(sky.cover) .. byte_of(sky.darkness) .. byte_of(sky.strato) .. byte_of(sky.alto) .. byte_of(sky.nimbus)
            if sky.nimbus >= STORMY_TOWERS then
                storms = storms + 1
            end
        end
    end
    local x0, z0 = controller.centre_of(square.cx - half, square.cz - half)
    local map = {
        origin = { x = x0 - config.SQUARE // 2, z = z0 - config.SQUARE // 2 },
        cell = config.SQUARE,
        size = size,
        cover = covers,
        darkness = darks,
    }
    if HAS_MAP_GENERA then
        map.stratocumulus, map.altocumulus, map.cumulonimbus = stratos, altos, nimbi
    end
    return map, square.cx .. ":" .. square.cz .. ":" .. table.concat(bytes), storms
end

-- An engine older than the genera (before d587fb6) refuses the three
-- fields as misspellings; the first refusal turns them off, as the map's.
local HAS_GENERA = true

-- Further than this many steps of the floor is a journey, not a walk.
local BASE_SNAP_STEPS = 8

local function clouds_for(uuid, where, square, was)
    local sky = sky_of(square.kind, square.intensity, square.mega)
    -- The floor moves a step an evaluation toward where it should be, since
    -- the client applies `base` as it arrives: at the alpine border the deck
    -- climbs its lift over ten seconds rather than jumping it. A player who
    -- has gone far (a teleport, the rim from the axis) gets the floor there
    -- at once, because a deck sinking for a minute after a /tp is worse than
    -- a jump nobody saw the start of.
    local target = floor_at(where.x, where.y, where.z)
    local step = config.CLOUD_BASE_STEP
    local base = was.base or target
    if math.abs(target - base) > BASE_SNAP_STEPS * step then
        base = target
    elseif base < target then
        base = math.min(target, base + step)
    elseif base > target then
        base = math.max(target, base - step)
    end
    was.base = base
    local map, map_key, storms
    if HAS_MAP then
        map, map_key, storms = map_around(square, wx.now)
    end
    local key = string.format("%.2f:%.2f:%.2f:%.2f:%.2f:%d:%s", sky.cover, sky.darkness,
        sky.strato, sky.alto, sky.nimbus, base, map_key or "")
    if was.clouds == key then
        return
    end
    -- A player's first sky is there at once: easing it in from nothing would
    -- show a newcomer a clear sky for the first half minute. Only a change of
    -- weather is eased.
    local first = was.clouds == nil
    was.clouds = key
    local spec = {
        cover = sky.cover,
        darkness = sky.darkness,
        base = base,
        map = map,
        ease_ticks = first and 0 or config.CLOUD_EASE_TICKS,
    }
    if HAS_GENERA then
        for short, field in pairs(GENUS_FIELD) do
            spec[field] = sky[short]
        end
    end
    -- An engine older than the map or the genera refuses the field; send
    -- without it, once and for good, newest field first: the map's genera
    -- (W16), then the player's (W13), then the map itself (W10).
    local ok, err = pcall(game.set_clouds, uuid, spec)
    if not ok and map ~= nil and HAS_MAP_GENERA then
        HAS_MAP_GENERA = false
        game.log("tiamat_weather: this engine takes no genera in the cloud map, so a distant storm has no anvil: " .. tostring(err))
        map.stratocumulus, map.altocumulus, map.cumulonimbus = nil, nil, nil
        ok, err = pcall(game.set_clouds, uuid, spec)
    end
    if not ok and HAS_GENERA then
        HAS_GENERA = false
        game.log("tiamat_weather: this engine takes no cloud genera, so the sky is cumulus alone: " .. tostring(err))
        for _, field in pairs(GENUS_FIELD) do
            spec[field] = nil
        end
        ok, err = pcall(game.set_clouds, uuid, spec)
    end
    if not ok then
        if map == nil then
            error(err, 0)
        end
        HAS_MAP = false
        game.log("tiamat_weather: this engine takes no cloud map, so storms are not seen at a distance: " .. tostring(err))
        spec.map = nil
        game.set_clouds(uuid, spec)
    end
    M.clouds_sent[uuid] = { cover = sky.cover, darkness = sky.darkness, base = base,
        stratocumulus = HAS_GENERA and sky.strato or nil, altocumulus = HAS_GENERA and sky.alto or nil,
        cumulonimbus = HAS_GENERA and sky.nimbus or nil, storms = HAS_MAP and storms or nil }
    M.stats.clouds = M.stats.clouds + 1
end

-- ------------------------------------------------------------ the tick

-- How much of the sky a player's head is under, 0 to 15: the sun there, and
-- 15 under a canopy. Leaves dim the sun (engine 41ce033), so under a forest
-- the sun alone reads like a cave mouth's and a storm would half go quiet;
-- the topmost thing over the player being leaves is what tells a forest from
-- an overhang. No sun at all is underground whatever is overhead, so a cave
-- under a wood is still a refuge.
local function exposure_at(head)
    local sun = math.max(0, math.min(15, game.get_light(head).sun))
    if sun == 0 or sun == 15 or next(climate.canopy) == nil then
        return sun
    end
    local top = game.surface_at{ x = head.x, z = head.z, from = head.y + config.CANOPY_SCAN,
        depth = config.CANOPY_SCAN, skip_passable = true }
    if top and top.y > head.y and climate.canopy[top.material] then
        M.stats.canopy = M.stats.canopy + 1
        return 15
    end
    return sun
end

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
            -- 15 is open sky or a forest; less is a cave mouth, an overhang
            -- or a doorway.
            local exposure = exposure_at(head)
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

wx.on_tick(function(dt_ticks)
    thunder(wx.now)
    fires_seen(dt_ticks)
end)

-- A player who leaves takes their settings with them; one who rejoins is on
-- the plain sky until their first evaluation.
wx.on_leave(function(uuid)
    sent[uuid] = nil
    M.clouds_sent[uuid] = nil
end)

return M
