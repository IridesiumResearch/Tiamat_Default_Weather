-- SPDX-FileCopyrightText: Iridesium
-- SPDX-License-Identifier: GPL-3.0-only
--
-- A wreck at the end of the rainbow (2026-10-12): "a worn down, crashed ship
-- with a tiny bit of gold and other loot in it, at one random end of a
-- rainbow".
--
-- **Where a rainbow ends.** The bow stands 42 degrees round the point
-- opposite the sun, and the sun's arc is the client's (`sky.rs`): sunlight
-- travels along (cos a, -sin a, 0.25) with a = (t - 0.25) turns, so with the
-- sun low enough for a bow at all it travels +x in the morning and -x in the
-- evening, tilted 0.25 towards +z. The bow meets the horizon about 42 degrees
-- either side of that heading, so its two ends are those two headings, from
-- constants — no trigonometry, and nothing here reaches the simulation but a
-- position to build at. One end is drawn from the rain's own stream, and the
-- wreck goes WRECK_DISTANCE blocks out along it, on open ground.
--
-- **A schematic, stamped at run time** (engine 75a0132e, ask W35). The hull is
-- one `game.schematic`, built once from the materials as they resolve, and
-- `game.stamp_schematic` writes it turned, paced with the plans, a few ticks
-- for the whole ship. The chest is not in it: Craft registers after Weather
-- loads, so its id is not known when the hull is built, and it goes in by
-- itself through the queue — on a cell the hull does not write, so the two
-- may land in either order. On an engine without the stamp, or if the engine
-- will not take one now, the hull goes block by block through the queue as
-- it did before.
--
-- **The loot is a Tiamat Default Craft chest**, when Craft is installed:
-- its chest block, and the container Craft opens for it, named the way Craft
-- names a chest's (`tiamat_default_craft:chest:x,y,z`, its stations.lua).
-- Craft loads after Weather (it names Weather in its optional_depends, and
-- the engine refuses a cycle), so there is no export to call; the name is
-- the contract, and Craft documents it as stable for other mods to fill
-- (its docs/exports.md, "Containers"; sibling ask Wx-C1, answered in Craft
-- 452d034). Without Craft the wreck has no chest.

local config = wx.config
local climate = wx.climate
local controller = wx.controller
local blocks = wx.blocks
local queue = wx.queue

local M = {}

M.stats = { offered = 0, spawned = 0, stamped = 0, no_site = 0, resting = 0, edits = 0, stocked = 0, unstocked = 0 }

local Y_WRAP = 1 << 30
local CHUNK = 16
local FULL = game.OCCUPANCY_FULL
local TWO_LAYERS = blocks.LAYER_MASK[2]
local ONE_LAYER = blocks.LAYER_MASK[1]

-- ------------------------------------------------------------ materials

local function exists(id)
    local ok, n = pcall(game.get_block_id, id)
    return ok and n ~= nil
end

local function first(ids)
    for _, id in ipairs(ids) do
        if exists(id) then
            return id
        end
    end
    return nil
end

-- Resolved on first use, when every mod has registered.
local mats = nil
local function materials()
    if mats then
        return mats
    end
    local log = first({ "tiamat_default_world:oak_log", "tiamat_default_world:fir_log", "tiamat_default_world:birch_log" })
    mats = {
        plank = first({ "tiamat_default_world:willow_planks", "tiamat_default_world:kapok_planks",
            "tiamat_default_world:ironwood_planks" }) or log,
        log = log,
        char = blocks.CHARRED,
        chest = first({ "tiamat_default_craft:chest" }),
    }
    return mats
end

-- ------------------------------------------------------------ the ship

-- A small hull nine long and five wide, keel buried a block, listing towards
-- +z: the near rail and the stern stand, the far side is broken down to
-- stumps, the floor is holed, a mast snapped at the deck lies off the side,
-- and a few boards are burnt black. The chest sits aft. Offsets are from the
-- middle of the deck, x along the keel.
local SHIP = {}
local function put(dx, dy, dz, kind, mask)
    SHIP[#SHIP + 1] = { dx, dy, dz, kind, mask }
end

for x = -3, 3 do
    put(x, -1, 0, "log")                                   -- the keel, in the ground
end
for x = -3, 3 do                                           -- the floor, holed
    for z = -1, 1 do
        if not ((x == -1 and z == -1) or (x == 2 and z == 1)) then
            put(x, 0, z, (x == 0 and z == 1) and "char" or "plank")
        end
    end
end
put(-4, 0, 0, "plank")                                     -- the bow's point
put(-4, 1, 0, "plank", TWO_LAYERS)
for z = -1, 1 do
    put(4, 0, z, "plank")                                  -- the stern, standing
    put(4, 1, z, "plank")
    put(4, 2, z, z == 0 and "char" or "plank", TWO_LAYERS)
end
for x = -3, 3 do                                           -- the near rail, standing
    put(x, 1, 2, x == 1 and "char" or "plank")
    if x >= -1 and x <= 2 then
        put(x, 2, 2, "plank", ONE_LAYER)
    end
end
for x = -3, 3 do                                           -- the far rail, broken down
    if x ~= -1 and x ~= 0 then
        put(x, 1, -2, (x == 2) and "char" or "plank", (x % 2 == 0) and TWO_LAYERS or ONE_LAYER)
    end
end
put(0, 1, 0, "log", ONE_LAYER)                             -- the mast's stump
for z = -3, -7, -1 do
    put(-1, 1, z, "log")                                   -- the mast, fallen off the side
end
put(3, 1, 0, "chest")                                      -- the chest, aft

M.SHIP = SHIP

-- Turns an offset a quarter turn `r` times about the vertical.
-- The stamp's own sense (engine W35): one turn takes +z to +x, so (dx, dz)
-- becomes (dz, -dx). Kept the same everywhere here, so the site measured is
-- the ship stamped and the chest lands inside it.
local function turned(dx, dz, r)
    for _ = 1, r do
        dx, dz = dz, -dx
    end
    return dx, dz
end

local HAS_STAMP = type(game.stamp_schematic) == "function" and type(game.schematic) == "function"
local hull = nil              -- the schematic, once built; false if it cannot be
local function hull_schematic(m)
    if hull ~= nil then
        return hull or nil
    end
    hull = false
    if not HAS_STAMP then
        return nil
    end
    local list = {}
    for _, b in ipairs(SHIP) do
        local name = b[4] ~= "chest" and m[b[4]] or nil
        if name then
            list[#list + 1] = { b[1], b[2], b[3], game.get_block_id(name), b[5] or FULL }
        end
    end
    local ok, made = pcall(game.schematic, list)
    if ok and made then
        hull = made
    else
        game.log("tiamat_weather: the wreck's schematic did not build: " .. tostring(made))
    end
    return hull or nil
end

-- ------------------------------------------------------------ where the bow ends

-- Sunlight's heading on the ground, normalised: (±1, 0.25) / |(1, 0.25)|.
local HEAD_X, HEAD_Z = 0.97014250, 0.24253563
-- 42 degrees.
local COS42, SIN42 = 0.74314483, 0.66913061

-- The two ends of a bow seen at day fraction `t`, as unit headings. The sun is
-- low enough for a bow only in the morning and the evening; at noon there is
-- none to end anywhere, and the answer is nil.
local function ends_at(t)
    local ax
    if t >= config.WRECK_MORNING[1] and t <= config.WRECK_MORNING[2] then
        ax = HEAD_X
    elseif t >= config.WRECK_EVENING[1] and t <= config.WRECK_EVENING[2] then
        ax = -HEAD_X
    else
        return nil
    end
    local az = HEAD_Z
    return {
        { x = ax * COS42 - az * SIN42, z = ax * SIN42 + az * COS42 },
        { x = ax * COS42 + az * SIN42, z = -ax * SIN42 + az * COS42 },
    }
end
M.ends_at = ends_at

-- The ground under open sky at a column, or nil: looked for from well over
-- the player down, and refused if it is water, a canopy, or roofed.
local SCAN = 256
local function ground(x, z, near_y)
    local from = math.floor(near_y) + 64
    for _ = 1, 2 do
        local top = game.surface_at{ x = x, z = z, from = from, depth = SCAN }
        if top ~= nil then
            if top.fluid ~= nil or climate.canopy[top.material] then
                return nil
            end
            if game.get_light({ x = x, y = top.y + 1, z = z }).sun ~= 15 then
                return nil
            end
            return top
        end
        from = from - SCAN
    end
    return nil
end

-- A place for the hull at (cx, cz): open, dry ground no more than
-- WRECK_SLOPE blocks out of level under its middle and its four corners.
local function site(cx, cz, near_y, r)
    local middle = ground(cx, cz, near_y)
    if middle == nil then
        return nil
    end
    local low, high = middle.y, middle.y
    for _, c in ipairs({ { -4, -2 }, { 4, -2 }, { -4, 2 }, { 4, 2 } }) do
        local dx, dz = turned(c[1], c[2], r)
        local g = ground(cx + dx, cz + dz, near_y)
        if g == nil then
            return nil
        end
        low, high = math.min(low, g.y), math.max(high, g.y)
    end
    if high - low > config.WRECK_SLOPE then
        return nil
    end
    return { x = cx, y = middle.y, z = cz }
end

-- ------------------------------------------------------------ building

local pending = {}           -- edits not yet handed to the queue: { pos, block, mask }
local since = 0

-- Hands the queue one chunk's worth of the wreck at a time, when it has room.
wx.on_tick(function(dt)
    if #pending == 0 then
        return
    end
    since = since + dt
    if since < config.QUEUE_EVERY then
        return
    end
    since = 0
    if not queue.room() then
        return
    end
    local p = pending[1][1]
    local cx, cy, cz = p.x // CHUNK, p.y // CHUNK, p.z // CHUNK
    local rest = {}
    queue.begin()
    for _, e in ipairs(pending) do
        local q = e[1]
        if q.x // CHUNK == cx and q.y // CHUNK == cy and q.z // CHUNK == cz then
            queue.push(q, e[2], e[3])
            M.stats.edits = M.stats.edits + 1
        else
            rest[#rest + 1] = e
        end
    end
    if queue.commit() then
        pending = rest
    end
end)

-- The loot: a little gold, and a couple of the things a ship would carry.
local LOOT = {
    { "iron_nails", 2, 6 }, { "cord", 1, 3 }, { "cloth", 1, 2 }, { "leather", 1, 2 },
    { "cured_meat", 1, 3 }, { "charcoal", 2, 5 }, { "copper_ingot", 1, 2 }, { "iron_chain", 1, 1 },
}
local CRAFT = "tiamat_default_craft:"

local function stock(pos, rng)
    local name = CRAFT .. "chest:" .. pos.x .. "," .. pos.y .. "," .. pos.z
    local function give(item, count)
        local id = CRAFT .. item
        if count > 0 and exists(id) then
            pcall(game.container_give, name, { material = id, count = count })
        end
    end
    local ok = pcall(game.make_container, name, 27)
    if not ok then
        M.stats.unstocked = M.stats.unstocked + 1
        return false
    end
    give("gold_flake", 2 + rng:below(4))
    if rng:below(3) == 0 then
        give("gold_ingot", 1)
    end
    for _ = 1, 2 + rng:below(2) do
        local l = LOOT[rng:below(#LOOT) + 1]
        give(l[1], l[2] + rng:below(l[3] - l[2] + 1))
    end
    if rng:below(8) == 0 then
        give("silver_ingot", 1)
    end
    M.stats.stocked = M.stats.stocked + 1
    return true
end

-- Builds the wreck with its middle at `at`, turned `r` quarter turns.
local function build(at, r, rng)
    local m = materials()
    if m.plank == nil then
        return false
    end
    local schematic = hull_schematic(m)
    local stamped = false
    if schematic then
        local ok, accepted = pcall(game.stamp_schematic, schematic, { x = at.x, y = at.y, z = at.z }, { turn = r })
        stamped = ok and accepted == true
        if stamped then
            M.stats.stamped = M.stats.stamped + 1
        end
    end
    for _, b in ipairs(SHIP) do
        if stamped and b[4] ~= "chest" then
            goto continue
        end
        local dx, dz = turned(b[1], b[3], r)
        local block = m[b[4]]
        if block ~= nil then
            local pos = { x = at.x + dx, y = at.y + b[2], z = at.z + dz }
            local mask = b[5]
            if mask == FULL then
                mask = nil
            end
            pending[#pending + 1] = { pos, block, mask }
            if b[4] == "chest" then
                stock(pos, rng)
            end
        end
        ::continue::
    end
    M.stats.spawned = M.stats.spawned + 1
    M.last = { x = at.x, y = at.y, z = at.z }
    return true
end

-- Finds a site out along `heading` from (px, py, pz) and builds there.
local function along(heading, px, py, pz, rng)
    local r = rng:below(4)
    for _, d in ipairs(config.WRECK_DISTANCE) do
        local cx = math.floor(px + heading.x * d)
        local cz = math.floor(pz + heading.z * d)
        local s = site(cx, cz, py, r)
        if s then
            return build(s, r, rng), s
        end
    end
    M.stats.no_site = M.stats.no_site + 1
    return false
end

-- ------------------------------------------------------------ when

-- fx.lua calls this when a player's rainbow first shows: the square's rain
-- event is `square.last_rain`. One wreck per rain event, and none within
-- WRECK_REGION of the last for WRECK_REST_TICKS, both kept in storage so a
-- restart does not deal the same rainbow twice.
function M.offer(uuid, square, tick)
    if not config.wrecks then
        return false
    end
    M.stats.offered = M.stats.offered + 1
    local where = controller.where[uuid]
    local t = controller.day_fraction(tick)
    if where == nil or t == nil then
        return false
    end
    local headings = ends_at(t)
    if headings == nil then
        return false
    end
    local event = "wreck:" .. square.cx .. ":" .. square.cz .. ":" .. square.last_rain
    if game.storage.get(event) ~= nil then
        return false
    end
    game.storage.set(event, "1")
    local region = config.WRECK_REGION
    local rkey = "wreck_rest:" .. (math.floor(where.x) // region) .. ":" .. (math.floor(where.z) // region)
    local rested = tonumber(game.storage.get(rkey) or "")
    if rested and tick - rested < config.WRECK_REST_TICKS then
        M.stats.resting = M.stats.resting + 1
        return false
    end
    local rng = game.rng_stream({ x = square.cx, y = square.last_rain % Y_WRAP, z = square.cz,
        seed = game.world_seed }, "wx_wreck")
    local built = along(headings[rng:below(2) + 1], where.x, where.y, where.z, rng)
    if built then
        game.storage.set(rkey, tostring(tick))
    end
    return built
end

-- For /weather wreck: a wreck at one end of the bow `uuid` would see now,
-- or the morning's if the sun is too high for one. Answers the site or nil.
function M.force(uuid)
    local where = controller.where[uuid]
    if where == nil then
        return nil
    end
    local t = controller.day_fraction(wx.now) or 0.3
    local headings = ends_at(t) or ends_at(config.WRECK_MORNING[1])
    local rng = game.rng_stream({ x = math.floor(where.x), y = wx.now % Y_WRAP, z = math.floor(where.z),
        seed = game.world_seed }, "wx_wreck")
    local built, s = along(headings[rng:below(2) + 1], where.x, where.y, where.z, rng)
    if built then
        return s
    end
    return nil
end

return M
