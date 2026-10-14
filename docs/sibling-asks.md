<!-- SPDX-FileCopyrightText: Iridesium -->
<!-- SPDX-License-Identifier: GPL-3.0-only -->

# Asks of the sibling mods

What Tiamat Weather needs from the OTHER mods beside the engine, as the
engine's `docs/engine-asks/tiamat_weather.md` holds what it needs from the
engine. Each says what was wanted, what stands in for it today, and the
smallest change that would answer it. Newest first. What the siblings asked
of Weather, and Weather's answers, are in `exports-contract.md`.

## Tiamat Default Craft

### Wx-C1. A chest another mod may fill (2026-10-12): ANSWERED 2026-10-14 (Craft 452d034)

**Answered.** Craft's `docs/exports.md` ("Containers") now says a chest's
container, `tiamat_default_craft:chest:x,y,z` (27 slots, `<domain>@` before
the position off the overworld), is a stable name another mod may fill, and
that a change to it will be said there and to every mod relying on it.
Nothing changes on this side: the wreck already fills it that way.

**Wanted.** A wreck at the end of a rainbow (`wreck.lua`) holds a little
gold and some loot in one of Craft's chests, so a player opens it with the
screen they already know.

**Standing in.** Weather sets down `tiamat_default_craft:chest` and fills
the container Craft opens for it, by the name Craft gives a chest's
container: `tiamat_default_craft:chest:x,y,z` (Craft's `stations.lua`,
`ST.name`), with `game.make_container` (make-if-absent) and
`game.container_give`. Craft names Weather in its `optional_depends`, so
Weather cannot read Craft's exports (the engine refuses the cycle); the name
is the whole contract.

**Smallest change.** Keep that name stable and say so where it is made — a
line in Craft's docs that a chest's container is
`tiamat_default_craft:chest:<x,y,z>` (with `<domain>@` before the position
off the overworld) and other mods may fill it. If it ever changes, tell
Weather, whose wrecks would otherwise come up with empty chests.
