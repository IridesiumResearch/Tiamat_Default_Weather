-- SPDX-License-Identifier: MIT
--
-- What weather leaves on the ground: snow layers, damp ground, and the thaw.
--
-- **The sampler** (plan 5.3). Random ticks come up about every twenty minutes
-- per block, which is too slow to watch snow settle, so near players this
-- file samples columns itself. It runs on the queue's cadence, not per player
-- per tick, and it asks the queue for room BEFORE it reads a single block:
--
--   every QUEUE_EVERY ticks, if queue.room():
--     the NEXT player in a round-robin who is under snow or rain (or in a
--     square that snowed recently, to thaw it)
--     -> one chunk footprint within SAMPLE_RADIUS of them
--     -> COLUMNS_PER_BATCH columns in it, each scanned down for its surface
--     -> one batch, committed
--
-- **The surface** is the first block that is not air, scanning down from
-- SCAN_ABOVE over the player's feet. The API cannot say whether a block is
-- passable, so anything that is not a WHOLE block of one material (a grass
-- tuft, a chiselled step, a fern) is not a support and the column is skipped,
-- except this mod's own snow. The cell above the surface must be open sky
-- (`sun == 15`) and hold no fluid, or a roof over the scan's start would let
-- snow settle on the floor under it.
--
-- **The thaw** (plan 5.6) is the sampler reversed near players, and a random
-- tick on this mod's own materials everywhere else. Only this mod's
-- materials are ticked, so nothing conflicts with the Spindle's handlers.

local config = wx.config
local climate = wx.climate
local blocks = wx.blocks
local controller = wx.controller
local queue = wx.queue

local M = {}

M.stats = {
    turns = 0, no_room = 0, columns = 0, unloaded = 0, buried = 0, roofed = 0, wet = 0,
    not_support = 0, layered = 0, grown = 0, capped = 0, thawed = 0, damped = 0, dried = 0,
    tick_thaws = 0, tick_dries = 0, tick_budget = 0, puddles = 0, joined = 0, steamed = 0,
}

local SNOW = blocks.SNOW
local SNOW_ID = blocks.snow_id
local AIR = "engine:air"
local FULL = game.OCCUPANCY_FULL
local MASK = blocks.LAYER_MASK
local CHUNK = 16
local Y_WRAP = 1 << 30          -- rng_stream takes y as a 32-bit integer

-- ------------------------------------------------------------ damp ids

-- Resolved on first use: the numeric ids exist once registration is done.
local damp_of, dry_of, dry_id_of = nil, nil, nil
local function resolve_damp()
    if damp_of ~= nil then
        return
    end
    damp_of, dry_of, dry_id_of = {}, {}, {}
    for dry, damp in pairs(climate.damp) do
        local ok_dry, dry_id = pcall(game.get_block_id, dry)
        local ok_damp, damp_id = pcall(game.get_block_id, damp)
        if ok_dry and ok_damp and dry_id and damp_id then
            damp_of[dry_id] = damp
            dry_of[damp_id] = dry
            dry_id_of[damp_id] = dry_id
        end
    end
end

-- Whether a whole block may hold a puddle: the climate's open ground, damp
-- or dry, or anything at all where the climate does not say.
local function holds_puddle(material)
    local ground = climate.puddle_ground
    if ground == nil then
        return true
    end
    resolve_damp()
    return ground[material] or ground[dry_id_of[material] or -1] or false
end

-- ------------------------------------------------------------ snow

local function family_of(kind)
    return controller.KINDS[kind].family
end

-- The occupancy with its top layer of cells removed, 0 when nothing is left.
local function without_top_layer(occupancy)
    for n = 3, 1, -1 do
        local above = MASK[n] & ~MASK[n - 1]
        if occupancy & above ~= 0 then
            return occupancy & MASK[n - 1]
        end
    end
    return 0
end

local function push_thaw(position, occupancy)
    local left = without_top_layer(occupancy)
    if left == 0 then
        queue.push(position, AIR)
    else
        queue.push(position, SNOW, left)
    end
end

-- ------------------------------------------------------------ one column

-- What a sampled column gets. `square` is the player's evaluated square.
local function column(x, z, feet_y, square, tick, rng)
    M.stats.columns = M.stats.columns + 1
    -- **One crossing for the column** (engine `surface_at`, ask W6): the
    -- first occupied block at or below the start, through loaded chunks only.
    -- It used to be a loop of up to 48 `get_block` reads. Passable blocks are
    -- NOT skipped: a grass tuft is what the column has on it, and the rule
    -- below is that only a whole block of one material holds anything. A
    -- block holding fluid and nothing solid comes back with `fluid` set,
    -- which is a pond's surface or one of this mod's own puddles.
    local top = game.surface_at{
        x = x, z = z,
        from = math.floor(feet_y) + config.SCAN_ABOVE,
        depth = config.SCAN,
    }
    if top == nil then
        -- Unloaded, nothing within reach, or no world: one answer.
        M.stats.unloaded = M.stats.unloaded + 1
        return
    end
    if top.fluid ~= nil then
        M.stats.wet = M.stats.wet + 1
        return
    end
    local surface, y = { material = top.material, occupancy = top.occupancy }, top.y
    local open = { x = x, y = y + 1, z = z }
    if game.get_light(open).sun ~= 15 then
        M.stats.roofed = M.stats.roofed + 1
        return
    end

    local family = family_of(square.kind)
    local falling = square.intensity > 0
    local snowing = falling and family == "snow"
    local raining = falling and family == "rain"
    local freezing = climate.freezing(x, y + 1, z)
    local here = { x = x, y = y, z = z }

    -- This mod's snow, whatever shape it has been dug into.
    if surface.material == SNOW_ID then
        if snowing and freezing then
            local n = blocks.layers_of(surface.occupancy)
            local cap = square.kind == "blizzard" and config.BLIZZARD_LAYERS or config.SNOW_LAYERS
            if n ~= nil and n < cap then
                queue.push(here, SNOW, MASK[n + 1])
                M.stats.grown = M.stats.grown + 1
            else
                M.stats.capped = M.stats.capped + 1
            end
        elseif not snowing and not freezing then
            push_thaw(here, surface.occupancy)
            M.stats.thawed = M.stats.thawed + 1
        end
        return
    end

    -- Everything else must be a whole block of one material to hold anything.
    if surface.occupancy ~= FULL then
        M.stats.not_support = M.stats.not_support + 1
        return
    end

    if snowing and freezing then
        if not climate.covered[surface.material] then
            queue.push(open, SNOW, MASK[1])
            M.stats.layered = M.stats.layered + 1
        end
        return
    end

    if raining and config.puddles and holds_puddle(surface.material) and rng:below(config.PUDDLE_ONE_IN) == 0 then
        local cells = (square.mega or 0) >= config.MEGA_LABEL_AT and config.MEGA_PUDDLE_CELLS
            or square.kind == "storm" and config.STORM_PUDDLE_CELLS or config.PUDDLE_CELLS
        queue.push_fluid(open, blocks.RAINWATER, cells)
        M.stats.puddles = M.stats.puddles + 1
    end

    if config.damp_ground then
        resolve_damp()
        if raining and damp_of[surface.material] then
            queue.push(here, damp_of[surface.material])
            M.stats.damped = M.stats.damped + 1
        elseif not raining and dry_of[surface.material]
            and tick - square.last_rain >= config.DRY_AFTER_TICKS then
            queue.push(here, dry_of[surface.material])
            M.stats.dried = M.stats.dried + 1
        end
    end
end

-- ------------------------------------------------------------ the sampler

-- Whether a player's square has anything for the sampler to do.
local function wanted(square, tick)
    if square == nil then
        return false
    end
    local family = family_of(square.kind)
    if square.intensity > 0 and (family == "snow" or (family == "rain" and (config.damp_ground or config.puddles))) then
        return true
    end
    if tick - square.last_snow < config.THAW_MEMORY_TICKS then
        return true
    end
    return config.damp_ground and tick - square.last_rain < config.THAW_MEMORY_TICKS
end

local cursor = 0
local since = 0

local function sample()
    local tick = wx.now
    local list = controller.players()
    local n = #list
    if n == 0 then
        return
    end
    for _ = 1, n do
        cursor = cursor % n + 1
        local uuid = list[cursor]
        local where = controller.where[uuid]
        local square = where and controller.squares[where.key]
        if wanted(square, tick) then
            M.stats.turns = M.stats.turns + 1
            local px, pz = math.floor(where.x), math.floor(where.z)
            local rng = game.rng_stream({ x = px // CHUNK, y = tick % Y_WRAP, z = pz // CHUNK,
                seed = game.world_seed }, "wx_ground")
            local reach = config.SAMPLE_RADIUS
            local fx = (px - reach + rng:below(2 * reach + 1)) // CHUNK
            local fz = (pz - reach + rng:below(2 * reach + 1)) // CHUNK
            queue.begin()
            for _ = 1, config.COLUMNS_PER_BATCH do
                column(fx * CHUNK + rng:below(CHUNK), fz * CHUNK + rng:below(CHUNK), where.y, square, tick, rng)
            end
            queue.commit()
            return
        end
    end
end

wx.on_tick(function(dt_ticks)
    since = since + dt_ticks
    if since < config.QUEUE_EVERY then
        return
    end
    since = 0
    if next(controller.squares) == nil then
        return
    end
    -- Room first: a batch nobody will land is a batch nobody should build.
    if not queue.room() then
        M.stats.no_room = M.stats.no_room + 1
        return
    end
    sample()
end)

-- ------------------------------------------------------------ puddles meeting fluids

-- Plan 5.10. Two fluids never share a block, and since engine 62608bf a flow
-- into a block of ANOTHER fluid is reported with `meets` naming it, both
-- beside and straight down. Rainwater that reaches a river, a sea or a pool
-- of anything else is LET GO: its block's fluid is cleared, as if it ran in.
-- It is not added to the other body: rain is matter this mod made from
-- nothing, and topping up the Spindle's seas with it would move their shores.
-- Against a hot fluid it goes as steam.
--
-- Registered whether or not puddles are on, so puddles left from a session
-- that had them still drain into rivers rather than lying against them.
local RAINWATER = blocks.RAINWATER
local STEAM = { r = 0.92, g = 0.94, b = 0.96, a = 0.5 }

local function let_go(position, other, toward)
    game.set_fluid(position, { volume = 0 })
    M.stats.joined = M.stats.joined + 1
    if climate.hot_fluids[other] then
        M.stats.steamed = M.stats.steamed + 1
        game.emit_particles{
            pos = { x = toward.x + 0.5, y = toward.y + 1.0, z = toward.z + 0.5 },
            count = 12, colour = STEAM, size = 0.5, lifetime = 2.0,
            velocity = { y = 1.5 }, spread = 0.6, area = { x = 0.5, y = 0.2, z = 0.5 },
            gravity = -0.5, collide = false,
        }
    end
end

game.register_on_fluid_flow(function(event)
    local meets = event.meets
    if meets == nil then
        return
    end
    if event.fluid == RAINWATER and meets ~= RAINWATER then
        let_go(event.from, meets, event.into)
    elseif meets == RAINWATER and event.fluid ~= RAINWATER then
        let_go(event.into, event.fluid, event.into)
    end
end)

-- ------------------------------------------------------------ random ticks

-- Everywhere nobody is standing. Each handler evaluates the weather function
-- (two noise reads and a square root), so a field of snow a thousand chunks
-- wide would otherwise spend the tick on it: past TICK_BUDGET a tick, a block
-- is simply passed over. It comes up again.
local TICK_BUDGET = 16
local spent, spent_at = 0, -1

local function afford()
    if spent_at ~= wx.now then
        spent_at, spent = wx.now, 0
    end
    if spent >= TICK_BUDGET or not queue.room() then
        M.stats.tick_budget = M.stats.tick_budget + 1
        return false
    end
    spent = spent + 1
    return true
end

game.register_random_tick(SNOW, function(event)
    if game.world_seed == nil or not afford() then
        return
    end
    local here = { x = event.x, y = event.y, z = event.z }
    local b = game.get_block(here)
    if b == nil or b.material ~= SNOW_ID or b.cells ~= nil then
        return
    end
    if climate.freezing(event.x, event.y, event.z) then
        return
    end
    local kind, intensity = controller.weather(event.x, event.y, event.z, wx.now, nil)
    if family_of(kind) == "snow" and intensity > 0 then
        return
    end
    queue.begin()
    push_thaw(here, b.occupancy)
    if queue.commit() then
        M.stats.tick_thaws = M.stats.tick_thaws + 1
    end
end)

for _, damp in ipairs(blocks.damp_ids) do
    game.register_random_tick(damp, function(event)
        if game.world_seed == nil or not afford() then
            return
        end
        resolve_damp()
        local here = { x = event.x, y = event.y, z = event.z }
        local b = game.get_block(here)
        if b == nil or b.cells ~= nil or b.occupancy ~= FULL or dry_of[b.material] == nil then
            return
        end
        local kind, intensity = controller.weather(event.x, event.y, event.z, wx.now, nil)
        if family_of(kind) == "rain" and intensity > 0 then
            return
        end
        queue.begin()
        queue.push(here, dry_of[b.material])
        if queue.commit() then
            M.stats.tick_dries = M.stats.tick_dries + 1
        end
    end)
end

return M
