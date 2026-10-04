-- healing/damage_attribution.lua
local mq = require('mq')
local lazy = require('smartheal.util.lazy_require')

local M = {}

local Config = nil

-- Lazy-load Logger
local getLogger = lazy.once('smartheal.logger')

-- Combat timeout tracking
local _lastDamageEvent = 0
local COMBAT_TIMEOUT = 5  -- seconds
local WINDOW_DURATION = 3  -- seconds for DPS calculation
local COMBAT_TIMEOUT_MS = COMBAT_TIMEOUT * 1000
local WINDOW_DURATION_MS = WINDOW_DURATION * 1000

-- Per-target damage attribution
local _targetDamage = {}  -- [targetId] = { sources = {}, sourceCount, totalDps, ... }

-- AE damage tracking (same mob hitting multiple targets)
local _aeDamage = {}  -- [mobId] = { targets = {}, isAE, totalDps }

-- Combat text contains only an NPC name. Keep every observed ID for that name
-- so duplicate NPCs are not silently attributed to the last scanned spawn.
local _mobNameCache = {}  -- [mobName] = { ids = {[id] = lastSeen}, lastSeen }
local _lastMobCacheRefresh = 0

-- Cache of findTargetIdByName results (keyed by lowercased attacker/target
-- name, populated on cache miss). Every damage event passes through this
-- function; each miss used to iterate the full group. We invalidate when
-- group membership changes or on combat timeout.
local _targetIdCache = {}
local _lastGroupSignature = ''

function M.init(config)
    Config = config
    COMBAT_TIMEOUT = Config and Config.combatTimeoutSec or 5
    WINDOW_DURATION = Config and Config.dpsWindowSec or 3
    COMBAT_TIMEOUT_MS = COMBAT_TIMEOUT * 1000
    WINDOW_DURATION_MS = WINDOW_DURATION * 1000
    _targetDamage = {}
    _aeDamage = {}
    _mobNameCache = {}
    _lastMobCacheRefresh = 0
    _targetIdCache = {}
    _lastGroupSignature = ''
    _lastDamageEvent = 0
end

-- Cache TTL in milliseconds (30 seconds)
local CACHE_TTL_MS = 30000
local CACHE_REFRESH_MS = 500

-- Refresh mob name cache from XTarget and prune stale entries
local function refreshMobCache()
    local now = mq.gettime()
    if (now - _lastMobCacheRefresh) < CACHE_REFRESH_MS then return end
    _lastMobCacheRefresh = now
    local me = mq.TLO.Me
    if not me or not me() then return end

    -- Prune stale entries (older than TTL)
    for name, entry in pairs(_mobNameCache) do
        for id, lastSeen in pairs(entry.ids or {}) do
            if (now - lastSeen) > CACHE_TTL_MS then entry.ids[id] = nil end
        end
        local emptyAndUnclassified = not next(entry.ids or {}) and not entry.ambiguous
        if emptyAndUnclassified or (entry.lastSeen and (now - entry.lastSeen) > CACHE_TTL_MS) then
            _mobNameCache[name] = nil
        end
    end

    -- Refresh from XTarget (normalize to lowercase for consistent lookup)
    local xtCount = tonumber(me.XTarget()) or 0
    for i = 1, xtCount do
        local xt = me.XTarget(i)
        if xt and xt() and xt.ID() and xt.ID() > 0 then
            local name = xt.CleanName() or xt.Name()
            local id = xt.ID()
            if name and id then
                local key = name:lower()
                local entry = _mobNameCache[key] or { ids = {} }
                entry.ids[id] = now
                entry.lastSeen = now
                _mobNameCache[key] = entry
            end
        end
    end
end

-- Resolve attacker name to mob ID
local function resolveMobId(attackerName)
    if not attackerName then return nil, false end

    -- Normalize to lowercase for consistent cache lookup
    local key = attackerName:lower()
    local cached = _mobNameCache[key]
    if cached then
        local found = nil
        for id in pairs(cached.ids or {}) do
            local spawn = mq.TLO.Spawn(tonumber(id) or 0)
            local live = spawn and spawn()
                and (tonumber(spawn.ID()) or 0) == (tonumber(id) or 0)
                and tostring(spawn.Type and spawn.Type() or ''):lower() == 'npc'
                and tostring((spawn.CleanName and spawn.CleanName())
                    or (spawn.Name and spawn.Name()) or ''):lower() == key
            if not live then
                cached.ids[id] = nil
                goto continue_cached_id
            end
            if found then return nil, true end
            found = id
            ::continue_cached_id::
        end
        if found then return found, false end
        if cached.ambiguous
            and (mq.gettime() - (tonumber(cached.lastSeen) or 0)) < CACHE_REFRESH_MS then
            return nil, true
        end
    end

    local query = 'npc ="' .. attackerName .. '"'
    local count = 0
    pcall(function() count = tonumber(mq.TLO.SpawnCount(query)()) or 0 end)
    if count > 1 then
        _mobNameCache[key] = { ids = {}, lastSeen = mq.gettime(), ambiguous = true }
        return nil, true
    end

    -- Fallback: direct spawn lookup. Hot path in AE fights — back-fill the
    -- cache so subsequent hits on the same mob don't re-scan spawns.
    local spawn = mq.TLO.Spawn('npc "' .. attackerName .. '"')
    if spawn and spawn() and spawn.ID() > 0 then
        local id = spawn.ID()
        local seen = mq.gettime()
        _mobNameCache[key] = { ids = { [id] = seen }, lastSeen = seen }
        return id, false
    end

    return nil, false
end

-- Refresh the group signature used to key findTargetIdByName cache. Called
-- from the hot path; short-circuits on cached match.
local function _currentGroupSignature()
    local me = mq.TLO.Me
    local myId = (me and me() and me.ID()) or 0
    local sig = tostring(myId)
    local groupCount = tonumber(mq.TLO.Group.Members()) or 0
    for i = 1, groupCount do
        local member = mq.TLO.Group.Member(i)
        if member and member() then
            local id = member.ID and member.ID()
            if id and id > 0 then
                sig = sig .. ',' .. id
            end
        end
    end
    return sig, myId, groupCount
end

-- Find target ID by name (group members only). Cached by lowercased name;
-- invalidated when the group-id signature changes (member joins/leaves/zones).
local function findTargetIdByName(name)
    if not name or name == '' then return nil end

    local lname = tostring(name):lower()
    -- Handle "YOU"/"You" as self
    if lname == 'you' then
        local me = mq.TLO.Me
        if me and me() and me.ID() then
            return me.ID()
        end
        return nil
    end

    -- Rebuild name->id map when group membership changes.
    local sig, myId, groupCount = _currentGroupSignature()
    if sig ~= _lastGroupSignature then
        _targetIdCache = {}
        _lastGroupSignature = sig

        local me = mq.TLO.Me
        if me and me() then
            local myName = me.CleanName()
            if myName and myName ~= '' and myName ~= 'NULL' then
                _targetIdCache[myName:lower()] = myId
            end
        end
        for i = 1, groupCount do
            local member = mq.TLO.Group.Member(i)
            if member and member() then
                local memberName = member.CleanName and member.CleanName() or (member.Name and member.Name())
                local id = member.ID and member.ID()
                if memberName and memberName ~= '' and memberName ~= 'NULL' and id and id > 0 then
                    _targetIdCache[memberName:lower()] = id
                end
            end
        end
    end

    return _targetIdCache[lname]
end

-- Check if combat has timed out (no damage for N seconds)
local function checkCombatTimeout()
    local now = mq.gettime()
    if _lastDamageEvent > 0 and (now - _lastDamageEvent) > COMBAT_TIMEOUT_MS then
        -- Clear all attribution data
        _targetDamage = {}
        _aeDamage = {}
        _mobNameCache = {}
        _lastDamageEvent = 0
    end
end

-- Record a damage event
function M.recordDamage(targetName, amount, attackerName, dmgType)
    if not amount or amount <= 0 then return end

    local now = mq.gettime()
    _lastDamageEvent = now

    -- Ignore outgoing damage (we're the attacker)
    if attackerName == 'You' or attackerName == 'you' then
        return
    end

    -- Resolve target
    local targetId = findTargetIdByName(targetName)
    if not targetId then return end  -- Not a group member we track

    -- Resolve mob
    local mobId, ambiguous = resolveMobId(attackerName)
    local sourcePrefix = ambiguous and 'ambiguous_' or 'unknown_'
    local sourceKey = mobId or (sourcePrefix .. tostring(attackerName or '?'):lower())

    -- Log damage event
    local log = getLogger()
    if log and log.debug then
        log.debug('attribution', 'DAMAGE: %s hit %s(id=%s) for %d (%s) mobId=%s ambiguous=%s',
            tostring(attackerName), tostring(targetName), tostring(targetId), amount, tostring(dmgType),
            tostring(mobId), tostring(ambiguous == true))
    end

    -- Initialize target tracking
    if not _targetDamage[targetId] then
        _targetDamage[targetId] = {
            sources = {},
            sourceCount = 0,
            totalDps = 0,
            primarySourceId = nil,
            primarySourceDps = 0,
            isMultiSource = false,
        }
    end

    local targetData = _targetDamage[targetId]

    -- Initialize source tracking
    if not targetData.sources[sourceKey] then
        targetData.sources[sourceKey] = {
            mobId = mobId,
            mobName = attackerName,
            ambiguous = ambiguous == true,
            lastHit = now,
            dps = 0,
            entries = {},
        }
    end

    local sourceData = targetData.sources[sourceKey]
    sourceData.lastHit = now
    table.insert(sourceData.entries, {
        time = now,
        amount = amount,
        dmgType = dmgType,
    })

    -- Track for AE detection (only if we have a mobId)
    if mobId then
        if not _aeDamage[mobId] then
            _aeDamage[mobId] = {
                targets = {},
                activeTargetCount = 0,
                isAE = false,
                totalDps = 0,
            }
        end
        _aeDamage[mobId].targets[targetId] = now
    end
end

-- Calculate DPS for a specific target
local function calculateTargetDps(targetId)
    local targetData = _targetDamage[targetId]
    if not targetData then return end

    local now = mq.gettime()
    local cutoff = now - WINDOW_DURATION_MS

    local activeSourceCount = 0
    local totalDps = 0
    local primaryId = nil
    local primaryDps = 0

    for sourceKey, sourceData in pairs(targetData.sources) do
        -- Prune old entries, sum recent damage
        local recentDamage = 0
        local recentEntries = {}

        for _, entry in ipairs(sourceData.entries) do
            if entry.time >= cutoff then
                table.insert(recentEntries, entry)
                recentDamage = recentDamage + entry.amount
            end
        end
        sourceData.entries = recentEntries

        -- Calculate this source's DPS
        local sourceDps = recentDamage / WINDOW_DURATION
        sourceData.dps = sourceDps

        if #recentEntries > 0 then
            activeSourceCount = activeSourceCount + 1
            totalDps = totalDps + sourceDps

            if sourceDps > primaryDps then
                primaryDps = sourceDps
                primaryId = sourceKey
            end
        end
    end

    -- Update aggregate fields
    targetData.sourceCount = activeSourceCount
    targetData.totalDps = totalDps
    targetData.primarySourceId = primaryId
    targetData.primarySourceDps = primaryDps
    targetData.isMultiSource = activeSourceCount >= 2
end

-- Calculate AE status for all tracked mobs
local function calculateAeStatus()
    local now = mq.gettime()
    local cutoff = now - WINDOW_DURATION_MS
    -- Mobs with no recent hits for this long get evicted entirely (they're
    -- dead or out of range). Without this, _aeDamage grew unbounded through
    -- long pulls and was only cleared on full combat timeout.
    local AE_EVICT_MS = WINDOW_DURATION_MS * 4

    for mobId, aeData in pairs(_aeDamage) do
        -- Count targets hit recently
        local activeTargets = {}
        local newestHit = 0
        for targetId, lastHit in pairs(aeData.targets) do
            if lastHit >= cutoff then
                table.insert(activeTargets, targetId)
            else
                aeData.targets[targetId] = nil  -- Prune stale
            end
            if lastHit > newestHit then newestHit = lastHit end
        end

        aeData.activeTargetCount = #activeTargets
        aeData.isAE = #activeTargets >= 2

        -- Sum DPS this mob is doing across all targets
        local totalMobDps = 0
        for _, targetId in ipairs(activeTargets) do
            local targetData = _targetDamage[targetId]
            if targetData and targetData.sources[mobId] then
                totalMobDps = totalMobDps + (targetData.sources[mobId].dps or 0)
            end
        end
        aeData.totalDps = totalMobDps

        -- Evict mobs with no active targets whose newest hit is stale.
        if aeData.activeTargetCount == 0 and (newestHit == 0 or (now - newestHit) > AE_EVICT_MS) then
            _aeDamage[mobId] = nil
        end
    end
end

-- Query: Is this target taking AE damage?
function M.isTargetInAE(targetId)
    for mobId, aeData in pairs(_aeDamage) do
        if aeData.isAE and aeData.targets[targetId] then
            return true, mobId, aeData.activeTargetCount
        end
    end
    return false, nil, 0
end

-- Query: Is there any active AE damage?
function M.hasActiveAE()
    for mobId, aeData in pairs(_aeDamage) do
        if aeData.isAE and aeData.totalDps > 0 then
            return true
        end
    end
    return false
end

-- Validate log-based DPS against HP delta DPS
function M.validateDps(targetId, hpDeltaDps)
    calculateTargetDps(targetId)
    local targetData = _targetDamage[targetId]

    local logDps = targetData and targetData.totalDps or 0
    hpDeltaDps = hpDeltaDps or 0

    local maxDps = math.max(logDps, hpDeltaDps, 1)
    local variance = math.abs(logDps - hpDeltaDps) / maxDps * 100
    local threshold = Config and Config.dpsVarianceThreshold or 25

    local result = {
        logDps = logDps,
        hpDeltaDps = hpDeltaDps,
        variance = variance,
        isReliable = variance <= threshold,
    }

    -- Log validation result
    local log = getLogger()
    if log and log.debug then
        log.debug('attribution', 'VALIDATE_DPS: target=%s logDps=%.1f hpDeltaDps=%.1f variance=%.1f%% reliable=%s',
            tostring(targetId), logDps, hpDeltaDps, variance, tostring(result.isReliable))
    end

    return result
end

-- Get damage attribution summary for a target
function M.getTargetDamageInfo(targetId)
    calculateTargetDps(targetId)
    calculateAeStatus()

    local data = _targetDamage[targetId]
    if not data then
        return {
            totalDps = 0,
            sourceCount = 0,
            isMultiSource = false,
            primarySourceDps = 0,
            primarySourceName = nil,
            isInAE = false,
            aeTargetCount = 0,
        }
    end

    local isInAE, aeMobId, aeTargetCount = M.isTargetInAE(targetId)
    local primaryName = nil
    if data.primarySourceId and data.sources[data.primarySourceId] then
        primaryName = data.sources[data.primarySourceId].mobName
    end

    return {
        totalDps = data.totalDps,
        sourceCount = data.sourceCount,
        isMultiSource = data.isMultiSource,
        primarySourceDps = data.primarySourceDps,
        primarySourceName = primaryName,
        isInAE = isInAE,
        aeTargetCount = aeTargetCount,
    }
end

-- Tick function - call each frame
function M.tick()
    checkCombatTimeout()
    refreshMobCache()
end

local _eventsRegistered = false

function M.registerEvents()
    if _eventsRegistered then return end
    _eventsRegistered = true

    -- === HIGH FREQUENCY MELEE VERBS ===

    -- punches (46,846)
    mq.event('DmgAttrPunch', '#1# punches #2# for #3# points of damage.', function(_, attacker, target, amount)
        M.recordDamage(target, tonumber(amount) or 0, attacker, 'punch')
    end)

    -- hits (42,663)
    mq.event('DmgAttrHit', '#1# hits #2# for #3# points of damage.', function(_, attacker, target, amount)
        M.recordDamage(target, tonumber(amount) or 0, attacker, 'hit')
    end)

    -- slashes (36,683)
    mq.event('DmgAttrSlash', '#1# slashes #2# for #3# points of damage.', function(_, attacker, target, amount)
        M.recordDamage(target, tonumber(amount) or 0, attacker, 'slash')
    end)

    -- bites (13,985)
    mq.event('DmgAttrBite', '#1# bites #2# for #3# points of damage.', function(_, attacker, target, amount)
        M.recordDamage(target, tonumber(amount) or 0, attacker, 'bite')
    end)

    -- pierces (9,973)
    mq.event('DmgAttrPierce', '#1# pierces #2# for #3# points of damage.', function(_, attacker, target, amount)
        M.recordDamage(target, tonumber(amount) or 0, attacker, 'pierce')
    end)

    -- kicks (9,887)
    mq.event('DmgAttrKick', '#1# kicks #2# for #3# points of damage.', function(_, attacker, target, amount)
        M.recordDamage(target, tonumber(amount) or 0, attacker, 'kick')
    end)

    -- strikes (7,632)
    mq.event('DmgAttrStrike', '#1# strikes #2# for #3# points of damage.', function(_, attacker, target, amount)
        M.recordDamage(target, tonumber(amount) or 0, attacker, 'strike')
    end)

    -- bashes (7,201)
    mq.event('DmgAttrBash', '#1# bashes #2# for #3# points of damage.', function(_, attacker, target, amount)
        M.recordDamage(target, tonumber(amount) or 0, attacker, 'bash')
    end)

    -- frenzies on (4,748)
    mq.event('DmgAttrFrenzy', '#1# frenzies on #2# for #3# points of damage.', function(_, attacker, target, amount)
        M.recordDamage(target, tonumber(amount) or 0, attacker, 'frenzy')
    end)

    -- claws (4,076)
    mq.event('DmgAttrClaw', '#1# claws #2# for #3# points of damage.', function(_, attacker, target, amount)
        M.recordDamage(target, tonumber(amount) or 0, attacker, 'claw')
    end)

    -- shoots (3,464)
    mq.event('DmgAttrShoot', '#1# shoots #2# for #3# points of damage.', function(_, attacker, target, amount)
        M.recordDamage(target, tonumber(amount) or 0, attacker, 'shoot')
    end)

    -- === MEDIUM FREQUENCY MELEE VERBS ===

    -- backstabs (2,685)
    mq.event('DmgAttrBackstab', '#1# backstabs #2# for #3# points of damage.', function(_, attacker, target, amount)
        M.recordDamage(target, tonumber(amount) or 0, attacker, 'backstab')
    end)

    -- crushes (2,556)
    mq.event('DmgAttrCrush', '#1# crushes #2# for #3# points of damage.', function(_, attacker, target, amount)
        M.recordDamage(target, tonumber(amount) or 0, attacker, 'crush')
    end)

    -- smashes (828)
    mq.event('DmgAttrSmash', '#1# smashes #2# for #3# points of damage.', function(_, attacker, target, amount)
        M.recordDamage(target, tonumber(amount) or 0, attacker, 'smash')
    end)

    -- === LOW FREQUENCY MELEE VERBS ===

    -- stings (377)
    mq.event('DmgAttrSting', '#1# stings #2# for #3# points of damage.', function(_, attacker, target, amount)
        M.recordDamage(target, tonumber(amount) or 0, attacker, 'sting')
    end)

    -- slices (146)
    mq.event('DmgAttrSlice', '#1# slices #2# for #3# points of damage.', function(_, attacker, target, amount)
        M.recordDamage(target, tonumber(amount) or 0, attacker, 'slice')
    end)

    -- gores (78)
    mq.event('DmgAttrGore', '#1# gores #2# for #3# points of damage.', function(_, attacker, target, amount)
        M.recordDamage(target, tonumber(amount) or 0, attacker, 'gore')
    end)

    -- rends (21)
    mq.event('DmgAttrRend', '#1# rends #2# for #3# points of damage.', function(_, attacker, target, amount)
        M.recordDamage(target, tonumber(amount) or 0, attacker, 'rend')
    end)

    -- mauls (1)
    mq.event('DmgAttrMaul', '#1# mauls #2# for #3# points of damage.', function(_, attacker, target, amount)
        M.recordDamage(target, tonumber(amount) or 0, attacker, 'maul')
    end)

    -- === SPELL/DOT DAMAGE ===

    -- Spell damage
    mq.event('DmgAttrSpell', '#1# hit #2# for #3# points of #4# damage by #5#.', function(_, caster, target, amount, dmgType, spell)
        M.recordDamage(target, tonumber(amount) or 0, caster, 'spell')
    end)

    -- DoT damage
    mq.event('DmgAttrDot', '#1# has taken #2# damage from #3# by #4#.', function(_, target, amount, spell, caster)
        M.recordDamage(target, tonumber(amount) or 0, caster, 'dot')
    end)

    -- Non-melee to self (no attacker specified)
    mq.event('DmgAttrNonMeleeSelf', 'You were hit by non-melee for #1# damage.', function(_, amount)
        local myName = mq.TLO.Me.CleanName()
        M.recordDamage(myName, tonumber(amount) or 0, 'unknown', 'nonmelee')
    end)

    -- Non-melee to others
    mq.event('DmgAttrNonMeleeOther', '#1# was hit by non-melee for #2# points of damage.', function(_, target, amount)
        M.recordDamage(target, tonumber(amount) or 0, 'unknown', 'nonmelee')
    end)
end

return M
