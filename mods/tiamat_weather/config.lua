-- SPDX-License-Identifier: MIT
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

    -- Thresholds on front + moisture, which runs about -1..1.
    CLOUDY_AT = -0.05,
    RAIN_AT = 0.10,
    STORM_AT = 0.25,

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
    CLOUD_ABOVE = 400,          -- blocks over the ground the cloud floor sits
    CLOUD_BASE_STEP = 64,       -- the floor moves in steps of this, so walking does not nudge the sky
    CLOUD_THICKNESS = 200,      -- blocks from the floor to the tallest tower's top (160 until 2026-09-23: "a little bit bigger")
    -- Coarse on purpose (2026-09-18): 8-block cubes cost a frame at the
    -- horizon for detail nobody could see. 16 halves the steps a ray takes.
    -- Since engine 0d8e857 the deck is heaps: FREQUENCY spaces them (a heap
    -- every 0.42 / FREQUENCY blocks), THICKNESS sets how tall they grow, and
    -- OCTAVES no longer shapes anything.
    CLOUD_CELL = 16,            -- blocks per cube
    CLOUD_DETAIL = 2,           -- small cubes per cube edge on the surface
    -- Heaps sit on a lattice 0.42 / FREQUENCY blocks apart, each 0.30 to
    -- 0.68 of that across, so this is their size as much as their spacing:
    -- 1/500 was heaps up to 140 blocks wide, 210 apart; 1/680 is up to 190
    -- wide, 285 apart. The sheet's cells and the mackerel layer's cloudlets
    -- scale with it too. Raised 2026-09-23, the designer's "a little bigger".
    CLOUD_FREQUENCY = 1 / 680,  -- the field's horizontal scale, cycles per block
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
    CLOUD_LIFT_ALPINE = 320,    -- blocks, over CLOUD_ABOVE, in the alpine highlands
    CLOUD_LIFT_FROST = 160,     -- and in the frost ring beside them, whose terrain fades into the alpine's
    CANOPY_SCAN = 48,           -- blocks over a player's head a canopy is looked for
    THUNDER_ODDS = 12,          -- one in this many storm evaluations strikes
    MEGA_THUNDER_ODDS = 3,      -- and in a mega storm at full strength
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
    MEGA_PUDDLE_CELLS = 12,     -- and in a mega storm
    RAIN_EVAPORATES = 300,      -- one cell in this many fluid ticks (10 Hz): 3 cells in the open last about 90 s

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
}
