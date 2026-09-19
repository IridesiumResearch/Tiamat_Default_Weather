-- SPDX-License-Identifier: MIT
--
-- Switches and tunables. Every number a designer might turn is here, with
-- what it does; docs/weather-plan.md section 9 is where they came from.
--
-- Ticks are simulation ticks, twenty a second. Intensities are permille.

return {
    -- ---------------------------------------------------------- switches

    -- "auto" picks the Spindle adapter when tiamot_default_world is loaded
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
    -- Whether /weather set and /weather clear work. The engine has no
    -- operators yet, so this is a server-wide yes or no.
    commands = true,
    -- The plain adapter's idea of where the ground is, for warmth.
    sea_level = 0,

    -- ---------------------------------------------------------- the clock

    CLOCK_SAVE_EVERY = 200,     -- ticks between writes of the clock to storage

    -- ---------------------------------------------------------- the front

    FRONT_FREQUENCY = 1 / 2400, -- inverse size of a weather system, in blocks
    FRONT_OCTAVES = 2,
    TICKS_PER_Y = 600,          -- ticks per unit of the noise's time axis
    DRIFT_TICKS = 40,           -- ticks per block the front drifts along x

    -- Thresholds on front + moisture, which runs about -1..1.
    CLOUDY_AT = -0.05,
    RAIN_AT = 0.10,
    STORM_AT = 0.25,
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
    STRIKE_ABOVE = 40,          -- blocks over the player the flash is centred
    STRIKE_SEEN = 512,          -- blocks the flash is seen from
    STRIKE_HEARD = 400,         -- blocks the thunder is heard from
    -- The cloud deck (register_clouds), shaped after docs/reference/.
    CLOUD_ABOVE = 400,          -- blocks over the ground the cloud floor sits
    CLOUD_BASE_STEP = 64,       -- the floor moves in steps of this, so walking does not nudge the sky
    CLOUD_THICKNESS = 160,      -- blocks from the floor to the tallest tower's top
    -- Coarse on purpose (2026-09-18): 8-block cubes cost a frame at the
    -- horizon for detail nobody could see. 16 halves the steps a ray takes;
    -- two octaves and fewer towers read as heaps rather than as noise.
    CLOUD_CELL = 16,            -- blocks per cube
    CLOUD_DETAIL = 2,           -- small cubes per cube edge on the surface
    CLOUD_FREQUENCY = 1 / 500,  -- the field's horizontal scale, cycles per block
    CLOUD_OCTAVES = 2,
    CLOUD_TOWERS = 0.2,         -- how much taller the highest heaps grow
    CLOUD_EVOLVE = 1 / 2400,    -- how fast the shape changes, per second
    CLOUD_EASE_TICKS = 600,     -- how long a change of cover takes on the client
    THUNDER_ODDS = 12,          -- one in this many storm evaluations strikes
    HUD_ROW_SPINDLE = 78,       -- below the Spindle's biome name (y = 44, size 26)
    HUD_ROW_PLAIN = 44,

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
    PUDDLE_ONE_IN = 8,          -- one sampled column in this many gets rainwater: puddles, not a film
    PUDDLE_CELLS = 3,           -- cells of rainwater a sampled column gets in RAIN
    STORM_PUDDLE_CELLS = 6,     -- and in a STORM
    RAIN_EVAPORATES = 300,      -- one cell in this many fluid ticks (10 Hz): 3 cells in the open last about 90 s
}
