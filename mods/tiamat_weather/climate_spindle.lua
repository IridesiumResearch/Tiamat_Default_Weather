-- SPDX-License-Identifier: MIT
--
-- The Spindle adapter: its climate, READ FROM ITS EXPORTS where it offers
-- them, and mirrored where it does not.
--
-- **The exports (engine 482958a, `game.export`).** The one channel between
-- sandboxes: the Spindle publishes a table, and this mod, which names it in
-- `optional_depends`, reads it. What this file uses, all optional:
--
--   version = 1
--   humidity          a compiled density: the humidity noise, +/-0.5
--   HUMIDITY_SPLIT    number: the wet/dry line in the humidity's units
--   climate(x, z)     number 0..1: the ring temperature T = 4t(1-t), at the dome
--   biome_under(x, y, z)   string: the biome id at a place, or nil
--   add_soil_alias(block, dry)   treat `block` as `dry` in soil, owner and growth rules
--   add_harmless_fluid(fluid)    a fluid that neither breaks leaves nor quenches lava
--
-- **The fault rules.** A function called through an export runs in the
-- Spindle's own sandbox: if it errors, the Spindle is disabled, the call
-- answers nil, and this mod carries on. So every call here treats nil (or a
-- wrong type) as "use the mirror", and a Spindle that faults mid-session
-- leaves weather on its mirrored climate rather than off. Once the Spindle is
-- disabled its functions answer nil and run nothing; a density handle it
-- exported is an opaque value this mod evaluates itself, and keeps working.
--
-- **Every constant marked MIRRORS is a copy**, used only where the export is
-- missing. They are pinned by the `< 0.2` bound in mod.toml, and checked at
-- runtime by `drift_check` (plan 3.4). Change them only together with the
-- Spindle.

local config = wx.config

local M = { name = "spindle", hud_row = config.HUD_ROW_SPINDLE }

-- The id the Spindle is installed under (climate.lua).
local SPINDLE = wx.spindle_id or "tiamat_default_world"
M.spindle_id = SPINDLE

-- One of its blocks, by name.
local function theirs(name)
    return SPINDLE .. ":" .. name
end

-- **An engine older than 482958a has no exports at all**, and calling a nil
-- field would disable this whole mod. On such an engine the mirror is the
-- only climate there is, which is what this mod was written against.
local EX = nil
if type(game.exports) == "function" then
    EX = game.exports(SPINDLE)
else
    game.log("tiamat_weather: this engine has no game.exports; using the mirrored climate")
end
if EX ~= nil and EX.version ~= 1 then
    game.log("tiamat_weather: the Spindle exports version " .. tostring(EX.version)
        .. ", not 1; using the mirrored climate")
    EX = nil
end

-- A density handle is only usable if it answers like one: calling `:at` on
-- anything else would be OUR error, and would disable this mod.
local function density_or_nil(value)
    if value == nil then
        return nil
    end
    local ok, len = pcall(function() return value:len() end)
    if ok and type(len) == "number" then
        return value
    end
    return nil
end

local function fn_or_nil(value)
    return type(value) == "function" and value or nil
end

local SPINDLE_HUMIDITY = EX and density_or_nil(EX.humidity)
local SPINDLE_CLIMATE = EX and fn_or_nil(EX.climate)
local SPINDLE_BIOME = EX and fn_or_nil(EX.biome_under)
local SPINDLE_DOME = EX and fn_or_nil(EX.dome_y)

-- What this adapter is reading, for /weather and the log.
M.sources = {
    humidity = SPINDLE_HUMIDITY and "exported" or "mirrored",
    warmth = SPINDLE_CLIMATE and "exported" or "mirrored",
    biome = SPINDLE_BIOME and "exported" or "ground",
    dome = SPINDLE_DOME and "exported" or "mirrored",
}

-- ------------------------------------------------------------ moisture

-- MIRRORS tiamat_default_world 0.1.0 shape.lua: M.humidity()
-- HUMIDITY_FREQ = 1/9000, HUMIDITY_OCTAVES = 2, HUMIDITY_STRETCH = { y = 1000 },
-- NOISE_RANGE = 0.5, amplitude 1.0. A noise node's stream is hashed from its
-- NAME alone, so this program is the Spindle's field, bit for bit.
local HUMIDITY = game.density{
    op = "clamp", low = -0.5, high = 0.5,
    a = { op = "noise", stream = "humidity", frequency = 1 / 9000, octaves = 2,
          amplitude = 1.0, stretch = { y = 1000 } },
}
-- MIRRORS shape.lua: HUMIDITY_SPLIT, the wet/dry line in the humidity's units.
M.HUMIDITY_SPLIT = -0.05
if EX and type(EX.HUMIDITY_SPLIT) == "number" then
    M.HUMIDITY_SPLIT = EX.HUMIDITY_SPLIT
end
-- The mirror stays compiled even when the export is in use: comparing the
-- two IS the drift check now, and it needs no loaded ground (below).
local MIRROR_HUMIDITY = HUMIDITY
if SPINDLE_HUMIDITY then
    HUMIDITY = SPINDLE_HUMIDITY
end

-- MIRRORS shape.lua: R_DISC = 59 km, u = r^2 / R^2 in the Spindle's spelling.
local INV_R2 = 1e-6 / (59.0 * 59.0)
-- MIRRORS shape.lua: VERDANT_U, GLASS_U.
local VERDANT_U = { 0.48 * 0.48, 0.60 * 0.60 }
local GLASS_U = { 0.42 * 0.42, 0.48 * 0.48 }
local BELT_RAMP_U = 0.008
local VERDANT_WET = 0.12        -- this mod's own: the rain belt is wetter than its noise
local GLASS_DRY = 0.15          -- and the glass waste drier

local function u_of(x, z)
    return (x * x + z * z) * INV_R2
end

-- 1 inside [lo, hi], 0 outside, a straight ramp of `ramp` either side.
local function band(u, lo, hi, ramp)
    if u <= lo - ramp or u >= hi + ramp then return 0.0 end
    if u < lo then return (u - (lo - ramp)) / ramp end
    if u > hi then return ((hi + ramp) - u) / ramp end
    return 1.0
end

local function belt_bias(u)
    return VERDANT_WET * band(u, VERDANT_U[1], VERDANT_U[2], BELT_RAMP_U)
        - GLASS_DRY * band(u, GLASS_U[1], GLASS_U[2], BELT_RAMP_U)
end

-- The Spindle's humidity at a place, without the belts: what the drift
-- check compares against the ground.
function M.humidity(x, y, z)
    return HUMIDITY:at(x, y, z, game.world_seed)
end

function M.moisture(x, y, z)
    return M.humidity(x, y, z) + belt_bias(u_of(x, z))
end

-- ------------------------------------------------------------ warmth

-- The Spindle's climate is T = 4t(1-t) in t = r/R = sqrt(u). A mod may not
-- call sqrt (math.sqrt and ^ are platform library calls), so t is found by
-- Newton's method: a FIXED number of steps of + - * /, the same IEEE
-- operations in the same order on every machine. From 1, the error halves
-- each step until it is near the root, then squares, so 20 steps are exact
-- to the last bit for every u a player can stand at (1e-8 .. 4).
local function root(u)
    if u < 1e-8 then
        return 0.0
    end
    local g = 1.0
    for _ = 1, 20 do
        g = 0.5 * (g + u / g)
    end
    return g
end
M.root = root

-- MIRRORS shape.lua: Y0 = 11000, SUMMIT = 19 km, DOME_DROP = 2.5 km.
-- World y of the base dome: H(u) = SUMMIT - u * (2*DROP - DROP*u), km -> blocks.
local function dome_y(u)
    return 11000 + (19.0 - u * (5.0 - 2.5 * u)) * 1000
end

-- The mirrored ring temperature, 0..1: what the Spindle exports as `climate`.
local function mirrored_climate(x, z)
    local t = root(u_of(x, z))
    if t > 1.0 then
        t = 1.0
    end
    return 4.0 * t * (1.0 - t)
end

-- The ground the clouds float over: the base dome's world y under (x, z).
-- The Spindle's own `dome_y` export where it offers one, the mirror where not.
function M.surface_y(x, z)
    local y = SPINDLE_DOME and SPINDLE_DOME(x, z)
    if type(y) == "number" and y == y then
        return y
    end
    return dome_y(u_of(x, z))
end

function M.warmth(x, y, z)
    local u = u_of(x, z)
    local w = SPINDLE_CLIMATE and SPINDLE_CLIMATE(x, z)
    if type(w) ~= "number" or w ~= w then
        -- Not exported, or the Spindle faulted (nil), or nonsense: the mirror.
        w = mirrored_climate(x, z)
    end
    local lapse = (y - dome_y(u)) / config.CLIMATE_LAPSE
    local value = math.floor(1000 * w - config.BAND * lapse)
    if value < 0 then return 0 end
    if value > 1000 then return 1000 end
    return value
end

-- The cloud floor's lift over CLOUD_ABOVE, by biome. MIRRORS
-- alpine_highlands.lua RIDGE_AMP: the Crown's ridges sum to about 0.9 km over
-- the dome, and shape.lua cold_terms: Frostmoor (frozen_wastes) and Firwold
-- (taiga) cross-fade into the alpine's mountains. Elsewhere the world's
-- relief is a few hundred blocks and CLOUD_ABOVE clears it.
local CLOUD_LIFT = {
    alpine_highlands = config.CLOUD_LIFT_ALPINE,
    frozen_wastes = config.CLOUD_LIFT_FROST,
    taiga = config.CLOUD_LIFT_FROST,
}

-- Blocks the cloud floor is lifted over a place: by the Spindle's own biome
-- where it exports one, none where it does not (or before the world opens).
function M.cloud_lift(x, y, z)
    if SPINDLE_BIOME == nil or game.world_seed == nil then
        return 0
    end
    local biome = SPINDLE_BIOME(math.floor(x), math.floor(y), math.floor(z))
    if type(biome) ~= "string" then
        return 0
    end
    return CLOUD_LIFT[biome] or 0
end

-- ------------------------------------------------------------ wind

-- Rim-ward, normalised by |x| + |z| rather than a square root.
function M.wind(x, z, _tick)
    local s = math.abs(x) + math.abs(z)
    if s < 1 then
        return { x = 1.0, z = 0.0 }
    end
    return { x = x / s, z = z / s }
end

-- ------------------------------------------------------------ the ground

local function ids(names)
    local set = {}
    for _, name in ipairs(names) do
        local ok, id = pcall(game.get_block_id, theirs(name))
        if ok and id ~= nil then
            set[id] = true
        end
    end
    return set
end

-- The Ember Ridge's ground: ash falls here instead of rain.
local ASH_GROUND = ids({ "lava_rock", "pumice", "sulfur", "obsidian", "dark_sand" })
-- Loose dry ground a strong front lifts.
local DUST_GROUND = ids({ "sand", "salt" })
-- Ground that is already snow: nothing settles on it (plan 3.2). The
-- Spindle's Frozen Wastes run their own drift rule on their snow.
M.covered = ids({ "snow", "ice", "clear_ice", "permafrost" })

-- A canopy: what a player under trees has overhead. Leaves dim the sun
-- (engine 41ce033, `light_falloff`), so under them the sun at head height
-- reads like a cave mouth's; with one of these on top of the column it is a
-- forest, and the storm is still over it (fx.lua).
M.canopy = ids({ "oak_leaves", "willow_leaves", "ironwood_leaves", "kapok_leaves", "apple_leaves",
    "cherry_leaves", "birch_leaves", "mangrove_leaves", "acacia_leaves", "fir_needles", "juniper_needles",
    "redwood_needles", "apple_blossom", "cherry_blossom", "gorse" })

-- Where a puddle may be left: open ground, not canopies or plants. The
-- Spindle's leaves rule removes a leaf block ANY fluid presses on (plan 7).
M.puddle_ground = ids({ "dirt", "packed_dirt", "sand", "gravel", "stone", "mud", "dried_mud" })

-- Fluids that boil rain away rather than take it in: a meeting makes steam.
M.hot_fluids = { [theirs("lava")] = true }

M.damp = {
    [theirs("dirt")] = "tiamat_weather:damp_dirt",
    [theirs("packed_dirt")] = "tiamat_weather:damp_packed_dirt",
    [theirs("sand")] = "tiamat_weather:damp_sand",
}

-- ------------------------------------------------------------ fuel

-- What burns (plan 5.12), by material. `catch` is permille odds, against
-- FIRE_SPREAD, that a burning neighbour lights it; `burn` is how long it
-- burns, in ticks; `residue` what is left; `kind` decides the cap and the
-- radius a blaze that starts in it gets. Turf is never fuel: a burning
-- ground block would be a pit for the burn's duration. Every name goes
-- through pcall, so a Spindle that has lost one still loads with the rest.
--
-- The residues are this mod's own blocks named as STRINGS, not read from
-- wx.blocks: blocks.lua loads AFTER this file, because it needs the adapter
-- to know whether to make the damp blocks. fire.lua checks at load that
-- every residue names a registered block before it will push one.
local AIR = "engine:air"
local CHARRED = "tiamat_weather:charred_log"
local SCORCHED = "tiamat_weather:scorched_ground"

M.fuel = {}
local function fuels(kind, burn, residue, list)
    for _, entry in ipairs(list) do
        local ok, id = pcall(game.get_block_id, theirs(entry[1]))
        if ok and id ~= nil then
            M.fuel[id] = { catch = entry[2], burn = entry.burn or burn, residue = residue, kind = kind }
        end
    end
end
-- Canopies go fast and leave nothing. The wet giants (kapok, ironwood) and
-- the mangroves over water catch poorly; needles and gorse catch best, and
-- with redwood it is the needles that go, not the resinous trunk.
fuels("canopy", 300, AIR, {
    { "oak_leaves", 800 }, { "birch_leaves", 800 }, { "willow_leaves", 700 }, { "apple_leaves", 800 },
    { "cherry_leaves", 800 }, { "acacia_leaves", 800 }, { "kapok_leaves", 400 }, { "ironwood_leaves", 400 },
    { "mangrove_leaves", 300 }, { "fir_needles", 900 }, { "juniper_needles", 900 }, { "redwood_needles", 600 },
    { "apple_blossom", 800 }, { "cherry_blossom", 800 }, { "gorse", 950 },
})
-- Wood catches slowly and burns long, to a charred log. Ironwood barely
-- catches at all; a dead log is tinder and is gone sooner; planks are dry.
fuels("wood", 900, CHARRED, {
    { "oak_log", 250 }, { "birch_log", 250 }, { "fir_log", 300 }, { "willow_log", 250 }, { "kapok_log", 250 },
    { "juniper_log", 300 }, { "apple_log", 250 }, { "cherry_log", 250 }, { "mangrove_log", 200 },
    { "acacia_log", 250 }, { "redwood_log", 200 }, { "ironwood_log", 100 }, { "dead_log", 700, burn = 500 },
    { "willow_planks", 300, burn = 700 }, { "ironwood_planks", 300, burn = 700 }, { "kapok_planks", 300, burn = 700 },
})
-- Plants are a field fire: quick and wide, and they scorch the turf under
-- them (M.scorch). Dead sagebrush is the tinder of the dry half. A tuft
-- burns twelve seconds (the spec said six): in a flat meadow only eight of
-- a fire's twenty-six neighbours are tufts, and at six seconds a field fire
-- in dry, warm country lit fewer than one tuft for each that burnt, so it
-- went out after two. Twelve lets one creep to a black patch of a few dozen
-- blocks and still end short of its cap (tests/native, fire_field_check).
fuels("plant", 240, AIR, {
    { "tall_grass", 700 }, { "fern", 500 }, { "bramble", 600 }, { "heather", 800 }, { "dead_sagebrush", 950, burn = 80 },
    { "ladys_mantle", 400 }, { "ladys_mantle_bloom", 400 }, { "blue_lunaria", 300 }, { "roman_chamomile", 300 },
    { "rose_bush", 400 }, { "rose_blooms", 400 }, { "wild_mint", 300 }, { "allium", 350 }, { "peony", 350 },
    { "poppy", 350 }, { "bluebell", 350 }, { "reeds", 500 }, { "climbing_ivy", 400 }, { "monstera", 300 },
})

-- Whole ground blocks a plant fire scorches, and what each becomes.
M.scorch = {}
for id in pairs(ids({ "grass", "mulch" })) do
    M.scorch[id] = SCORCHED
end

-- Solid blocks that light what stands beside them. Still lava as a FLUID
-- has no name to look up (`get_fluid` answers volume alone), so fire.lua
-- tells it from water by its light instead.
M.hot_blocks = ids({ "magma", "lava" })

-- What scorched ground heals to.
M.bare = theirs("dirt")

-- ------------------------------------------------------------ switches the Spindle unlocks

-- Damp ground needs the Spindle to treat damp dirt as dirt (plan 7.1), and
-- puddles need its leaves rule to leave rainwater alone (plan 7.3). Each is
-- an exported function this mod CALLS at load, which is the whole Spindle
-- change: no damp id has to exist when the Spindle loads. `true` from the
-- call is the Spindle saying it took it; anything else, including nil from a
-- fault, leaves the feature off.
local function called(name, ...)
    local fn = EX and fn_or_nil(EX[name])
    return fn ~= nil and fn(...) == true
end

function M.unlock_damp()
    local all = true
    for dry, damp in pairs(M.damp) do
        all = called("add_soil_alias", damp, dry) and all
    end
    return all
end

function M.unlock_puddles()
    return called("add_harmless_fluid", "tiamat_weather:rainwater")
end

-- Scorched ground is dirt to the Spindle's rules (plan 5.12), so its grass
-- grows back over a burnt field. Called from fire.lua, once the block
-- exists; the Spindle keeps the names as strings and resolves them later.
function M.unlock_scorched()
    return called("add_soil_alias", SCORCHED, theirs("dirt"))
end

local DUST_WARMTH = 700
local GROUND_SCAN = 3

-- Biomes, by the Spindle's own ids, whose weather is not rain.
local ASH_BIOMES = { volcanic_foothills = true, obsidian_barrens = true, geyser_basin = true, cinder_coast = true }
local DUST_BIOMES = { dunes = true, salt_pan = true, arid_mesa = true, badlands = true }

-- What the place at feet (x, y, z) says about the weather: the Spindle's own
-- biome where it exports one, the ground where it does not.
function M.override(x, y, z)
    if SPINDLE_BIOME then
        local fx, fy, fz = math.floor(x), math.floor(y), math.floor(z)
        local biome = SPINDLE_BIOME(fx, fy, fz)
        if type(biome) == "string" then
            local water = game.get_fluid{ x = fx, y = fy, z = fz }
            local under = game.get_fluid{ x = fx, y = fy - 1, z = fz }
            if (water and not water.empty) or (under and not under.empty) then
                return "sea"
            end
            if ASH_BIOMES[biome] then
                return "ash"
            end
            if DUST_BIOMES[biome] and M.warmth(x, y, z) > DUST_WARMTH
                and M.moisture(x, y, z) < M.HUMIDITY_SPLIT then
                return "dust"
            end
            return nil
        end
        -- nil: the Spindle faulted or had no answer; read the ground instead.
    end
    return M.ground_override(x, y, z)
end

-- The same question answered from the ground alone: the fallback.
function M.ground_override(x, y, z)
    local fx, fy, fz = math.floor(x), math.floor(y), math.floor(z)
    local water = game.get_fluid{ x = fx, y = fy, z = fz }
    local under = game.get_fluid{ x = fx, y = fy - 1, z = fz }
    if (water and not water.empty) or (under and not under.empty) then
        return "sea"
    end
    for dy = 1, GROUND_SCAN do
        local b = game.get_block{ x = fx, y = fy - dy, z = fz }
        if b == nil then
            return nil
        end
        if b.occupancy ~= 0 then
            if ASH_GROUND[b.material] then
                return "ash"
            end
            if DUST_GROUND[b.material] and M.warmth(x, y, z) > DUST_WARMTH
                and M.moisture(x, y, z) < M.HUMIDITY_SPLIT then
                return "dust"
            end
            return nil
        end
    end
    return nil
end

-- ------------------------------------------------------------ the drift check

-- Plan 3.4. Owners from the Spindle's whereami.lua: wood that only the wet
-- half grows, and ground only the dry half lays. Dirt says nothing, since
-- both halves of the temperate ring lie on it.
local WET_OWNERS = ids({ "oak_log", "birch_log" })
local DRY_OWNERS = ids({ "packed_dirt" })
local DRIFT_STEP = 48
local DRIFT_REACH = 5            -- steps either side: an 11 x 11 grid
local DRIFT_SCAN = 40
local DRIFT_BLEND = 0.04         -- MIRRORS shape.lua HUMIDITY_BLEND: too near the split to judge

-- **Against the exported fields**, when they are there: the mirror and the
-- Spindle's own field sampled at the same points, which needs no loaded
-- ground and answers exactly. A noise stream is hashed from its NAME, so two
-- programs built the same way are the same field, and any difference means a
-- constant here is stale.
--
-- Returns agreed, disagreed, judged, and a line naming the worst gap.
local FIELD_STEP = 977              -- a prime, so the points do not land on a feature
local FIELD_POINTS = 11
local FIELD_TOLERANCE = 1e-6

function M.field_check(x, y, z)
    local agreed, disagreed = 0, 0
    local worst, worst_at = 0.0, ""
    local cx, cy, cz = math.floor(x), math.floor(y), math.floor(z)
    for i = 0, FIELD_POINTS - 1 do
        for k = 0, FIELD_POINTS - 1 do
            local px = cx + (i - FIELD_POINTS // 2) * FIELD_STEP
            local pz = cz + (k - FIELD_POINTS // 2) * FIELD_STEP
            local gap = 0.0
            if SPINDLE_HUMIDITY then
                gap = math.abs(SPINDLE_HUMIDITY:at(px, cy, pz, game.world_seed)
                    - MIRROR_HUMIDITY:at(px, cy, pz, game.world_seed))
            end
            if SPINDLE_CLIMATE then
                local theirs = SPINDLE_CLIMATE(px, pz)
                if type(theirs) == "number" then
                    local climate_gap = math.abs(theirs - mirrored_climate(px, pz))
                    if climate_gap > gap then
                        gap = climate_gap
                    end
                end
            end
            if gap > worst then
                worst, worst_at = gap, px .. "," .. pz
            end
            if gap <= FIELD_TOLERANCE then
                agreed = agreed + 1
            else
                disagreed = disagreed + 1
            end
        end
    end
    return agreed, disagreed, agreed + disagreed,
        string.format("worst gap %.9f at %s", worst, worst_at)
end

-- Whether there is anything exported to compare the mirror against.
function M.has_exported_fields()
    return SPINDLE_HUMIDITY ~= nil or SPINDLE_CLIMATE ~= nil
end

-- Samples loaded ground around (x, y, z). Returns agreed, disagreed, judged.
-- The fallback when nothing is exported: the mirror against the ground the
-- Spindle laid, which needs loaded chunks and only judges the wet/dry side.
function M.drift_check(x, y, z)
    local agreed, disagreed = 0, 0
    local cx, cy, cz = math.floor(x), math.floor(y), math.floor(z)
    for i = -DRIFT_REACH, DRIFT_REACH do
        for k = -DRIFT_REACH, DRIFT_REACH do
            local px, pz = cx + i * DRIFT_STEP, cz + k * DRIFT_STEP
            local h = M.humidity(px, cy, pz)
            if math.abs(h - M.HUMIDITY_SPLIT) > DRIFT_BLEND then
                local said = nil
                for dy = DRIFT_SCAN, -DRIFT_SCAN, -1 do
                    local b = game.get_block{ x = px, y = cy + dy, z = pz }
                    if b == nil then
                        break
                    end
                    if WET_OWNERS[b.material] then
                        said = "wet"
                        break
                    elseif DRY_OWNERS[b.material] then
                        said = "dry"
                        break
                    end
                end
                if said ~= nil then
                    local mirror = h > M.HUMIDITY_SPLIT and "wet" or "dry"
                    if said == mirror then
                        agreed = agreed + 1
                    else
                        disagreed = disagreed + 1
                    end
                end
            end
        end
    end
    return agreed, disagreed, agreed + disagreed
end

return M
