-- healing/hot_analyzer.lua
-- HoT Trust & Healing Efficiency Module
-- Determines when to trust active HoTs vs when to supplement with direct heals
local mq = require('mq')
local lazy = require('smartheal.util.lazy_require')

local M = {}

-- Dependencies (set via init)
local Config = nil
local HealTracker = nil
local CombatAssessor = nil
local Proactive = nil

-- Lazy-load Logger
local getLogger = lazy.once('smartheal.logger')

-- Lazy-load DamageAttribution
local getDamageAttribution = lazy.once('smartheal.damage_attribution')

--------------------------------------------------------------------------------
-- Initialization
--------------------------------------------------------------------------------

function M.init(config, healTracker, combatAssessor, proactive)
    Config = config
    HealTracker = healTracker
    CombatAssessor = combatAssessor
    Proactive = proactive
end

--------------------------------------------------------------------------------
-- Helper Functions
--------------------------------------------------------------------------------

-- Get pressure level from combat state
-- Returns: pressure ('low'/'normal'/'high'), mobCount, ttk, survivalMode, mobDifficulty
local function getPressureLevel()
    local state = CombatAssessor and CombatAssessor.getState() or {}

    local mobCount = state.activeMobCount or 0
    local ttk = state.estimatedTTK or 999
    local survival = state.survivalMode or false
    local highPressure = state.highPressure or false
    local hasRaidMob = state.hasRaidMob or false
    local hasNamedMob = state.hasNamedMob or false
    local mobMultiplier = state.mobDpsMultiplier or 1.0
    local mobTier = state.mobDifficultyTier or 'normal'

    local pressure = 'normal'
    if survival or highPressure then
        pressure = 'high'
    elseif hasRaidMob or mobMultiplier >= 2.5 then
        -- Raid/extreme mobs: treat as high pressure even if other indicators are normal
        -- We expect heavier damage that may not be fully captured in DPS tracking yet
        pressure = 'high'
    elseif mobMultiplier >= 1.5 then
        -- Named mobs (difficult/formidable): at least normal pressure, never low
        pressure = 'normal'
    elseif mobCount <= (Config and Config.lowPressureMobCount or 1) then
        pressure = 'low'
    end

    -- Return mob difficulty info for logging
    local mobDifficulty = {
        hasRaidMob = hasRaidMob,
        hasNamedMob = hasNamedMob,
        multiplier = mobMultiplier,
        tier = mobTier,
    }

    return pressure, mobCount, ttk, survival, mobDifficulty
end

-- Get projection window capped by pressure, TTK, and HoT remaining time
-- Returns window in seconds
local function getProjectionWindow(pressure, ttk, hotRemainingSec)
    local cfg = Config or {}

    -- Base window from pressure level
    local baseWindow
    if pressure == 'low' then
        baseWindow = cfg.projectionWindowLow or 8
    elseif pressure == 'high' then
        baseWindow = cfg.projectionWindowHigh or 3
    else
        baseWindow = cfg.projectionWindowNormal or 6
    end

    -- Cap by TTK (fight won't last longer than this)
    local window = math.min(baseWindow, ttk or 999)

    -- Cap by HoT remaining time (HoT won't help beyond its duration)
    if hotRemainingSec and hotRemainingSec > 0 then
        window = math.min(window, hotRemainingSec)
    end

    return math.max(1, window)  -- At least 1 second
end

-- Get heal threshold based on role and pressure level
-- Returns HP% below which we should intervene with direct heals
local function getHealThreshold(role, pressure)
    local cfg = Config or {}
    local thresholds = cfg.healThresholds or {
        tank    = { low = 50, normal = 60, high = 70 },
        healer  = { low = 60, normal = 70, high = 80 },
        dps     = { low = 55, normal = 65, high = 75 },
        squishy = { low = 65, normal = 75, high = 85 },
    }

    -- Normalize role
    local roleKey = role or 'dps'
    if roleKey == 'tank' or roleKey == 'healer' or roleKey == 'squishy' then
        -- Use as-is
    else
        roleKey = 'dps'
    end

    local roleThresholds = thresholds[roleKey] or thresholds.dps
    return roleThresholds[pressure] or roleThresholds.normal or 65
end

-- Get HoT healing per second for a spell
-- Returns HPS (healing per second)
local function getHotHps(spellName)
    if not spellName then return 0 end

    -- Try HealTracker first for learned tick amounts
    local tickAmount = 0
    if HealTracker and HealTracker.getExpected then
        tickAmount = HealTracker.getExpected(spellName, 'tick') or 0
    end

    -- Fallback to spell data
    if tickAmount <= 0 then
        local spell = mq.TLO.Spell(spellName)
        if spell and spell() and spell.Base then
            local base = spell.Base(1)
            if base and base() then
                tickAmount = math.abs(tonumber(base()) or 0)
            end
        end
    end

    if tickAmount <= 0 then return 0 end

    -- HoTs tick every 6 seconds
    local tickInterval = 6
    return tickAmount / tickInterval
end

-- Get attributed DPS for a target from damage attribution module
-- Falls back to recentDps from target info if attribution unavailable
local function getAttributedDps(targetId, fallbackDps)
    local da = getDamageAttribution()
    if da and da.getTargetDamageInfo then
        local info = da.getTargetDamageInfo(targetId)
        if info and info.totalDps and info.totalDps > 0 then
            return info.totalDps, info.sourceCount or 1, info
        end
    end
    return fallbackDps or 0, 1, nil
end

-- Get HoT remaining time and ticks for a target
-- Returns: remainingSec, ticksRemaining, spellName
local function getActiveHotInfo(targetIdOrName)
    if not Proactive then return 0, 0, nil end

    local hasHot, spellName, remainingMs = Proactive.hasActiveHoT(targetIdOrName)
    if not hasHot or not remainingMs or remainingMs <= 0 then
        return 0, 0, nil
    end

    -- remainingMs is in milliseconds from mq.gettime(), convert to seconds
    local remainingSec = remainingMs / 1000
    local tickInterval = 6
    local ticksRemaining = math.floor(remainingSec / tickInterval)

    return remainingSec, ticksRemaining, spellName
end

--------------------------------------------------------------------------------
-- Main Trust Decision: shouldTrustHoT
--------------------------------------------------------------------------------

-- Determine if we should trust an active HoT to handle healing
-- Returns: trustHoT (bool), analysis (table), decision (string)
function M.shouldTrustHoT(targetInfo, situation)
    local cfg = Config or {}
    local log = getLogger()

    -- Extract target info
    local targetId = targetInfo.id or 0
    local targetName = targetInfo.name or '?'
    local currentHP = targetInfo.currentHP or 0
    local maxHP = targetInfo.maxHP or 1
    local currentPct = (maxHP > 0) and (currentHP / maxHP * 100) or 0
    local deficit = targetInfo.deficit or (maxHP - currentHP)
    local role = targetInfo.role or 'dps'
    local recentDps = targetInfo.recentDps or 0

    -- Analysis structure for logging
    local analysis = {
        targetName = targetName,
        targetId = targetId,
        currentHP = currentHP,
        maxHP = maxHP,
        currentPct = currentPct,
        deficit = deficit,
        role = role,
    }

    -- 1. Hard safety floor check - BYPASS HoT trust entirely if HP too low
    local hardFloor = cfg.hotTrustHardFloorPct or 35
    if currentPct < hardFloor then
        analysis.bypassReason = 'hard_floor'
        analysis.threshold = hardFloor
        local decision = string.format('BYPASS_HARD_FLOOR (HP %.0f%% < %.0f%%)', currentPct, hardFloor)
        if log and log.logHotCoverageDecision then
            log.logHotCoverageDecision(targetName, analysis, decision)
        end
        return false, analysis, decision
    end

    -- 2. Check for active HoT
    local hotRemainingSec, ticksRemaining, hotSpellName = getActiveHotInfo(targetId)
    if hotRemainingSec <= 0 then
        analysis.hotSpell = nil
        analysis.hotRemainingSec = 0
        local decision = 'NO_ACTIVE_HOT'
        if log and log.logHotCoverageDecision then
            log.logHotCoverageDecision(targetName, analysis, decision)
        end
        return false, analysis, decision
    end

    analysis.hotSpell = hotSpellName
    analysis.hotRemainingSec = hotRemainingSec
    analysis.ticksRemaining = ticksRemaining

    -- 3. Get HoT HPS
    local hotHps = getHotHps(hotSpellName)
    analysis.hotHps = hotHps
    analysis.tickAmount = hotHps * 6  -- tick amount = HPS * tick interval

    -- 4. Get attributed DPS
    local dps, sourceCount, attrInfo = getAttributedDps(targetId, recentDps)
    analysis.dps = dps
    analysis.sourceCount = sourceCount

    -- Build source list for verbose logging
    if attrInfo and attrInfo.primarySourceName then
        analysis.sources = {}
        -- Primary source
        table.insert(analysis.sources, {
            name = attrInfo.primarySourceName,
            dps = attrInfo.primarySourceDps or 0,
            isPrimary = true,
        })
    end

    -- 5. DPS floor check - don't trust HoT if DPS data unreliable
    local dpsFloor = cfg.hotMinDpsForTrust or 100
    if dps < dpsFloor then
        analysis.dpsFloor = dpsFloor
        analysis.bypassReason = 'dps_below_floor'
        local decision = string.format('DPS_BELOW_FLOOR (DPS %.0f < %.0f)', dps, dpsFloor)
        if log and log.logHotCoverageDecision then
            log.logHotCoverageDecision(targetName, analysis, decision)
        end
        -- With low/unreliable DPS, don't trust HoT - be conservative
        return false, analysis, decision
    end

    -- 6. Get pressure level and projection window
    local pressure, mobCount, ttk, survival, mobDifficulty = getPressureLevel()
    analysis.pressure = pressure
    analysis.mobCount = mobCount
    analysis.ttk = ttk
    analysis.survivalMode = survival
    analysis.mobDifficulty = mobDifficulty

    -- 7. Calculate projection window (capped by pressure, TTK, and HoT remaining)
    local windowSec = getProjectionWindow(pressure, ttk, hotRemainingSec)
    analysis.windowSec = windowSec

    -- 8. Calculate coverage ratio (HoT HPS vs DPS)
    local coverageRatio = (dps > 0) and (hotHps / dps) or 0

    -- Boost coverage ratio for multi-source damage (HoT more effective against sustained patterns)
    if sourceCount >= 2 then
        coverageRatio = coverageRatio * 1.2
    end
    analysis.coverageRatio = coverageRatio

    -- 9. Calculate projected HP
    local damageInWindow = dps * windowSec
    local healingInWindow = hotHps * windowSec
    local projectedHP = currentHP - damageInWindow + healingInWindow
    projectedHP = math.max(0, math.min(projectedHP, maxHP))
    local projectedPct = (maxHP > 0) and (projectedHP / maxHP * 100) or 0

    analysis.damageInWindow = damageInWindow
    analysis.healingInWindow = healingInWindow
    analysis.projectedHP = projectedHP
    analysis.projectedPct = projectedPct

    -- 10. Get threshold based on role + pressure
    local threshold = getHealThreshold(role, pressure)
    analysis.threshold = threshold

    -- 11. Calculate uncovered gap (damage not covered by HoT)
    -- This is used for sizing direct heals if needed
    local uncoveredGap = math.max(0, damageInWindow - healingInWindow)
    -- CRITICAL: Never return 0 gap - keeps target in priority queue
    uncoveredGap = math.max(1, uncoveredGap)
    analysis.uncoveredGap = uncoveredGap

    -- Recommend heal size based on gap
    if uncoveredGap < 1000 then
        analysis.recommendedSize = 'small'
    elseif uncoveredGap < 3000 then
        analysis.recommendedSize = 'medium'
    else
        analysis.recommendedSize = 'large'
    end

    -- 12. Make trust decision
    local trustHoT = projectedPct >= threshold
    local decision

    if trustHoT then
        decision = string.format('TRUST_HOT (proj %.0f%% >= %.0f%% threshold)', projectedPct, threshold)
    else
        decision = string.format('SUPPLEMENT_NEEDED (proj %.0f%% < %.0f%% threshold, gap=%.0f)',
            projectedPct, threshold, uncoveredGap)
    end

    -- 13. Log decision
    if log and log.logHotCoverageDecision then
        log.logHotCoverageDecision(targetName, analysis, decision)
    end

    return trustHoT, analysis, decision
end

--------------------------------------------------------------------------------
-- HoT Application Decision: shouldApplyHoT
--------------------------------------------------------------------------------

-- Determine if a HoT should be applied to target
-- Returns: shouldApply (bool), analysis (table), reason (string)
function M.shouldApplyHoT(targetInfo, hotSpellName, situation)
    local cfg = Config or {}
    local log = getLogger()

    -- Extract target info
    local targetId = targetInfo.id or 0
    local targetName = targetInfo.name or '?'
    local currentHP = targetInfo.currentHP or 0
    local maxHP = targetInfo.maxHP or 1
    local currentPct = (maxHP > 0) and (currentHP / maxHP * 100) or 0
    local recentDps = targetInfo.recentDps or 0

    -- Analysis structure
    local analysis = {
        targetName = targetName,
        targetId = targetId,
        hotSpell = hotSpellName,
        currentPct = currentPct,
    }

    -- Get combat state
    local pressure, mobCount, ttk, survival, mobDifficulty = getPressureLevel()
    analysis.pressure = pressure
    analysis.mobCount = mobCount
    analysis.ttk = ttk
    analysis.mobDifficulty = mobDifficulty

    -- Get spell duration
    local spell = mq.TLO.Spell(hotSpellName)
    local hotDurationSec = 0
    if spell and spell() and spell.Duration and spell.Duration.TotalSeconds then
        hotDurationSec = tonumber(spell.Duration.TotalSeconds()) or 0
    end
    if hotDurationSec <= 0 then
        hotDurationSec = cfg.hotTypicalDuration or 36
    end
    analysis.hotDuration = hotDurationSec

    -- Get HoT HPS
    local hotHps = getHotHps(hotSpellName)
    analysis.hotHps = hotHps

    -- Get attributed DPS
    local dps, sourceCount, _ = getAttributedDps(targetId, recentDps)
    analysis.dps = dps
    analysis.sourceCount = sourceCount

    -- Gate 1: TTK check - will HoT get enough ticks?
    local tickInterval = 6
    local usableTicks = math.floor(math.min(ttk, hotDurationSec) / tickInterval)
    local minUsableTicks = cfg.hotMinUsableTicks or 2
    analysis.usableTicks = usableTicks
    analysis.minUsableTicks = minUsableTicks

    if usableTicks < minUsableTicks then
        local reason = string.format('TTK_TOO_SHORT (ticks=%d < min=%d)', usableTicks, minUsableTicks)
        if log and log.logHotApplicationDecision then
            log.logHotApplicationDecision(targetName, analysis, false, reason)
        end
        return false, analysis, reason
    end

    -- Gate 2: DPS ratio check - is there enough damage to justify HoT?
    local dpsRatio = (hotHps > 0) and (dps / hotHps) or 0
    local requiredRatio
    local mobType
    if mobCount <= 1 then
        requiredRatio = cfg.hotSingleMobMinDpsRatio or 0.8
        mobType = 'single'
    else
        requiredRatio = cfg.hotMultiMobMinDpsRatio or 0.3
        mobType = 'multi'
    end
    analysis.dpsRatio = dpsRatio
    analysis.requiredRatio = requiredRatio
    analysis.mobType = mobType

    if dpsRatio < requiredRatio then
        local reason = string.format('DPS_RATIO_LOW (ratio=%.2f < required=%.2f for %s-mob)',
            dpsRatio, requiredRatio, mobType)
        if log and log.logHotApplicationDecision then
            log.logHotApplicationDecision(targetName, analysis, false, reason)
        end
        return false, analysis, reason
    end

    -- Gate 3: Overheal ratio check - will most of the HoT be wasted?
    local effectiveDuration = math.min(ttk, hotDurationSec)
    local expectedHealing = hotHps * effectiveDuration
    local expectedDamage = dps * effectiveDuration
    local overhealRatio = (expectedDamage > 0) and (expectedHealing / expectedDamage) or 999
    local maxOverhealRatio = cfg.hotMaxOverhealRatio or 1.5
    analysis.expectedHealing = expectedHealing
    analysis.expectedDamage = expectedDamage
    analysis.overhealRatio = overhealRatio
    analysis.maxOverhealRatio = maxOverhealRatio

    if overhealRatio > maxOverhealRatio then
        local reason = string.format('OVERHEAL_TOO_HIGH (ratio=%.2f > max=%.2f)',
            overhealRatio, maxOverhealRatio)
        if log and log.logHotApplicationDecision then
            log.logHotApplicationDecision(targetName, analysis, false, reason)
        end
        return false, analysis, reason
    end

    -- All gates passed
    local reason = string.format('APPLY_HOT (ticks=%d, dpsRatio=%.2f, overheal=%.2f)',
        usableTicks, dpsRatio, overhealRatio)
    if log and log.logHotApplicationDecision then
        log.logHotApplicationDecision(targetName, analysis, true, reason)
    end
    return true, analysis, reason
end

--------------------------------------------------------------------------------
-- Gap Calculation: getUncoveredGap
--------------------------------------------------------------------------------

-- Get the uncovered healing gap for a target (damage not covered by active HoT)
-- This is used for sizing direct heals
-- Returns: gap (HP amount, never 0), analysis (table)
function M.getUncoveredGap(targetInfo)
    local cfg = Config or {}

    -- Extract target info
    local targetId = targetInfo.id or 0
    local currentHP = targetInfo.currentHP or 0
    local maxHP = targetInfo.maxHP or 1
    local recentDps = targetInfo.recentDps or 0

    -- Get pressure and window
    local pressure, _, ttk, _ = getPressureLevel()

    -- Get active HoT info
    local hotRemainingSec, _, hotSpellName = getActiveHotInfo(targetId)

    -- Get projection window
    local windowSec = getProjectionWindow(pressure, ttk, hotRemainingSec)

    -- Get DPS
    local dps, _, _ = getAttributedDps(targetId, recentDps)

    -- Calculate expected damage
    local damageInWindow = dps * windowSec

    -- Calculate HoT healing
    local healingInWindow = 0
    if hotSpellName and hotRemainingSec > 0 then
        local hotHps = getHotHps(hotSpellName)
        healingInWindow = hotHps * math.min(windowSec, hotRemainingSec)
    end

    -- Calculate gap
    local gap = damageInWindow - healingInWindow

    -- CRITICAL: Never return 0 - keeps target in priority queue
    gap = math.max(1, gap)

    local analysis = {
        windowSec = windowSec,
        damageInWindow = damageInWindow,
        healingInWindow = healingInWindow,
        gap = gap,
        hotSpell = hotSpellName,
        hotRemainingSec = hotRemainingSec,
    }

    return gap, analysis
end

--------------------------------------------------------------------------------
-- Utility Exports
--------------------------------------------------------------------------------

-- Expose helper functions for external use
M.getPressureLevel = getPressureLevel
M.getProjectionWindow = getProjectionWindow
M.getHealThreshold = getHealThreshold
M.getHotHps = getHotHps
M.getAttributedDps = getAttributedDps
M.getActiveHotInfo = getActiveHotInfo

return M
