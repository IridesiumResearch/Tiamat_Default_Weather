# Exports between Weather, the Spindle and Life (2026-09-17)

Engine 482958a added `game.export` and `game.exports`: one table a mod
publishes, readable by the mods that name it in `depends` or
`optional_depends`. This page is the contract Weather reads and offers. Every
field is optional. Weather checks what it is given, and a missing field means
the old behaviour, not an error.

## The fault rules (engine), for everyone writing against this

- A function called through an export runs in its **owner's** sandbox. If it
  errors, the owner is disabled, the call answers `nil`, and the caller
  carries on.
- A callback passed **into** an export runs in the sandbox that wrote it. If it
  errors when the owner calls it, the **caller** is disabled and the owner
  gets `nil`.
- Everything crossing is read-only. Writing into another mod's exports is an
  error, and tables hand out read-only tables. `pairs` and `#` work.
- `game.exports(id)` is `nil` for absent, undeclared, exported-nothing, or
  disabled, so there is one case to handle.

What follows for a mod that exports: **an exported function must not error
on a bad argument**, because the error disables the exporter. Check types,
and answer `nil`.

---

**Status 2026-09-17:** the Spindle implements version 1 in full
(`mods/tiamat_default_world/exports.lua`), and Weather reads it. Loading both
in one engine logs `humidity exported, warmth exported, biomes exported; damp
ground on, puddles on`. Life has not adopted Weather's side yet.

**Status 2026-09-23:** Weather's side grew fire (`fire_at`, `flammable`,
`ignite`, `extinguish`, `fires`, `on_lightning`), version 1 still, and the
Spindle's `add_soil_alias` is called once more, for scorched ground. Life is
asked for two unlocks of its own (the last section) and exports nothing yet.

## What the Spindle can export for Weather (`tiamat_default_world`)

Weather already names the Spindle in `optional_depends`, so nothing changes
on Weather's side. Export any subset, in `init.lua`'s registration window:

```lua
game.export{
    version = 1,

    -- Climate. With these, Weather stops mirroring shape.lua's constants.
    humidity = <compiled density>,        -- the humidity noise, +/-0.5 (shape.humidity(), no dither)
    HUMIDITY_SPLIT = -0.05,               -- the wet/dry line, in the humidity's units
    climate = function(x, z) ... end,     -- number 0..1: the ring temperature T = 4t(1-t) at the dome
    biome_under = function(x, y, z) ... end,  -- the biome id there ("dunes", "volcanic_foothills"...), or nil

    -- Unlocks. Weather CALLS these once at load; answer `true` if taken.
    add_soil_alias = function(block, dry) ... end,
    add_harmless_fluid = function(fluid) ... end,
}
```

**`add_soil_alias(block, dry)`** is called with
`("tiamat_weather:damp_dirt", "tiamat_default_world:dirt")`, and the same for
`damp_packed_dirt` and `damp_sand`. It asks the Spindle to treat `block` as
`dry` wherever it compares materials: `tdw.soil_under`, the `OWNER` table in
`whereami.lua`, and the `.soil` checks (plan 5.5 has the list). Resolve the id
lazily on first use, because the damp blocks register after the Spindle loads.
If every call answers `true`, **Weather turns damp ground on**. The alpine's
random tick registered on `dirt` cannot be extended to a block registered
later, and that cost is accepted.

**Since 2026-09-23 it is also called with
`("tiamat_weather:scorched_ground", "tiamat_default_world:dirt")`**, once, at
load, so the black patch a field fire leaves counts as dirt while it heals
and the Spindle's grass regrows over it. The same lazy resolution serves:
scorched ground registers after the Spindle too. Its answer is logged and
gates nothing — fire is on without it, and the patch heals to dirt by its own
random tick either way (plan 5.12).

**`add_harmless_fluid(fluid)`** is called with `"tiamat_weather:rainwater"`.
Since engine 2f9b036 the fluid itself declares `washes = false`, so a mod
that has moved its plants to the engine's `washes_away` needs no list from
anybody: rain cannot sweep them.
It asks the leaves rule in `rules.lua` not to remove leaves this fluid presses
on, and the lava rule not to quench against it. Weather already handles
rainwater meeting lava as steam. If it answers `true`, **Weather turns
puddles on**.

**Optional, and new with engine ask W7:** the Spindle may now declare
`absorbs = { rate = 3, becomes = "tiamat_weather:damp_dirt", fluid =
"tiamat_weather:rainwater" }` on its dirt and sand. Named, the block drinks
that fluid alone, so it wets in the rain without draining the rivers — the
thing `absorbs` could not do when the plan was written. That would replace
Weather's material swap for damp ground with the engine's own. Weather does
not need it: if it lands, `config.damp_ground = false` and the ground still
wets. The fluid is resolved at freeze, so naming it is safe even though
Weather registers it later.

**Wanted for clouds (optional):** `dome_y(x, z)`, a function answering the
base dome's world y there. Weather sends each player a cloud floor 400 blocks
over the ground under them, and reads the ground from this when it is
exported, and from its mirrored dome formula when it is not. Version 1 stays
valid without it; it matters only if the dome is ever reshaped.

`biome_under` replaces Weather's ground-material guesses for ash (the Ember
Ridge's four biomes) and dust (dunes, salt pan, arid mesa, badlands).

Checked in `tests/native`:

- with all of it, Weather reads the humidity, climate and biome, and both
  unlocks turn on
- with none of it, Weather uses its mirror and both stay off
- with a `climate` that errors, the Spindle is disabled and Weather carries on,
  on its mirror

## What Weather exports (`tiamat_weather`)

A mod that adds `tiamat_weather` to its `optional_depends` can read:

```lua
local wx = game.exports("tiamat_weather")     -- nil if Weather is absent or disabled
if wx then
    wx.version                   -- 1
    wx.climate                   -- "spindle" | "plain"
    wx.kinds                     -- kind -> { family, precip, label }
    wx.weather_at(x, y, z)       -- kind, intensity, mega (permille): what a player there sees
    wx.weather_for(player)       -- kind, intensity, label, mega, at that player (UUID)
                                 -- mega: how far into a mega storm, 0..1000 (2026-09-19;
                                 -- a trailing value, so older callers are unaffected)
    wx.falling_on(player)        -- "rain" | "snow" | "ash" | "dust", only under open sky; nil otherwise
    wx.warmth(x, y, z)           -- 0..1000
    wx.freezing(x, y, z)         -- boolean

    -- Fire (2026-09-23). Block coordinates; fractions are floored.
    wx.fire_at(x, y, z)          -- boolean: is that block alight
    wx.flammable(x, y, z)        -- boolean: is it fuel (and holding no fluid)
    wx.ignite(x, y, z)           -- boolean: light it, under the natural rules
    wx.extinguish(x, y, z)       -- boolean: put that block out
    wx.fires()                   -- blocks alight, blazes alight
    wx.on_lightning(fn)          -- boolean: fn(x, y, z) after every bolt, grounded or not
end
```

Every function checks its arguments and runs under a `pcall`, so a bad call
answers `nil` and neither mod is disabled. Kinds are `clear`, `cloudy`,
`rain`, `storm`, `snow`, `blizzard`, `ash`, `ash_storm` and `dust`. Families
are `dry`, `rain`, `snow`, `ash` and `dust`.

**`ignite` is a natural ignition, not a command.** It obeys every cap
(`FIRE_MAX_BLAZES`, `FIRE_MAX_BURNING`, a blaze's own block count and
radius), the square's rest after a blaze and the spacing from a live one, and
rolls no odds of its own: what your mod asks to burn, burns, if the world
allows a fire there now. `false` is any of "off in this world", "no fuel",
"cap", "resting" or "already alight"; the reason is not exported. Only `/weather fire` skips
the rest and the spacing, and nothing skips the caps (plan 5.12).

**`on_lightning(fn)`** calls `fn(x, y, z)` with the block the flash was
centred on, after the flash, for every bolt: the block over the ground it
struck, or — when no column under the bolt answered (unloaded, or nothing
within 128 blocks) — `STRIKE_ABOVE` (40) blocks over the player, a point in
the air with nothing under it. Check the ground yourself if a bolt in the
air should not count. It is a callback passed
in, so it runs in **your** sandbox: a fault in it disables your mod, not
Weather, and Weather logs it once and goes on. Register once, at load.

**For Life (`tiamat_default_life`):** `falling_on(player)` is "is this person
getting wet", and `warmth` or `freezing` is weather's cold. Both fit the
thermometer and the weather shield. `on_lightning` is how Life hurts whoever
stands beside a strike; what a bolt does to a body is Life's to write.

**Life reads Weather, not the other way round.** Weather does NOT name Life
in its `optional_depends`: the engine refuses a dependency cycle at load,
optional edges included, and the direction worth keeping is Life's — the
thermometer wants `falling_on` and `warmth`, and fire wants Life to know one
block's name. So Life adds `optional_depends = ["tiamat_weather >=0.1"]`, as
the 2026-09-17 note said, loads after Weather, and finds every Weather block
registered by the time it resolves its own tables.

## What Life adds for fire (`tiamat_default_life`)

Life keys `C.contact_fire` and `C.heat_sources` on material NAMES
(`config.lua`, about lines 206–214) and resolves them at load. With Weather
in its `optional_depends`, Weather has loaded first and `tiamat_weather:fire`
exists, so the whole change is two rows and the dependency:

```lua
-- config.lua
C.contact_fire["tiamat_weather:fire"] = { damage = 1, ticks = 20, after = 40 }
C.heat_sources["tiamat_weather:fire"] = 1.0
```

Standing in a burning block then takes `damage` every `ticks` ticks and
burns for `after` ticks once out of it, the three fields Life's rows carry
for magma and the campfire; and a fire warms whoever stands near it as the
campfire does. Life already resolves every id in those tables with `pcall`,
so a world without Weather still loads it.

Until this lands, **fire hurts nobody**. Weather says so in its plan (10.14)
and README. Nothing on Weather's side waits for it: the block is registered,
named and stable.
