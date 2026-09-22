# Engine asks from weather (2026-09-16)

> **New asks are filed in the engine repo, `docs/engine-asks/tiamat_weather.md`**
> (`../Tiamat/docs/engine-asks/` from here), where the engine agent reads
> every mod's asks. This file is the history of W1–W9. The two items
> deferred from W2, the cover map and cloud shadows, are open there as W10
> and W11. W12 (the deck's cost at the horizon, and heaps with flat bases,
> domed tops and a fake subsurface glow in place of a thresholded field) was
> filed there on 2026-09-18 and built in engine 0d8e857 the same night.
> W10, the cover map, was built in engine 8929ca1 (2026-09-20). W14, a fluid
> that does not wash plants away, was filed 2026-09-22.

These asks come out of the weather plan (`weather-plan.md`) for the
standalone `tiamat_weather` mod. **They are numbered W1–W9**, not in the
Spindle's `docs/engine-asks.md` sequence. They were first numbered 33–41 to
follow that file, and then the Spindle filed its own ask 33 (a chunk tint that
could not brighten, fixed in engine f219d6d). An engine commit citing "ask 33"
has to mean one thing. They use that file's
shape: what is seen, why the mod cannot fix it, and the smallest engine change
that would.

**One honest difference from the existing entries:** these were found by
*designing* against `api/stubs/game.lua`, not by building and measuring. Each
one says which parts are read from the stubs and which are assumptions. The
entries marked *confirm first* rest on behaviour the stubs do not spell out,
and should be checked headless before they are filed.

**Status, 2026-09-17 (evening): every ask but W2 is built.**

| Ask | Status |
|---|---|
| W1, the sky under weather | **Done**, `game.set_sky_modifier`. Storms darken the day, pull the fog in and drain the colour, per player, eased |
| W3, lightning | **Done**, `game.flash`. A strike is a flash, and its thunder is late by the distance |
| W4, particles per player and kept going | **Done**, `player` on `emit_particles` and `game.set_precipitation`. Rain is a shape the client spawns; only clouds are bursts now |
| W5, loops per player | **Done**. One loop per player, its gain moved rather than restarted |
| W6, the top of a column | **Done**, `game.surface_at`. The sampler's 48 reads a column are one call |
| W7, absorbing one fluid | **Done**, `absorbs = { fluid = ... }`. Weather does not use it yet: the block that would drink rainwater is the Spindle's dirt, so it is the Spindle's to declare (`docs/exports-contract.md`) |
| W8, fog and tint composition | **Done for composition** (every mod is asked, last non-nil wins, a faulted mod no longer silences the rest). `refresh_chunk_presentation` was declined, so chunk fog is still serve-time only; W1 covers the weather half |
| W9, exports between mods | **Done**, engine 482958a and 823aac3 |
| W2, clouds | **Done 2026-09-18** (engine 42368d5..55607e7): `register_clouds`, `set_clouds`, a raymarched cloud pass and a player cloud setting. Weather registers its deck and steers it per player |

Still open: the part of W8 that was declined, and the cover map deferred from W2.

Priority when filed, highest first: **W1, W4, W9, W6, W5, W3, W2, W7, W8.** W1 and W4
decide whether weather feels like weather at all. W9 removes the most fragile
part of the plan, the mirrored climate constants. W2 is the largest and can
wait.

---

## W1. The sky cannot change with the weather (2026-09-16)

A storm arrives under a noon sky. `game.register_sky` takes its keyframes
**in the registration window only**, and the client interpolates them from
the clock. After load, nothing a mod does can move `intensity`, `sky`, `sun`
or `grade`. Rain at full daylight with a blue horizon reads as a sprinkler,
not weather, and a blizzard should close the horizon in.

The mod cannot work round it:

- **Chunk fog** (`register_chunk_fog`) is asked when a chunk is served and
  never again, so it cannot follow a front across chunks the player already
  has. See 40.
- **Registering a darker sky** makes every day dark.
- **A HUD overlay** is 2D, on top of the world, and would grey out the
  interface too.

The smallest change is **a per-player modifier over the keyframes**, sent as
a small message and eased client-side like the keyframes already are:

```lua
game.set_sky_modifier(player, {
    intensity = 0.55,              -- multiplies the keyframe's intensity
    sky = { 0.55, 0.58, 0.62 },    -- lerp target for the horizon/fog colour
    sky_mix = 0.7,                 -- how far toward it, 0..1
    fog_distance = 0.6,            -- multiplies distance fog, <1 is closer
    grade = { saturation = 0.7 },  -- multiplies/offsets the keyframe grade (mode 3)
    ease_ticks = 400,              -- how long the client takes to get there
})
game.set_sky_modifier(player, nil) -- back to the plain sky, eased
```

It is presentation only and outside every determinism hash, like the
keyframes. It is per player rather than per domain because two players in
the same domain can stand under different weather. Scaling stored sunlight at
draw time, as `intensity` already does, keeps this free of relighting.

## W2. Clouds: a voxel cloud layer the client draws (revised 2026-09-18)

*Done 2026-09-18*, as a raymarch rather than a mesh: the client marches a ray
through a cloud field in one fullscreen pass, and the cubes are what it hits.
The API below survived unchanged. All four review amendments are in the
shader:

- two height ranges per column, so undersides step and heaps mushroom
- depth is written, so clouds sort against terrain both ways
- resolution is tied to the player's cloud setting (Off, Coarse, Normal, Fine)
- the sky gradient, sun glow and sun disc are drawn in the same pass

Deferred by agreement: the coarse cover map, and cloud shadows on the ground.
`base` is a number with a per-player override, not a density, and Weather
sends each player a floor that follows the dome under them.

**The target is two reference images** the designer supplied (kept with this
sheet as `docs/reference/clouds-1.webp` and `clouds-2.webp`): a golden-hour
sky full of **voxel cumulus**. Nothing a mod can send gets there. Particle
puffs were built as a stand-in (plan 5.1) and have been shown not to
converge: they are sprites at most 4 blocks across, drawn within 128 blocks,
and they read as specks, not cloud. This ask replaces them.

### What the references show, as requirements

1. **Clouds made of cubes, at two scales.** Each cloud is a mass of large
   cubes whose edges break into smaller cubes: a blocky cauliflower, not a
   smooth blob and not a flat slab. The large scale is the cloud's "cell";
   the small scale is detail on its surface only.
2. **Cumulus shape.** Flat bases at a common altitude, domed and heaped tops,
   and some towers much taller than they are wide (the central cloud in both
   images). Scattered small puffs of only a few cubes between the big masses.
   Layered, flatter banks further off.
3. **Lit by the sun, with self-shadow.** Faces toward the sun take the sun's
   colour, gold at this hour. Faces away and the undersides are shaded blue to
   violet, from the sky's own colour. The interior of a heap is darker than its
   rim, because cloud above and sunward of a cube shadows it. At low sun a
   bright rim runs along silhouettes near the sun.
4. **Aerial perspective.** Distant clouds fade toward the horizon colour and
   lose contrast. The near ones are crisp. The deck runs **to the horizon**,
   well past chunk view distance.
5. **Moving and changing.** They drift with a wind and evolve slowly, as the
   rest of the weather does.

### The ask

**One registration** (like the sky), **one per-player control** (like W1), and
**one client setting**:

```lua
game.register_clouds{                  -- registration window only
    base = 420,                        -- world y of the cloud base; or a density, see below
    thickness = 96,                    -- blocks from base to the tallest tower's top
    cell = 8,                          -- blocks per LARGE cube at full resolution
    detail = 2,                        -- small cubes per large-cube edge on the surface (1 = none)
    frequency = 1 / 600, octaves = 3,  -- the cloud field's horizontal scale
    towers = 0.25,                     -- how much taller the tallest heaps grow (0 = flat banks)
    drift = { x = 1.5, z = 0.4 },      -- blocks per second
    evolve = 1 / 2400,                 -- how fast the field changes shape, per second
    colour = { 1.0, 1.0, 1.0 },        -- lit cloud, before the sun's colour
    shade = { 0.42, 0.44, 0.58 },      -- the unlit side, before the sky's colour
}

game.set_clouds(player, {              -- latest state, sent when it changes, eased
    cover = 0.55,                      -- 0 = clear, 1 = overcast
    darkness = 0.0,                    -- 0 = fair-weather white, 1 = storm grey
    base = nil,                        -- optional override of the registered base
    ease_ticks = 600,
})
```

**The cloud field is the client's, and it does not need to be deterministic.**
Two players may see slightly different cauliflower. The server owns only
cover, darkness and the clock, so they see the same sky shape to within the
eased cover. The client may use fast, non-deterministic noise and whatever
drawing it likes.

**The shape, as a field, so a renderer can meet the references.** At column
(x, z), a 2-D noise `c` against `cover` decides whether there is cloud and
how thick. The base is flat. The top is `base + thickness * h(c)`, with
`towers` pushing the top of the highest values up. A 3-D detail noise at the
small-cube scale bites the surface, never the inside, which gives the
cauliflower edge. Cubes are quantised to `cell` and to `cell / detail`. That
is a suggestion; the requirements above are the contract.

**The client setting: cloud resolution.** A slider in the graphics settings,
the player's own choice like view distance. It scales `cell` (for example
0.5x, 1x, 2x, 4x of the registered value) and the cloud draw distance with
it: fine and near, or coarse and to the horizon. "Off" draws no clouds at
all. The server is never told.

**By lighting mode**, so mode 1 pays for nothing it cannot show:

| Mode | Clouds |
|---|---|
| 1 Simple | Cubes flat-shaded by face direction; one ambient |
| 2 Classic | Plus sun colour on sunward faces, sky colour on the rest, aerial perspective |
| 3 Beautiful | Plus self-shadow (cloud above and sunward darkens a cube), the low-sun rim, and cloud shadows on the ground if the cascades can take them |

**Reaching the horizon.** Past chunk view distance the clouds are all that is
drawn in the sky, so they need their own distance and their own LOD: big
cubes far away, the detail cubes only near. The references show cloud down to
the horizon line.

**Two weather details worth building in now:**

- **A storm on the horizon.** Per-player `cover` makes the whole sky one
  weather. A later extension is a coarse cover map, for example a 16 x 16 grid
  over 4 km sent on change, so a front seen from outside it is a wall of cloud
  over the next valley. Say whether this is in scope.
- **Rain under the cloud.** With `darkness` high, the base goes grey. That and
  W1's sky modifier together should make a storm read from a distance.

**Spindle-specific: the base on a dome.** The world is a dome falling 2.5 km
from axis to rim, so a fixed world y puts cloud in the ground near the
summit and kilometres up at the rim. Either `base` accepts a compiled density
(the client already has the density evaluator in core) and the mod passes one
that follows the dome, or `base` is relative: `above = 400`, measured from a
surface the client already knows (its LOD summaries). The first is more
general. The Spindle would export the dome density (a new field in its
exports contract).

### What Weather does once it lands

- `register_clouds` at load, with the Spindle's dome as the base when it is
  exported.
- `set_clouds(player, { cover, darkness })` from each evaluation, beside W1's
  sky modifier, from a cover per kind (clear 0.15, cloudy 0.55, rain 0.8,
  storm and blizzard 1.0).
- The particle clouds are deleted, and with them the only bursts the mod
  still emits.

### Acceptance

Standing at golden hour under `cover = 0.55` in mode 3, a screenshot should
be comparable with the references: blocky two-scale cumulus with flat bases,
sunlit gold tops, violet undersides, towers among flatter banks, and cloud
down to the horizon. Under `cover = 1, darkness = 1` the sky should be a low
grey ceiling.

## W3. Lightning cannot be seen (2026-09-16)

Thunder can be heard (`play_sound`) but not seen. Nothing in the API adds
light to a frame for a moment:

- `light_emit` is a block property. A lamp block placed and removed means two
  relights per strike.
- Particles are **lit by where they are**, so a white burst at night is a
  dim grey burst, which is the one time a flash matters.
- Ask W1's modifier eases, and a flash must not.

The ask is **a flash**:

```lua
game.flash{ pos = { x = ..., y = ..., z = ... }, radius = 256,   -- who sees it
            intensity = 1.0, colour = { 0.9, 0.92, 1.0 },
            attack_ticks = 1, decay_ticks = 6 }
```

It is a short additive term on sky and sun intensity for every player within
`radius`, applied client-side with no relight. That is the whole visible
effect of lightning at a distance. A visible bolt could be a later
`shape = "bolt"` option. A flash alone plus thunder delayed by distance is
already convincing.

## W4. Particles cannot be addressed to a player, or kept going (2026-09-16)

*Half done 2026-09-17:* `player` on `game.emit_particles` sends a burst to
one player. Weather's rain, haze and clouds are all per player now, which
gives each player the whole budget and makes the particles setting
per-player. An emitter that keeps going without a burst every few ticks is
still wanted.

Two separate problems with `game.emit_particles` for weather:

**(a) Every burst goes to everyone within `radius`.** A player who picked
"off" in the mod's own particle setting still gets a neighbour's rain, so the
setting is dishonest. It also forces the plan to emit per occupied 32-block
square, not per player, to avoid doubling.

**(b) Precipitation is continuous, and the API only has bursts.** Keeping
rain alive around a player means a burst of up to 256 every 3–5 ticks, per
square, for as long as the storm lasts. That is thousands of messages a
minute for something whose parameters change every forty seconds. The stubs
already say bursts are dropped when a connection falls behind, so under load
rain would stutter first.

The smallest change for (a) is **a `player` field on `emit_particles`** that
narrows recipients to one UUID. It is additive and is one filter in the send
loop.

The change that fixes (b) is **a per-player emitter the client runs**:

```lua
game.set_precipitation(player, {
    rate = 900,                                -- particles per second
    size = 0.06, colour = { r = 0.7, g = 0.75, b = 0.85, a = 0.55 },
    velocity = { x = 3, y = -22, z = 0 }, spread = 0.3, gravity = 0,
    lifetime = 1.0, area = { x = 16, y = 3, z = 16 }, above = 18,
    ease_ticks = 200,
})
game.set_precipitation(player, nil)
```

The client spawns around its own camera and occludes with the collision it
already runs for `collide = true`, so the server sends one message when the
weather changes, not a stream. The client can also honour a graphics setting
of its own, which a server-sent burst cannot.

## W5. A loop cannot be played to one player (2026-09-16)

`game.play_loop` has `everywhere = true`, which is exactly ambience, but it
has no listener. The stubs do not say who is told when `everywhere` is set.
**Confirm first:** if it is every connected player, one storm plays
server-wide. The plan works round it with one positioned loop per weather
square, at the square's centre with a 256-block radius. That pans wrongly
near the centre and doubles where squares meet.

The smallest change is **a `player` field on `play_loop` and `stop_loop`**,
meaning "everywhere, for this listener". It comes with **`fade_ticks`** on
both. Weather crossfades, and a loop that starts and stops at full gain
clicks. Being able to change `gain` on a running loop without restarting it
would let intensity ease smoothly. Today, replacing a running loop restarts
it from the beginning of the file.

## W6. The top of a column cannot be asked for (2026-09-16)

Snow has to land on the surface, and the API has no surface query at
runtime. `game.get_block` answers one block, so the weather sampler scans
down from above the player, up to 48 crossings into the VM per column. The
stubs name that exact pattern as the cost the opaque handles exist to avoid
(`Density:at`: "do not loop this").

`noise_heightmap` and `Density:at` describe the generated terrain, not
what players have built or dug since, so snow would fall onto a hill that
was quarried away.

The ask is **a bounded native scan**:

```lua
local top = game.surface_at{ x = 120, z = -40, from = 200, depth = 64,
                             skip_passable = true, skip_fluid = false }
-- -> { y = 71, material = <id>, occupancy = <mask> } | nil (unloaded, or nothing within depth)
```

One VM crossing per column. It never generates a chunk, in keeping with
`get_block`. **Confirm first** whether the sunlight pass already keeps a
per-column "highest opaque" that could answer this for free. If it does, the
whole ask is exposing it.

## W7. A block cannot choose which fluid it absorbs (2026-09-16)

Rain-wet ground is what `absorbs` was made for: `dirt` → `damp_dirt` from
fluid touching it. But `absorbs` names only a rate and a successor, not a
fluid. The same dirt that drinks a puddle would drink the rivers out of their
beds and the shelf sea through its floor, so the weather plan cannot use it
and swaps materials by hand instead.

The smallest change is an optional **`fluid`** on `absorbs`:

```lua
absorbs = { rate = 3, becomes = "damp_dirt", fluid = "tiamat_default_world:rainwater" }
```

If it is omitted, the block absorbs any fluid, as today.

**Answered 2026-09-16 (engine 62608bf): what happens where two different
fluids meet.** They never share a block, and a flow into a block of a
different fluid is refused. It is reported through `register_on_fluid_flow`
with `meets` naming the other fluid, beside it and straight down. So
rainwater neither merges into a river nor displaces it, and the weather mod
lets a puddle go when it hears the meeting (plan 5.10). The `fluid` field on
`absorbs` above is still wanted: without it, damp ground stays a material
swap by hand.

## W8. Fog and tint are fixed once a chunk is served (2026-09-16)

**Worse than first written (checked in the engine 2026-09-17).** Weather
cannot give *any* chunk fog on the Spindle, not even stale fog:

- `place_answer` in `mlua_vm.rs` returns the answer of the **first mod that
  registered a fog callback**, and an answer of `nil` counts. The Spindle
  registers one and loads first, so a weather mod's callback is never asked.
- On a newly generated chunk, the fog is asked in the **generation worker**
  (`worldgen.rs`), a VM with no tick. The weather clock and any `/weather set`
  are not there.

So the ask grows. A fog that changes needs a per-player or per-area fog a mod
can set from its tick (the `refresh` below, or a `game.set_fog(player, ...)`
beside `set_hud`), **and** a way for two mods' fogs to combine, for example
denser wins. Until then the weather mod draws storm haze with particles.

`register_chunk_fog` and `register_chunk_tint` are "asked every time a chunk
is served, and never stored". A change only reaches a player through chunks
they have not loaded yet. Storm mist, a whiteout, or ground darkening as it
rains therefore appears at the edge of view distance and never where the
player is standing.

The smallest change is **a way to ask again**:

```lua
game.refresh_chunk_presentation{ min = { x = ..., z = ... }, max = { x = ..., z = ... },
                                  fog = true, tint = false }
```

It re-asks the callbacks for loaded chunk columns in the area and sends
only the changed values. The engine already blends per column, so a
refreshed front fades in over a chunk's width rather than snapping. It should
be rate-limited per call (for example, one area of at most 32 × 32 chunks
every 100 ticks), because every refresh is one callback per column. Ask W1
covers the player-centred part of weather. This covers weather seen from a
distance: the storm over the next valley.

---

## W9. A mod cannot read what another mod exports (2026-09-16)

*Done 2026-09-17* (engine 482958a, `game.export` and `game.exports`). Weather
reads the Spindle's `humidity`, `HUMIDITY_SPLIT`, `climate`, `biome_under`,
`add_soil_alias` and `add_harmless_fluid` when they are exported, and falls
back to its mirror when they are not. The contract is `docs/exports-contract.md`.

The weather mod needs the Spindle's climate: its humidity field, where its
rings are, and which biome a player is standing in. Each mod runs in a fresh
sandbox environment (`build_environment` in `mlua_vm.rs`), and
`game.storage` is private per mod, so none of `tdw.*` can be reached. The
weather mod keeps weather out of the Spindle for isolation, since a tick error
disables the whole mod. That leaves it **copying** the Spindle's constants and
rebuilding `M.humidity()` by hand.

The copy works today only because a noise stream is hashed from its name
alone (`fnv1a(stream)`), so the same name and parameters give the same field.
It is still a copy:

- When the Spindle retunes `HUMIDITY_FREQ`, the weather goes quietly wrong.
  The only guards are a version pin and a drift check that reads the ground.
- `tdw.biome_under` is ~50 lines of special cases the weather mod
  approximates with a smaller table.
- The same will happen to every mod that wants to know about a world: mobs
  that spawn by biome, seasons, a map.

`depends` and `optional_depends` already make load order a contract, so a
mod can know another mod is present and loaded first. What is missing is a
channel for more than block ids.

The smallest change is **a read-only export table per mod**, set during
registration and readable by mods that list the exporter as a dependency:

```lua
-- in tiamat_default_world, during init.lua
game.export{
    humidity = M.humidity_program,          -- a compiled Tiamat.Density handle
    biome_under = tdw.biome_under,          -- a function
    version = 1,
}

-- in tiamat_weather, which lists it in depends or optional_depends
local spindle = game.exports("tiamat_default_world")   -- nil if absent or not a dependency
if spindle then
    local wet = spindle.humidity:at(x, 0, z, game.world_seed)
end
```

Rules that keep it inside the charter:

- **Frozen with the registries.** `export` works in the registration window
  only, and the table is deep-frozen (read-only proxies), so one mod cannot
  mutate another's state.
- **Only for declared dependencies.** A mod may read the exports of mods in
  its `depends` or `optional_depends` and nothing else, so load order always
  guarantees the table exists when read.
- **Functions run in the exporter's sandbox and error budget.** An error
  inside `biome_under` is the Spindle's error, attributed to the Spindle.
  *Open question for the engine:* whether an error called through from
  another mod should disable the exporter, the caller, or only fail the call.
  "Only fail the call" is what keeps one mod's crash from spreading, which is
  the reason the weather mod is separate in the first place.
- **Handles pass through as they are.** A density program, a map or a
  schematic handle is already opaque and native, so exporting one gives
  nothing that could break determinism.

With it, the weather mod's `climate_spindle.lua` shrinks to a few lines and
the drift check disappears.

---

### Not asked for, on purpose

- **A weather system in the engine.** What rain is, where it falls, and
  whether a desert has any is world content (charter rule 1). Every ask above
  is a mechanism a weather mod needs, and each is also useful without one:
  W1 and W3 for a boss arena or an eclipse, W4 for a waterfall's spray, W6 for
  anything placed on the ground at runtime, W7 for a sponge, W8 for seasons,
  and W9 for any mod that builds on a world mod.
- **A time operation in density programs.** Passing the clock as the `y`
  argument of `Density:at` already makes a field morph over time.
- **Randomness outside a generator.** Checked in the source (2026-09-16):
  `game.rng_stream` accepts any `{ x, y, z, seed }` table at runtime, so a
  weather mod can key a stream on its square and the tick.
