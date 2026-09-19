# Tiamot Weather — plan

A standalone weather mod for the Tiamot engine, `tiamot_weather`. It is
written against the public Lua API only, and built to sit **beside** the
Spindle (`tiamot_default_world`) rather than inside it.

Tags: **[now]** can be built today. **[ask WN]** needs that entry in
`engine-asks-weather.md`. **[verify]** is behaviour this plan assumes and
nobody has measured. **[checked]** was confirmed in the engine source on
2026-09-16.

Weather here is **a function the server evaluates at a handful of points**.
Everything a player sees is presentation sent from those points.

**Amended 2026-09-16** after review, against the Spindle as it is in
`Tiamot_Default_World` today:

1. The sampler no longer produces work the queue will throw away (5.2, 5.3).
2. Snow has a depth cap for every kind of snowfall (5.4).
3. Drifts stay this mod's `snow_layer` and never become the Spindle's snow (5.4).
4. The particle table is recounted from lifetime, and every row fits four
   buckets under the client cap (5.1).
5. Damp ground is traced through every Spindle rule that reads the dry
   material, not only the HUD. The Spindle has no `loam`, so it is gone from
   the tables (3.2, 5.5, 7).
6. Warmth is the Spindle's `4t(1−t)`, with `t = √u` by fixed Newton steps in
   `+ − * /` (3.2).

---

## 1. Why a separate mod

**Isolation.** When a mod's tick callback errors, the engine disables *that
whole mod* for the session. Inside the Spindle, a weather bug would also stop
tree growth, the paced edit queue and spawn handling. As its own mod, a
weather crash takes down weather and nothing else.

**No hook conflicts.** [checked] Tick and chat hooks are keyed per mod
(`hook_key(hook, mod_id)`), so `tiamot_weather` has its own
`register_on_tick` and `register_on_chat`. The Spindle's chat handler already
returns `nil` for commands it does not own, so `/weather` reaches this mod.
Random ticks *are* one handler per material across all mods, but this mod only
random-ticks its own blocks.

**Players can opt out.** Weather can be switched off in the launcher without
touching the world mod.

**Licence and reuse.** The Spindle is GPL-3.0-only. This mod may take any
licence (MIT suggested, matching `api/`). With the climate behind an adapter
(section 3), it can run on worlds other than the Spindle.

**What it costs**, and how each cost is handled:

| Cost | Why | Handled by |
|---|---|---|
| No access to `tdw.*` | [checked] each mod gets a fresh sandbox environment | Mirroring the climate fields (3.2); ask W9 removes the mirror |
| Mirrored constants can drift | The Spindle may retune its humidity | Version pin + a drift check (3.4) |
| Its own edit queue | `tdw.edits` is out of reach | A conservative queue (5.2) that yields by budget |
| Damp ground hides dirt and sand from the Spindle | Its growth ticks, soil checks and HUD compare materials (5.5) | Damp only while wet and only under open air, plus a small Spindle change (7) |

---

## 2. Layout

```
tiamot_weather/
  mod.toml
  init.lua              load order only; hangs everything off the `wx` global
  config.lua            switches and tunables
  climate.lua           picks an adapter at load, exposes the climate interface
  climate_spindle.lua   the Spindle adapter: mirrored fields, ground overrides
  climate_plain.lua     fallback for any other world
  blocks.lua            snow_layer, damp_* variants
  controller.lua        weather(x, y, z, tick): the front, easing, override
  fx.lua                particles and sound
  ground.lua            the sampler, snow layers, damp ground, the thaw
  queue.lua             the paced edit queue
  commands.lua          /weather
  hud.lua               the HUD script (runs on clients)
  sounds/  textures/
```

`require` is confined to the mod's directory and does not cache. As in the
Spindle, only `init.lua` loads files, and everything exports through one
global (`wx`). Files stay flat, because subdirectories under `require` are
untested.

```toml
id = "tiamot_weather"
name = "Tiamot Weather"
version = "0.1.0"
depends = ["core >=0.1"]
optional_depends = ["tiamot_default_world >=0.1, <0.2"]
description = "Rain, snow, storms and the ground they leave behind."
license = "MIT"
```

[checked] `optional_depends` is load order only: if the Spindle is
installed, it loads first, so its block ids can be looked up during this
mod's registration. The upper bound is the drift guard (3.4). [checked] An
optional dependency that is installed at an incompatible version is refused,
not ignored. When the Spindle goes to 0.2, this mod stops loading until
someone checks the mirror. That is the intent.

---

## 3. The climate adapter

### 3.1 The interface

Everything outside `climate_*.lua` asks only this:

```lua
wx.climate = {
    name = "spindle" | "plain",
    warmth = function(x, y, z) end,         -- integer 0..1000
    freezing = function(x, y, z) end,       -- boolean
    moisture = function(x, y, z) end,       -- noise units, roughly -0.5..0.5
    override = function(x, y, z) end,       -- nil | "ash" | "dust" | "sea"
    damp = { ["mod:dry_block"] = "tiamot_weather:damp_x", ... },
}
```

`climate.lua` picks the adapter at load:
`pcall(game.get_block_id, "tiamot_default_world:dirt")` succeeding means the
Spindle is here. A `config.climate = "plain"` setting forces the fallback.

### 3.2 The Spindle adapter  [now]

**Moisture: the Spindle's own humidity field, mirrored.** [checked] A noise
node's stream is hashed from its **name alone** (`fnv1a(stream)`, no mod id).
A program built with the same name and parameters is therefore the same field,
bit for bit. From `shape.lua` at Spindle 0.1.0:

```lua
-- MIRRORS tiamot_default_world 0.1.0 shape.lua: M.humidity()
-- HUMIDITY_FREQ = 1/9000, HUMIDITY_OCTAVES = 2, HUMIDITY_STRETCH = { y = 1000 },
-- NOISE_RANGE = 0.5. Change these only together with the Spindle.
local HUMIDITY = game.density{
    op = "clamp", low = -0.5, high = 0.5,
    a = { op = "noise", stream = "humidity", frequency = 1 / 9000, octaves = 2,
          amplitude = 1.0, stretch = { y = 1000 } },
}
local function moisture(x, z)
    return HUMIDITY:at(x, 0, z, game.world_seed) + belt_bias(x, z)
end
```

`belt_bias` raises moisture over the Verdant Belt and lowers it over the
Glass Waste. It uses the ring spans copied from `shape.lua` (`M.VERDANT_U`
and the rest) and the plain-Lua `u` below.

**This mod's own streams must never use a Spindle name.** Its streams start
with `wx_`. The engine's own comment on stream names warns that a field
silently equal to someone else's is the hardest worldgen bug to see.

**Warmth: from the rings and the dome, in plain arithmetic.** The Spindle
plan's climate is `T = 4t(1−t)` in `t = r/R = √u`. There is no `sqrt` a mod
may call (`math.sqrt` and `^` are platform library calls), and no expression
in `u` alone equals `4√u(1−√u)`. A piecewise line in `u` was tried and is a
different climate: at `t = 0.25` it gives 0.25 where the Spindle has 0.75,
which puts snow in rings the Spindle made warm. So `t` is found by Newton's
method, a fixed number of steps of `+ − * /` only. That is the same sequence
of IEEE operations on every machine, so it is deterministic:

```lua
-- MIRRORS shape.lua: SCALE = 0.001, Y0 = 11000, R_DISC = 59, SUMMIT = 19, DOME_DROP = 2.5
local INV_R2 = 1e-6 / (59.0 * 59.0)          -- the Spindle's own spelling of it

local function u_of(x, z) return (x * x + z * z) * INV_R2 end

-- sqrt(u) for u in [0, 4]: 20 fixed Newton steps from 1. Halving to near
-- sqrt(u) takes at most ~7 steps for u >= 1e-4, then it converges
-- quadratically. Below 1e-8 (the axis) t is 0, which is also its limit.
local function root(u)
    if u < 1e-8 then return 0.0 end
    local g = 1.0
    for _ = 1, 20 do g = 0.5 * (g + u / g) end
    return g
end

-- World y of the base dome: H(u) = SUMMIT - u * (2*DROP - DROP*u), km -> blocks.
local function dome_y(u) return 11000 + (19.0 - u * (5.0 - 2.5 * u)) * 1000 end

local function warmth(x, y, z)
    local u = u_of(x, z)
    local t = root(u)
    local w = 4.0 * t * (1.0 - t)                                -- 1 at t = 0.5, 0 at the axis and the rim
    local lapse = (y - dome_y(u)) / CLIMATE_LAPSE                -- one band per CLIMATE_LAPSE blocks up
    return math.max(0, math.min(1000, math.floor(1000 * w - BAND * lapse)))
end
```

`t > 1` (past the rim) gives a negative `w`, clamped to 0.

The ring wobble (`u_biome`) is deliberately **not** mirrored. A climate edge
that is circular to within 2% of the radius is invisible in weather.

**Overrides: read from the ground.** Any mod can read block string ids, so
the adapter keeps a short table in the style of `whereami.lua`:

| Ground under the player (string ids) | Override |
|---|---|
| `lava_rock`, `pumice`, `sulfur`, the Ember Ridge's ash | `"ash"` |
| `sand`, in a warm and dry square (warmth > 700, moisture < −0.05) | `"dust"` |
| the surface block holds fluid (`game.get_fluid`), or its column has none within 8 blocks down | `"sea"` |

It is rougher than `tdw.biome_under`, and weather does not need exact biome
names.

**Damp materials:** `dirt`, `packed_dirt`, `sand`, all prefixed
`tiamot_default_world:`. (There is no `loam` block. The woodland's "loam"
is `dirt`.)

**Snow-covered ground:** `snow`, `ice`, `permafrost`, prefixed the same
way. Snow never settles on these. The ground is already white, and the
Spindle runs its own drift rule on its `snow` in the Crown
(`frozen_wastes.lua`), which a layer of this mod's snow on top would block.

### 3.3 The plain adapter  [now]

For any other world: moisture is this mod's own `wx_moisture` noise, warmth
falls with world y from a configured `sea_level`, there are no overrides, and
`damp` maps the core blocks if they exist. A plain world gets rain and snow
that ignore biomes, which is honest for a world the mod knows nothing about.

### 3.4 Keeping the mirror honest  [now]

- **Version pin:** `optional_depends` upper bound, as above.
- **A drift check** at the first tick, logged, never fatal. Sample the mirrored
  humidity at a fixed list of world points. At the same points, read the
  ground with the Spindle's wet-and-dry owners from `whereami.lua`, for
  example `oak_log`/`birch_log` (woodlands, wet) against `packed_dirt`
  (grasslands, dry). Both halves lie on `dirt`, so the soil alone says nothing. If more
  than a few points land on the wrong side of `HUMIDITY_SPLIT = -0.05`, log
  `"tiamot_weather: the Spindle's humidity no longer matches the mirror"`. This
  needs loaded chunks, so run it once a player has joined, and skip unloaded
  points.
- **Ask W9** replaces the mirror with a real read of the Spindle's field.

---

## 4. Weather is a function

```
weather(x, y, z, tick) -> { kind, intensity }       -- intensity in permille
```

Only the clock is persisted (`game.storage` key `tick`, written every 200
ticks, counted from `dt_ticks`). That gives three guarantees:

- Two players standing together agree, with nothing synchronised.
- A restart resumes the same storm.
- `/weather forecast` is free.

Every float operation is `+ - * /`, `math.floor`, or a `Density:at` read,
all inside the deterministic subset.

### 4.1 The front  [now]

This is a slow 3D noise read **with the clock in place of y**, so it
swells, drifts and dissolves without anything being moved:

```lua
local FRONT = game.density{ op = "noise", stream = "wx_front", frequency = 1 / 2400, octaves = 2 }
local function front(x, z, tick)
    local drift = tick // DRIFT_TICKS                      -- integer blocks
    return FRONT:at(x - drift, tick / TICKS_PER_Y, z, game.world_seed)
end
```

### 4.2 The answer

```
wet  = front + climate.moisture(x, z)
kind = CLEAR      if wet < CLOUDY_AT
       CLOUDY     if wet < RAIN_AT
       RAIN|SNOW  if wet < STORM_AT          (SNOW where climate.freezing)
       STORM|BLIZZARD otherwise
then climate.override: "ash" turns RAIN into ASH and STORM into ASH_STORM;
                       "dust" ignores moisture, and a strong front alone makes DUST;
                       "sea" adds spray to STORM
```

### 4.3 Where and how often

It is evaluated at the centre of the player's **256 × 256 square**
(`x // 256`, `z // 256`) every `EVAL_TICKS = 40`. The cost is players ×
(two `Density:at` reads + a few `get_block` reads for the override) every two
seconds.

**Eased:** the applied intensity moves at most `EASE = 50` permille per
evaluation, so an edge fades over about forty seconds. The easing lives in a
Lua table and is not persisted. After a restart, weather fades in from zero.

**Override:** `/weather set` stores `override:<cx>:<cz>` =
`"kind,intensity,until_tick"` in this mod's storage.

**Players:** tracked from `register_on_player_join` and `_leave`. Positions
come from `game.player_entity` → `game.entity(id).pos`, looked up each time,
because entity ids are per session.

---

## 5. What a player sees, hears and finds on the ground

### 5.1 Precipitation: bursts per occupied square  [now]  [ask W4]

`game.emit_particles` goes to **everyone** within its radius, so bursts are
per occupied **32-block** bucket, not per player:

1. Every `FX_TICKS`, bucket players by `x // 32`, `z // 32`.
2. Skip a bucket whose first player reads `game.get_light` at head height
   `sun == 0` (underground).
3. Emit one burst above the bucket.

`collide = true` stops a drop at the first solid cell, so roofs, overhangs
and canopies occlude rain without raycasts. Passable plants do not stop it.

**The budget** (revised 2026-09-17). The client draws at most 8,192
particles, shared by everything below. A player near a bucket's corner is
inside the radius of four bursts, and cloud puffs are sent 128 blocks:

| Share | Per | Worst case for one player |
|---|---|---|
| Precipitation | 1,400 a bucket | 4 buckets: 5,600 |
| Storm haze | 150 a bucket | 4 buckets: 600 |
| Clouds | 48 a cell | 32 cells within 128 blocks: 1,536 |
| | | **7,736** |

Live particles per bucket are `count × life / every`, both in ticks, using
the full lifetime: over a drop, water or a cliff edge a particle lives its
whole life. `fx.lua` asserts every row and the total at load.

**How much a storm hides** goes as `live × size² × alpha`. After play-testing,
storms were made three times as opaque as the first table. The storm row's
count was already at 256 a burst, so its particles grew instead: 0.07 → 0.12,
giving 12.7 against the first table's 4.0. Blizzard, ash storm and dust storm
were scaled the same way within the smaller budget.

| Kind | Every | Count | Size | Area (half) | Above | Vel. y | Grav. | Life | Live, worst | Colour (a) |
|---|---|---|---|---|---|---|---|---|---|---|
| Rain | 4 t | 60–220 | 0.06 | 16, 3, 16 | +18 | −22 | 0 | 1.0 s | 1,100 | 0.7 0.75 0.85 (0.55) |
| Storm | 3 t | 256 | 0.12 | 16, 3, 16 | +18 | −30 | 0 | 0.8 s | 1,365 | 0.55 0.6 0.68 (0.65) |
| Snow | 5 t | 20–70 | 0.15 | 16, 4, 16 | +14 | −2.5 | 0.3 | 5 s | 1,400 | 1 1 1 (0.9), spread 0.6 |
| Blizzard | 3 t | 70 | 0.24 | 16, 6, 16 | +8 | −3 | 0 | 3 s | 1,400 | 1 1 1 (0.85), wind 10 |
| Ash | 5 t | 8–30 | 0.18 | 16, 4, 16 | +14 | −1.5 | 0.2 | 7 s | 840 | 0.3 0.3 0.3 (0.8) |
| Ash storm | 5 t | 30 | 0.44 | 16, 4, 16 | +14 | −1.5 | 0.2 | 7 s | 840 | 0.28 0.27 0.27 (0.85), wind 6 |
| Dust | 3 t | 105 | 0.48 | 16, 3, 16 | +3 | 0 | 0 | 2 s | 1,400 | 0.85 0.7 0.5 (0.4), wind 12, no collide |

**Storm haze, the stand-in for fog.** Every 20 ticks per occupied bucket in
a storm, blizzard, ash storm or dust storm (and faintly in rain): 20
particles of size 4, alpha 0.14–0.18, 6 s, spread through 32 × 10 × 32
blocks round the player's feet, drifting with the wind and not colliding.
The count scales with intensity, so haze thickens as a storm eases in.

**Clouds, the stand-in for a cloud deck.** A 40-block grid of cells over
every player, out to 96 blocks. Each cell puffs every 15 s (staggered) with
24 particles of size 4 that live 30 s, packed into 28 × 4 × 28 blocks,
56 blocks over the player's feet (in steps of 16), drifting with the front.
Whether a cell is cloud comes from a fine `wx_clouds` noise (1/140), cut at
a line set by the square's weather:

| Weather | Cover | Grey |
|---|---|---|
| Clear | 18% | 0.97 |
| Cloudy | 60% | 0.86 |
| Rain, snow | 85% | 0.66, 0.8 |
| Storm, blizzard, ash storm | all | 0.42, 0.72, 0.3 |

**Wind** blows rim-ward on the Spindle (`(x, z) / (|x| + |z|)`, with no
square root) and along a slowly turning direction on the plain adapter.

The Spindle's own emitters (the Ember Ridge's fumaroles) share the same
8,192 cap, so ash there stays at half its count range (at most 30).

### 5.2 The paced edit queue  [now]

This is a smaller version of the Spindle's `edits.lua`, and **more
conservative**, because two mods now spend the relight budget without knowing
about each other:

- **One batch lands per `QUEUE_EVERY = 2` ticks**, at most.
- **A batch is one chunk footprint's edits** (5.3), so it touches at most
  `BATCH_CHUNKS = 2` chunks: the footprint's own, and the one above or below
  it where the surface crosses a chunk boundary.
- **At most `MAX_WAITING = 4` batches.** `queue.room()` is asked **before**
  any work is done (5.3), so nothing is scanned and then thrown away.
- **`game.set_block` returns `false` when the engine queue is full.** On
  `false`, the rest of that batch is dropped and the whole queue backs off
  for `BACKOFF_TICKS = 40`, which yields to the Spindle's trees. Dropping
  is safe: every edit is re-derived from the ground next time a column is
  sampled.

**Measured rate, not intended rate.** The first draft made one batch per
player per tick and drained one per two ticks. With one player the queue
filled in about 16 ticks, and after that half the sampled columns, each up to
48 `get_block` reads, were scanned and discarded. With N players it was worse,
and whoever came later in the player list never had a batch land. The
producer now runs at the drain's pace and asks for room first.

### 5.3 The ground sampler  [now]  [ask W6]

Random ticks come up about every twenty minutes per block, which is too slow
to watch snow settle. So the sampler runs **on the drain's cadence**, not per
player per tick:

1. **Every `QUEUE_EVERY` ticks, if `queue.room()`**, take the **next** player
   in a round-robin over the players standing in RAIN, SNOW or a storm (or in
   a warm CLEAR/CLOUDY square with something to thaw, 5.6). Skip the turn if
   nobody qualifies. The cursor persists across ticks, so every player gets a
   turn in order, whoever joined first.
2. **Pick one chunk footprint** (16 × 16 columns) whose centre is within
   `SAMPLE_RADIUS = 40` blocks of the player (2026-09-17: the scan itself is
   one `game.surface_at` call a column, not 48 `get_block` reads), from
   `game.rng_stream({ x = px // 16, y = tick, z = pz // 16, seed = game.world_seed },
   "wx_ground")`. [checked] It accepts any `{x, y, z, seed}` table at runtime.
3. **Pick `COLUMNS_PER_BATCH = 6` columns** inside that footprint, from the
   same stream.
4. **Find each column's surface.** Scan `get_block` down from `player.y + 24`
   to the first block that is neither air nor passable. Stop after `SCAN = 48`
   reads, or give up on `nil` (unloaded). **Then require `get_light` of the
   cell above the surface to be `sun == 15`.** That check is required, not
   optional. Without it, a roof higher than the scan start would let snow
   settle on the floor under it. Ask W6 would make this one call.
5. Decide each column (5.4, 5.5, 5.6) into one batch and commit it.

With one player that is 3 columns per tick over about 5,000 columns in
reach, so each column is looked at about every 80 seconds. Snow settles in
patches over a few minutes, which reads as snow settling. With N players,
each player's ground is looked at N times less often. That is the price of a
fixed budget, and it is the right one.

### 5.4 Snow layers  [now]

A new block, `tiamot_weather:snow_layer` ("Fresh snow"). It has hardness 0.1
and `drops` of its own material in units, so digging conserves. It grows in
whole sub-node layers. The occupancy index is `x + 3y + 9z`, so a layer is not
a run of low bits:

| Depth | Cells | Mask |
|---|---|---|
| one layer | 9 | `0x1C0E07` |
| two layers | 18 | `0xFC7E3F` |
| full | 27 | `game.OCCUPANCY_FULL` |

Where it is SNOW or BLIZZARD and `climate.freezing` holds at the surface:

- **The cap.** A `snow_layer` grows to at most `SNOW_LAYERS = 2` layers in
  SNOW and `BLIZZARD_LAYERS = 3` (a full block) in a BLIZZARD. **It never
  grows past one block.**
- On an existing `snow_layer` below its cap for the current kind, step it up
  one layer.
- On a **whole** support block with air above, write one layer. **A
  `snow_layer` is never a support**, even a full one, so snow cannot stack
  on snow. Without this rule the first draft grew without limit: a full
  `snow_layer` was a whole block with air above, so the next pass started a
  new layer on top of it.
- **Snow stays this mod's material.** A full `snow_layer` never becomes
  `tiamot_default_world:snow`. The Spindle's snow has two random-tick owners,
  the Frozen Wastes' drift rule and the Alpine Highlands' surface rule. Both
  do nothing outside their own province, and neither ever melts snow. A drift
  converted anywhere else would have been permanent in a warm ring. This
  mod's snow thaws (5.6).
- Skip partial blocks, fluid, anything under a `transparent` block, and the
  climate's snow-covered ground (3.2).
- **"Air above" means a block of occupancy 0**, not only a passable one. A
  grass tuft is passable and lets the sun through, but writing a layer there
  would replace the grass, and the grass would not come back when the snow
  thaws. So snow settles on bare ground, rock, sand and canopies, and not on
  grassy turf. That limit is honest until merge writes of snow into a grass
  block are measured.

### 5.5 Damp ground  [now, phase 2b]  [ask W7]

`absorbs` is not used: it would drain rivers and seas into the same dirt
(ask W7). Wetting is a material swap by the sampler, through
`climate.damp`:

| Dry | Damp | Drops |
|---|---|---|
| `tiamot_default_world:dirt` | `tiamot_weather:damp_dirt` | the dry block |
| `tiamot_default_world:packed_dirt` | `tiamot_weather:damp_packed_dirt` | the dry block |
| `tiamot_default_world:sand` | `tiamot_weather:damp_sand` | the dry block |

The damp blocks copy their dry block's hardness and tint by hand and use
darker textures. Only whole single-material blocks are swapped.

**What a swap hides from the Spindle.** A damp block is a different material,
so every Spindle rule that asks "is this dirt?" says no while the ground is
wet. As of `Tiamot_Default_World` today, the rules are:

| Spindle rule | Reads | While damp |
|---|---|---|
| Woodland and grassland growth, `on_random_tick(grass)` | `tdw.soil_under(...) == blocks.dirt` decides whose turn it is | Neither biome takes the turn, so no tree, rock, rose or burrow grows on that turf |
| Alpine surface growth, `on_random_tick(dirt)` | a tick registered **on `dirt` itself** | The block is not offered to the alpine at all, so no fir, boulder or hollow |
| Biome soil, `biomes.lua` `.soil` | `dirt` (flower forest, karst, redwoods, frostpine), `sand` (dunes, kelp) | Wrong soil answer |
| The HUD, `whereami.lua` `OWNER` | `dirt`, `packed_dirt` → grasslands | Wrong or missing biome name |
| Savanna tree shapes, `PRIORITY` | `packed_dirt` | A tree cut through damp ground does not treat it as its own |

Random ticks are rare, so while a block is damp **it loses the turns that
land in that time and nothing else**. Growth there slows by the share of time
it spends wet. That is acceptable only if dampness is short, so the design
holds to that:

- Ground dries on its first sample or random tick after `DRY_AFTER_TICKS`
  outside rain, **not** only "when it is warm" (5.6).
- Damp ground is never written under grass or any other cover. Only a
  surface block with open sky directly above is swapped, which keeps the
  woodland and grassland turf (dirt *under* grass) out of it entirely.
- The alpine's `dirt` ticks are the remaining cost. It is accepted and
  measured in phase 2b's acceptance.

**This phase ships switched off** (`config.damp_ground = false`) until the
Spindle has taken the changes in section 7, which map damp ids back to their
dry ones in `soil_under`, `.soil` and `OWNER`.

### 5.6 The thaw  [now]

- **Near players:** the sampler reversed. In a square that is not snowing and
  not freezing, a sampled `snow_layer` loses a layer. In a square that is not
  raining, damp ground goes dry.
- **Everywhere else:** `game.register_random_tick` on `snow_layer` and each
  damp block. These are this mod's materials, so nothing conflicts. Snow
  steps down when `weather()` there is not snow and the surface is not
  freezing. Damp ground dries whenever it is not raining there. A field of
  snow melts over an hour or two.

### 5.7 Sound  [now, workaround]  [ask W5]

- **Rain/wind:** one positioned `game.play_loop` per active 256-block square,
  id `rain:<cx>:<cz>`, at the square's centre, radius 256, gain by
  intensity. Starting a loop that is already running replaces it. It stops
  when the square clears or empties. It pans oddly near the centre, which ask
  W5 fixes.
- **Thunder:** `game.play_sound{ radius = 256 }` at a random point within 96
  blocks, one in `THUNDER_ODDS` evaluations.

### 5.8 HUD  [now]

This mod's own `hud.lua`, registered with `game.register_hud_script`. The
engine allows one per mod, so this does not displace the Spindle's. It draws
`state.values.weather` at the top anchor at **y = 78**, below the Spindle's
biome name (y = 44, size 26), at size 20. On a world without the Spindle, it
draws at y = 44. The server sends `game.set_hud(player, { weather = "Rain" })`
only when the value changes.

### 5.11 The sky, the rain and the lightning  [now]

Built 2026-09-17 on the engine's weather calls. All three are per player,
because two players in one domain can stand under different weather.

- **The sky** (`set_sky_modifier`): a storm multiplies the keyframe's
  intensity by 0.45, mixes the horizon and fog colour 0.8 of the way to a
  grey-blue, pulls the distance fog in to 0.35 of its reach, and drains the
  grade's saturation to 0.65. Every field eases from the identity by the
  square's intensity, so the sky darkens as the storm arrives and lifts as it
  goes. **This is the fog**; the particle haze that stood in for it is gone.
- **The rain** (`set_precipitation`): the SHAPE of the rain, which the client
  spawns around its own camera at `rate` a second. `rate` is the table's
  `live` divided by its lifetime, so the counts mean what they say: a client
  emitter holds exactly `live` particles, where the old bucket bursts
  overlapped two to four times over. One message per change, and the client
  keeps a quarter of its particle budget free of rain.
- **The lightning** (`flash`): in a storm, one evaluation in `THUNDER_ODDS`
  strikes within `STRIKE_REACH` of the square's first player. The flash is
  seen at once within `STRIKE_SEEN`; the thunder is queued and played when the
  sound would have arrived, at 19 blocks a tick.

### 5.9 Not buildable yet

Nothing on the sheet is left unbuilt. The cloud deck (W2) landed on
2026-09-18 and replaced the particle puffs (10.4).

Everything else on the sheet was built by the engine on 2026-09-17: the sky
darkens (5.11), the fog draws in with it, lightning flashes, the rain is the
client's own emitter, the loops are per player and the column scan is one
call. A storm is now a dark sky, close fog, heavy rain, thunder after the
flash, and the deck overhead closing in and going grey (10.4).

### 5.10 Puddles  [now, off by default]

Built 2026-09-16, once engine 62608bf settled what two fluids do when they
meet. They never share a block, and a flow into a block of a different
fluid is reported with `meets`.

- **A `rainwater` fluid**, `evaporates = RAIN_EVAPORATES` (300: one cell in
  300 fluid ticks, so 3 cells in the open last about 90 seconds), drawn
  faint (`opacity = 0.35`).
- **The sampler leaves it.** In RAIN or STORM, one sampled column in
  `PUDDLE_ONE_IN = 8` whose surface is the climate's open ground gets
  `PUDDLE_CELLS = 3` (6 in a storm) in the open cell above. It rides in the
  same batch as the block edits, paced the same way. On the Spindle, open
  ground is `dirt`, `packed_dirt`, `sand`, `gravel`, `stone`, `mud`,
  `dried_mud`, and their damp versions. Canopies and logs never get a puddle.
  A column that already holds fluid is skipped, because `get_fluid` cannot
  say whose fluid it is.
- **Meeting another fluid lets it go.** Rainwater pressing into a river, a
  sea or brine has its own block cleared, as if it ran in. It is **not**
  added to the other body: rain is matter this mod made, and topping up the
  Spindle's seas would move its shores. Against a hot fluid (the Spindle's
  lava) it goes as a small burst of steam. Other fluids meeting each other,
  and rainwater meeting terrain, are left alone. The hook is registered
  whether or not puddles are on, so puddles left by an earlier session still
  drain.

**Why it ships off:** the Spindle's `rules.lua` removes a leaf block when a
fluid presses on it, and it checks `event.block` without looking at
`event.fluid`. Rainwater that runs against a bush or a low canopy would strip
it (7.3).

---

## 6. Commands and settings

`register_on_chat` parses `/weather` and returns `nil` for anything else.

- `/weather` replies with kind, intensity, warmth, moisture, square and
  adapter, for where the speaker stands.
- `/weather set <kind> [minutes]` and `/weather clear` set or remove the
  override, gated by `config.commands` until the engine has operators.
- `/weather forecast` samples `weather()` at the speaker's square for the
  next ten minutes.
- `/weather drift` re-runs the check in 3.4 and replies with the result.

Setting: `game.register_setting{ id = "particles", options = { "off", "low",
"full" }, default = 2 }`. A bucket's burst uses its players' highest choice,
so "off" is only honest once ask W4 lands.

---

## 7. What the Spindle would change (optional, small)

**Superseded 2026-09-17 by exports** (`docs/exports-contract.md`). The
Spindle can now export functions Weather calls at load:
`add_soil_alias(block, dry)` replaces 7.1, and `add_harmless_fluid(fluid)`
replaces 7.3. `humidity`, `climate` and `biome_under` replace the mirror, so
7.2 matters only while the mirror is in use. Weather switches damp ground and
puddles on (`"auto"`) exactly when the Spindle answers `true`. The original
text follows, as what those functions must do inside the Spindle.

This is the only Spindle-side work, and weather runs without it:

1. **A damp-to-dry table, resolved lazily.** The Spindle cannot look the
   damp ids up at load: it loads *before* `tiamot_weather`, so the ids do not
   exist yet. Resolve them on first use, when the registries are frozen and
   complete, into one table that every rule in the 5.5 list reads through:

   ```lua
   local DAMP = { damp_dirt = "dirt", damp_packed_dirt = "packed_dirt", damp_sand = "sand" }
   local DRY = nil
   -- The dry material a damp one stands for, or the material itself.
   function tdw.dry(material)
       if DRY == nil then
           DRY = {}
           for damp, dry in pairs(DAMP) do
               local ok, id = pcall(game.get_block_id, "tiamot_weather:" .. damp)
               if ok then DRY[id] = tdw.blocks[dry] end
           end
       end
       return DRY[material] or material
   end
   ```

   Then `tdw.soil_under` returns `tdw.dry(b.material)`, `whereami.lua` looks
   up `OWNER[tdw.dry(material)]`, and the `.soil` comparisons go through it
   too. The alpine's tick registered on `dirt` cannot be extended to
   `damp_dirt`, because registration closes before the id exists. That is
   the accepted cost in 5.5.
2. **A note in `shape.lua`** beside `M.humidity()`: *mirrored by
   tiamot_weather; bump the minor version if this changes.* This gives the
   version pin in section 2 something to catch.
3. **The leaves rule checks which fluid it is.** `rules.lua`'s
   `register_on_fluid_flow` removes a leaf block whenever *any* fluid presses
   on it. With puddles on, rainwater would do that too. The change is one
   condition: act on leaves only for `event.fluid` of the Spindle's own
   water and brine. Its lava rule already names its fluids and needs
   nothing. Rainwater meeting lava is handled on this side (5.10).

---

## 8. Phases

| Phase | Contents | Blocked on |
|---|---|---|
| 0 | Manifest, adapters, `controller.lua`, easing, override, `/weather`, HUD, drift check | nothing |
| 1 | `fx.lua`: rain, snow, storm, blizzard bursts; square loops; thunder; setting | nothing |
| 2a | `queue.lua`, `ground.lua`: sampler, snow layers, both thaws | nothing |
| 2b | Damp ground switched on | Spindle change 7.1 |
| 3 | Ash and dust; puddles experiment (`rainwater` with `evaporates`); forecast | Built. Puddles ship off until Spindle change 7.3 |
| 4 | Sky, flash, clouds, per-player sound and particles; replace the mirror | asks W1–W5, W8, W9 |

**Acceptance for phase 2a**, measured headless with the bot:

- A blizzard over one square for ten minutes adds no more than `X` ms to the
  mean tick, measured **with the Spindle's woodland growing at the same
  time**.
- `game.set_block` never returns `false` for a Spindle tree because of
  weather. The backoff has to work.
- Digging a two-layer `snow_layer` yields exactly 18 units.
- An hour of SNOW over one square leaves no `snow_layer` deeper than two
  layers, and an hour of BLIZZARD none deeper than one block. No
  `tiamot_default_world:snow` is written by this mod, ever.
- With one player, the sampler's discarded-scan count is zero: every
  scanned column reaches the queue.
- A mid-storm restart resumes the same kind within one evaluation.
- Removing `tiamot_weather` from a world leaves `snow_layer` and damp blocks
  as unknown materials, which the engine lists rather than errors on. Decide
  before release whether a "clear all weather blocks" command is owed to
  players who uninstall.

---

## 9. Tunables (first guesses, `config.lua`)

```lua
EVAL_TICKS = 40         SQUARE = 256          EASE = 50
FX_TICKS = 3..5         FX_BUCKET = 32        THUNDER_ODDS = 12   BUCKET_LIVE_MAX = 2000
COLUMNS_PER_BATCH = 6   SAMPLE_RADIUS = 40    SCAN = 48           SCAN_ABOVE = 24
QUEUE_EVERY = 2         BATCH_CHUNKS = 2      MAX_WAITING = 4     BACKOFF_TICKS = 40
SNOW_LAYERS = 2         BLIZZARD_LAYERS = 3   DRY_AFTER_TICKS = 1200
CLIMATE_LAPSE = 3000    BAND = 250
CLOUDY_AT = -0.05       RAIN_AT = 0.10        STORM_AT = 0.25
FREEZE = 300            TICKS_PER_Y = 600     DRIFT_TICKS = 40
```

---

## 10. As built (2026-09-16)

Phases 0, 1 and 2a are built, and 2b is built but switched off. Ash and dust
from phase 3 came along too, since they are rows in tables that already
existed. Where the build settled something this plan left open, or had to
differ from it:

- **The override and the easing are per square** (review points 7 and 8).
  A square's representative is its first player in UUID order. That
  player's height decides rain or snow, and their ground decides ash, dust
  or sea, for everyone in the square. The eased state is keyed by square,
  so two players in one square always see the same thing.
- **Moisture is sampled at the player's height**, not `y = 0`. The
  Spindle's humidity is stretched ×1000 in y, so the difference is tiny,
  but sampling where the player stands leaves nothing to explain.
- **The surface is the first non-air block**, and only a whole block of one
  material is a support. `get_block` cannot say whether a block is passable,
  so grass tufts, ferns and chiselled blocks are skipped, not seen through.
  That is the "not on grassy turf" rule in 5.4.
- **The sea override** is fluid at the feet or just under them. The draft's
  "no ground within 8 blocks" fired on every treetop and bridge.
- **Damp blocks drop themselves**, not the dry block. A `drops` override
  would give a whole block's units for one chiselled cell. A damp block
  that is carried off and placed dries back by its random tick.
- **Ash counts are halved in the table itself** (8–30 and 30), since ash
  only falls on the Ember Ridge, whose fumaroles share the client's cap.
- **Loop ids are `square_<cx>_<cz>`, with `m` for minus.** An id holding a
  `:` is read as a namespace, and the engine refused it. The native check
  caught this.
- **The setting's default indexes from zero**, confirmed in the engine:
  `default = 2` is "full".
- **Random-tick thaw has a budget** of 16 evaluations per tick, and nothing
  is attempted without queue room. A field of snow a thousand chunks wide
  would otherwise spend the tick on noise reads.
- **Near-player thaw only samples a square that snowed in the last hour**
  (`THAW_MEMORY_TICKS`). A warm square that never snowed costs nothing.
  After a restart that memory is empty, and the random ticks do the thaw.

**Checked by `tests/native`** (the engine's real VM, a fake world):

- warmth at t = 0.25, 0.5 and 0.75 is 749, 999 and 749
- a storm's bursts stay within the budget, and a bucket never bursts faster
  than its row allows
- the rain loop starts four times while easing in, then is left alone
- a restart resumes the front to six decimals, and the override with it
- a blizzard never writes above one block, and snow never above two layers
- nothing but `snow_layer` is ever written
- grass and snow-covered ground get nothing
- edits never land on consecutive ticks, and never more than six at once
- a refused edit backs off to 5 attempts in 200 ticks
- a roof keeps the snow off
- the plain world works
- the HUD draws

**Not yet measured:** the tick cost with the Spindle's woodland growing
beside it, bytes on the wire, and whether a mod disabled after an error
leaves its loops playing.

### 10.1 After the engine update (2026-09-16, evening)

Three engine commits landed after the build. None of them is a weather ask.

- **62608bf, fluids meeting.** This answered the open part of W7, and
  puddles (5.10) are built on it, switched off until Spindle change 7.3.
  Checked natively: puddles land only on open ground and at the queue's
  pace. Rainwater that meets water is let go, and against lava it goes as
  steam. Other meetings are untouched.
- **f219d6d, chunk tints may brighten.** This was the *Spindle's* ask 33,
  not W1. Weather has no use for it yet, because a tint is fixed once a chunk
  is served (W8). This clash of numbers is why the weather asks are now
  W1–W9.
- **b03fa42, terraced fluid levels.** Worldgen only; nothing here reads it.

The mod had been moved into `Tiamot/game/` as a plain folder. It is back in
this repository, with a junction in `game/`, as the Spindle and Life are.

### 10.2 After the exports update (2026-09-17)

- **W9 exports.** `climate_spindle.lua` reads the Spindle's exports where
  they exist and its mirror where they do not, per field. A Spindle whose
  exported function faults is disabled by the engine, and Weather carries on
  with its mirror. `exports.lua` publishes Weather's own API. Every function
  there is argument-checked and under a `pcall`, so a bad call answers `nil`
  and never disables Weather.
- **Damp ground and puddles are `"auto"`.** They are on exactly when the
  Spindle exports `add_soil_alias` or `add_harmless_fluid` and answers `true`.
  Against today's Spindle, which exports nothing, both stay off.
- **Particles per player** (half of W4). Bursts carry `player`, so the
  budget is per player: 2,800 precipitation, 300 haze and 2,400 clouds. The
  per-bucket scheme and `FX_BUCKET` are gone. A player used to stand in about
  two bucket bursts on average, so the counts were doubled to keep the look.
  The storm's opacity measure is 19.1 per player, against 12.7 per bucket
  before.
- **The drift check compares fields, not ground** (3.4), when the Spindle
  exports them: the mirror and the exported humidity and climate sampled at
  121 points, needing no loaded chunks. Identical programs agree to the last
  bit, and a retuned field is caught at every point. The old ground-reading
  check remains for a Spindle that exports nothing.
- **An engine without exports no longer disables this mod.** `game.exports`
  and `game.export` are checked for before they are called: on an older
  engine the mirror is the climate and nothing is published.
- **Fluids are per fluid** (engine c17f243). Before this,
  every fluid used the first-registered fluid's settings: the Spindle's
  water, with `evaporates = 0`. Puddles would never have dried. They were off
  anyway.

### 10.3 After the weather calls (2026-09-17, evening)

Seven engine commits, `3f69bad..31ea96c`, protocol v60: every ask on the
sheet but clouds (W2). What changed here:

- **`fx.lua` was rewritten** onto standing per-player settings (5.11). The
  bucket scheme, the particle haze and the square loops are gone. What is
  left of the old file is the cloud grid.
- **Rain counts are the ones the "three times" was measured at.** A client
  emitter holds exactly `live` particles; the bucket bursts it replaces
  overlapped two to four times, so the same numbers now mean what they say.
  The storm measures 12.7 against the first table's 4.0.
- **`surface_at` replaced the column scan** (W6): one crossing a column
  instead of up to 48 `get_block` reads, and a pond's surface comes back
  named rather than having to be asked about separately.
- **A cloud cover of "all of it" was three cells short.** The noise is
  clamped to ±0.5 and does sit exactly on the floor, and the line
  `0.45 - 0.95 * cover` came out at -0.49999999999999994, just above it. The
  line is `0.5 - 1.01 * cover` now, which is below the floor at full cover.
  `/weather clouds` reports the decision per cell, which is how it was found.
- **W7 is built but unused here.** The block that would drink rainwater is
  the Spindle's dirt, so declaring it is the Spindle's (`exports-contract.md`).

### 10.4 The cloud deck (2026-09-18)

Engine 42368d5..55607e7 built W2 as a raymarch. The particle clouds are
deleted, and with them the last particles this mod emitted.

- **One deck, registered at load**, shaped after `docs/reference/`: 8-block
  cubes breaking into 4-block ones on the surface (16 and 8 since 10.6), 160 blocks from floor to
  the tallest top, towers at 0.35, a blue-violet shade, and a drift of half a
  block a second along +x, which is the fronts' own drift, so the sky and the
  rain under it travel together.
- **Per player, every evaluation**, `set_clouds` with a cover and darkness
  per kind. A precipitating kind eases from the cloudy sky to its own as it
  arrives: clear 0.15, cloudy 0.55, rain 0.8, storm 1.0 and 0.9 dark.
- **The floor follows the dome.** It is sent per player as 400 blocks over
  the ground under them, in steps of 64 so walking does not nudge it. It is
  about 1.3 km lower at the rim than halfway out. The ground is the Spindle's
  `dome_y` export when there is one, and the mirrored dome otherwise.
- **How fine the clouds are is the player's own graphics setting.** The
  weather particles setting no longer mentions them.
- `/weather clouds` reports what the player was sent: cover, darkness, and
  the floor and how far over them it is.

### 10.5 Under the ground (2026-09-18, evening)

The Spindle's caves got denser (e9bd43a: a cave under 18 to 69 % of the
columns in the cave biomes) and now come up to the surface, so a player
walks from a storm into the ground far more often. Rain already stopped
there, but two things followed them down: the engine pulls a sky
modifier's fog in wherever the player is, and the loop is `everywhere`.
Both are now scaled by the sun light at the player's head, 0 to 15: full
in the open, part way in a cave mouth, and the plain sky and silence
underground. The clouds stay set, so the sky is right when they come out.

### 10.6 Coarser clouds, and what the engine owes their shape (2026-09-18, night)

The designer, in game: the deck is far too fine, worst towards the horizon,
and it costs the frame; and it reads as a noise pattern running through the
sky rather than as cloud, which wants flat bottoms and bulbous tops.

- **The deck is coarser.** 16-block cubes (from 8), two octaves (from
  three), 1/500 (from 1/600), towers 0.2 (from 0.35). Rendered in the
  engine's own screenshot harness at 960 x 540, the deck's cost over a bare
  sky fell from 0.65 to 0.30 ms looking at the horizon from the ground, and
  from 2.9 to 1.2 ms looking across the top of the deck from above it.
- **The shape is the engine's.** The field is a thresholded fbm read as a
  height map: the underside lifts where the field is weak, which is the
  stepped terracing, and the top rises linearly, which is plateaus. No
  field a mod can register makes a flat base or a dome. A prototype of the
  shader (`docs/reference/cloud-prototype-2026-09-18.patch`) draws round
  heaps over flat bases with a fake subsurface glow, pictured beside the
  current deck in `docs/reference/cloud-prototype-2026-09-18.png`. It is
  filed as ask W12 in the engine repo's `docs/engine-asks/tiamot_weather.md`.

### 10.7 Heaps (2026-09-19)

Engine 0d8e857 built W12: a cloud is a clump of heaps, each a hemisphere
over a flat base, with wrapped light and a fake subsurface glow on the thin
parts; the march coarsens as a ray goes and no longer walks the air over a
floating anvil. The deck's settings mean something new: `frequency` is the
heap spacing (0.42 / frequency, about 210 blocks at 1/500), `thickness` how
tall a heap grows (about a third to a half of it), `towers` a share of heaps
grown taller, and `octaves` no longer shapes anything.

The deck was left as it is. In the harness it draws separate round heaps
from below and round crowns from above (`docs/reference/clouds-heaps-2026-09-19.png`,
top row), for 0.02 to 0.43 ms over a bare sky, against 0.30 to 1.15 ms on
the old shader. Taller decks (thickness 280 to 320, towers 0.35, the lower
rows) grow more of a cumulus tower for 0.1 to 0.4 ms more; a choice of look
for the designer, not a fix.
