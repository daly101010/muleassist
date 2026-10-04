-- healing/combat_assessor.lua
local mq = require('mq')
local lazy = require('smartheal.util.lazy_require')

local M = {}

local Config = nil
local TargetMonitor = nil

-- Lazy-load Logger
local getLogger = lazy.once('smartheal.logger')

-- Lazy-load DamageAttribution
local getDamageAttribution = lazy.once('smartheal.damage_attribution')

-- Lazy-load MobAssessor for named/raid mob detection
local getMobAssessor = lazy.once('smartheal.mob_assessor')

-- Mob HP tracking for TTK calculation
local _mobSnapshots = {}  -- mobId -> { snapshots = [{hpPct, time}], name }

-- Track mob IDs we've already checked for named status (prevents repeated checks)
local _checkedMobIds = {}  -- mobId -> true

-- Adaptive throttle tracking (rolling window during fight)
local _fightHealing = {
    healed = 0,
    overhealed = 0,
    healCount = 0,
    fightStartTime = 0,
}

local _state = {
    fightPhase = 'none',
    inCombat = false,
    survivalMode = false,
    highPressure = false,
    avgMobHP = 100,
    estimatedTTK = 999,
    activeMobCount = 0,
    totalMobCount = 0,
    mezzedMobCount = 0,
    totalIncomingDps = 0,
    tankDpsPct = 0,
    -- Named/raid mob tracking
    hasNamedMob = false,
    hasRaidMob = false,
    mobDpsMultiplier = 1.0,      -- Highest multiplier from engaged mobs
    mobDifficultyTier = 'normal', -- Tier of the hardest mob (raid, impossible, extreme, etc.)
    -- Adaptive throttle state
    fightOverhealPct = 0,        -- Overheal % during current fight
    throttleLevel = 0,           -- 0 = no throttle, 1.0 = max throttle
}

local _lastUpdate = 0
-- mq.gettime() returns milliseconds, so the throttle threshold must also be
-- in ms. Previously this was 0.5 (intended as half a second), which made the
-- guard fire only within 0.5 ms — effectively running tick() every frame.
local UPDATE_INTERVAL = 500
local _lastLoggedState = nil

function M.init(config, targetMonitor)
    Config = config
    TargetMonitor = targetMonitor
    _mobSnapshots = {}
    _checkedMobIds = {}
end

function M.getState()
    return _state
end

--- Wall-clock ms (mq.gettime) when the current fight started, or 0 if not
--- in combat. Used by heal_selector to apply opening-burst guards when DPS
--- history is cold.
function M.getFightStartTime()
    return _fightHealing.fightStartTime or 0
end

-- Record a heal for adaptive throttle tracking
-- Called from spell_events when a heal lands
function M.recordHealForThrottle(healed, overhealed)
    if not _state.inCombat then return end

    healed = tonumber(healed) or 0
    overhealed = tonumber(overhealed) or 0

    _fightHealing.healed = _fightHealing.healed + healed
    _fightHealing.overhealed = _fightHealing.overhealed + overhealed
    _fightHealing.healCount = _fightHealing.healCount + 1

    -- Update overheal percentage
    local totalPotential = _fightHealing.healed + _fightHealing.overhealed
    if totalPotential > 0 then
        _state.fightOverhealPct = (_fightHealing.overhealed / totalPotential) * 100
    end

    -- Calculate throttle level for raid fights
    -- Only throttle if: raid fight + enough heals to have data + high overheal
    local minHealsForThrottle = (Config and Config.throttleMinHeals) or 5
    local overhealThreshold = (Config and Config.throttleOverhealPct) or 40
    local maxThrottle = (Config and Config.throttleMaxLevel) or 0.5

    if (_state.hasRaidMob or _state.hasNamedMob) and
       _fightHealing.healCount >= minHealsForThrottle and
       _state.fightOverhealPct > overhealThreshold then
        -- Scale throttle: 40% overheal = 0 throttle, 70% overheal = max throttle
        local overhealExcess = _state.fightOverhealPct - overhealThreshold
        local throttleRange = 30  -- 40% to 70%
        _state.throttleLevel = math.min(maxThrottle, (overhealExcess / throttleRange) * maxThrottle)
    else
        _state.throttleLevel = 0
    end
end

-- Reset fight healing stats (called when combat ends or new fight starts)
local function resetFightHealing()
    _fightHealing.healed = 0
    _fightHealing.overhealed = 0
    _fightHealing.healCount = 0
    _fightHealing.fightStartTime = mq.gettime()
    _state.fightOverhealPct = 0
    _state.throttleLevel = 0
end

-- Get the current throttle adjustment info
function M.getThrottleInfo()
    return {
        overhealPct = _state.fightOverhealPct,
        throttleLevel = _state.throttleLevel,
        healCount = _fightHealing.healCount,
        healed = _fightHealing.healed,
        overhealed = _fightHealing.overhealed,
        isActive = _state.throttleLevel > 0,
    }
end

-- Record a mob's HP% snapshot for TTK calculation
-- All snapshot timestamps are in SECONDS (mq.gettime() returns milliseconds)
local function recordMobHP(mobId, mobName, hpPct)
    if not mobId or mobId == 0 then return end

    if not _mobSnapshots[mobId] then
        _mobSnapshots[mobId] = {
            name = mobName,
            snapshots = {},
        }
    end

    local now = mq.gettime() / 1000
    local data = _mobSnapshots[mobId]

    -- Add snapshot
    table.insert(data.snapshots, {
        hpPct = hpPct,
        time = now,
    })

    -- Keep only last 30 seconds of snapshots (timestamps are in seconds).
    local cutoff = now - 30
    while #data.snapshots > 1 and data.snapshots[1].time < cutoff do
        table.remove(data.snapshots, 1)
    end
end

-- Calculate time-to-kill for a mob based on HP% decline rate
-- Returns TTK in seconds, or nil if can't estimate
local function getMobTTK(mobId)
    local data = _mobSnapshots[mobId]
    if not data or #data.snapshots < 2 then
        return nil
    end

    local windowSec = (Config and Config.ttkWindowSec) or 5
    local now = mq.gettime() / 1000
    local cutoff = now - windowSec

    -- Collect samples within the window
    local samples = {}
    for _, snap in ipairs(data.snapshots) do
        if snap.time >= cutoff then
            table.insert(samples, snap)
        end
    end

    if #samples < 2 then
        return nil
    end

    -- Calculate HP% loss rate, filtering upward jumps (heals/regen).
    -- Snapshot timestamps are in seconds, so the rate math yields %/s directly.
    local totalHpLoss = 0
    local totalTimeSec = 0

    for i = 2, #samples do
        local prev = samples[i - 1]
        local curr = samples[i]
        local hpDelta = prev.hpPct - curr.hpPct
        local timeDeltaSec = curr.time - prev.time

        -- Only count HP decreases (ignore heals, regen)
        if hpDelta > 0 and timeDeltaSec > 0 then
            -- Clamp outliers: ignore if HP dropped more than 20% per second (likely target swap)
            local hpLossRate = hpDelta / timeDeltaSec
            if hpLossRate <= 20 then
                totalHpLoss = totalHpLoss + hpDelta
                totalTimeSec = totalTimeSec + timeDeltaSec
            end
        end
    end

    if totalTimeSec <= 0 or totalHpLoss <= 0 then
        return nil
    end

    local hpLossPerSec = totalHpLoss / totalTimeSec
    local currentHpPct = samples[#samples].hpPct

    -- TTK in seconds = remaining HP% / smoothed loss rate (%/s)
    return currentHpPct / hpLossPerSec
end

--- Public accessor: measured time-to-kill for a tracked mob
-- @param mobId number Spawn ID (must be an XTarget hater to have samples)
-- @return number|nil TTK in seconds, or nil if not enough samples
function M.getMobTTKById(mobId)
    return getMobTTK(mobId)
end

local function getXTargetData()
    local mobs = {}
    local me = mq.TLO.Me
    if not me or not me() then return mobs end

    local xtCount = tonumber(me.XTarget()) or 0
    for i = 1, xtCount do
        local xt = me.XTarget(i)
        if xt and xt() and xt.ID() and xt.ID() > 0 then
            local targetType = xt.TargetType and xt.TargetType() or ''
            -- Only count auto hater types
            if targetType:lower():find('hater') then
                local id = xt.ID()
                local name = xt.CleanName and xt.CleanName() or 'Unknown'
                local pctHP = tonumber(xt.PctHPs()) or 100
                local mezzed = xt.Mezzed and xt.Mezzed() or false

                -- Record HP snapshot for TTK tracking
                recordMobHP(id, name, pctHP)

                table.insert(mobs, {
                    id = id,
                    name = name,
                    pctHP = pctHP,
                    mezzed = mezzed,
                })
            end
        end
    end

    -- Clean up dead/gone mobs from snapshots
    local activeMobIds = {}
    for _, mob in ipairs(mobs) do
        activeMobIds[mob.id] = true
    end
    for mobId in pairs(_mobSnapshots) do
        if not activeMobIds[mobId] then
            _mobSnapshots[mobId] = nil
        end
    end

    return mobs
end

-- Estimate fight duration using average TTK of non-near-dead mobs
local function estimateFightDuration(mobs)
    if #mobs == 0 then
        return 999, 'none'
    end

    local nearDeadPct = (Config and Config.nearDeadMobPct) or 10
    local startingPct = (Config and Config.fightPhaseStartingPct) or 70
    local endingPct = (Config and Config.fightPhaseEndingPct) or 25
    local endingTTK = (Config and Config.fightPhaseEndingTTK) or 20

    local totalHP = 0
    local totalTTK = 0
    local ttkCount = 0
    local hpCount = 0

    for _, mob in ipairs(mobs) do
        -- Include all mobs above near-dead threshold in TTK (mezzed mobs will be fought eventually)
        -- Mezzed status only affects pressure detection, not fight duration
        if mob.pctHP > nearDeadPct then
            totalHP = totalHP + mob.pctHP
            hpCount = hpCount + 1

            -- Try to get actual TTK from HP tracking (mezzed mobs won't have decline data yet)
            local ttk = getMobTTK(mob.id)
            if ttk and ttk > 0 then
                totalTTK = totalTTK + ttk
                ttkCount = ttkCount + 1
            elseif mob.mezzed then
                -- Mezzed mob with no TTK data - estimate from HP% (will be fought later)
                local estimatedTTK = mob.pctHP * 0.5  -- Rough estimate
                totalTTK = totalTTK + estimatedTTK
                ttkCount = ttkCount + 1
            end
        end
    end

    local avgHP = hpCount > 0 and (totalHP / hpCount) or 0
    local estimatedTTK

    if ttkCount > 0 then
        -- Use average TTK from HP decline tracking
        estimatedTTK = totalTTK / ttkCount
    else
        -- Fallback: rough estimate from HP% (assume ~2% HP/sec)
        estimatedTTK = avgHP * 0.5
    end

    -- Determine fight phase
    local phase
    if hpCount == 0 then
        phase = 'none'
        estimatedTTK = 999
    elseif avgHP > startingPct then
        phase = 'starting'
    elseif avgHP < endingPct or estimatedTTK < endingTTK then
        phase = 'ending'
    else
        phase = 'mid'
    end

    return estimatedTTK, phase, avgHP
end

local function checkSurvivalMode()
    if not TargetMonitor then return false end

    local targets = TargetMonitor.getAllTargets()
    local tank = nil

    -- Find the tank
    for _, target in pairs(targets) do
        if target.role == 'tank' then
            tank = target
            break
        end
    end

    if not tank then return false end

    local dpsPct = (tank.recentDps / math.max(1, tank.maxHP)) * 100
    local tankFullPct = (Config and Config.survivalModeTankFullPct) or 90
    local survivalDpsPct = (Config and Config.survivalModeDpsPct) or 5

    -- Lower threshold when fighting raid/high-tier mobs (trigger survival earlier)
    -- Raid mobs hit harder, so we want to be more defensive sooner
    if _state.hasRaidMob or _state.hasNamedMob then
        local reduction = (Config and Config.raidMobSurvivalDpsPctReduction) or 2
        survivalDpsPct = math.max(1, survivalDpsPct - reduction)
    end

    return dpsPct >= survivalDpsPct and tank.pctHP < tankFullPct
end

-- Check if we're in high pressure situation
local function checkHighPressure(totalDps)
    local minDps = (Config and Config.highPressureMinDps) or 3000

    -- A confirmed named/raid target is high pressure even before enough HP
    -- samples have accumulated to calculate incoming DPS.
    if _state.hasNamedMob or _state.hasRaidMob then
        return true
    end

    -- Primary check: Total incoming DPS to group
    if totalDps >= minDps then
        return true
    end

    -- Check mob difficulty tier - raid/impossible mobs mean high pressure
    -- regardless of observed DPS (they hit hard and we may not have full data yet)
    local highPressureMultiplier = (Config and Config.highPressureMobMultiplier) or 3.0
    if _state.mobDpsMultiplier >= highPressureMultiplier then
        return true
    end

    local da = getDamageAttribution()
    if not da then
        return false
    end

    -- Check if tank is being swarmed (actively hit by multiple sources)
    if TargetMonitor then
        local targets = TargetMonitor.getAllTargets()
        for _, target in pairs(targets) do
            if target.role == 'tank' then
                local attrInfo = da.getTargetDamageInfo(target.id)
                if attrInfo.sourceCount >= 3 then
                    return true
                end
                break
            end
        end
    end

    -- Check for active AE damage hitting group
    if da.hasActiveAE() then
        return true
    end

    return false
end

local function countMobs(mobs)
    local active = 0
    local mezzed = 0
    for _, mob in ipairs(mobs) do
        if mob.mezzed then
            mezzed = mezzed + 1
        else
            active = active + 1
        end
    end
    return active, mezzed, #mobs
end

local function calcTotalIncomingDps()
    if not TargetMonitor then return 0 end

    local total = 0
    local targets = TargetMonitor.getAllTargets()
    for _, target in pairs(targets) do
        total = total + (target.recentDps or 0)
    end
    return total
end

function M.tick(opts)
    opts = opts or {}
    local now = mq.gettime()
    if (now - _lastUpdate) < UPDATE_INTERVAL then return end
    _lastUpdate = now

    local mobs = getXTargetData()

    _state.activeMobCount, _state.mezzedMobCount, _state.totalMobCount = countMobs(mobs)
    local wasInCombat = _state.inCombat
    _state.inCombat = _state.activeMobCount > 0

    -- Reset fight healing tracking when combat state changes
    if _state.inCombat and not wasInCombat then
        -- Entering combat - reset for new fight
        resetFightHealing()
    elseif not _state.inCombat and wasInCombat then
        -- Exiting combat - log final throttle stats if any
        local log = getLogger()
        if log and _fightHealing.healCount > 0 then
            log.info('combat_assessor', 'Fight ended: heals=%d healed=%d overheal=%d (%.1f%%) finalThrottle=%.2f',
                _fightHealing.healCount, _fightHealing.healed, _fightHealing.overhealed,
                _state.fightOverhealPct, _state.throttleLevel)
        end
        resetFightHealing()
    end

    _state.estimatedTTK, _state.fightPhase, _state.avgMobHP = estimateFightDuration(mobs)
    _state.totalIncomingDps = calcTotalIncomingDps()

    -- Calculate tank DPS %
    if TargetMonitor then
        local targets = TargetMonitor.getAllTargets()
        for _, target in pairs(targets) do
            if target.role == 'tank' and target.maxHP > 0 then
                _state.tankDpsPct = (target.recentDps / target.maxHP) * 100
                break
            end
        end
    end

    -- Query MobAssessor for named/raid mob status
    local ma = getMobAssessor()
    if ma and #mobs > 0 then
        local mobIds = {}
        for _, mob in ipairs(mobs) do
            table.insert(mobIds, mob.id)

            -- Check newly engaged mobs for named status (event spawns, etc.)
            if opts.readOnly ~= true and not _checkedMobIds[mob.id] then
                _checkedMobIds[mob.id] = true
                -- checkEngagedMob will do an immediate consider if it's an uncached named
                if ma.checkEngagedMob then
                    ma.checkEngagedMob(mob.id)
                end
            end
        end
        local maxMult, maxTier, hasNamed = ma.getMaxMobMultiplier(mobIds)
        _state.mobDpsMultiplier = maxMult
        _state.mobDifficultyTier = maxTier
        _state.hasNamedMob = hasNamed
        _state.hasRaidMob = ma.hasRaidMob(mobIds)
    else
        _state.mobDpsMultiplier = 1.0
        _state.mobDifficultyTier = 'normal'
        _state.hasNamedMob = false
        _state.hasRaidMob = false
        -- Clear checked mob IDs when out of combat (prepare for next fight)
        _checkedMobIds = {}
    end


    -- Difficulty state must be current before pressure/survival are derived.
    _state.survivalMode = checkSurvivalMode()
    _state.highPressure = checkHighPressure(_state.totalIncomingDps)

    -- Log combat state changes
    local stateKey = string.format('%s_%s_%s_%s_%d',
        _state.fightPhase, tostring(_state.inCombat), tostring(_state.survivalMode),
        tostring(_state.highPressure), _state.activeMobCount)
    if stateKey ~= _lastLoggedState then
        local log = getLogger()
        if log and log.logCombatState then
            log.logCombatState(_state)
        end
        _lastLoggedState = stateKey
    end
end

function M.getScoringWeights()
    if not Config or not Config.scoringPresets then
        return { coverage = 2.0, manaEff = 1.0, overheal = -1.5, throttled = false }
    end

    local weights

    -- Emergency/survival mode takes highest priority (never throttled)
    if _state.survivalMode then
        weights = Config.scoringPresets.emergency
        return {
            coverage = weights.coverage,
            manaEff = weights.manaEff,
            overheal = weights.overheal,
            throttled = false,
            preset = 'emergency',
        }
    end

    -- Determine base preset
    local preset = 'normal'
    if _state.hasRaidMob or _state.hasNamedMob then
        weights = Config.scoringPresets.raidFight or Config.scoringPresets.normal
        preset = 'raidFight'
    elseif _state.activeMobCount <= 1 then
        weights = Config.scoringPresets.lowPressure
        preset = 'lowPressure'
    else
        weights = Config.scoringPresets.normal
        preset = 'normal'
    end

    -- Apply adaptive throttle for raid fights with high overheal
    local throttled = false
    local throttleLevel = _state.throttleLevel or 0
    local adjustedCoverage = weights.coverage
    local adjustedOverheal = weights.overheal

    if throttleLevel > 0 and preset == 'raidFight' then
        -- Throttle down: reduce coverage weight, increase overheal penalty
        -- This makes us pick smaller heals and penalize overheal more
        adjustedCoverage = weights.coverage * (1 - throttleLevel * 0.5)  -- Up to 25% reduction at max throttle
        adjustedOverheal = weights.overheal * (1 + throttleLevel)        -- Up to 50% more penalty at max throttle
        throttled = true

        local log = getLogger()
        if log then
            log.debug('combat_assessor', 'Throttle active: level=%.2f overhealPct=%.1f coverage=%.2f->%.2f overheal=%.2f->%.2f',
                throttleLevel, _state.fightOverhealPct, weights.coverage, adjustedCoverage, weights.overheal, adjustedOverheal)
        end
    end

    return {
        coverage = adjustedCoverage,
        manaEff = weights.manaEff,
        overheal = adjustedOverheal,
        throttled = throttled,
        throttleLevel = throttleLevel,
        preset = preset,
    }
end

-- Check if high pressure (multiple mobs or high DPS)
function M.isHighPressure()
    return _state.highPressure, _state.activeMobCount, _state.totalIncomingDps
end

-- Get adjusted DPS expectation based on mob difficulty
-- baseDps: The observed/calculated DPS
-- Returns: adjustedDps factoring in raid/named mob multipliers
function M.getAdjustedDps(baseDps)
    return (baseDps or 0) * (_state.mobDpsMultiplier or 1.0)
end

-- Check if fighting raid-tier mobs
function M.isRaidFight()
    return _state.hasRaidMob == true
end

-- Check if fighting any named mobs
function M.hasNamedInFight()
    return _state.hasNamedMob == true
end

-- Get the mob difficulty info
function M.getMobDifficulty()
    return {
        multiplier = _state.mobDpsMultiplier or 1.0,
        tier = _state.mobDifficultyTier or 'normal',
        hasNamed = _state.hasNamedMob or false,
        hasRaid = _state.hasRaidMob or false,
    }
end

-- Check if HoT should be allowed based on fight state
-- Returns: allowed (bool), reason (string)
function M.shouldAllowHot(hotDurationSec)
    hotDurationSec = hotDurationSec or 36

    -- Block HoTs when not in combat
    if _state.activeMobCount == 0 or _state.fightPhase == 'none' then
        return false, 'no_combat'
    end

    -- Don't start new HoT if fight is ending (damage will cease soon)
    if _state.fightPhase == 'ending' then
        return false, 'fight_ending'
    end

    -- Check if fight will last long enough for HoT to be useful
    local minEfficiency = (Config and Config.hotMinFightDurationPct) or 50
    local minDuration = hotDurationSec * (minEfficiency / 100)

    if _state.estimatedTTK < minDuration then
        return false, string.format('ttk_too_short|ttk=%.0f<min=%.0f', _state.estimatedTTK, minDuration)
    end

    return true, 'ok'
end

-- Check if Promised heal should be allowed based on fight duration and tank state
function M.shouldAllowPromised(assessment, tankPct)
    if not assessment then return true, nil end

    local promisedDelay = (Config and Config.promisedDelaySeconds) or 18
    local buffer = (Config and Config.promisedDurationBuffer) or 5
    local minDuration = promisedDelay + buffer

    if assessment.fightPhase == 'ending' then
        return false, 'promised_blocked_ending'
    end

    if (assessment.estimatedTTK or 0) < minDuration then
        return false, string.format('promised_blocked_ttk|ttk=%.0f<min=%d', assessment.estimatedTTK or 0, minDuration)
    end

    local currentTankPct = tankPct or assessment.tankPct or 100
    local safetyFloor = M.getPromisedSafetyFloor()
    if currentTankPct < safetyFloor then
        return false, string.format('promised_blocked_floor|tankPct=%.0f<floor=%d', currentTankPct, safetyFloor)
    end

    return true, nil
end

function M.getPromisedSafetyFloor()
    local baseSafetyFloor = (Config and Config.promisedSafetyFloorPct) or 35
    local survivalSafetyFloor = (Config and Config.promisedSurvivalSafetyFloorPct) or 55

    local floor
    if _state and _state.survivalMode then
        floor = survivalSafetyFloor
    else
        floor = baseSafetyFloor
    end

    -- Raise floor when fighting named or raid mobs (they can spike damage quickly)
    if _state and (_state.hasRaidMob or _state.hasNamedMob) then
        local increase = (Config and Config.raidMobPromisedFloorIncrease) or 10
        floor = floor + increase
    end

    return math.min(floor, 80)  -- Cap at 80% to avoid blocking promised entirely
end

-- Backward/DeficitHealer-style aliases
M.ShouldAllowPromised = M.shouldAllowPromised
M.GetPromisedSafetyFloor = M.getPromisedSafetyFloor

-- Get the spell duration in seconds from MQ
function M.getSpellDuration(spellName)
    if not spellName then return 0 end

    local spell = mq.TLO.Spell(spellName)
    if not spell or not spell() then return 0 end

    -- MyDuration returns tick count for the player's version of the spell
    local mySpell = mq.TLO.Me.Spell(spellName)
    local ticks = 0
    if mySpell and mySpell() and mySpell.MyDuration then
        ticks = tonumber(mySpell.MyDuration()) or 0
    end
    if ticks <= 0 and spell.Duration then
        ticks = tonumber(spell.Duration()) or 0
    end

    -- Duration in seconds = ticks * 6 (HoTs tick every 6 seconds)
    return ticks * 6
end

return M
