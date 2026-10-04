-- healing/incoming_heals.lua
local mq = require('mq')
local lazy = require('smartheal.util.lazy_require')

local M = {}

local Config = nil
local TargetMonitor = nil

-- Lazy-load Analytics to avoid circular require
local getAnalytics = lazy.once('smartheal.analytics')

-- Incoming heals from all healers: [targetId][healerId] = data
local _incoming = {}

-- My character ID
local _myId = nil

function M.init(config, targetMonitor)
    Config = config
    TargetMonitor = targetMonitor
    _incoming = {}
    _myId = mq.TLO.Me.ID()
end

function M.getMyId()
    if not _myId or _myId <= 0 then
        local ok, id = pcall(function() return mq.TLO.Me.ID() end)
        if ok and id and id > 0 then
            _myId = id
        end
    end
    return _myId or 0
end

function M.add(healerId, targetId, data)
    if not targetId or targetId <= 0 then return end

    -- Use mq.gettime() for wall-clock accuracy (milliseconds)
    local now = mq.gettime()
    local castDurationMs = (tonumber(data.castDuration) or 2.0) * 1000
    local remainingMs = tonumber(data.remainingMs)
    _incoming[targetId] = _incoming[targetId] or {}
    _incoming[targetId][healerId] = {
        spellName = data.spellName,
        expectedAmount = tonumber(data.expectedAmount) or 0,
        castStartTime = tonumber(data.castStartTime) or now,
        -- Cross-client messages carry a duration, not another process's
        -- mq.gettime() deadline. Local registrations may still pass landsAt.
        landsAt = remainingMs and (now + math.max(0, remainingMs))
            or tonumber(data.landsAt)
            or (now + castDurationMs),
        isHoT = data.isHoT or false,
        hotExpiresAt = tonumber(data.hotExpiresAt),
    }

    M.updateTargetIncoming(targetId)
end

function M.remove(healerId, targetId)
    if not targetId or not _incoming[targetId] then return end

    _incoming[targetId][healerId] = nil

    -- Clean up empty target entries
    local hasAny = false
    for _ in pairs(_incoming[targetId]) do
        hasAny = true
        break
    end
    if not hasAny then
        _incoming[targetId] = nil
    end

    M.updateTargetIncoming(targetId)
end

function M.getForTarget(targetId)
    return _incoming[targetId] or {}
end

--- Read-only snapshot of all in-flight heals across every target.
--- Caller must treat as read-only.
function M.getAll()
    return _incoming
end

function M.sumForTarget(targetId, excludeHealerId)
    local total = 0
    local entries = _incoming[targetId]
    if not entries then return 0 end

    local now = mq.gettime()
    for healerId, data in pairs(entries) do
        -- Only count heals that haven't landed yet
        if healerId ~= excludeHealerId and data.landsAt > now then
            total = total + (data.expectedAmount or 0)
        end
    end

    return total
end

function M.updateTargetIncoming(targetId)
    if TargetMonitor then
        local total = M.sumForTarget(targetId)
        TargetMonitor.updateIncoming(targetId, total)
    end
end

function M.prune()
    local now = mq.gettime()
    -- Default timeout reduced to 3 seconds - heals should land within cast time + buffer
    local timeoutSec = (Config and Config.incomingHealTimeoutSec ~= nil) and Config.incomingHealTimeoutSec or 3
    local timeoutMs = timeoutSec * 1000

    local targetsToUpdate = {}

    for targetId, entries in pairs(_incoming) do
        local hadPruned = false
        for healerId, data in pairs(entries) do
            -- Remove if past expected land time + timeout
            if data.landsAt and (now - data.landsAt) > timeoutMs then
                entries[healerId] = nil
                hadPruned = true

                -- Track expired incoming heals in analytics
                local analytics = getAnalytics()
                if analytics and analytics.recordIncomingExpired then
                    analytics.recordIncomingExpired()
                end
            end
        end

        -- Clean up empty target entries
        local hasAny = false
        for _ in pairs(entries) do
            hasAny = true
            break
        end
        if not hasAny then
            _incoming[targetId] = nil
        end

        -- Mark for update if we pruned anything
        if hadPruned then
            table.insert(targetsToUpdate, targetId)
        end
    end

    -- Update target monitor with new totals after pruning
    for _, targetId in ipairs(targetsToUpdate) do
        M.updateTargetIncoming(targetId)
    end
end

function M.tick()
    M.prune()
end

-- Called when we start casting a heal
-- Note: hotTickAmount param kept for backward compatibility but not stored (unused)
function M.registerMyCast(targetId, spellName, expectedAmount, castDuration, isHoT, hotTickAmount, hotDuration)
    local now = mq.gettime()
    local castDurationMs = (tonumber(castDuration) or 2.0) * 1000
    local hotDurationMs = (tonumber(hotDuration) or 0) * 1000
    M.add(M.getMyId(), targetId, {
        spellName = spellName,
        expectedAmount = expectedAmount,
        castStartTime = now,
        landsAt = now + castDurationMs,
        isHoT = isHoT,
        hotExpiresAt = isHoT and (now + castDurationMs + hotDurationMs) or nil,
    })
end

-- Called when our cast completes or is cancelled
function M.unregisterMyCast(targetId)
    M.remove(M.getMyId(), targetId)
end

return M
