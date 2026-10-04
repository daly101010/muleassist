-- healing/spell_events.lua
local mq = require('mq')
local lazy = require('smartheal.util.lazy_require')

local M = {}

-- Lazy-load Logger to avoid circular requires
local getLogger = lazy.once('smartheal.logger')

local HealTracker = nil
local IncomingHeals = nil
local Analytics = nil
local Config = nil
local CombatAssessor = nil

-- Lazy-load CombatAssessor for throttle tracking
local getCombatAssessor = lazy.once('smartheal.combat_assessor')

local _currentCast = nil
local _eventHandlers = {}
local _pendingHotHeals = {}
local TICK_MS = 6000  -- 6 seconds in milliseconds

-- Get current time in milliseconds. Prefers mq.TLO.Time.MillisecondsSinceEpoch
-- when available; falls back to mq.gettime() so the clock baseline matches
-- everything else in the system. Previously fell back to os.time()*1000
-- (epoch ms ~1.7e12), which would silently disagree with mq.gettime() values
-- (boot ms ~1e7) elsewhere — any cross-comparison would be wildly off.
local function nowMs()
    local tloTime = mq.TLO.Time.MillisecondsSinceEpoch
    if tloTime then
        local ok, value = pcall(function() return tloTime() end)
        if ok and value and type(value) == 'number' then
            return value
        end
    end
    return mq.gettime and mq.gettime() or (os.time() * 1000)
end

-- Callbacks for broadcasting (set by init.lua to avoid circular require)
local _broadcastLandedCallback = nil
local _broadcastCancelledCallback = nil

function M.init(healTracker, incomingHeals, analytics, config)
    HealTracker = healTracker
    IncomingHeals = incomingHeals
    Analytics = analytics
    Config = config

    M.registerEvents()
end

local function normalizeKey(value)
    if not value then return '' end
    return tostring(value):lower()
end

local function canonicalSpellName(spellName)
    if not spellName then return nil end
    local cleaned = tostring(spellName):gsub('%s+$', '')
    cleaned = cleaned:gsub('%s*%((C|c)ritical%)$', ''):gsub('%s+$', '')
    cleaned = cleaned:gsub('%.$', ''):gsub('%s+$', '')
    local spell = mq.TLO.Spell(cleaned)
    if spell and spell() and spell.Name then
        local name = spell.Name()
        if name and name ~= '' then
            cleaned = name
        end
    end
    cleaned = cleaned:gsub('%s+[Rr]k%.?%s*[%w]+$', '')
    cleaned = cleaned:gsub('%s+[Rr]ank%s*[%w]+$', '')
    cleaned = cleaned:gsub('%.$', ''):gsub('%s+$', '')
    return cleaned
end

local function getHotTickCount(spellName, durationSec)
    local ticks = 0
    local log = getLogger()

    -- First try from passed durationSec (in seconds, divide by 6 seconds per tick)
    if durationSec and durationSec > 0 then
        ticks = math.floor(durationSec / (TICK_MS / 1000))
        if log then
            log.debug('events', 'getHotTickCount(%s): from durationSec=%d -> %d ticks',
                tostring(spellName), durationSec, ticks)
        end
    end
    if ticks > 0 then return ticks end

    -- Fallback to TLO - MyDuration returns tick count directly
    local spell = mq.TLO.Spell(spellName)
    if spell and spell() then
        local myDuration = 0
        pcall(function()
            ---@diagnostic disable-next-line: undefined-field
            if mq.TLO.Me and mq.TLO.Me.Spell then
                ---@diagnostic disable-next-line: undefined-field
                local mySpell = mq.TLO.Me.Spell(spellName)
                if mySpell and mySpell() then
                    myDuration = tonumber(mySpell.MyDuration()) or 0
                end
            end
        end)
        local baseDuration = tonumber(spell.Duration()) or 0

        -- MyDuration and Duration return tick count directly in MQ
        ticks = myDuration > 0 and myDuration or baseDuration

        if log then
            log.debug('events', 'getHotTickCount(%s): MyDuration=%d Duration=%d -> %d ticks',
                tostring(spellName), myDuration, baseDuration, ticks)
        end
    end
    return ticks or 0
end

local function getExpectedTick(spellName, fallback)
    local expected = fallback or 0
    if expected <= 0 and HealTracker and HealTracker.getExpected then
        expected = HealTracker.getExpected(spellName, 'tick') or 0
    end
    if expected <= 0 then
        local spell = mq.TLO.Spell(spellName)
        if spell and spell() then
            local base = tonumber(spell.Base(1)()) or 0
            if base > 0 then expected = base end
        end
    end
    return expected
end

local function registerHotTarget(targetName, spellName, expectedTick, durationSec)
    if not targetName or not spellName then return end
    local rawSpellName = spellName
    spellName = canonicalSpellName(spellName)
    local keyTarget = normalizeKey(targetName)
    local keySpell = normalizeKey(spellName)
    local ticksTotal = getHotTickCount(rawSpellName, durationSec)
    local tickExpected = getExpectedTick(spellName, expectedTick)
    local expectedTotal = (tickExpected > 0 and ticksTotal > 0) and (tickExpected * ticksTotal) or 0
    local now = nowMs()
    local windowMs = (ticksTotal > 0 and ticksTotal * TICK_MS) or ((durationSec or 0) * 1000)
    if windowMs <= 0 then windowMs = TICK_MS * 3 end

    -- Single and group HoTs share one non-stacking effect on each recipient.
    _pendingHotHeals[keyTarget] = {}
    _pendingHotHeals[keyTarget][keySpell] = {
        target = targetName,
        spell = spellName,
        expectedTick = tickExpected,
        ticksTotal = ticksTotal,
        expectedTotal = expectedTotal,
        ticksSeen = 0,
        expectedUsed = 0,
        actualTotal = 0,
        castTimeMs = now,
        durationMs = windowMs,
        expiresAtMs = now + windowMs,
    }

    local log = getLogger()
    if log then
        log.info('events', 'HOT_REGISTERED: spell=%s target=%s ticks=%d expectedTick=%d',
            tostring(spellName), tostring(targetName), ticksTotal, tickExpected)
    end
end

local function recordHotCast(spellName)
    if Analytics and Analytics.recordHotCast then
        local spell = mq.TLO.Spell(spellName)
        local mana = spell and spell() and tonumber(spell.Mana()) or 0
        Analytics.recordHotCast(canonicalSpellName(spellName), mana)
    end
end

function M.registerHotCast(targetName, spellName, expectedTick, durationSec, castTime)
    if not targetName or not spellName then return end
    registerHotTarget(targetName, spellName, expectedTick, durationSec)
    recordHotCast(spellName)
end

function M.registerGroupHotCast(targetNames, spellName, expectedPerTarget, durationSec, castTime)
    if not targetNames or not spellName then return end
    -- Use the same per-target slot as single HoTs. A later single replaces only
    -- its recipient; a later group cast leaves out-of-range recipients intact.
    for _, name in ipairs(targetNames) do
        if name and name ~= '' then
            registerHotTarget(name, spellName, expectedPerTarget, durationSec)
        end
    end
    recordHotCast(spellName)
end

-- Remaining time is calculated here so callers never mix epoch and MQ clocks.
function M.getActiveHot(targetName)
    local perTarget = _pendingHotHeals[normalizeKey(targetName)]
    if not perTarget then return nil, 0 end
    local _, info = next(perTarget)
    if not info then return nil, 0 end
    return info, math.max(0, (info.expiresAtMs or 0) - nowMs())
end

function M.getIncomingHotRemaining(targetName)
    if not targetName then return 0, {} end
    local keyTarget = normalizeKey(targetName)
    local now = nowMs()
    local total = 0
    local details = {}
    local bySpell = {}

    local perTarget = _pendingHotHeals[keyTarget]
    if perTarget then
        for _, info in pairs(perTarget) do
            local ticksTotal = info.ticksTotal or 0
            local expectedTick = info.expectedTick or 0
            if ticksTotal > 0 and expectedTick > 0 then
                local elapsedMs = now - (info.castTimeMs or now)
                local ticksElapsed = math.floor(elapsedMs / TICK_MS)
                local ticksRemaining = math.max(0, ticksTotal - math.max(ticksElapsed, info.ticksSeen or 0))
                local remaining = expectedTick * ticksRemaining
                bySpell[normalizeKey(info.spell)] = remaining
                if remaining > 0 then
                    table.insert(details, string.format('%s:%d*%d=%d', info.spell or '?', expectedTick, ticksRemaining, remaining))
                end
            end
        end
    end

    for _, amount in pairs(bySpell) do total = total + amount end
    return total, details, bySpell
end

-- Check if a spell is one of our configured healing spells
local function isConfiguredHealSpell(spellName)
    if not Config or not Config.spells or not spellName then
        return false
    end
    local normalized = canonicalSpellName(spellName) or spellName
    local lowerName = normalized:lower()
    for _, spells in pairs(Config.spells) do
        for _, name in ipairs(spells) do
            if name:lower() == lowerName then
                return true
            end
        end
    end
    return false
end

function M.setBroadcastCallbacks(landedCallback, cancelledCallback)
    _broadcastLandedCallback = landedCallback
    _broadcastCancelledCallback = cancelledCallback
end

local _eventsRegistered = false

-- List of all event names we register (for cleanup)
local _eventNames = {
    'HealLandedCrit', 'HealLanded', 'HealLandedNoFullCrit', 'HealLandedNoFull',
    'HealLandedHaveCrit', 'HealLandedHave', 'HealLandedHaveNoFullCrit', 'HealLandedHaveNoFull',
    'HotLandedCrit', 'HotLandedNoFullCrit', 'HotLanded', 'HotLandedNoFull',
    'HotLandedHave', 'HotLandedHaveNoFull', 'HotLandedHaveCrit', 'HotLandedHaveNoFullCrit',
    'SpellInterrupted', 'SpellFizzle', 'SpellNotHold',
}

function M.unregisterEvents()
    -- Clean up any existing event handlers before re-registering
    for _, eventName in ipairs(_eventNames) do
        pcall(function() mq.unevent(eventName) end)
    end
    _eventsRegistered = false
end

function M.registerEvents()
    local log = getLogger()

    -- Always unregister first to prevent duplicates (handles script reload)
    M.unregisterEvents()

    if log then log.info('events', 'Registering heal event handlers (cleaned up old handlers first)') end
    _eventsRegistered = true

    -- Direct heals (with potential/Full indicator in #3#)
    -- EQ format: "You healed Bob for 5000 (8000) hit points by Remedy." or "... (Full) ..."
    -- Critical versions must come first (more specific) so they match before non-crit versions
    mq.event('HealLandedCrit', 'You healed #1# for #2# (#3#) hit points by #4#. (Critical)', function(line, target, amount, potential, spell)
        local eventLog = getLogger()
        if eventLog then eventLog.info('events', 'EVENT[HealLandedCrit]: target=%s amount=%s potential=%s spell=%s', tostring(target), tostring(amount), tostring(potential), tostring(spell)) end
        M.onHealLanded(target, amount, spell, true, false, potential)
    end)

    mq.event('HealLanded', 'You healed #1# for #2# (#3#) hit points by #4#.', function(line, target, amount, potential, spell)
        local eventLog = getLogger()
        if eventLog then eventLog.info('events', 'EVENT[HealLanded]: target=%s amount=%s potential=%s spell=%s', tostring(target), tostring(amount), tostring(potential), tostring(spell)) end
        M.onHealLanded(target, amount, spell, false, false, potential)
    end)

    -- NoFull variants don't have potential info - assume no overheal
    -- Critical versions must come first
    -- Guard: Skip if amount contains '(' which means the Full pattern should have matched
    mq.event('HealLandedNoFullCrit', 'You healed #1# for #2# hit points by #3#. (Critical)', function(line, target, amount, spell)
        if tostring(amount):find('%(') then return end
        local eventLog = getLogger()
        if eventLog then eventLog.info('events', 'EVENT[HealLandedNoFullCrit]: target=%s amount=%s spell=%s', tostring(target), tostring(amount), tostring(spell)) end
        M.onHealLanded(target, amount, spell, true, false, nil)
    end)

    mq.event('HealLandedNoFull', 'You healed #1# for #2# hit points by #3#.', function(line, target, amount, spell)
        if tostring(amount):find('%(') then return end
        local eventLog = getLogger()
        if eventLog then eventLog.info('events', 'EVENT[HealLandedNoFull]: target=%s amount=%s spell=%s', tostring(target), tostring(amount), tostring(spell)) end
        M.onHealLanded(target, amount, spell, false, false, nil)
    end)

    -- "You have healed" variants
    -- Critical versions must come first
    mq.event('HealLandedHaveCrit', 'You have healed #1# for #2# (#3#) hit points by #4#. (Critical)', function(line, target, amount, potential, spell)
        local eventLog = getLogger()
        if eventLog then eventLog.info('events', 'EVENT[HealLandedHaveCrit]: target=%s amount=%s potential=%s spell=%s', tostring(target), tostring(amount), tostring(potential), tostring(spell)) end
        M.onHealLanded(target, amount, spell, true, false, potential)
    end)

    mq.event('HealLandedHave', 'You have healed #1# for #2# (#3#) hit points by #4#.', function(line, target, amount, potential, spell)
        local eventLog = getLogger()
        if eventLog then eventLog.info('events', 'EVENT[HealLandedHave]: target=%s amount=%s potential=%s spell=%s', tostring(target), tostring(amount), tostring(potential), tostring(spell)) end
        M.onHealLanded(target, amount, spell, false, false, potential)
    end)

    mq.event('HealLandedHaveNoFullCrit', 'You have healed #1# for #2# hit points by #3#. (Critical)', function(line, target, amount, spell)
        if tostring(amount):find('%(') then return end
        local eventLog = getLogger()
        if eventLog then eventLog.info('events', 'EVENT[HealLandedHaveNoFullCrit]: target=%s amount=%s spell=%s', tostring(target), tostring(amount), tostring(spell)) end
        M.onHealLanded(target, amount, spell, true, false, nil)
    end)

    mq.event('HealLandedHaveNoFull', 'You have healed #1# for #2# hit points by #3#.', function(line, target, amount, spell)
        if tostring(amount):find('%(') then return end
        local eventLog = getLogger()
        if eventLog then eventLog.info('events', 'EVENT[HealLandedHaveNoFull]: target=%s amount=%s spell=%s', tostring(target), tostring(amount), tostring(spell)) end
        M.onHealLanded(target, amount, spell, false, false, nil)
    end)

    -- HoT ticks (with potential/Full indicator)
    -- Critical versions must come first (more specific)
    mq.event('HotLandedCrit', 'You healed #1# over time for #2# (#3#) hit points by #4#. (Critical)', function(line, target, amount, potential, spell)
        local eventLog = getLogger()
        if eventLog then eventLog.info('events', 'EVENT[HotLandedCrit]: target=%s amount=%s potential=%s spell=%s', tostring(target), tostring(amount), tostring(potential), tostring(spell)) end
        M.onHealLanded(target, amount, spell, true, true, potential)
    end)

    mq.event('HotLandedNoFullCrit', 'You healed #1# over time for #2# hit points by #3#. (Critical)', function(line, target, amount, spell)
        -- Skip if amount contains '(' - means this message should have matched the Full pattern
        if tostring(amount):find('%(') then return end
        local eventLog = getLogger()
        if eventLog then eventLog.info('events', 'EVENT[HotLandedNoFullCrit]: target=%s amount=%s spell=%s', tostring(target), tostring(amount), tostring(spell)) end
        M.onHealLanded(target, amount, spell, true, true, nil)
    end)

    -- Non-critical versions (WITH trailing period to match actual EQ messages)
    mq.event('HotLanded', 'You healed #1# over time for #2# (#3#) hit points by #4#.', function(line, target, amount, potential, spell)
        local eventLog = getLogger()
        if eventLog then eventLog.info('events', 'EVENT[HotLanded]: target=%s amount=%s potential=%s spell=%s', tostring(target), tostring(amount), tostring(potential), tostring(spell)) end
        M.onHealLanded(target, amount, spell, false, true, potential)
    end)

    mq.event('HotLandedNoFull', 'You healed #1# over time for #2# hit points by #3#.', function(line, target, amount, spell)
        -- Skip if amount contains '(' - means this message should have matched the Full pattern
        if tostring(amount):find('%(') then return end
        local eventLog = getLogger()
        if eventLog then eventLog.info('events', 'EVENT[HotLandedNoFull]: target=%s amount=%s spell=%s', tostring(target), tostring(amount), tostring(spell)) end
        M.onHealLanded(target, amount, spell, false, true, nil)
    end)

    -- "You have healed" HoT variants (WITH trailing period)
    mq.event('HotLandedHave', 'You have healed #1# over time for #2# (#3#) hit points by #4#.', function(line, target, amount, potential, spell)
        local eventLog = getLogger()
        if eventLog then eventLog.info('events', 'EVENT[HotLandedHave]: target=%s amount=%s potential=%s spell=%s', tostring(target), tostring(amount), tostring(potential), tostring(spell)) end
        M.onHealLanded(target, amount, spell, false, true, potential)
    end)

    mq.event('HotLandedHaveNoFull', 'You have healed #1# over time for #2# hit points by #3#.', function(line, target, amount, spell)
        -- Skip if amount contains '(' - means this message should have matched the Full pattern
        if tostring(amount):find('%(') then return end
        local eventLog = getLogger()
        if eventLog then eventLog.info('events', 'EVENT[HotLandedHaveNoFull]: target=%s amount=%s spell=%s', tostring(target), tostring(amount), tostring(spell)) end
        M.onHealLanded(target, amount, spell, false, true, nil)
    end)

    mq.event('HotLandedHaveCrit', 'You have healed #1# over time for #2# (#3#) hit points by #4#. (Critical)', function(line, target, amount, potential, spell)
        local eventLog = getLogger()
        if eventLog then eventLog.info('events', 'EVENT[HotLandedHaveCrit]: target=%s amount=%s potential=%s spell=%s', tostring(target), tostring(amount), tostring(potential), tostring(spell)) end
        M.onHealLanded(target, amount, spell, true, true, potential)
    end)

    mq.event('HotLandedHaveNoFullCrit', 'You have healed #1# over time for #2# hit points by #3#. (Critical)', function(line, target, amount, spell)
        -- Skip if amount contains '(' - means this message should have matched the Full pattern
        if tostring(amount):find('%(') then return end
        local eventLog = getLogger()
        if eventLog then eventLog.info('events', 'EVENT[HotLandedHaveNoFullCrit]: target=%s amount=%s spell=%s', tostring(target), tostring(amount), tostring(spell)) end
        M.onHealLanded(target, amount, spell, true, true, nil)
    end)

    -- Interrupts
    mq.event('SpellInterrupted', 'Your spell is interrupted.', function()
        M.onInterrupt('interrupted')
    end)

    mq.event('SpellFizzle', 'Your spell fizzles!', function()
        M.onInterrupt('fizzle')
    end)

    mq.event('SpellNotHold', 'Your target cannot be healed.', function()
        M.onInterrupt('invalid_target')
    end)
end

-- AA proc heals that shouldn't be tracked as cast HoTs
-- These fire automatically and pollute HoT analytics
local IGNORED_PROC_HEALS = {
    ['abundant healing'] = true,  -- Cleric AA proc
}

local function isIgnoredProcHeal(spellName)
    if not spellName then return false end
    local lower = tostring(spellName):lower()
    for procName, _ in pairs(IGNORED_PROC_HEALS) do
        if lower:find(procName, 1, true) then
            return true
        end
    end
    return false
end

function M.onHealLanded(targetName, amount, spellName, isCrit, isHoT, potential)
    amount = tonumber(amount) or 0
    local log = getLogger()

    -- GUARD: Skip AA proc heals (Abundant Healing, etc.) - these are passive and shouldn't be tracked
    if isIgnoredProcHeal(spellName) then
        if log then
            log.debug('events', 'SKIP: Ignored proc heal (spell=%s)', tostring(spellName))
        end
        return
    end

    -- GUARD: Skip if this is a direct heal pattern that incorrectly matched a HoT message
    -- (detected by "over time" being captured in the target name)
    if not isHoT and targetName and tostring(targetName):find('over time') then
        if log then
            log.debug('events', 'SKIP: Direct heal pattern incorrectly matched HoT message (target=%s)', tostring(targetName))
        end
        return
    end

    -- GUARD: Skip duplicate pattern matches (amount=0 with nil potential means NoFull pattern matched after Full pattern)
    if amount == 0 and potential == nil then
        if log then
            log.debug('events', 'SKIP: Duplicate pattern match (amount=0, potential=nil)')
        end
        return
    end

    -- Preserve raw spell name for TLO lookups before canonicalizing
    local rawSpellName = spellName
    -- Clean up trailing period but keep rank for TLO lookups
    local tloSpellName = rawSpellName and tostring(rawSpellName):gsub('%.$', ''):gsub('%s+$', '') or nil
    spellName = canonicalSpellName(spellName)

    -- Log entry point with all parameters
    if log then
        log.info('events', 'PROCESS_HEAL: type=%s target=%s rawSpell=%s canonSpell=%s amount=%d potential=%s crit=%s',
            isHoT and 'HOT' or 'DIRECT', tostring(targetName), tostring(rawSpellName), tostring(spellName),
            amount, tostring(potential), tostring(isCrit))
    end

    -- Only track spells that are configured as healing spells OR match our current cast
    local isConfigured = isConfiguredHealSpell(spellName)
    local isCurrentCast = _currentCast and _currentCast.spellName and
        normalizeKey(canonicalSpellName(_currentCast.spellName)) == normalizeKey(spellName or '')

    if log then
        log.debug('events', 'PROCESS_HEAL: isConfigured=%s isCurrentCast=%s',
            tostring(isConfigured), tostring(isCurrentCast))
    end

    -- HoT tick handling - always record these since EQ explicitly tells us it's a HoT
    if isHoT then
        -- Calculate HoT overheal from potential value
        local hotOverheal = 0
        if potential then
            local potentialLower = tostring(potential):lower()
            if potentialLower == 'full' then
                -- "Full" means target was at 100% HP - entire tick was overheal
                -- Use tloSpellName (with rank) for TLO lookup
                local lookupName = tloSpellName or spellName
                if lookupName then
                    local spell = mq.TLO.Spell(lookupName)
                    if spell and spell() then
                        local baseHeal = tonumber(spell.Base(1)()) or 0
                        if baseHeal > 0 then
                            hotOverheal = baseHeal
                        end
                    end
                end
            else
                local potentialNum = tonumber(potential)
                if potentialNum and potentialNum > amount then
                    hotOverheal = potentialNum - amount
                end
            end
        end

        if log then
            log.debug('events', 'HoT tick: spell=%s target=%s amount=%d overheal=%d configured=%s',
                tostring(spellName), tostring(targetName), amount, hotOverheal, tostring(isConfigured))
        end

        -- Record HoT ticks to analytics even if amount is 0 (useless tick tracking)
        -- EQ explicitly says "over time" so we know it's a HoT - track it regardless of config
        if Analytics and Analytics.recordHotTick then
            Analytics.recordHotTick(spellName, amount, hotOverheal, isCrit)
        end

        -- Also track to HealTracker for learning (only if configured)
        -- Use full potential (amount + overheal) so learned data reflects actual spell power
        local fullHotHeal = amount + hotOverheal
        if isConfigured and HealTracker and fullHotHeal > 0 then
            if log then
                log.debug('events', 'Recording HoT to HealTracker: %s amount=%d overheal=%d full=%d crit=%s',
                    tostring(spellName), amount, hotOverheal, fullHotHeal, tostring(isCrit))
            end
            HealTracker.recordHeal(spellName, fullHotHeal, isCrit, true)
        end

        -- Track pending HoT tick usage
        local keyTarget = normalizeKey(targetName)
        local keySpell = normalizeKey(spellName)
        local hotInfo = _pendingHotHeals[keyTarget] and _pendingHotHeals[keyTarget][keySpell] or nil

        -- Check if existing HoT tracking has expired (tick from a NEW cast of same spell)
        -- If so, finalize old tracking and treat this as a new HoT
        if hotInfo and hotInfo.expiresAtMs then
            local now = nowMs()
            if now > hotInfo.expiresAtMs then
                -- Old HoT expired - finalize it and clear for re-registration
                local ticksTotal = hotInfo.ticksTotal or 0
                local ticksSeen = hotInfo.ticksSeen or 0
                local missedTicks = math.max(0, ticksTotal - ticksSeen)
                if missedTicks > 0 and Analytics and Analytics.recordHotMissed then
                    Analytics.recordHotMissed(hotInfo.spell, missedTicks, hotInfo.expectedTick or 0)
                end
                if log then
                    log.debug('events', 'HoT expired (new tick detected): %s on %s - %d/%d ticks seen, %d missed',
                        hotInfo.spell or '?', hotInfo.target or '?', ticksSeen, ticksTotal, missedTicks)
                end
                -- Clear old tracking so we re-register below
                _pendingHotHeals[keyTarget][keySpell] = nil
                hotInfo = nil
            end
        end

        -- Auto-register HoT if we see a tick but don't have it tracked (manual cast or other source)
        -- Use tloSpellName (with rank) for TLO lookup, but canonical spellName for storage key
        if not hotInfo and spellName then
            local ticksTotal = getHotTickCount(tloSpellName or spellName, nil)
            if ticksTotal > 0 then
                -- Calculate full potential for this tick
                local fullTickHeal = amount + hotOverheal
                local now = nowMs()
                local windowMs = ticksTotal * TICK_MS

                -- The first observed tick fires ~one tick interval after the
                -- actual cast. Anchor castTime backwards by TICK_MS so the
                -- expiry isn't overestimated by ~6s of healing — otherwise
                -- getIncomingHotRemaining over-counts and SelectHeal skips
                -- direct heals it should have fired.
                local castTime = now - TICK_MS
                -- A tick from a different HoT proves that effect replaced the old one.
                _pendingHotHeals[keyTarget] = {}
                _pendingHotHeals[keyTarget][keySpell] = {
                    target = targetName,
                    spell = spellName,
                    expectedTick = fullTickHeal,
                    ticksTotal = ticksTotal,
                    expectedTotal = fullTickHeal * ticksTotal,
                    ticksSeen = 0,
                    expectedUsed = 0,
                    actualTotal = 0,
                    castTimeMs = castTime,
                    durationMs = windowMs,
                    expiresAtMs = castTime + windowMs,
                    autoRegistered = true,
                }
                hotInfo = _pendingHotHeals[keyTarget][keySpell]
                if log then
                    log.info('events', 'HOT_AUTO_REGISTER: spell=%s target=%s ticks=%d expectedTick=%d (detected from first tick)',
                        tostring(spellName), tostring(targetName), ticksTotal, fullTickHeal)
                end
            else
                if log then
                    log.info('events', 'HOT_TICK_ORPHAN: spell=%s target=%s (no pending HoT and could not auto-register)',
                        tostring(spellName or ''), tostring(targetName or ''))
                end
            end
        end

        if hotInfo then
            hotInfo.ticksSeen = (hotInfo.ticksSeen or 0) + 1
            hotInfo.actualTotal = (hotInfo.actualTotal or 0) + (amount or 0)
            if (hotInfo.expectedTick or 0) <= 0 and amount > 0 then
                hotInfo.expectedTick = amount
            end
            if (hotInfo.expectedTick or 0) > 0 then
                hotInfo.expectedUsed = (hotInfo.expectedUsed or 0) + hotInfo.expectedTick
            else
                hotInfo.expectedUsed = (hotInfo.expectedUsed or 0) + amount
            end
            -- Guard against undercounted tick totals (some HoTs tick immediately)
            if (hotInfo.ticksTotal or 0) > 0 and hotInfo.ticksSeen > hotInfo.ticksTotal then
                local now = nowMs()
                hotInfo.ticksTotal = hotInfo.ticksSeen
                hotInfo.durationMs = hotInfo.ticksTotal * TICK_MS
                hotInfo.expiresAtMs = now + TICK_MS
            end
            if log then
                log.debug('events', 'HOT_TICK_TRACKED: spell=%s target=%s ticksSeen=%d/%d actualTotal=%d auto=%s',
                    tostring(spellName), tostring(targetName), hotInfo.ticksSeen, hotInfo.ticksTotal or 0,
                    hotInfo.actualTotal, tostring(hotInfo.autoRegistered or false))
            end
        end

        -- HoT ticks don't need further processing unless they match current cast
        if not isCurrentCast then
            return
        end
    end

    -- Skip non-healing events with no heal amount
    if amount <= 0 then return end

    if not isConfigured and not isCurrentCast then
        -- Not a healing spell we care about (e.g., buff with heal component)
        return
    end

    -- Calculate overheal from potential value
    -- potential can be: a number (spell's potential heal), "Full" (100% overheal), or nil (no data)
    local overhealed = 0
    if potential then
        local potentialLower = tostring(potential):lower()
        if potentialLower == 'full' then
            -- "Full" means target was at 100% HP - entire heal was overheal
            -- But amount is what actually healed (usually 0 in this case)
            -- The potential heal would be the spell's base value
            -- Use tloSpellName (with rank) for TLO lookup
            local lookupName = tloSpellName or spellName
            if lookupName then
                local spell = mq.TLO.Spell(lookupName)
                if spell and spell() then
                    local baseHeal = tonumber(spell.Base(1)()) or 0
                    if baseHeal > 0 then
                        overhealed = baseHeal
                    end
                end
            end
        else
            local potentialNum = tonumber(potential)
            if potentialNum and potentialNum > amount then
                overhealed = potentialNum - amount
            end
        end
    end

    -- Record to heal tracker for learning (only configured spells, HoTs handled above)
    -- Use full potential (amount + overheal) so learned data reflects actual spell power
    local fullHealAmount = amount + overhealed
    if isConfigured and HealTracker and not isHoT and fullHealAmount > 0 then
        if log then
            log.debug('events', 'Recording direct heal to HealTracker: %s amount=%d overheal=%d full=%d crit=%s',
                tostring(spellName), amount, overhealed, fullHealAmount, tostring(isCrit))
        end
        HealTracker.recordHeal(spellName, fullHealAmount, isCrit, false)
    end

    -- Check if this matches our current cast (use case-insensitive comparison)
    local isOurCast = false
    local targetId = nil
    local manaCost = 0

    if _currentCast then
        local castSpell = normalizeKey(canonicalSpellName(_currentCast.spellName))
        local eventSpell = normalizeKey(spellName or '')
        -- Match if spell names are equal (case insensitive) or if one contains the other
        isOurCast = (castSpell == eventSpell) or
                (castSpell:find(eventSpell, 1, true) ~= nil) or
                (eventSpell:find(castSpell, 1, true) ~= nil)

        if isOurCast then
            targetId = _currentCast.targetId
            manaCost = _currentCast.manaCost or 0
        else
            -- Even if spell doesn't match exactly, check if target name matches
            -- This handles cases where spell name has rank suffix differences
            local castTarget = normalizeKey(_currentCast.targetName or '')
            local eventTarget = normalizeKey(targetName or '')
            if castTarget ~= '' and eventTarget ~= '' and
               (castTarget == eventTarget or castTarget:find(eventTarget, 1, true) or eventTarget:find(castTarget, 1, true)) then
                -- Target matches - assume this is our heal (maybe spell name formatting differs)
                isOurCast = true
                targetId = _currentCast.targetId
                manaCost = _currentCast.manaCost or 0
            end
        end
    end

    -- If we matched our cast, handle it
    if isOurCast and targetId then
        if IncomingHeals then
            IncomingHeals.unregisterMyCast(targetId)
        end

        -- Broadcast to other healers that heal landed (so they can clear their tracking)
        if _broadcastLandedCallback then
            _broadcastLandedCallback(targetId, spellName)
        end

        _currentCast = nil
    end

    -- Record to analytics (HoT ticks are recorded earlier in the function)
    if Analytics and not isHoT then
        -- Direct heal
        if Analytics.recordHealComplete then
            if manaCost == 0 then
                -- Try to look up mana cost from spell data
                if spellName then
                    local spell = mq.TLO.Spell(spellName)
                    if spell and spell() then
                        manaCost = tonumber(spell.Mana()) or 0
                    end
                end
            end
            Analytics.recordHealComplete(spellName, targetId, amount, overhealed, manaCost, isCrit)
        end
    end

    -- Record to combat assessor for adaptive throttle tracking
    local ca = getCombatAssessor()
    if ca and ca.recordHealForThrottle then
        ca.recordHealForThrottle(amount, overhealed)
    end
end

function M.onInterrupt(reason)
    if not _currentCast then return end

    local targetId = _currentCast.targetId
    local spellName = _currentCast.spellName

    -- Clear incoming heal tracking
    if IncomingHeals then
        IncomingHeals.unregisterMyCast(targetId)
    end

    -- Broadcast to other healers that cast was cancelled
    if _broadcastCancelledCallback then
        _broadcastCancelledCallback(targetId, spellName, reason)
    end

    -- Record to analytics
    if Analytics and Analytics.recordInterrupt then
        Analytics.recordInterrupt(spellName, reason)
    end

    _currentCast = nil
end

function M.setCastInfo(info)
    if info and info.spellName then
        info.spellName = canonicalSpellName(info.spellName)
    end
    _currentCast = info
end

function M.getCastInfo()
    return _currentCast
end

function M.isCasting()
    return _currentCast ~= nil
end

function M.tick()
    mq.doevents()

    -- Prune expired HoT tracking and record missed ticks
    local now = nowMs()
    for targetKey, spells in pairs(_pendingHotHeals) do
        for spellKey, info in pairs(spells) do
            if info.expiresAtMs and now > info.expiresAtMs then
                -- Calculate missed ticks (ticks that never fired because target was at full HP)
                local ticksTotal = info.ticksTotal or 0
                local ticksSeen = info.ticksSeen or 0
                if ticksSeen > ticksTotal then
                    ticksTotal = ticksSeen
                end
                local missedTicks = math.max(0, ticksTotal - ticksSeen)
                local expectedTick = info.expectedTick or 0

                -- Record missed ticks to analytics (ticks that never fired)
                -- These are ticks we expected but never saw events for
                if missedTicks > 0 and Analytics and Analytics.recordHotMissed then
                    Analytics.recordHotMissed(info.spell, missedTicks, expectedTick)
                end

                -- Log expired HoT for debugging
                local log = getLogger()
                if log and (ticksSeen > 0 or missedTicks > 0) then
                    log.debug('events', 'HoT expired: %s on %s - %d/%d ticks seen, %d missed (actualHealed=%d)',
                        info.spell or '?', info.target or '?', ticksSeen, ticksTotal, missedTicks, info.actualTotal or 0)
                end

                spells[spellKey] = nil
            end
        end
        if next(spells) == nil then
            _pendingHotHeals[targetKey] = nil
        end
    end
end

return M
