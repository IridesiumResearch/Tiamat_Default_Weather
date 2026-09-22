-- SPDX-License-Identifier: MIT
--
-- The paced edit queue: a smaller, more conservative version of the
-- Spindle's edits.lua, because two mods now spend the relight budget
-- without knowing about each other (plan 5.2).
--
-- Every block changed at runtime costs the server a relight of its chunk
-- and every client a remesh, so what matters is how many CHUNKS a tick
-- touches, not how many edits. So:
--
-- * one batch lands every QUEUE_EVERY ticks, at most;
-- * a batch touches at most BATCH_CHUNKS chunks (the sampler builds each from
--   one chunk footprint; this file enforces it);
-- * at most MAX_WAITING batches wait, and `room()` is asked BEFORE anybody
--   does the work of building one, so nothing is scanned and thrown away;
-- * when the engine refuses an edit (`set_block` answers false: its queue is
--   full), the rest of that batch is dropped and the queue backs off for
--   BACKOFF_TICKS. That is the yield to the Spindle's trees. Dropping is
--   safe: every edit here is re-derived from the ground when its column is
--   next sampled.

local config = wx.config

local M = {}

local batches = {}
local head, tail = 1, 0
local cooldown = 0
local backoff = 0
local current = nil

M.stats = { committed = 0, landed = 0, edits = 0, fluids = 0, refused = 0, dropped = 0, full = 0, clipped = 0 }

function M.waiting()
    return tail - head + 1
end

-- Whether a batch would be accepted now. Ask before doing the work.
function M.room()
    return backoff <= 0 and M.waiting() < config.MAX_WAITING
end

function M.begin()
    current = {}
end

---@param position { x: integer, y: integer, z: integer }
---@param block string a qualified block id, or "engine:air"
---@param occupancy integer? the cells, or nil for the whole block
function M.push(position, block, occupancy)
    assert(current, "queue.push outside begin/commit")
    current[#current + 1] = { position, block, occupancy }
end

-- A fluid write rides in the same batch, paced the same way: a puddle is a
-- remesh for every client that can see it, like a block.
---@param position { x: integer, y: integer, z: integer }
---@param fluid string a qualified fluid id
---@param volume integer cells of 27
function M.push_fluid(position, fluid, volume)
    assert(current, "queue.push_fluid outside begin/commit")
    current[#current + 1] = { position, nil, nil, { fluid = fluid, volume = volume } }
end

local CHUNK = 16

-- Queues the batch. False, with nothing queued, if there was no room.
function M.commit()
    local batch = current
    current = nil
    if batch == nil or #batch == 0 then
        return true
    end
    if not M.room() then
        M.stats.full = M.stats.full + 1
        return false
    end
    -- Keep only the edits in the first BATCH_CHUNKS chunks named.
    local chunks, count, kept = {}, 0, {}
    for _, edit in ipairs(batch) do
        local p = edit[1]
        local key = (p.x // CHUNK) .. ":" .. (p.y // CHUNK) .. ":" .. (p.z // CHUNK)
        if not chunks[key] then
            if count < config.BATCH_CHUNKS then
                chunks[key] = true
                count = count + 1
            end
        end
        if chunks[key] then
            kept[#kept + 1] = edit
        else
            M.stats.clipped = M.stats.clipped + 1
        end
    end
    tail = tail + 1
    batches[tail] = kept
    M.stats.committed = M.stats.committed + 1
    return true
end

wx.on_tick(function(dt_ticks)
    if backoff > 0 then
        backoff = backoff - dt_ticks
        return
    end
    cooldown = cooldown - dt_ticks
    if cooldown > 0 or head > tail then
        return
    end
    cooldown = config.QUEUE_EVERY
    local batch = batches[head]
    batches[head] = nil
    head = head + 1
    if head > tail then
        head, tail = 1, 0
    end
    for i, edit in ipairs(batch) do
        if edit[4] then
            -- A fluid write answers "changed", not "queued": false is not a
            -- full queue, so it never backs off.
            if game.set_fluid(edit[1], edit[4]) then
                M.stats.fluids = M.stats.fluids + 1
            end
        elseif game.set_block(edit[1], edit[2], edit[3]) then
            M.stats.edits = M.stats.edits + 1
        else
            M.stats.refused = M.stats.refused + 1
            M.stats.dropped = M.stats.dropped + (#batch - i)
            backoff = config.BACKOFF_TICKS
            return
        end
    end
    M.stats.landed = M.stats.landed + 1
end)

return M
