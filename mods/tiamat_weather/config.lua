-- SPDX-FileCopyrightText: Iridesium
-- SPDX-License-Identifier: GPL-3.0-only
--
-- Switches and tunables. Every number a designer might turn is here, with
-- what it does; docs/weather-plan.md section 9 is where they came from.
--
-- Ticks are simulation ticks, twenty a second. Intensities are permille.

return {
    -- ---------------------------------------------------------- switches

    -- "auto" picks the Spindle adapter when tiamat_default_world is loaded
    -- and the plain one otherwise; "plain" forces the plain one.
    climate = "auto",
    -- Damp ground (plan 5.5). "auto" is on exactly when the Spindle exports
    -- `add_soil_alias` and takes the damp ids (plan 7.1); true or false forces.
    damp_ground = "auto",
    -- Puddles (plan 5.10): rain leaves a little `rainwater` fluid on open
    -- ground, which runs downhill, joins any other fluid it meets, and
    -- evaporates. "auto" is on exactly when the Spindle exports
    -- `add_harmless_fluid` and takes rainwater (plan 7.3): until then its
    -- leaves rule would strip a canopy rainwater pressed on.
    puddles = "auto",
    -- Who may run /weather set and /weather clear: "operators" (the server's
    -- own list, `game.is_operator`), true for everyone, or false for nobody.
    -- On an engine older than operators, "operators" lets everyone, as before.
    commands = "operators",
    -- The plain adapter's idea of where the ground is, for warmth.
    sea_level = 0,

    -- ---------------------------------------------------------- the clock

    CLOCK_SAVE_EVERY = 200,     -- ticks between writes of the clock to storage

    -- ---------------------------------------------------------- the front

    FRONT_FREQUENCY = 1 / 2400, -- inverse size of a weather system, in blocks
    FRONT_OCTAVES = 2,
    TICKS_PER_Y = 600,          -- ticks per unit of the noise's time axis
    DRIFT_TICKS = 40,           -- ticks per block the front drifts along x

    -- Thresholds on front + MOISTURE_WEIGHT * moisture, which runs about -1..1.
    -- Retuned 2026-09-25 ("it rains far too often"), by `/weather survey`
    -- over twelve places across the dome: at weight 1 and 0.10 / 0.25 rain
    -- or snow fell 41% of the year and storms 27%, and the wettest place
    -- stormed 60% of it, because the humidity field is so wide that a wet
    -- place was wet for good. Now 18% falling, 7% storm, 31% at the wettest.
    -- The weight is what keeps a wet belt wetter without making it a monsoon.
    -- CLOUDY_AT sets the clear share: the designer wants nearly cloudless
    -- skies about 60% of play time, and 0.12 is 64% (0.10 was 61%, 0.20 71%).
    MOISTURE_WEIGHT = 0.4,
    CLOUDY_AT = 0.12,
    RAIN_AT = 0.32,
    STORM_AT = 0.46,

    -- ---------------------------------------------------------- fog
    -- Morning fog (2026-09-30): on a clear or cloudy morning over wet ground,
    -- one morning in FOG_ODDS per FOG_REGION, rising from FOG_FROM, thickest
    -- at FOG_PEAK and burnt off by FOG_TO (fractions of the day: 0.25 is
    -- dawn, 0.5 noon). FOG_MOISTURE is on the climate's moisture, about
    -- -0.5..0.5; the Spindle's wet/dry line is -0.05.
    FOG_FROM = 0.19,
    FOG_PEAK = 0.26,
    FOG_TO = 0.36,
    FOG_MOISTURE = 0.0,
    FOG_ODDS = 3,
    FOG_REGION = 1024,          -- blocks on a side of the lattice a foggy morning is rolled on

    -- ---------------------------------------------------------- rainbows
    -- After rain, by day, one rain in RAINBOW_ODDS leaves a rainbow over the
    -- square for RAINBOW_TICKS, rising over RAINBOW_RISE_TICKS and fading
    -- out. Drawn by the engine (engine 143ed0f, ask W30), which decides where it stands from
    -- the sun and hides it when the sun is too high for one.
    RAINBOW_ODDS = 2,
    RAINBOW_TICKS = 2400,
    RAINBOW_RISE_TICKS = 200,
    RAINBOW_DAY_FROM = 0.27,    -- the sun is up from here...
    RAINBOW_DAY_TO = 0.73,      -- ...to here

    -- ---------------------------------------------------------- mega storms
    -- Everything a storm does, turned up to 11, about twice a year at any
    -- one place. One per MEGA_REGION in each half of an in-game year, at a
    -- hashed time and place, drifting with the fronts. Its disc covers about
    -- its region's area, so a place is under about two a year, some of them
    -- at full strength and some at the edge.
    DAY_TICKS = 24000,          -- the engine's default day (game/core_sky)
    DAYS_PER_YEAR = 365,
    MEGA_PER_YEAR = 2,
    MEGA_REGION = 4096,         -- blocks on a side of the lattice a mega storm is rolled on
    MEGA_RADIUS = 2300,         -- its disc: pi * r^2 is about one region
    MEGA_CORE = 0.8,            -- full strength inside this share of the radius
    MEGA_TICKS = 12000,         -- half a day, building for the first and dying for the last
    MEGA_RISE_TICKS = 2400,
    MEGA_FALL_TICKS = 3000,
    MEGA_LABEL_AT = 500,        -- the HUD says "Mega ..." from here (permille)
    -- A strong front alone makes dust over dry sand (the "dust" override).
    DUST_AT = 0.20,

    -- ---------------------------------------------------------- climate

    FREEZE = 300,               -- warmth below this is freezing (0..1000)
    CLIMATE_LAPSE = 3000,       -- blocks above the dome per BAND of warmth lost
    BAND = 250,

    -- ---------------------------------------------------------- evaluation

    EVAL_TICKS = 40,            -- ticks between evaluations of each occupied square
    SQUARE = 256,               -- blocks on a side of an evaluated square
    EASE = 50,                  -- permille the applied intensity moves per evaluation
    FORGET_SQUARE_TICKS = 2400, -- an empty square's eased state is forgotten after this

    -- ---------------------------------------------------------- presentation

    EASE_TICKS = 80,            -- how long a client takes to ease rain, sky and loops in
    STRIKE_REACH = 96,          -- blocks from the player a bolt may strike
    STRIKE_ABOVE = 40,          -- blocks over the player a bolt is centred when no ground is found under it
    STRIKE_SEEN = 512,          -- blocks the flash is seen from
    STRIKE_HEARD = 400,         -- blocks the thunder is heard from
    -- The cloud deck (register_clouds), shaped after docs/reference/.
    CLOUD_ABOVE = 500,          -- blocks over the ground the cloud floor sits (400 until 2026-09-25: "a bit too low", up a quarter)
    CLOUD_BASE_STEP = 64,       -- the floor moves in steps of this, so walking does not nudge the sky
    -- 180 since 2026-09-25 ("a bit too laggy, cut some corners"): the steps
    -- a ray takes through the deck scale with it, and 140 measured a tenth
    -- off (plan 10.19). 160 until 2026-09-23, 200 until today.
    CLOUD_THICKNESS = 180,      -- blocks from the floor to the tallest tower's top
    -- Coarse on purpose (2026-09-18): 8-block cubes cost a frame at the
    -- horizon for detail nobody could see. 16 halves the steps a ray takes.
    -- Since engine 0d8e857 the deck is heaps: FREQUENCY spaces them (a heap
    -- every 0.42 / FREQUENCY blocks), THICKNESS sets how tall they grow, and
    -- OCTAVES no longer shapes anything. 24 since 2026-09-23 (plan 10.19):
    -- the heaps have grown 1.7 times since 16 was chosen, so 24 keeps the
    -- cubes-per-cloud 16 gave, and it is a seventh off the deck's cost on
    -- every view measured; 32 would be a quarter off and reads as blocks.
    -- 32 since 2026-09-25, the lag again: a quarter off 16's cost where 24
    -- was a seventh (plan 10.19), so about an eighth off 24's, and blockier.
    CLOUD_CELL = 32,            -- blocks per cube
    CLOUD_DETAIL = 2,           -- small cubes per cube edge on the surface
    -- Heaps sit on a lattice 0.42 / FREQUENCY blocks apart, each with a
    -- RADIUS of 0.30 to 0.68 of that spacing (the engine's curve, by the
    -- heap's own strength), so this is their size as much as their spacing:
    -- 1/500 was heaps 125 to 285 blocks across, 210 apart; 1/680 was 170 to
    -- 390 across, 285 apart; 1/850 is 215 to 485 across, 357 apart. The
    -- sheet's cells and the mackerel layer's cloudlets scale with it too.
    -- Raised twice on 2026-09-23: "a little bigger", then "the average cloud
    -- about 25% bigger and the big clouds about 75%" — the second quarter is
    -- this number, and the rest of the big ones' growth is the engine's
    -- curve (ask W20), since one number scales every heap alike.
    CLOUD_FREQUENCY = 1 / 850,  -- the field's horizontal scale, cycles per block
    CLOUD_OCTAVES = 2,
    CLOUD_TOWERS = 0.2,         -- how much taller the highest heaps grow
    CLOUD_EVOLVE = 1 / 2400,    -- how fast the shape changes, per second
    CLOUD_EASE_TICKS = 600,     -- how long a change of cover takes on the client
    CLOUD_MAP_SIZE = 16,        -- the cover map around a player, in squares a side (engine max 16)
    CLOUD_MAP_TICKS = 400,      -- how stale a square nobody is in may be before its weather is asked again
    -- The floor stands higher where the ground does. The Spindle's Crown has
    -- mountains up to 0.9 km over the dome (climate_spindle.lua, MIRRORS), and
    -- a floor CLOUD_ABOVE over the dome sat mid-mountain there. Lifted by
    -- biome, so a player still climbs above the deck on the highest peaks.
    CLOUD_LIFT_ALPINE = 400,    -- blocks, over CLOUD_ABOVE, in the alpine highlands (320 until 2026-09-25, up a quarter with the floor)
    CLOUD_LIFT_FROST = 200,     -- and in the frost ring beside them, whose terrain fades into the alpine's (160 until 2026-09-25)
    CANOPY_SCAN = 48,           -- blocks over a player's head a canopy is looked for
    -- One in this many storm evaluations (EVAL_TICKS apart) strikes: about
    -- one bolt every eight seconds in a storm. 12 until 2026-09-25, one every
    -- twenty-four, and "lightning is too rare".
    THUNDER_ODDS = 4,
    MEGA_THUNDER_ODDS = 2,      -- and in a mega storm at full strength

    -- ---------------------------------------------------------- the ground

    QUEUE_EVERY = 2,            -- ticks between batches landing, and between samples
    BATCH_CHUNKS = 2,           -- chunks one batch may touch
    MAX_WAITING = 4,            -- batches held; the sampler asks for room before working
    BACKOFF_TICKS = 40,         -- after the engine refuses an edit, wait this long
    COLUMNS_PER_BATCH = 6,      -- columns sampled per batch, all in one chunk footprint
    SAMPLE_RADIUS = 40,         -- blocks from a player a sampled footprint's centre may be
    SCAN_ABOVE = 24,            -- blocks above the player's feet the surface scan starts
    SCAN = 48,                  -- reads the surface scan may spend on a column
    SNOW_LAYERS = 2,            -- the cap on a snow_layer in SNOW
    BLIZZARD_LAYERS = 3,        -- the cap in a BLIZZARD: one whole block, never more
    DRY_AFTER_TICKS = 1200,     -- damp ground near a player dries this long after the rain
    THAW_MEMORY_TICKS = 72000,  -- a square that snowed within this still gets near-player thaw samples
    -- Puddles, retuned 2026-09-25 ("rain creates way too many water
    -- sources"): fewer and smaller. They dry by the fluid's own `evaporates`,
    -- which since engine 1c475a8 (ask W24) keeps a settled puddle open to the
    -- air on the solver's books until it is gone; before that a settled
    -- puddle was rolled once and then never again, and lay there for good.
    PUDDLE_ONE_IN = 32,         -- one sampled column in this many gets rainwater: puddles, not a film
    PUDDLE_CELLS = 3,           -- cells of rainwater a sampled column gets in RAIN
    STORM_PUDDLE_CELLS = 4,     -- and in a STORM
    MEGA_PUDDLE_CELLS = 8,      -- and in a mega storm
    RAIN_EVAPORATES = 100,      -- one cell in this many fluid ticks (10 Hz): a puddle open to the air is gone in about a minute

    -- ---------------------------------------------------------- fire
    -- Plan 5.12. "Not out of control" is the first requirement, so every
    -- number below is a cap before it is a flavour.

    -- "auto": on unless the world option tiamat_weather:fires is off;
    -- true/false forces. A WORLD option, never a player setting: a fire is
    -- world state, and a world whose fires depended on who was logged in
    -- would disagree with itself.
    fires = "auto",
    FIRE_TURN_TICKS = 10,        -- ticks between turns of every burning block (half a second)
    FIRE_MAX_BLAZES = 4,         -- blazes alight at once, world-wide
    FIRE_MAX_BURNING = 120,      -- burning blocks at once, world-wide; nothing lights past it
    FIRE_FOREST_BLOCKS = 60,     -- blocks one forest blaze may light in its life
    FIRE_FOREST_RADIUS = 12,     -- and how far (horizontally) from where it started
    FIRE_FIELD_BLOCKS = 90,      -- a field fire spreads wider and leaves less
    FIRE_FIELD_RADIUS = 16,
    FIRE_BLAZE_TICKS = 3600,     -- a blaze spreads for at most three minutes, then only burns down
    FIRE_SPREAD = 500,           -- permille: base odds per turn that a burning block lights a neighbour
    FIRE_DOUSE = 600,            -- permille per turn, at full rain, that a fire under the sky goes out
    FIRE_EXPOSED_SUN = 8,        -- sun at the fire at least this and the rain reaches it (a canopy dims it a little, a roof to 0)
    FIRE_REST_TICKS = 24000,     -- a square that had a blaze starts no NATURAL one for this long (a game day)
    FIRE_APART = 48,             -- a natural blaze starts no nearer than this to a live one's origin
    FIRE_LIGHTNING_ODDS = 3,     -- one strike in this many that lands on fuel lights it
    FIRE_LAVA_ODDS = 6,          -- one sampled hot surface in this many lights the fuel beside it
    FIRE_FLOW_ODDS = 2,          -- one lava flow pressing on fuel in this many lights it
    FIRE_SAMPLE_TICKS = 20,      -- ticks between hot-ground samples near a player
    FIRE_SAMPLE_COLUMNS = 4,     -- columns per sample
    -- An edit not seen in the world after this is given up. Longer than the
    -- queue's worst wait — two BACKOFF_TICKS behind two refusals, MAX_WAITING
    -- batches at QUEUE_EVERY, and a turn to notice — because a fire edit
    -- given up on that then lands is an orphan block nothing spreads from
    -- and nothing but its random tick clears. Retune the queue, retune this.
    FIRE_CONFIRM_TICKS = 120,
    FIRE_SAVE_TICKS = 100,       -- ticks between writes of the fire state to storage while anything burns
    FIRE_HEAL_ODDS = 3,          -- one random tick in this many turns scorched ground bare again
    STRIKE_CANDIDATES = 3,       -- ground points tried per strike; the highest is hit
    STRIKE_SCORCH_ODDS = 2,      -- one strike in this many on bare turf leaves a scorch mark
    STRIKE_ALIGHT_RADIUS = 3,    -- blocks from a landed bolt within which a body is set alight (through Life)
    STRIKE_ALIGHT_TICKS = 100,   -- and for how long: five seconds, Life's own after-lava figure
    PLAYER_STRIKE_ODDS = 500,    -- one strike in this many is aimed at a player under open sky
    STRIKE_HIT_TICKS = 200,      -- and burns whoever it hits for ten seconds
}
