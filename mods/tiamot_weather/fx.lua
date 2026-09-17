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
-- **Clouds are still particles** (ask W2 is the one thing not built): puffs
-- of the largest particle on a grid overhead, addressed to one player. They
-- are all this file emits now, so the particle budget is theirs alone.

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
    description = "Rain, snow and clouds drawn around you. The storm's own sky is not affected.",
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
    local rate = row.rate * square.intensity // 1000
    if share == 1 then
        rate = rate // 2
    end
    local key = square.kind .. ":" .. rate
    if was.precip == key then
        return
    end
    was.precip = key
    game.set_precipitation(uuid, {
        rate = rate,
        size = row.size,
        colour = { r = row.colour[1], g = row.colour[2], b = row.colour[3], a = row.colour[4] },
        lifetime = row.life,
        velocity = { x = wind.x * row.wind, y = row.vy, z = wind.z * row.wind },
        spread = row.spread or 0,
        gravity = row.gravity,
        collide = row.collide ~= false,
        area = { x = row.area[1], y = row.area[2], z = row.area[3] },
        above = row.above,
        ease_ticks = config.EASE_TICKS,
    })
    M.stats.precipitation = M.stats.precipitation + 1
end

-- Towards the kind's sky by how far it has eased in. The particles setting
-- does not touch this: the weather's own daylight is not a particle.
local function sky_for(uuid, square, was)
    local row = M.SKY[square.kind]
    local far = square.intensity / 1000
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
    local key = string.format("%s:%d", square.kind, square.intensity)
    if was.sky == key then
        return
    end
    was.sky = key
    game.set_sky_modifier(uuid, {
        intensity = towards(1.0, row.intensity),
        sky = row.sky,
        sky_mix = towards(0.0, row.sky_mix),
        fog_distance = towards(1.0, row.fog),
        saturation = towards(1.0, row.saturation),
        ease_ticks = config.EASE_TICKS,
    })
    M.stats.sky = M.stats.sky + 1
end

-- One ambience loop per player: the gain MOVES rather than restarting, so a
-- storm can be nudged as often as it is evaluated (engine 2026-09-17).
local LOOP_SOUND = { rain = "rain", storm = "rain", blizzard = "wind", dust = "wind", ash_storm = "wind" }
local LOOP_GAIN = { rain = 0.8, storm = 1.0, blizzard = 1.0, dust = 0.9, ash_storm = 0.8 }
local LOOP_ID = "weather"

local function loop_for(uuid, square, was)
    local sound = square.intensity > 0 and LOOP_SOUND[square.kind] or nil
    if sound == nil then
        if was.loop then
            was.loop = nil
            game.stop_loop{ id = LOOP_ID, player = uuid, fade_ticks = config.EASE_TICKS }
        end
        return
    end
    -- Quarter steps: a nudge every evaluation is cheap, but the table is not.
    local step = math.max(1, (square.intensity + 125) // 250)
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
    if rng:below(config.THUNDER_ODDS) ~= 0 then
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
        gain = 0.5 + square.intensity / 2000 }
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

-- A fine noise the cloud cells are cut from, drifting with the front so the
-- sky moves the way the weather does. Its own stream, never a Spindle one.
local CLOUD_NOISE = game.density{
    op = "clamp", low = -0.5, high = 0.5,
    a = { op = "noise", stream = "wx_clouds", frequency = config.CLOUD_FREQUENCY, octaves = 2, amplitude = 1.0 },
}

-- A kind's sky, as the LINE its cloud noise must clear and how grey a puff
-- is. The line is not a fraction: the noise is a two-octave fractal, so its
-- values bunch around zero, and a line of 0.3 leaves far less than a third of
-- the sky clouded. These are read off that distribution — 0.15 is a fair-
-- weather sky with a few clouds in it, -0.05 is half cloud, -0.5 is below
-- the noise's own floor and covers everything.
local SKY_LINE = {
    clear = { 0.15, 0.97 }, cloudy = { -0.05, 0.86 }, rain = { -0.25, 0.66 }, snow = { -0.25, 0.8 },
    ash = { -0.25, 0.4 }, dust = { 0.05, 0.8 }, storm = { -0.51, 0.42 }, blizzard = { -0.51, 0.72 },
    ash_storm = { -0.51, 0.3 },
}

local CELL = config.CLOUD_CELL
local REACH = config.CLOUD_REACH
local CLOUD_LIVE_PER_CELL = config.CLOUD_COUNT * config.CLOUD_LIFE * TICKS_PER_SECOND // config.CLOUD_PERIOD
do
    local reach = REACH / CELL + 0.5
    local cells = math.floor(3.1416 * reach * reach)
    assert(cells * CLOUD_LIVE_PER_CELL <= config.CLOUD_LIVE_MAX, string.format(
        "clouds hold %d live particles, over the budget of %d", cells * CLOUD_LIVE_PER_CELL, config.CLOUD_LIVE_MAX))
    assert(REACH * REACH + config.CLOUD_ABOVE * config.CLOUD_ABOVE <= 128 * 128,
        "a cloud puff at the edge of CLOUD_REACH is past the 128-block send radius")
end

-- Whether the sky has cloud over a cell now, and how grey: nil for clear sky.
-- The same answer for every player, so two players see one sky.
function M.cloud_at(cell_x, cell_z, square, tick)
    local kind = square and square.kind or "clear"
    local intensity = square and square.intensity or 0
    local line, grey = SKY_LINE[kind][1], SKY_LINE[kind][2]
    -- A precipitating kind that has not eased in yet is only cloudy.
    if controller.KINDS[kind].precip and intensity <= 0 then
        line, grey = SKY_LINE.cloudy[1], SKY_LINE.cloudy[2]
    end
    local x, z = cell_x * CELL + CELL // 2, cell_z * CELL + CELL // 2
    local drift = tick // config.DRIFT_TICKS
    local n = CLOUD_NOISE:at(x - drift, tick / config.TICKS_PER_Y, z, game.world_seed)
    -- The noise is CLAMPED to +/-0.5 and does sit exactly on the floor in
    -- places, so a storm's line is -0.51, below the floor: every cell is
    -- cloud, with no arithmetic close enough to go either way. (A line
    -- computed as 0.45 - 0.95 * cover came out at -0.49999999999999994 and
    -- left three cells of a full storm clear.)
    if n < line then
        return nil, n, line, kind
    end
    return grey, n, line, kind
end

local function clouds(uuid, pos, own_square, share, was, tick)
    was.cells = was.cells or {}
    local cells = was.cells
    local seen = {}
    local r = REACH // CELL + 1
    local pcx, pcz = math.floor(pos.x) // CELL, math.floor(pos.z) // CELL
    -- Quantised to 16 blocks so walking up a hill does not lift the sky.
    local base = (math.floor(pos.y) + config.CLOUD_ABOVE) // 16 * 16
    for i = -r, r do
        for k = -r, r do
            local cx, cz = pcx + i, pcz + k
            local dx = (cx * CELL + CELL // 2) - pos.x
            local dz = (cz * CELL + CELL // 2) - pos.z
            if dx * dx + dz * dz <= REACH * REACH then
                local key = cx .. ":" .. cz
                seen[key] = true
                if tick >= (cells[key] or 0) then
                    -- Staggered by cell, so a sky does not pulse all at once.
                    cells[key] = tick + config.CLOUD_PERIOD - ((cx * 7 + cz * 13) % (config.CLOUD_PERIOD // 2))
                    local sx, sz = controller.square_of(cx * CELL, cz * CELL)
                    local square = controller.squares[controller.key_of(sx, sz)] or own_square
                    local grey = M.cloud_at(cx, cz, square, tick)
                    local count = share == 1 and config.CLOUD_COUNT // 2 or config.CLOUD_COUNT
                    if grey and count > 0 then
                        game.emit_particles{
                            pos = { x = cx * CELL + CELL // 2, y = base, z = cz * CELL + CELL // 2 },
                            count = count,
                            colour = { r = grey, g = grey, b = math.min(1.0, grey + 0.03), a = config.CLOUD_ALPHA },
                            size = 4.0,
                            lifetime = config.CLOUD_LIFE,
                            velocity = { x = TICKS_PER_SECOND / config.DRIFT_TICKS, y = 0, z = 0 },
                            spread = 0.05,
                            -- Packed into 28 of the cell's 40 blocks: a puff is
                            -- about as much cloud as sky.
                            area = { x = 14, y = 2, z = 14 },
                            gravity = 0,
                            collide = false,
                            radius = 128,
                            player = uuid,
                        }
                        M.stats.clouds = M.stats.clouds + 1
                    end
                end
            end
        end
    end
    for key in pairs(cells) do
        if not seen[key] then
            cells[key] = nil
        end
    end
end

-- ------------------------------------------------------------ the tick

local since_clouds = 0

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
            local under_sky = game.get_light(head).sun > 0
            if under_sky then
                precipitation_for(uuid, square, share, wind, was)
            else
                M.stats.underground = M.stats.underground + 1
                if was.precip then
                    was.precip = nil
                    game.set_precipitation(uuid, nil)
                end
            end
            sky_for(uuid, square, was)
            loop_for(uuid, square, was)
            if square.kind == "storm" and square.intensity > 0 then
                strike(square, tick)
            end
        end
    end
end)

wx.on_tick(function(dt_ticks)
    thunder(wx.now)
    since_clouds = since_clouds + dt_ticks
    if since_clouds < config.CLOUD_SCAN_TICKS or game.world_seed == nil then
        return
    end
    since_clouds = 0
    local here = {}
    for _, uuid in ipairs(controller.players()) do
        here[uuid] = true
        local pos = controller.position(uuid)
        local share = share_of(uuid)
        if pos and share > 0 then
            local was = sent[uuid]
            if was == nil then
                was = {}
                sent[uuid] = was
            end
            local sx, sz = controller.square_of(pos.x, pos.z)
            clouds(uuid, pos, controller.squares[controller.key_of(sx, sz)], share, was, wx.now)
        end
    end
    for uuid in pairs(sent) do
        if not here[uuid] then
            sent[uuid] = nil
        end
    end
end)

-- A player who leaves takes their settings with them; one who rejoins is on
-- the plain sky until their first evaluation.
wx.on_leave(function(uuid)
    sent[uuid] = nil
end)

return M
