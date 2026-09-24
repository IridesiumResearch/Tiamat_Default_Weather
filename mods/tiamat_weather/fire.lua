-- SPDX-FileCopyrightText: Iridesium
-- SPDX-License-Identifier: GPL-3.0-only
--
-- Fire (plan 5.12): what lightning and lava start, what it spreads to, and
-- what puts it out.
--
-- **"Not out of control" is the first requirement.** A FIRE is one block of
-- fuel replaced by `tiamat_weather:fire` for the fuel's burn time and then
-- by what the fuel leaves: air for leaves and plants, a charred log for a
-- trunk, and scorched turf under a burnt plant. A BLAZE is one ignition and
-- everything it spread to, and every blaze is capped three ways: in the
-- blocks it may ever light, in how far from its origin it may reach, and in
-- how long it may spread at all before it only burns down. The world is
-- capped twice more, in blazes alight at once and in blocks alight at once.
-- A square that had a blaze rests for a day before a natural one may start
-- there, and no natural blaze starts near a live one. Rain and snow put a
-- fire under the sky out. A fire dug or flooded is heard, not fought.
--
-- **Fire drives itself from this mod's tick**, not from random ticks:
-- `register_random_tick` is keyed by MATERIAL across every mod, and the
-- Spindle already ticks its grass and its ivy. The random ticks on this
-- mod's own fire and scorched ground are safety nets only: a fire block
-- nobody here lit (a restart with lost storage, one an operator placed)
-- goes out, and scorched ground heals.
--
-- **Everything is re-derived from the world.** `game.set_block` answers
-- "accepted", not "landed", so each fire is verified with one `get_block`
-- every turn: an edit not seen after FIRE_CONFIRM_TICKS is given up, a fire
-- that has gone from the world is forgotten, and a residue that never
-- landed is pushed again. Edits go through wx.queue in groups of at most
-- BATCH_CHUNKS chunks, because `queue.commit()` clips anything past that.
--
-- Every float operation here is + - * /, math.floor/min/max/abs or a
-- Density:at read through the climate, and every draw is a game.rng_stream
-- keyed by a blaze's origin and the tick, so two servers burn the same wood
-- the same way.

local config = wx.config
local climate = wx.climate
local blocks = wx.blocks
local controller = wx.controller
local queue = wx.queue

local M = {}

M.FIRE, M.CHARRED, M.SCORCHED = blocks.FIRE, blocks.CHARRED, blocks.SCORCHED
M.fire_id = blocks.fire_id

local FIRE = blocks.FIRE
local FIRE_ID = blocks.fire_id
local SCORCHED_ID = blocks.scorched_id
local AIR = "engine:air"
local FULL = game.OCCUPANCY_FULL
local CHUNK = 16
local Y_WRAP = 1 << 30          -- rng_stream takes y as a 32-bit integer
local floor = math.floor

-- ------------------------------------------------------------ the switch

-- "auto" is the world's choice. `world_option` answers nil for an id no
-- loaded mod declares (an engine older than world options, a rig that set
-- none), and nil is ON: the option exists to turn fire OFF.
local function resolve(value)
    if value == "auto" then
        local chosen = nil
        if type(game.world_option) == "function" then
            chosen = game.world_option("tiamat_weather:fires")
        end
        return chosen ~= false
    end
    return value == true
end
M.enabled = resolve(config.fires)

M.stats = {
    ignited = 0, spread = 0, burnt = 0, doused = 0, gone = 0, scorched = 0, blazes = 0,
    ended = 0, lightning = 0, lava = 0, refused_off = 0, refused_fuel = 0, refused_cap = 0,
    refused_rest = 0, refused_wet = 0, orphans = 0, healed = 0, edits = 0, no_room = 0,
}
local stats = M.stats

-- ------------------------------------------------------------ state

-- id -> { id, ox, oy, oz, kind, born, ignited, reason, fires = { [key] = fire }, list = { fire, ... } }
-- Each fire: { x, y, z, born, burn, residue, kind, state, blaze, pending?, pushed? }, state
-- "catching" (edit pushed, not yet seen) -> "burning" (seen) -> "dying" (residue pushed).
local blazes = {}
-- The live ids, ascending. Every walk over the blazes is in this order, and
-- every walk over a blaze's fires is in `list` order: the rng is drawn as
-- they are visited, so the order is part of the result.
local order = {}
-- key -> fire, across every blaze: what burning_at, count and spread ask.
local fires = {}
local count = 0
-- square key -> the tick a blaze there last ended
local rest = {}
local next_id = 1
local loaded = false
local dirty = false

local function key_of(x, y, z)
    return x .. "," .. y .. "," .. z
end

-- Chunks are 16 on every axis, and the queue groups by all three.
local function chunk_of(p)
    return (p.x // CHUNK) .. ":" .. (p.y // CHUNK) .. ":" .. (p.z // CHUNK)
end

-- Integer block coordinates, whatever a caller handed in: a float key
-- ("12.0") would never match an integer one ("12").
local function block_pos(pos)
    return { x = floor(pos.x), y = floor(pos.y), z = floor(pos.z) }
end

local function cheb(dx, dz)
    return math.max(math.abs(dx), math.abs(dz))
end

local function cap_of(blaze)
    return blaze.kind == "field" and config.FIRE_FIELD_BLOCKS or config.FIRE_FOREST_BLOCKS
end

local function radius_of(blaze)
    return blaze.kind == "field" and config.FIRE_FIELD_RADIUS or config.FIRE_FOREST_RADIUS
end

local function square_key(x, z)
    return controller.key_of(controller.square_of(x, z))
end

local function rebuild_order()
    order = {}
    for id in pairs(blazes) do
        order[#order + 1] = id
    end
    table.sort(order)
end

-- What a caller may hold: a fresh copy, with the blaze's extent.
local function summary(blaze)
    local min = { x = blaze.ox, y = blaze.oy, z = blaze.oz }
    local max = { x = blaze.ox, y = blaze.oy, z = blaze.oz }
    for _, f in ipairs(blaze.list) do
        min.x, min.y, min.z = math.min(min.x, f.x), math.min(min.y, f.y), math.min(min.z, f.z)
        max.x, max.y, max.z = math.max(max.x, f.x), math.max(max.y, f.y), math.max(max.z, f.z)
    end
    return {
        id = blaze.id, x = blaze.ox, y = blaze.oy, z = blaze.oz, kind = blaze.kind, born = blaze.born,
        ignited = blaze.ignited, count = #blaze.list, reason = blaze.reason, min = min, max = max,
    }
end

-- ------------------------------------------------------------ listeners

local listeners = {}
local warned = {}

-- fn(event): event.kind is "blaze_start" | "blaze_end" | "ignite" | "burnt" |
-- "doused" | "gone" | "scorched"; event.pos the block; event.blaze the
-- blaze's summary (nil for a scorch mark lightning left).
function M.on_change(fn)
    listeners[#listeners + 1] = fn
end

-- A listener is presentation; a fault in one is logged once, and the fire
-- goes on burning.
local function emit(kind, pos, blaze)
    if #listeners == 0 then
        return
    end
    local event = { kind = kind, pos = pos, blaze = blaze }
    for i, fn in ipairs(listeners) do
        local ok, err = pcall(fn, event)
        if not ok and not warned[i] then
            warned[i] = true
            game.log("tiamat_weather: a fire listener failed on " .. kind .. ": " .. tostring(err))
        end
    end
end

-- ------------------------------------------------------------ fuel

-- A residue naming nothing registered would be an edit the engine refuses,
-- and one refusal backs the whole queue off; such fuel is dropped at load
-- and named, rather than found out on the first blaze.
for id, fuel in pairs(climate.fuel) do
    if fuel.residue ~= AIR then
        local ok, n = pcall(game.get_block_id, fuel.residue)
        if not (ok and n ~= nil) then
            game.log("tiamat_weather: fuel " .. tostring(game.block_of(id)) .. " leaves unknown block "
                .. tostring(fuel.residue) .. "; it will not burn")
            climate.fuel[id] = nil
        end
    end
end

-- Weather's damp ground, by numeric id: wet ground does not carry a field fire.
local damp = {}
for _, id in ipairs(blocks.damp_ids) do
    local ok, n = pcall(game.get_block_id, id)
    if ok and n ~= nil then
        damp[n] = true
    end
end

-- The fuel table for the block at pos, or nil. A block holding any fluid is
-- never fuel (reeds in water, a flooded tuft); a partial block (ivy cells,
-- a chiselled log) is, if its material is.
function M.fuel_at(pos)
    local p = block_pos(pos)
    local b = game.get_block(p)
    if b == nil or b.material == nil or b.occupancy == 0 then
        return nil
    end
    local fuel = climate.fuel[b.material]
    if fuel == nil then
        return nil
    end
    local held = game.get_fluid(p)
    if held ~= nil and not held.empty then
        return nil
    end
    return fuel
end

-- ------------------------------------------------------------ fires and blazes

local function add_fire(blaze, x, y, z, fuel, state)
    local fire = {
        x = x, y = y, z = z, born = wx.now, burn = fuel.burn, residue = fuel.residue,
        kind = fuel.kind, state = state or "catching", blaze = blaze,
    }
    local key = key_of(x, y, z)
    fires[key] = fire
    blaze.fires[key] = fire
    blaze.list[#blaze.list + 1] = fire
    count = count + 1
    dirty = true
    return fire
end

-- A NEW list rather than a hole: a turn walks `list` with ipairs while it
-- removes, and ipairs keeps the table it was given.
local function remove_fire(blaze, fire)
    local key = key_of(fire.x, fire.y, fire.z)
    if blaze.fires[key] ~= fire then
        return
    end
    blaze.fires[key] = nil
    fires[key] = nil
    local kept = {}
    for _, f in ipairs(blaze.list) do
        if f ~= fire then
            kept[#kept + 1] = f
        end
    end
    blaze.list = kept
    count = count - 1
    dirty = true
end

-- ------------------------------------------------------------ persistence

-- fire:next, fire:blaze:<id> = "kind,ox,oy,oz,born,ignited,reason",
-- fire:fires:<id> = "x,y,z,born,burn,residue,kind,state;...", fire:rest:<cx>:<cz> = tick.
-- Strings, never numeric ids (charter rule 8): a residue is its block's name.
local BLAZE_LINE = "^(%a+),(%-?%d+),(%-?%d+),(%-?%d+),(%-?%d+),(%d+),(%a+)$"
local FIRE_LINE = "^(%-?%d+),(%-?%d+),(%-?%d+),(%-?%d+),(%d+),([%w_:]+),(%a+),(%a+)$"

local function blaze_key(id)
    return "fire:blaze:" .. id
end

local function fires_key(id)
    return "fire:fires:" .. id
end

local function forget_keys(id)
    game.storage.set(blaze_key(id), nil)
    game.storage.set(fires_key(id), nil)
end

local function save_blaze(blaze)
    game.storage.set(blaze_key(blaze.id), string.format("%s,%d,%d,%d,%d,%d,%s",
        blaze.kind, blaze.ox, blaze.oy, blaze.oz, blaze.born, blaze.ignited, blaze.reason))
    local parts = {}
    for _, f in ipairs(blaze.list) do
        parts[#parts + 1] = string.format("%d,%d,%d,%d,%d,%s,%s,%s",
            f.x, f.y, f.z, f.born, f.burn, f.residue, f.kind, f.state)
    end
    game.storage.set(fires_key(blaze.id), table.concat(parts, ";"))
end

local function save()
    if not dirty then
        return
    end
    dirty = false
    game.storage.set("fire:next", next_id)
    for _, id in ipairs(order) do
        save_blaze(blazes[id])
    end
end

-- Once, on the first turn after the controller has restored the clock: a
-- fire's age is measured against wx.now. A stored `catching` fire that has
-- since landed becomes `burning` on its first verify; a `dying` one whose
-- residue never landed is pushed again (`pushed` is not stored, so nil).
local function load()
    loaded = true
    local saved_next = game.storage.get("fire:next")
    if type(saved_next) == "number" then
        next_id = floor(saved_next)
    end
    local highest = 0
    for _, key in ipairs(game.storage.keys()) do
        local id = string.match(key, "^fire:blaze:(%d+)$")
        if id then
            id = tonumber(id)
            local kind, ox, oy, oz, born, ignited, reason = string.match(tostring(game.storage.get(key)), BLAZE_LINE)
            local blaze = nil
            if (kind == "forest" or kind == "field") and blazes[id] == nil then
                blaze = {
                    id = id, ox = tonumber(ox), oy = tonumber(oy), oz = tonumber(oz), kind = kind,
                    born = tonumber(born), ignited = tonumber(ignited), reason = reason, fires = {}, list = {},
                }
                for line in string.gmatch(tostring(game.storage.get(fires_key(id)) or ""), "[^;]+") do
                    local x, y, z, fborn, burn, residue, fkind, state = string.match(line, FIRE_LINE)
                    if x and (state == "catching" or state == "burning" or state == "dying") then
                        x, y, z = tonumber(x), tonumber(y), tonumber(z)
                        if fires[key_of(x, y, z)] == nil then
                            local fire = add_fire(blaze, x, y, z,
                                { burn = tonumber(burn), residue = residue, kind = fkind }, state)
                            fire.born = tonumber(fborn)
                        end
                    end
                end
            end
            if blaze ~= nil and #blaze.list > 0 then
                blazes[id] = blaze
                if id > highest then
                    highest = id
                end
            else
                forget_keys(id)
            end
        end
        local cx, cz = string.match(key, "^fire:rest:(%-?%d+):(%-?%d+)$")
        if cx then
            local at = game.storage.get(key)
            if type(at) == "number" and wx.now - at < config.FIRE_REST_TICKS then
                rest[cx .. ":" .. cz] = at
            else
                game.storage.set(key, nil)
            end
        end
    end
    if next_id <= highest then
        next_id = highest + 1
    end
    rebuild_order()
    dirty = false
    if #order > 0 then
        game.log(string.format("tiamat_weather: %d blaze(s) still alight, %d blocks", #order, count))
    end
end

local function ensure_loaded()
    if not loaded and game.world_seed ~= nil and controller.ready() then
        load()
    end
end

local function end_blaze(blaze)
    blazes[blaze.id] = nil
    rebuild_order()
    forget_keys(blaze.id)
    local skey = square_key(blaze.ox, blaze.oz)
    rest[skey] = wx.now
    game.storage.set("fire:rest:" .. skey, wx.now)
    stats.ended = stats.ended + 1
    dirty = true
    emit("blaze_end", { x = blaze.ox, y = blaze.oy, z = blaze.oz }, summary(blaze))
end

-- ------------------------------------------------------------ edits

-- An edit is { pos, block, apply }: `apply` runs only once the edit has been
-- handed to the queue, so a transition nobody could push is a transition
-- that did not happen, and is tried again next turn. Committed in groups of
-- BATCH_CHUNKS chunks, since the queue clips a batch past that, and never
-- more than `budget` in all. Returns the budget left and whether everything
-- went.
local function commit(edits, budget)
    if #edits == 0 then
        return budget, true
    end
    local groups, chunks = {}, {}
    for _, e in ipairs(edits) do
        local ck = chunk_of(e.pos)
        if groups[ck] == nil then
            groups[ck] = {}
            chunks[#chunks + 1] = ck
        end
        local g = groups[ck]
        g[#g + 1] = e
    end
    local per = config.BATCH_CHUNKS
    for first = 1, #chunks, per do
        if budget <= 0 or not queue.room() then
            stats.no_room = stats.no_room + 1
            return budget, false
        end
        queue.begin()
        local pushed = {}
        for i = first, math.min(first + per - 1, #chunks) do
            for _, e in ipairs(groups[chunks[i]]) do
                if budget > 0 then
                    queue.push(e.pos, e.block, nil)
                    pushed[#pushed + 1] = e
                    budget = budget - 1
                end
            end
        end
        if not queue.commit() then
            stats.no_room = stats.no_room + 1
            return budget, false
        end
        stats.edits = stats.edits + #pushed
        for _, e in ipairs(pushed) do
            e.apply()
        end
    end
    return budget, true
end

-- ------------------------------------------------------------ the turn

-- The 26 neighbours, diagonals included: a field fire jumps a one-block gap.
local OFFSETS = {}
for dy = -1, 1 do
    for dz = -1, 1 do
        for dx = -1, 1 do
            if dx ~= 0 or dy ~= 0 or dz ~= 0 then
                OFFSETS[#OFFSETS + 1] = { dx, dy, dz }
            end
        end
    end
end

local function clamp(v, lo, hi)
    return math.min(hi, math.max(lo, v))
end

-- How wet it is over a blaze, in permille: the eased weather of the square
-- somebody is standing in, else the function itself. Snow douses like
-- rain; ash and dust do not.
local function wetness(blaze)
    local kind, intensity
    local square = controller.squares[square_key(blaze.ox, blaze.oz)]
    if square ~= nil and square.kind ~= nil then
        kind, intensity = square.kind, square.intensity
    else
        kind, intensity = controller.weather(blaze.ox, blaze.oy, blaze.oz, wx.now, nil)
    end
    local k = controller.KINDS[kind]
    if k ~= nil and k.precip and (k.family == "rain" or k.family == "snow") and intensity > 0 then
        return intensity
    end
    return 0
end

-- Whether rain reaches a fire: the sun at its block or, since an occupied
-- block may hold no light of its own in the engine's store, at the air over
-- it. A canopy dims either a little (leaves shade); a roof takes both to 0,
-- and so does being underground.
local function exposed(pos)
    local sun = game.get_light(pos).sun
    if sun == 0 then
        sun = game.get_light{ x = pos.x, y = pos.y + 1, z = pos.z }.sun
    end
    return sun >= config.FIRE_EXPOSED_SUN
end

-- One blaze's turn. `shared` is the turn's: candidates already claimed, and
-- spreads reserved against the world cap before their edits land.
local function turn_blaze(blaze, budget, shared)
    local ox, oy, oz = blaze.ox, blaze.oy, blaze.oz
    local now = wx.now
    local rng = game.rng_stream({ x = ox, y = now % Y_WRAP, z = oz, seed = game.world_seed }, "wx_fire")
    -- Weather and climate once per blaze per turn, at the origin: the noise
    -- reads are the cost, and per fire there would be a hundred of them.
    local wet = wetness(blaze)
    local dryness = clamp(0.6 - climate.moisture(ox, oy, oz) * 1.2, 0.1, 1.0)
    local heat = clamp(0.3 + climate.warmth(ox, oy, oz) * 0.0007, 0.3, 1.0)
    if climate.freezing(ox, oy, oz) then
        heat = heat * 0.5
    end
    local radius, cap = radius_of(blaze), cap_of(blaze)
    local spreading = now - blaze.born < config.FIRE_BLAZE_TICKS
    local lit = 0                    -- spreads this turn, against the blaze's cap
    local edits = {}

    for _, fire in ipairs(blaze.list) do
        local pos = { x = fire.x, y = fire.y, z = fire.z }
        local b = game.get_block(pos)
        if b == nil then
            -- Unloaded: nothing to see and nothing to do, and it burns on
            -- when somebody is back — unless it would have burnt out by now
            -- had anyone been watching, in which case it is forgotten. Left
            -- as it was, a blaze whose chunk nobody revisits (lightning
            -- lands STRIKE_REACH from a player who then walks off, or a
            -- restart with the player elsewhere) would hold one of the
            -- FIRE_MAX_BLAZES slots, its blocks and FIRE_APART round its
            -- origin for ever, and four of them would end fire world-wide
            -- with nothing able to recover it: `/weather fire out` marks
            -- them dying, and the next turn reads nil again. The block left
            -- in the chunk is an orphan, which its random tick clears when
            -- the chunk is next loaded.
            if now - fire.born > fire.burn + config.FIRE_CONFIRM_TICKS then
                remove_fire(blaze, fire)
                stats.gone = stats.gone + 1
            end
        elseif fire.state == "catching" then
            if fire.pending then
                -- Lit when the queue had no room. Push it now, if the fuel
                -- is still there to burn.
                if M.fuel_at(pos) == nil then
                    remove_fire(blaze, fire)
                    stats.gone = stats.gone + 1
                else
                    edits[#edits + 1] = { pos = pos, block = FIRE, apply = function()
                        fire.pending = nil
                        fire.born = wx.now
                        dirty = true
                    end }
                end
            elseif b.material == FIRE_ID then
                fire.state = "burning"
                dirty = true
            elseif now - fire.born > config.FIRE_CONFIRM_TICKS then
                -- Refused or clipped: it never landed.
                remove_fire(blaze, fire)
                stats.gone = stats.gone + 1
            end
        elseif fire.state == "burning" then
            if b.material ~= FIRE_ID then
                -- Dug, or washed away by water: heard, not fought.
                remove_fire(blaze, fire)
                stats.gone = stats.gone + 1
                emit("gone", pos, summary(blaze))
            elseif now - fire.born >= fire.burn then
                edits[#edits + 1] = { pos = pos, block = fire.residue, apply = function()
                    fire.state = "dying"
                    fire.pushed = wx.now
                    stats.burnt = stats.burnt + 1
                    dirty = true
                    emit("burnt", pos, summary(blaze))
                end }
                if fire.kind == "plant" then
                    -- A field fire leaves a black patch: the whole block
                    -- the plant stood on, if it is turf the climate names.
                    local under = { x = fire.x, y = fire.y - 1, z = fire.z }
                    local g = game.get_block(under)
                    if g ~= nil and g.cells == nil and g.occupancy == FULL and climate.scorch[g.material] then
                        edits[#edits + 1] = { pos = under, block = climate.scorch[g.material], apply = function()
                            stats.scorched = stats.scorched + 1
                            emit("scorched", under, summary(blaze))
                        end }
                    end
                end
            elseif wet > 0 and exposed(pos) and rng:below(1000) < config.FIRE_DOUSE * wet // 1000 then
                edits[#edits + 1] = { pos = pos, block = AIR, apply = function()
                    fire.state = "dying"
                    fire.residue = AIR
                    fire.pushed = wx.now
                    stats.doused = stats.doused + 1
                    dirty = true
                    emit("doused", pos, summary(blaze))
                end }
            elseif spreading and blaze.ignited + lit < cap and count + shared.reserved < config.FIRE_MAX_BURNING then
                -- One candidate per fire per turn.
                local o = OFFSETS[rng:below(26) + 1]
                local cx, cy, cz = fire.x + o[1], fire.y + o[2], fire.z + o[3]
                local ckey = key_of(cx, cy, cz)
                if fires[ckey] == nil and shared.claimed[ckey] == nil and cheb(cx - ox, cz - oz) <= radius then
                    local cpos = { x = cx, y = cy, z = cz }
                    local fuel = M.fuel_at(cpos)
                    if fuel ~= nil then
                        local wet_ground = false
                        if fuel.kind == "plant" then
                            local g = game.get_block{ x = cx, y = cy - 1, z = cz }
                            wet_ground = g ~= nil and damp[g.material] == true
                        end
                        if wet_ground then
                            stats.refused_wet = stats.refused_wet + 1
                        else
                            -- Permille, integer wherever it can be; the
                            -- climate's factors are the only floats.
                            local odds = config.FIRE_SPREAD * fuel.catch // 1000
                            odds = floor(odds * dryness * heat) * (1000 - wet) // 1000
                            if rng:below(1000) < odds then
                                shared.claimed[ckey] = true
                                shared.reserved = shared.reserved + 1
                                lit = lit + 1
                                edits[#edits + 1] = { pos = cpos, block = FIRE, apply = function()
                                    add_fire(blaze, cx, cy, cz, fuel)
                                    blaze.ignited = blaze.ignited + 1
                                    stats.spread = stats.spread + 1
                                    emit("ignite", cpos, summary(blaze))
                                end }
                            end
                        end
                    end
                end
            end
        elseif fire.state == "dying" then
            if b.material ~= FIRE_ID then
                remove_fire(blaze, fire)
            elseif fire.pushed == nil or now - fire.pushed > config.FIRE_CONFIRM_TICKS then
                -- The residue never landed (or was never pushed): again.
                edits[#edits + 1] = { pos = pos, block = fire.residue, apply = function()
                    fire.pushed = wx.now
                end }
            end
        end
    end

    budget = commit(edits, budget)
    if #blaze.list == 0 then
        end_blaze(blaze)
    end
    return budget
end

local function turn()
    -- Never more than FIRE_MAX_BURNING edits in one turn, across every blaze.
    local budget = config.FIRE_MAX_BURNING
    local shared = { claimed = {}, reserved = 0 }
    for _, id in ipairs(order) do
        local blaze = blazes[id]
        if blaze ~= nil then
            budget = turn_blaze(blaze, budget, shared)
        end
    end
end

-- ------------------------------------------------------------ ignition

-- The live blaze whose radius holds (x, z), if any: an ignition inside one
-- joins it and counts against its cap rather than starting another.
local function blaze_over(x, z)
    for _, id in ipairs(order) do
        local blaze = blazes[id]
        if cheb(x - blaze.ox, z - blaze.oz) <= radius_of(blaze) then
            return blaze
        end
    end
    return nil
end

-- Whether a NATURAL blaze may not start at (x, z): its square had one within
-- FIRE_REST_TICKS (an entry that has aged out is pruned here), or a live
-- blaze's origin is within FIRE_APART.
local function resting(x, z)
    local skey = square_key(x, z)
    local at = rest[skey]
    if at ~= nil then
        if wx.now - at < config.FIRE_REST_TICKS then
            return true
        end
        rest[skey] = nil
        game.storage.set("fire:rest:" .. skey, nil)
    end
    for _, id in ipairs(order) do
        local blaze = blazes[id]
        if cheb(x - blaze.ox, z - blaze.oz) < config.FIRE_APART then
            return true
        end
    end
    return false
end

-- Lights the block at pos. `reason` is "lightning" | "lava" | "command" |
-- "export"; opts.force (a command) skips the square's rest and FIRE_APART,
-- never the caps. Answers ok, why: why is "off", "no fuel", "cap", "rest" or
-- "burning" (already alight there). The natural odds (FIRE_LIGHTNING_ODDS
-- and the rest) are the CALLER's roll, not this one's.
function M.ignite(pos, reason, opts)
    if not M.enabled then
        stats.refused_off = stats.refused_off + 1
        return false, "off"
    end
    ensure_loaded()
    local p = block_pos(pos)
    -- Alight first: a fire block is not fuel, so asked the other way round
    -- an alight block would answer "no fuel".
    if fires[key_of(p.x, p.y, p.z)] ~= nil then
        return false, "burning"
    end
    local fuel = M.fuel_at(p)
    if fuel == nil then
        stats.refused_fuel = stats.refused_fuel + 1
        return false, "no fuel"
    end
    local force = opts ~= nil and opts.force == true
    local blaze = blaze_over(p.x, p.z)
    local started = false
    if blaze ~= nil then
        if blaze.ignited >= cap_of(blaze) or count >= config.FIRE_MAX_BURNING then
            stats.refused_cap = stats.refused_cap + 1
            return false, "cap"
        end
    else
        if #order >= config.FIRE_MAX_BLAZES or count >= config.FIRE_MAX_BURNING then
            stats.refused_cap = stats.refused_cap + 1
            return false, "cap"
        end
        if not force and resting(p.x, p.z) then
            stats.refused_rest = stats.refused_rest + 1
            return false, "rest"
        end
        blaze = {
            id = next_id, ox = p.x, oy = p.y, oz = p.z,
            kind = fuel.kind == "plant" and "field" or "forest",
            born = wx.now, ignited = 0, reason = reason, fires = {}, list = {},
        }
        next_id = next_id + 1
        blazes[blaze.id] = blaze
        rebuild_order()
        started = true
        stats.blazes = stats.blazes + 1
        emit("blaze_start", p, summary(blaze))
    end
    local fire = add_fire(blaze, p.x, p.y, p.z, fuel)
    blaze.ignited = blaze.ignited + 1
    stats.ignited = stats.ignited + 1
    if reason == "lightning" or reason == "lava" then
        stats[reason] = stats[reason] + 1
    end
    -- Pushed at once, so a command sees it land next tick. With no room it
    -- is still lit, and the next turn pushes it.
    fire.pending = true
    if queue.room() then
        queue.begin()
        queue.push(p, FIRE, nil)
        if queue.commit() then
            fire.pending = nil
            stats.edits = stats.edits + 1
        end
    end
    emit("ignite", p, summary(blaze))
    if started then
        -- A new blaze goes to storage now rather than at the next save, so a
        -- restart in the next few seconds does not leave its block an orphan.
        save()
    end
    return true
end

-- ------------------------------------------------------------ putting out

-- Marks a fire dying with air for its residue and queues the edit. A fire
-- that was never placed (lit with no room) is simply forgotten. Returns
-- whether a block in the world was put out.
local function put_out(fire, edits)
    if fire.state == "dying" then
        return false
    end
    if fire.pending then
        remove_fire(fire.blaze, fire)
        return false
    end
    fire.state = "dying"
    fire.residue = AIR
    fire.pushed = nil
    dirty = true
    edits[#edits + 1] = { pos = { x = fire.x, y = fire.y, z = fire.z }, block = AIR, apply = function()
        fire.pushed = wx.now
    end }
    return true
end

-- The blazes left empty by put_out end as they would after a turn.
local function end_empty()
    for _, id in ipairs(order) do
        local blaze = blazes[id]
        if blaze ~= nil and #blaze.list == 0 then
            end_blaze(blaze)
        end
    end
end

-- A burning block goes to air now (through the queue).
function M.extinguish(pos)
    local p = block_pos(pos)
    local fire = fires[key_of(p.x, p.y, p.z)]
    if fire == nil then
        return false
    end
    local edits = {}
    local out = put_out(fire, edits)
    if out then
        commit(edits, config.FIRE_MAX_BURNING)
        emit("doused", p, summary(fire.blaze))
    end
    end_empty()
    return out
end

-- Every blaze. Returns the blocks put out.
function M.extinguish_all()
    local n = 0
    local edits = {}
    for _, id in ipairs(order) do
        local blaze = blazes[id]
        for _, fire in ipairs(blaze.list) do
            if put_out(fire, edits) then
                n = n + 1
                emit("doused", { x = fire.x, y = fire.y, z = fire.z }, summary(blaze))
            end
        end
    end
    commit(edits, config.FIRE_MAX_BURNING)
    end_empty()
    return n
end

-- ------------------------------------------------------------ what a caller may ask

function M.burning_at(pos)
    local p = block_pos(pos)
    return fires[key_of(p.x, p.y, p.z)] ~= nil
end

-- Blocks alight: every fire this mod is still watching, the dying included,
-- since their blocks are fire in the world until the residue lands.
function M.count()
    return count
end

-- Fresh copies, in id order.
function M.blazes()
    local out = {}
    for _, id in ipairs(order) do
        out[#out + 1] = summary(blazes[id])
    end
    return out
end

-- A whole block in climate.scorch at pos becomes scorched ground: what
-- lightning leaves on bare turf. Under the same switch as fire, since a
-- world that turned wildfires off wants its ground left alone.
function M.scorch_mark(pos)
    if not M.enabled then
        return false
    end
    local p = block_pos(pos)
    local b = game.get_block(p)
    if b == nil or b.cells ~= nil or b.occupancy ~= FULL then
        return false
    end
    local to = climate.scorch[b.material]
    if to == nil or not queue.room() then
        return false
    end
    queue.begin()
    queue.push(p, to, nil)
    if not queue.commit() then
        return false
    end
    stats.edits = stats.edits + 1
    stats.scorched = stats.scorched + 1
    emit("scorched", p, nil)
    return true
end

-- ------------------------------------------------------------ lava

-- Flowing: a hot fluid pressing on fuel is reported as a blocked flow, and
-- `event.block` names the fuel. One roll per report; lava presses every
-- fluid tick, so a leaf beside it does not wait long.
wx.on_fluid_flow(function(event)
    if not M.enabled or game.world_seed == nil or event.block == nil or event.meets ~= nil then
        return
    end
    if not climate.hot_fluids[event.fluid] then
        return
    end
    local ok, id = pcall(game.get_block_id, event.block)
    if not ok or id == nil or climate.fuel[id] == nil then
        return
    end
    local into = event.into
    local rng = game.rng_stream({ x = into.x, y = wx.now % Y_WRAP, z = into.z, seed = game.world_seed }, "wx_fire_flow")
    if rng:below(config.FIRE_FLOW_ODDS) == 0 then
        M.ignite(into, "lava")
    end
end)

-- The eight horizontal neighbours, for what stands beside a hot column.
local ROUND = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 }, { 1, 1 }, { 1, -1 }, { -1, 1 }, { -1, -1 } }

-- Still: a settled pool reports no flows, so near players columns are
-- sampled as ground.lua samples them, and a hot surface is looked round.
-- Still lava has no name to look up (`surface_at` gives a numeric fluid id,
-- `get_fluid` a volume), so it is told from water by its LIGHT: the
-- Spindle's lava block emits { 15, 8, 1 } and its magma { 15, 7, 0 }, and no
-- water glows red. A mod's lava that does not glow is not found.
local cursor = 0

-- Whether one of this mod's own fires is within two blocks of (x, y, z).
-- The fire block emits { 15, 9, 2 }, so the block beside a burning tuft
-- reads about { 14, 8, 1 } and passes the lava test below: a pond, a river
-- or a puddle on the bank of a live blaze would be called lava, and the
-- fuel round it lit as "by lava" — outside the spread rules, so in a
-- downpour that is trying to put the blaze out. A green threshold cannot
-- separate the two (lava itself reads { 15, 8, 1 }), so a glowing fluid
-- next to a fire of ours is simply not hot. `fires` holds at most
-- FIRE_MAX_BURNING entries and a glowing column is rare.
local function near_fire(x, y, z)
    for _, f in pairs(fires) do
        if math.abs(f.x - x) <= 2 and math.abs(f.y - y) <= 2 and math.abs(f.z - z) <= 2 then
            return true
        end
    end
    return false
end

local function sample_hot()
    if not M.enabled or next(climate.fuel) == nil or not queue.room() then
        return
    end
    local list = controller.players()
    local n = #list
    if n == 0 then
        return
    end
    cursor = cursor % n + 1
    local where = controller.where[list[cursor]]
    if where == nil then
        return
    end
    local px, pz = floor(where.x), floor(where.z)
    local rng = game.rng_stream({ x = px // CHUNK, y = wx.now % Y_WRAP, z = pz // CHUNK,
        seed = game.world_seed }, "wx_fire_hot")
    local reach = config.SAMPLE_RADIUS
    local fx = (px - reach + rng:below(2 * reach + 1)) // CHUNK
    local fz = (pz - reach + rng:below(2 * reach + 1)) // CHUNK
    for _ = 1, config.FIRE_SAMPLE_COLUMNS do
        local x, z = fx * CHUNK + rng:below(CHUNK), fz * CHUNK + rng:below(CHUNK)
        local top = game.surface_at{
            x = x, z = z, from = floor(where.y) + config.SCAN_ABOVE, depth = config.SCAN,
        }
        if top ~= nil then
            local hot = false
            if top.fluid ~= nil then
                local light = game.get_light{ x = x, y = top.y, z = z }
                hot = light.r >= 14 and light.b <= 3 and not near_fire(x, top.y, z)
            elseif climate.hot_blocks[top.material] then
                hot = true
            end
            if hot then
                -- Sixteen reads at most, and only for a hot column, which
                -- is rare. The first fuel found is the one that is rolled
                -- for; one ignition per sample at most.
                for dy = 0, 1 do
                    for _, d in ipairs(ROUND) do
                        local p = { x = x + d[1], y = top.y + dy, z = z + d[2] }
                        if M.fuel_at(p) ~= nil then
                            if rng:below(config.FIRE_LAVA_ODDS) == 0 then
                                M.ignite(p, "lava")
                            end
                            return
                        end
                    end
                end
            end
        end
    end
end

-- ------------------------------------------------------------ random ticks

-- The safety nets, on this mod's own materials only. Under the same budget
-- idea as ground.lua's: nothing without room in the queue, and no more than
-- TICK_BUDGET handled in one tick.
local TICK_BUDGET = 16
local spent, spent_at = 0, -1

local function afford()
    if spent_at ~= wx.now then
        spent_at, spent = wx.now, 0
    end
    if spent >= TICK_BUDGET or not queue.room() then
        return false
    end
    spent = spent + 1
    return true
end

-- A fire block in no blaze is an orphan: a restart that lost its storage, a
-- fire an operator placed, an edit that landed after it was given up on.
-- With fire switched off every fire block is one.
game.register_random_tick(FIRE, function(event)
    if game.world_seed == nil then
        return
    end
    if M.enabled and not loaded then
        return                  -- the index is not read yet; it may be ours
    end
    if fires[key_of(event.x, event.y, event.z)] ~= nil or not afford() then
        return
    end
    queue.begin()
    queue.push({ x = event.x, y = event.y, z = event.z }, AIR, nil)
    if queue.commit() then
        stats.orphans = stats.orphans + 1
    end
end)

-- Scorched ground heals to the climate's bare ground: one tick in
-- FIRE_HEAL_ODDS, or at once when it is raining there.
game.register_random_tick(blocks.SCORCHED, function(event)
    if game.world_seed == nil or climate.bare == nil or not afford() then
        return
    end
    local here = { x = event.x, y = event.y, z = event.z }
    local b = game.get_block(here)
    if b == nil or b.material ~= SCORCHED_ID or b.cells ~= nil or b.occupancy ~= FULL then
        return
    end
    local rng = game.rng_stream({ x = event.x, y = wx.now % Y_WRAP, z = event.z, seed = game.world_seed }, "wx_fire_heal")
    local heal = rng:below(config.FIRE_HEAL_ODDS) == 0
    if not heal then
        -- The weather function costs noise reads; asked only when the roll failed.
        local kind, intensity = controller.weather(event.x, event.y, event.z, wx.now, nil)
        local k = controller.KINDS[kind]
        heal = k ~= nil and k.family == "rain" and intensity > 0
    end
    if not heal then
        return
    end
    queue.begin()
    queue.push(here, climate.bare, nil)
    if queue.commit() then
        stats.healed = stats.healed + 1
    end
end)

-- ------------------------------------------------------------ the tick

local since_turn, since_sample, since_save = 0, 0, 0

wx.on_tick(function(dt_ticks)
    if not M.enabled or game.world_seed == nil then
        return
    end
    if not loaded then
        if not controller.ready() then
            return              -- the clock is not restored yet
        end
        load()
    end
    since_sample = since_sample + dt_ticks
    if since_sample >= config.FIRE_SAMPLE_TICKS then
        since_sample = 0
        sample_hot()
    end
    -- A world without fire costs nothing past this line.
    if #order == 0 then
        return
    end
    since_turn = since_turn + dt_ticks
    if since_turn >= config.FIRE_TURN_TICKS then
        since_turn = 0
        turn()
    end
    since_save = since_save + dt_ticks
    if since_save >= config.FIRE_SAVE_TICKS then
        since_save = 0
        save()
    end
end)

-- ------------------------------------------------------------ unlocks at load

-- The Spindle treats scorched ground as dirt, so its grass grows back.
local took = climate.unlock_scorched()
game.log("tiamat_weather: scorched ground as dirt: " .. (took and "taken" or "not offered"))

-- **Life makes fire hurt** (Life a1d016c, 2026-09-23, docs/exports-contract.md).
-- Life keys its contact-fire and heat tables on material names and resolves
-- them at its own load, which is before this mod's, so it exports two
-- unlocks that keep the name and resolve it on its first tick; this mod
-- calls both once here, for its fire block. Reading Life's exports is
-- allowed because mod.toml names it in optional_depends. Without Life, or
-- on a Life older than the unlocks, fire burns nothing and nobody.
local LIFE = nil
if type(game.exports) == "function" then
    LIFE = game.exports("tiamat_default_life")
end
M.life = { contact = false, heat = false, alight = false }
if LIFE ~= nil then
    if type(LIFE.add_contact_fire) == "function" then
        M.life.contact = LIFE.add_contact_fire(M.FIRE, { damage = 1, ticks = 20, after = 40 }) == true
    end
    if type(LIFE.add_heat_source) == "function" then
        M.life.heat = LIFE.add_heat_source(M.FIRE, 1.0) == true
    end
    M.life.alight = type(LIFE.set_alight) == "function"
end
game.log(string.format("tiamat_weather: fire hurts %s, warms %s, lightning sets alight %s",
    M.life.contact and "yes" or "no", M.life.heat and "yes" or "no", M.life.alight and "yes" or "no"))

-- Sets a body alight through Life: `target` is a player's UUID (an entity's
-- `owner`) or an entity id, `ticks` how long it burns. Answers whether
-- anyone was set alight; false without Life. Not gated on M.enabled: a bolt
-- hurts whoever it hits whether or not the world's trees may burn.
function M.set_alight(target, ticks)
    if not M.life.alight then
        return false
    end
    return LIFE.set_alight(target, ticks) == true
end

return M
