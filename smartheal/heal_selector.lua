-- healing/heal_selector.lua
-- healing/heal_selector.lua (DeficitHealer logic)
local mq = require('mq')
local lazy = require('smartheal.util.lazy_require')

local M = {}

---@class HealSelectorConfig
---@field spells table
---@field scoringPresets table|nil
---@field burstDpsScale number|nil
---@field critOverhealThreshold number|nil
---@field critOverhealPenalty number|nil
---@field smallHealPenalty number|nil
---@field maxOverhealRatio number|nil
---@field hotSupplementMinDps number|nil
---@field hotMinDps number|nil
---@field emergencyPct number|nil
---@field considerIncomingHot boolean|nil
---@field hotIncomingCoveragePct number|nil
---@field hotOverrideDpsPct number|nil
---@field hotEnabled boolean|nil
---@field hotMaxDeficitPct number|nil
---@field hotLearnMaxDeficitPct number|nil
---@field hotPreferUnderDps number|nil
---@field sustainedDamageThreshold number|nil
---@field hotMinDeficitPct number|nil
---@field nonSquishyHotMinDeficitPct number|nil
---@field lowPressureHotMinDeficitPct number|nil
---@field hotLearnForce boolean|nil
---@field hotTankOnly boolean|nil
---@field hotMinDpsForNonTank number|nil
---@field bigHotWithPromisedMinDps number|nil
---@field minHealPct number|nil
---@field nonSquishyMinHealPct number|nil
---@field lowPressureMinDeficitPct number|nil
---@field quickHealsEmergencyOnly boolean|nil
---@field quickHealMaxPct number|nil
---@field groupHealMinCount number|nil
---@field bigHotMinMobDps number|nil
---@field bigHotMinXTargetCount number|nil

---@type HealSelectorConfig
local Config = { spells = {} }
local HealTracker = nil
local TargetMonitor = nil
local IncomingHeals = nil
local CombatAssessor = nil

local getProactive = lazy.once('smartheal.proactive')

local getLogger = lazy.once('smartheal.logger')

local function getExpectedHeal(tracker, spellName)
    if tracker and tracker.GetExpectedHeal then
        return tracker.GetExpectedHeal(spellName)
    end
    if tracker and tracker.getExpected then
        return tracker.getExpected(spellName)
    end
    return nil
end

local _lastAction = nil
local TICK_MS = 6000

function M.init(config, healTracker, targetMonitor, incomingHeals, combatAssessor)
    Config = config
    HealTracker = healTracker
    TargetMonitor = targetMonitor
    IncomingHeals = incomingHeals
    CombatAssessor = combatAssessor
    M._lastScores = nil
    M._lastTargetScores = nil
    _lastAction = nil
end

local function getSpellMeta(spellName)
    local spell = mq.TLO.Spell(spellName)
    if not spell or not spell() then
        return nil
    end

    -- Get mana cost
    local rawMana = spell.Mana()
    local manaCost = tonumber(rawMana) or 0

    -- Get cast time (in milliseconds)
    local rawCastTime = nil
    local rawDuration = nil
    pcall(function()
        ---@diagnostic disable-next-line: undefined-field
        if mq.TLO.Me and mq.TLO.Me.Spell then
            ---@diagnostic disable-next-line: undefined-field
            local mySpell = mq.TLO.Me.Spell(spellName)
            if mySpell and mySpell() then
                rawCastTime = mySpell.MyCastTime()
                rawDuration = mySpell.MyDuration()
            end
        end
    end)
    local baseCastTime = tonumber(spell.CastTime()) or 0
    local castTime = tonumber(rawCastTime) or baseCastTime

    -- Get recast time
    local recastTime = tonumber(spell.RecastTime()) or 0

    -- Get duration
    local duration = tonumber(rawDuration) or tonumber(spell.Duration()) or 0

    -- Get base heal amount
    local baseHeal = tonumber(spell.Base(1)()) or 0
    if baseHeal < 0 then
        baseHeal = -baseHeal
    end

    -- Debug logging
    local log = getLogger()
    if log and manaCost == 0 then
        log.debug('spellMeta', 'getSpellMeta(%s): rawMana=%s manaCost=%d castTime=%d baseHeal=%d',
            tostring(spellName), tostring(rawMana), manaCost, castTime, baseHeal)
    end

    return {
        mana = manaCost,
        castTimeMs = castTime,
        baseCastTimeMs = baseCastTime,
        recastTimeMs = recastTime,
        durationTicks = duration,
        baseHeal = baseHeal,
    }
end

local function isCompleteHeal(spellName)
    if Config and Config.excludeCompleteHealFromEfficiency == false then return false end
    local normalized = tostring(spellName or ''):lower():gsub('[^%a%d]+', ' ')
    return normalized:find('complete heal', 1, true) ~= nil
end

local function isFastDirectHeal(meta, category)
    local maxCastMs = tonumber(Config and Config.fastHealMaxCastMs) or 2000
    return category == 'fast' or ((tonumber(meta and meta.baseCastTimeMs) or math.huge) <= maxCastMs)
end

local function isSpellUsable(spellName, meta)
    local me = mq.TLO.Me
    if me and me() and me.Book then
        local ok, known = pcall(function()
            local bookSpell = me.Book(spellName)
            return bookSpell and bookSpell() and true or false
        end)
        if ok and not known then
            return false
        end
    end
    local ready = mq.TLO.Me.SpellReady(spellName)
    if ready ~= nil and not ready() then
        return false
    end
    local currentMana = mq.TLO.Me.CurrentMana() or 0
    local manaBuffer = meta.mana > 0 and math.max(5, math.ceil(meta.mana * 0.03)) or 0
    if meta.mana > 0 and currentMana < (meta.mana + manaBuffer) then
        return false
    end
    return true
end

local function predictedDeficit(deficit, dps, timeSec, maxHP)
    if not dps or dps <= 0 or not timeSec or timeSec <= 0 then
        return deficit
    end
    local predicted = deficit + (dps * timeSec)
    if maxHP and predicted > maxHP then
        predicted = maxHP
    end
    return predicted
end

-- Stable healing optimizes effective healing per mana. Unlike the pressure
-- score, it does not reward a short cast merely for being short. Healing above
-- the projected deficit is not counted as useful healing.
local function scoreStableEfficiency(meta, expected, deficit, dps, maxHP)
    local castSec = (tonumber(meta.castTimeMs) or 0) / 1000
    local predicted = predictedDeficit(deficit, tonumber(dps) or 0, castSec, maxHP)
    local effective = math.min(math.max(0, tonumber(expected) or 0), math.max(1, predicted))
    local mana = tonumber(meta.mana) or 0
    if mana <= 0 then mana = math.max(1, tonumber(expected) or 1) end
    local manaEff = effective / mana
    local overheal = math.max(0, (tonumber(expected) or 0) - predicted)
    local overhealRatio = overheal / math.max(1, predicted)
    local score = manaEff - (overhealRatio * 0.25)
    return score, {
        coverage = effective / math.max(1, predicted),
        overheal = overhealRatio,
        manaEff = manaEff,
        castSec = castSec,
        predicted = predicted,
        expected = expected,
        effective = effective,
        selectionMode = 'stable_efficiency',
    }, 'mode=stable_efficiency effective_hpm'
end

-- Score a group direct heal on the same effective-healing-per-mana scale as a
-- stable single-target direct heal. Each target only contributes healing that
-- will actually fit in its projected deficit when the spell lands.
local function scoreGroup(meta, expectedPerTarget, targets)
    local castSec = (tonumber(meta.castTimeMs) or 0) / 1000
    local totalExpected = 0
    local totalEffective = 0
    local totalPredicted = 0
    local minLandingPct = 100

    for _, t in ipairs(targets or {}) do
        local maxHP = math.max(1, tonumber(t.maxHP) or 1)
        local deficit = tonumber(t.deficit) or 0
        if Config and Config.considerIncomingHot and (tonumber(t.incomingHotRemaining) or 0) > 0 then
            local dpsPct = ((tonumber(t.recentDps) or 0) / maxHP) * 100
            if dpsPct <= (tonumber(Config.hotOverrideDpsPct) or 5) then
                deficit = math.max(0, deficit - (tonumber(t.incomingHotRemaining) or 0))
            end
        end
        local predicted = predictedDeficit(
            deficit,
            tonumber(t.recentDps) or 0,
            castSec,
            maxHP)
        local effective = math.min(math.max(0, tonumber(expectedPerTarget) or 0), math.max(0, predicted))
        totalExpected = totalExpected + math.max(0, tonumber(expectedPerTarget) or 0)
        totalEffective = totalEffective + effective
        totalPredicted = totalPredicted + predicted

        local currentHP = tonumber(t.currentHP)
            or (maxHP * ((tonumber(t.pctHP) or 100) / 100))
        local landingPct = math.max(0, ((currentHP - ((tonumber(t.recentDps) or 0) * castSec)) / maxHP) * 100)
        minLandingPct = math.min(minLandingPct, landingPct)
    end

    local mana = tonumber(meta.mana) or 0
    if mana <= 0 then mana = math.max(1, totalExpected) end
    local manaEff = totalEffective / mana
    local overheal = math.max(0, totalExpected - totalEffective)
    local overhealRatio = overheal / math.max(1, totalPredicted)
    local score = manaEff - (overhealRatio * 0.25)

    return score, {
        coverage = totalEffective / math.max(1, totalPredicted),
        overheal = overhealRatio,
        manaEff = manaEff,
        castSec = castSec,
        expected = totalExpected,
        predicted = totalPredicted,
        effective = totalEffective,
        targets = #(targets or {}),
        minLandingPct = minLandingPct,
        selectionMode = 'stable_efficiency',
    }
end

local function scoreHot(meta, expectedTick, deficit, dps, maxHP)
    local config = Config or { spells = {} }
    config.spells = config.spells or {}
    local tracker = HealTracker
    local mana = math.max(meta.mana, 1)
    local castSec = meta.castTimeMs / 1000
    local recastSec = meta.recastTimeMs / 1000
    local durationSec = math.max(meta.durationTicks * (TICK_MS / 1000), 1)
    local totalExpected = expectedTick * math.max(meta.durationTicks, 1)
    local predicted = predictedDeficit(deficit, dps, durationSec, maxHP)
    local safeDeficit = math.max(predicted, 1)
    local coverage = math.min(totalExpected, safeDeficit) / safeDeficit
    local manaEff = totalExpected / mana
    local hps = totalExpected / durationSec

    local critRate = 0
    local critOverheal = 0
    local critPenalty = 0
    if tracker and tracker.GetHealingGiftCritRate then
        critRate = tracker.GetHealingGiftCritRate() or 0
    end
    if critRate > 0 then
        local baseTick = expectedTick / (1 + critRate)
        local critTick = baseTick * 2
        local totalCritHeal = critTick * math.max(meta.durationTicks, 1)
        local critOverhealAmt = math.max(0, totalCritHeal - safeDeficit)
        critOverheal = critOverhealAmt / safeDeficit
        local critOverhealThreshold = config and config.critOverhealThreshold or 0.5
        if critOverheal > critOverhealThreshold then
            local excessCritOverheal = critOverheal - critOverhealThreshold
            local critPenaltyWeight = (config and config.critOverhealPenalty or -0.8) * 0.5
            critPenalty = excessCritOverheal * critRate * critPenaltyWeight
        end
    end

    local score = (coverage * 2) + (manaEff * 0.5) + (hps * 0.001) + critPenalty - (castSec * 0.2) - (recastSec * 0.1)
    return score, {
        coverage = coverage,
        manaEff = manaEff,
        hps = hps,
        castSec = castSec,
        recastSec = recastSec,
        durationSec = durationSec,
        expected = totalExpected,
        predicted = safeDeficit,
        critRate = critRate,
        critOverheal = critOverheal,
        critPenalty = critPenalty,
    }
end

local function scorePromised(meta, expected, deficit, dps, maxHP)
    local config = Config or { spells = {} }
    config.spells = config.spells or {}
    local tracker = HealTracker
    local mana = math.max(meta.mana, 1)
    local castSec = meta.castTimeMs / 1000
    local recastSec = meta.recastTimeMs / 1000
    local delaySec = meta.durationTicks * (TICK_MS / 1000)
    local predicted = predictedDeficit(deficit, dps, delaySec, maxHP)
    local safeDeficit = math.max(predicted, 1)
    local coverage = math.min(expected, safeDeficit) / safeDeficit
    local manaEff = expected / mana

    local critRate = 0
    local critOverheal = 0
    local critPenalty = 0
    if tracker and tracker.GetHealingGiftCritRate then
        critRate = tracker.GetHealingGiftCritRate() or 0
    end
    if critRate > 0 then
        local baseHeal = expected / (1 + critRate)
        local critHeal = baseHeal * 2
        local critOverhealAmt = math.max(0, critHeal - safeDeficit)
        critOverheal = critOverhealAmt / safeDeficit
        local critOverhealThreshold = config and config.critOverhealThreshold or 0.5
        if critOverheal > critOverhealThreshold then
            local excessCritOverheal = critOverheal - critOverhealThreshold
            local critPenaltyWeight = config and config.critOverhealPenalty or -0.8
            critPenalty = excessCritOverheal * critRate * critPenaltyWeight
        end
    end

    local score = (coverage * 2) + (manaEff * 0.5) - (delaySec * 0.05) - (castSec * 0.2) - (recastSec * 0.1) + critPenalty
    return score, {
        coverage = coverage,
        manaEff = manaEff,
        delaySec = delaySec,
        castSec = castSec,
        recastSec = recastSec,
        expected = expected,
        predicted = safeDeficit,
        critRate = critRate,
        critOverheal = critOverheal,
        critPenalty = critPenalty,
    }
end

local function getExpectedWithFallback(tracker, spellName, fallback, isHot)
    local expected = getExpectedHeal(tracker, spellName)
    if expected ~= nil then
        return expected
    end
    local meta = getSpellMeta(spellName)
    if meta and meta.baseHeal and meta.baseHeal > 0 then
        local aaMult = 1.0
        if tracker and tracker.GetHealingBoonMultiplier and isHot then
            aaMult = tracker.GetHealingBoonMultiplier() or 1.0
        elseif tracker and tracker.GetHealingAdeptMultiplier then
            aaMult = tracker.GetHealingAdeptMultiplier() or 1.0
        end
        local critRate = tracker and tracker.GetHealingGiftCritRate and tracker.GetHealingGiftCritRate() or 0
        local estimated = meta.baseHeal * aaMult * (1 + critRate)
        return estimated
    end
    if tracker and tracker.IsLearning and tracker.IsLearning() and fallback and fallback > 0 then
        return fallback
    end
    return nil
end

local function attachExpected(allSpells, deficit, tracker)
    local list = {}
    for _, spell in ipairs(allSpells) do
        local expected = getExpectedWithFallback(tracker, spell.name, deficit, false)
        if expected then
            table.insert(list, { name = spell.name, cat = spell.cat, expected = expected })
        end
    end
    return list
end

local function preFilterSpells(allSpells, deficit, situation, tracker, config)
    local candidates = attachExpected(allSpells, deficit, tracker)
    if deficit <= 0 or #candidates == 0 then
        return candidates
    end

    local maxOverheal = deficit * (config.maxOverhealRatio or 2.0)
    local filtered = {}
    for _, spell in ipairs(candidates) do
        local expected = spell.expected or 0
        if expected <= maxOverheal or (situation and situation.hasEmergency) then
            table.insert(filtered, spell)
        end
    end

    if #filtered == 0 then
        filtered = candidates
    end

    table.sort(filtered, function(a, b)
        return (a.expected or 0) < (b.expected or 0)
    end)

    return filtered
end

local function formatComponents(components)
    if not components then
        return ''
    end
    local parts = {}
    if components.coverage then table.insert(parts, string.format('cov=%.2f', components.coverage)) end
    if components.overheal then table.insert(parts, string.format('over=%.2f', components.overheal)) end
    if components.manaEff then table.insert(parts, string.format('mana=%.2f', components.manaEff)) end
    if components.underhealBonus and components.underhealBonus > 0 then table.insert(parts, string.format('under=+%.2f', components.underhealBonus)) end
    if components.castSec then table.insert(parts, string.format('cast=%.2f', components.castSec)) end
    if components.recastSec then table.insert(parts, string.format('recast=%.2f', components.recastSec)) end
    if components.delaySec then table.insert(parts, string.format('delay=%.2f', components.delaySec)) end
    if components.hps then table.insert(parts, string.format('hps=%.1f', components.hps)) end
    if components.effective then table.insert(parts, string.format('effective=%.0f', components.effective)) end
    if components.targets then table.insert(parts, string.format('targets=%d', components.targets)) end
    if components.minLandingPct then table.insert(parts, string.format('landMin=%.1f%%', components.minLandingPct)) end
    if components.critPenalty then table.insert(parts, string.format('crit=%.2f', components.critPenalty)) end
    if components.categoryPenalty then table.insert(parts, string.format('cat=%.2f', components.categoryPenalty)) end
    return table.concat(parts, ' ')
end

local function formatScoreDetails(trigger, category, components)
    local c = formatComponents(components)
    if c ~= '' then
        return string.format('trigger=%s category=%s %s', trigger or '', category or '', c)
    end
    return string.format('trigger=%s category=%s', trigger or '', category or '')
end

local function joinDetails(primary, extra)
    if extra == nil or extra == '' then
        return primary
    end
    if primary == nil or primary == '' then
        return extra
    end
    return primary .. ' | ' .. extra
end

-- Snapshot the most recent scoring pass for the dashboard. `scores` is a list
-- of `{ spell|name, score, category?, expected, mana?, castTime? }` rows.
-- Stored in M._lastScores; read via M.getLastScores(). Always overwrites — we
-- only ever surface the most recent decision, regardless of pass kind.
local function stashScores(kind, targetInfo, scores, winnerSpell, winnerScore)
    if not scores then scores = {} end
    local out = {}
    for _, s in ipairs(scores) do
        table.insert(out, {
            spell = s.spell or s.name,
            score = s.score,
            category = s.category,
            expected = s.expected,
            mana = s.mana or 0,
            castTime = s.castTime or 0,
        })
    end
    table.sort(out, function(a, b) return (a.score or 0) > (b.score or 0) end)
    local snapshot = {
        kind = kind,
        targetName = (targetInfo and (targetInfo.name or targetInfo.targetName)) or '?',
        deficit = (targetInfo and targetInfo.deficit) or 0,
        pctHP = (targetInfo and targetInfo.pctHP) or 0,
        maxHP = (targetInfo and targetInfo.maxHP) or 0,
        maxHPKnown = targetInfo and targetInfo.maxHPKnown == true or false,
        maxHPSource = (targetInfo and targetInfo.maxHPSource) or 'unknown',
        recentDps = (targetInfo and targetInfo.recentDps) or 0,
        scores = out,
        winner = winnerSpell,
        winnerScore = winnerScore,
        at = os.time(),
    }
    M._lastScores = snapshot
    local targetName = tostring(snapshot.targetName or ''):lower()
    if targetInfo and tonumber(targetInfo.maxHP) and tonumber(targetInfo.maxHP) > 0
        and targetName ~= '' and targetName ~= 'group' and targetName ~= 'target' then
        M._lastTargetScores = snapshot
    end
end

local function getHighPressure()
    if CombatAssessor and CombatAssessor.isHighPressure then
        local hp, mobs, dps = CombatAssessor.isHighPressure()
        return hp == true, (mobs or 0), (dps or 0)
    end
    return false, 0, 0
end

local function getTotalIncomingDps()
    if CombatAssessor and CombatAssessor.getState then
        local s = CombatAssessor.getState()
        return s and s.totalIncomingDps or 0
    end
    return 0
end

local function calculateSupplementGap(targetInfo, config)
    local log = getLogger()
    local proactive = getProactive()
    local hotData = proactive and proactive.GetHotData and proactive.GetHotData(targetInfo.name) or nil
    if not hotData or not hotData.spell then
        if log then log.debug('supplement', '[%s] No active HoT, supplement allowed', targetInfo.name or '?') end
        return true, targetInfo.deficit, 'no_hot_active'
    end

    local remainingPct = proactive and proactive.GetHotRemainingPct and proactive.GetHotRemainingPct(targetInfo.name) or 0
    if remainingPct <= 0 then
        if log then log.debug('supplement', '[%s] HoT expired, supplement allowed', targetInfo.name or '?') end
        return true, targetInfo.deficit, 'hot_expired'
    end

    local remainingSec = (remainingPct / 100) * (hotData.duration or 0)

    local tracker = HealTracker
    local hpPerTick = 0
    if tracker and hotData.spell then
        hpPerTick = getExpectedHeal(tracker, hotData.spell) or 0
    end
    if hpPerTick <= 0 then
        if log then log.debug('supplement', '[%s] No HoT data for %s, supplement allowed', targetInfo.name or '?', hotData.spell or '?') end
        return true, targetInfo.deficit, 'no_hot_data'
    end

    local tickInterval = TICK_MS / 1000  -- 6 seconds per tick
    local ticksRemaining = math.floor(remainingSec / tickInterval)
    local remainingHotHealing = hpPerTick * ticksRemaining

    -- Calculate HoT HPS (healing per second)
    local hotHps = hpPerTick / tickInterval
    local dps = targetInfo.recentDps or 0

    -- ============================================================
    -- Opening-burst guards (force supplement when HoT/DPS data is cold)
    -- ============================================================
    -- Two failure modes were observed at fight start, both of which made
    -- the downstream "HoT keeping up" / "safety buffer" math return safe
    -- when the tank was actually about to die:
    --   (1) A just-cast HoT contributes ZERO real healing for the first
    --       tickInterval (~6s) — first tick fires after the interval — but
    --       the math above optimistically credits it with hpPerTick/6s of
    --       HPS from the moment of cast.
    --   (2) targetInfo.recentDps is computed from a sliding damage window
    --       (target_monitor.lua) which is empty for the first ~5s of a
    --       fresh fight. Reported DPS = 0 → "HoT keeping up" false
    --       positive. By the time real DPS data arrives the tank is
    --       already in trouble.
    -- The downstream "safety buffer" (8s default) compounds both: even
    -- with degraded inputs, hpAboveDanger / |netHps| typically still
    -- exceeds 8s while HP is high, so we'd skip supplement anyway. So
    -- rather than perturb the inputs we short-circuit and return
    -- "supplement needed" outright.
    local now = mq.gettime()
    local hotJustCast = false
    if hotData.castTime then
        local hotAgeMs = now - hotData.castTime
        if hotAgeMs >= 0 and hotAgeMs < TICK_MS then
            hotJustCast = true
        end
    end

    local fightStartTime = (CombatAssessor and CombatAssessor.getFightStartTime
        and CombatAssessor.getFightStartTime()) or 0
    local fightAgeMs = (fightStartTime > 0) and (now - fightStartTime) or math.huge
    local OPENING_BURST_WINDOW_MS = (config.hotOpeningWindowSec or 5) * 1000
    local fightIsYoung = fightAgeMs < OPENING_BURST_WINDOW_MS

    -- Both guards are gated on "fight is young" so mid-fight HoT refreshes
    -- and brief DPS lulls don't trigger phantom supplements.
    local warmupGate = hotJustCast and fightIsYoung
    local coldStartGate = (dps <= 0) and fightIsYoung

    if warmupGate or coldStartGate then
        local reason = warmupGate
            and (coldStartGate and 'opening_burst_hot_warmup_and_dps_cold'
                or 'opening_burst_hot_warmup')
            or 'opening_burst_dps_cold'
        local details = string.format(
            'hotAge=%.1fs fightAge=%.1fs dps=%.0f hotHps=%.0f hotJustCast=%s dpsZero=%s',
            (hotData.castTime and (now - hotData.castTime) or 0) / 1000,
            fightAgeMs / 1000, dps, hotHps, tostring(hotJustCast), tostring(dps <= 0))
        if log then
            log.info('supplement', '[%s] OPENING-BURST SUPPLEMENT (%s): %s',
                targetInfo.name or '?', reason, details)
        end
        return true, targetInfo.deficit, reason
    end

    -- Net HPS: positive = gaining HP, negative = losing HP
    local netHps = hotHps - dps

    if log then
        log.debug('supplement', '[%s] HoT=%s hpPerTick=%.0f ticksRemain=%d hotHps=%.0f dps=%.0f netHps=%.0f',
            targetInfo.name or '?', hotData.spell or '?', hpPerTick, ticksRemaining, hotHps, dps, netHps)
    end

    -- If HoT is keeping up with damage (positive net HPS), no supplement needed
    if netHps >= 0 then
        local details = string.format('hotHps=%.0f dps=%.0f netHps=+%.0f (HoT keeping up, no supplement)',
            hotHps, dps, netHps)
        if log then log.info('supplement', '[%s] HoT KEEPING UP: %s', targetInfo.name or '?', details) end
        return false, 0, details
    end

    -- HoT isn't keeping up - check if we have enough safety buffer
    -- Calculate current HP and danger threshold
    local currentHp = targetInfo.currentHP or ((targetInfo.maxHP or 1) * ((targetInfo.pctHP or 100) / 100))
    local dangerPct = config.getEmergencyPct()
    local dangerHp = (targetInfo.maxHP or 1) * (dangerPct / 100)
    local hpAboveDanger = currentHp - dangerHp

    -- Calculate time until we reach danger threshold at current net loss rate
    -- netHps is negative here, so we're losing HP
    local safetyBufferSec = config.hotSafetyBufferSec or 8  -- Default 8 seconds of safety buffer

    if log then
        log.debug('supplement', '[%s] currentHp=%.0f dangerHp=%.0f hpAboveDanger=%.0f safetyBuffer=%.0fs',
            targetInfo.name or '?', currentHp, dangerHp, hpAboveDanger, safetyBufferSec)
    end

    if hpAboveDanger > 0 then
        local timeUntilDanger = hpAboveDanger / math.abs(netHps)

        -- If we have enough time before danger, let HoT work
        if timeUntilDanger > safetyBufferSec then
            local details = string.format('hotHps=%.0f dps=%.0f netHps=%.0f hpBuffer=%.0f dangerIn=%.1fs safetyReq=%.0fs (safe, HoT working)',
                hotHps, dps, netHps, hpAboveDanger, timeUntilDanger, safetyBufferSec)
            if log then log.info('supplement', '[%s] HoT SAFE (%.1fs to danger > %.0fs buffer): %s', targetInfo.name or '?', timeUntilDanger, safetyBufferSec, details) end
            return false, 0, details
        end

        -- Danger is approaching - calculate the gap we need to cover
        -- Gap = how much HP we'll lose beyond what HoT can heal before HoT expires or we reach danger
        local hpLossRate = math.abs(netHps)
        local hpLossDuringHot = hpLossRate * remainingSec
        local gap = math.max(0, hpLossDuringHot - hpAboveDanger)

        -- Only supplement if gap is significant (at least 5% of max HP)
        local minGapPct = config.hotSupplementMinGapPct or 5
        local minGap = (targetInfo.maxHP or 1) * (minGapPct / 100)
        if gap < minGap then
            local details = string.format('hotHps=%.0f dps=%.0f netHps=%.0f dangerIn=%.1fs gap=%.0f minGap=%.0f (gap too small, skip supplement)',
                hotHps, dps, netHps, timeUntilDanger, gap, minGap)
            if log then log.info('supplement', '[%s] GAP TOO SMALL (%.0f < %.0f): %s', targetInfo.name or '?', gap, minGap, details) end
            return false, 0, details
        end

        local details = string.format('hotHps=%.0f dps=%.0f netHps=%.0f dangerIn=%.1fs gap=%.0f (supplement needed)',
            hotHps, dps, netHps, timeUntilDanger, gap)
        if log then log.warn('supplement', '[%s] SUPPLEMENT NEEDED (danger in %.1fs, gap=%.0f): %s', targetInfo.name or '?', timeUntilDanger, gap, details) end
        return true, gap, details
    end

    -- Already at or below danger threshold - need immediate supplement
    local details = string.format('hotHps=%.0f dps=%.0f netHps=%.0f hpBuffer=%.0f (at danger, supplement NOW)',
        hotHps, dps, netHps, hpAboveDanger)
    if log then log.warn('supplement', '[%s] AT DANGER THRESHOLD: %s', targetInfo.name or '?', details) end
    return true, targetInfo.deficit, details
end

local function shouldUseFastCatchup(targetInfo, efficientHeal, situation)
    if not targetInfo or not efficientHeal then return false, 'no_efficient_heal' end

    local maxHP = math.max(1, tonumber(targetInfo.maxHP) or 1)
    local dps = math.max(0, tonumber(targetInfo.recentDps) or 0)
    local dpsPct = (dps / maxHP) * 100
    local state = situation and situation.combatAssessment or {}
    local pressure = (situation and situation.survivalMode == true)
        or state.highPressure == true
        or targetInfo.burstDetected == true
        or dpsPct >= (tonumber(Config and Config.fastHealMinDpsPct) or 2)
    if not pressure then
        return false, string.format('stable dpsPct=%.2f', dpsPct)
    end

    local meta = getSpellMeta(efficientHeal.spell)
    if not meta then return false, 'efficient_meta_missing' end
    local castSec = math.max(0, (tonumber(meta.castTimeMs) or 0) / 1000)
    local expected = math.max(0, tonumber(efficientHeal.expected) or 0)
    local currentHP = tonumber(targetInfo.currentHP)
        or (maxHP * ((tonumber(targetInfo.pctHP) or 100) / 100))
    local projectedPctAtLand = ((currentHP - (dps * castSec)) / maxHP) * 100
    local netCatchup = expected - (dps * castSec)
    local emergencyFloor = Config.getEmergencyPct()
    local maxHPKnown = targetInfo.maxHPKnown == true
    local fallingBehind = targetInfo.burstDetected == true
        -- Absolute DPS is scaled by the fallback Max HP estimate. It cannot be
        -- compared to real spell amounts until Max HP is known; percentage
        -- projection remains valid for estimated targets.
        or (maxHPKnown and netCatchup <= 0)
        or projectedPctAtLand <= emergencyFloor

    return fallingBehind, string.format(
        'pressure=%s dps=%.0f dpsPct=%.2f cast=%.1fs net=%.0f projected=%.1f%% floor=%.1f%% maxKnown=%s',
        tostring(pressure), dps, dpsPct, castSec, netCatchup, projectedPctAtLand,
        emergencyFloor, tostring(maxHPKnown))
end

function M.SelectHeal(targetInfo, situation)
    local config = Config or { spells = {} }
    config.spells = config.spells or {}
    local tracker = HealTracker
    -- Resolve Proactive lazily; earlier code referenced a bare global
    -- `Proactive` that always resolved to nil, silently disabling the
    -- promised-heal safety gate, HoT refresh path, and supplement logic.
    local Proactive = getProactive()
    local deficit = targetInfo.deficit
    local learning = tracker and tracker.IsLearning and tracker.IsLearning()
    local nonSquishy = not targetInfo.isSquishy
    local lowPressure = situation and situation.lowPressure

    if deficit <= 0 then return nil, 'no_deficit' end

    local isSelf = targetInfo._isSelf or false

    if targetInfo.pctHP < config.getEmergencyPct() then
        local heal = M.FindFastestHeal(deficit, isSelf, targetInfo)
        if heal then
            heal.details = joinDetails(heal.details, 'trigger=emergency')
        end
        if not heal then
            return nil, 'emergency_no_heal'
        end
        return heal
    end

    local deficitPct = (targetInfo.maxHP > 0) and (deficit / targetInfo.maxHP) * 100 or 0

    if Proactive and Proactive.IsSafeToWaitForPromised then
        local isSafe, projection = Proactive.IsSafeToWaitForPromised(targetInfo)
        if isSafe and projection then
            local reason = 'promised_covering|' .. (projection.details or '')
            return nil, reason
        end
        if projection and projection.minPctDuringWait and projection.safetyFloorPct then
            local safetyGapPct = projection.safetyFloorPct - projection.minPctDuringWait
            if safetyGapPct > 0 and safetyGapPct < deficitPct then
                local safetyGap = (safetyGapPct / 100) * (targetInfo.maxHP or 1)
                deficit = safetyGap
                deficitPct = safetyGapPct
                targetInfo._promisedSafetyGap = safetyGap
                targetInfo._promisedSafetyDetails = string.format(
                    'promised_pending safetyGap=%.0f gapPct=%.1f minPct=%.1f floor=%d%% %s',
                    safetyGap, safetyGapPct, projection.minPctDuringWait,
                    projection.safetyFloorPct, projection.details or ''
                )
            end
        end
    end

    if config.considerIncomingHot and targetInfo.incomingHotRemaining and targetInfo.incomingHotRemaining > 0 then
        local coveragePct = config.hotIncomingCoveragePct or 100
        local incoming = targetInfo.incomingHotRemaining or 0
        local maxHP = targetInfo.maxHP or 1
        local dps = targetInfo.recentDps or 0
        local dpsPctPerSec = (dps / maxHP) * 100
        local hotOverrideDpsPct = config.hotOverrideDpsPct or 5
        local lowDps = dpsPctPerSec <= hotOverrideDpsPct
        if lowDps and deficit > 0 and incoming >= (deficit * (coveragePct / 100)) then
            return nil, 'incoming_hot_cover'
        end
        deficit = math.max(0, deficit - incoming)
        if deficit <= 0 then
            return nil, 'incoming_hot_cover'
        end
        deficitPct = (targetInfo.maxHP > 0) and (deficit / targetInfo.maxHP) * 100 or 0
    end

    local hotEnabled = config.hotEnabled ~= false
    local hotMaxPct = config.hotMaxDeficitPct or 35  -- HoTs eligible up to 35% deficit (65% HP)
    local learnMaxPct = config.hotLearnMaxDeficitPct or hotMaxPct
    local hotPreferUnderDps = config.hotPreferUnderDps or config.sustainedDamageThreshold or 3000
    local hotMinDeficitPct = config.hotMinDeficitPct or 20  -- HoTs start at 20% deficit (80% HP)
    if nonSquishy and config.nonSquishyHotMinDeficitPct then
        hotMinDeficitPct = math.max(hotMinDeficitPct, config.nonSquishyHotMinDeficitPct)
    end
    if lowPressure and nonSquishy and config.lowPressureHotMinDeficitPct then
        hotMinDeficitPct = math.max(hotMinDeficitPct, config.lowPressureHotMinDeficitPct)
    end
    local allowLearnHot = learning and config.hotLearnForce and deficitPct <= learnMaxPct
    local refreshable = true
    if Proactive and Proactive.HasActiveHot and Proactive.HasActiveHot(targetInfo.name) then
        -- Pre-selection check: we don't know which HoT we'd cast yet, so ask
        -- generically via nil spell name. Self buffs and the shared single/group
        -- HoT slot both participate in refresh eligibility.
        refreshable = Proactive.ShouldRefreshHot and Proactive.ShouldRefreshHot(targetInfo.name, nil) or false
    end

    local isPriorityTarget = targetInfo.role == 'tank'
    local hotTankOnly = config.hotTankOnly ~= false
    local hotMinDpsForNonTank = config.hotMinDpsForNonTank or 500
    local hotMinDps = config.hotMinDps or 200
    local targetDps = targetInfo.recentDps or 0
    local hasSustainedDamage = targetDps >= hotMinDpsForNonTank
    local hasAnyDamage = targetDps >= hotMinDps  -- Require at least hotMinDps for any HoT
    local isHighPressure, mobs, totalDps = getHighPressure()
    local allowHighPressureHot = isPriorityTarget and isHighPressure

    -- Target must have minimum DPS for HoT consideration (prevents HoTs at full HP with no damage)
    local targetAllowedHot = (isPriorityTarget and hasAnyDamage) or hasSustainedDamage or allowLearnHot

    local hotEligible = hotEnabled
        and deficitPct >= hotMinDeficitPct
        and (deficitPct <= hotMaxPct or allowLearnHot)
        and ((targetDps <= hotPreferUnderDps and hasAnyDamage) or allowLearnHot or allowHighPressureHot)
        and refreshable
        and targetAllowedHot

    if hotEligible then
        local useLight = true
        if isPriorityTarget and isHighPressure then
            local totalIncoming = getTotalIncomingDps()
            local bigHotWithPromisedMinDps = config.bigHotWithPromisedMinDps or 6000
            local promisedAvailable = false
            if Proactive and Proactive.HasActivePromised and Proactive.HasActivePromised(targetInfo.name) then
                promisedAvailable = true
            end
            if not promisedAvailable and config.spells and config.spells.promised then
                for _, spellName in ipairs(config.spells.promised) do
                    local ready = mq.TLO.Me.SpellReady(spellName)
                    if ready and ready() then
                        promisedAvailable = true
                        break
                    end
                end
            end
            if promisedAvailable and totalIncoming < bigHotWithPromisedMinDps then
                useLight = true
            else
                useLight = false
            end
        end
        local allowFallback = isPriorityTarget or not hotTankOnly
        local bestHot = M.SelectBestHot(targetInfo, useLight, allowFallback)
        if bestHot then
            local trigger = allowLearnHot and 'trigger=hot_learn_force' or 'trigger=hot_preference'
            local refreshTag = (refreshable and Proactive and Proactive.HasActiveHot
                and Proactive.HasActiveHot(targetInfo.name)) and ' refresh=true' or ''
            local pressureTag = ''
            if not useLight then
                pressureTag = string.format(' bigHot=true highPressure=mobs:%s dps:%s', tostring(mobs or 0), tostring(totalDps or 0))
            else
                pressureTag = ' lightHot=true'
            end
            local detail = joinDetails(
                bestHot.details,
                string.format('%s dps=%.0f deficitPct=%.1f%s%s', trigger, targetInfo.recentDps or 0, deficitPct, refreshTag, pressureTag)
            )
            return { spell = bestHot.spell, expected = bestHot.expected, category = 'hot', details = detail }
        end
    end

    if Proactive and Proactive.HasActiveHot and Proactive.HasActiveHot(targetInfo.name) then
        local log = getLogger()
        local supplementMinPct = config.minHealPct or 10
        if nonSquishy and config.nonSquishyMinHealPct then
            supplementMinPct = math.max(supplementMinPct, config.nonSquishyMinHealPct)
        end
        if lowPressure and nonSquishy and config.lowPressureMinDeficitPct then
            supplementMinPct = math.max(supplementMinPct, config.lowPressureMinDeficitPct)
        end
        if deficitPct < supplementMinPct then
            if log then log.debug('supplement', '[%s] Deficit %.1f%% below supplement min %.1f%%, skipping', targetInfo.name or '?', deficitPct, supplementMinPct) end
            return nil, string.format('supplement_below_min_pct|deficitPct=%.1f minPct=%.1f', deficitPct, supplementMinPct)
        end

        if log then log.debug('supplement', '[%s] Checking supplement: deficit=%.0f deficitPct=%.1f%% pctHP=%.0f%% dps=%.0f',
            targetInfo.name or '?', deficit, deficitPct, targetInfo.pctHP or 0, targetInfo.recentDps or 0) end

        local needsSupplement, gap, supplementDetails = calculateSupplementGap(targetInfo, config)
        if not needsSupplement or gap <= 0 then
            if log then log.info('supplement', '[%s] HoT covering deficit, NO SUPPLEMENT: %s', targetInfo.name or '?', supplementDetails or '') end
            return nil, 'hot_covering|' .. (supplementDetails or '')
        end

        if log then log.info('supplement', '[%s] Supplement NEEDED, gap=%.0f: %s', targetInfo.name or '?', gap, supplementDetails or '') end

        local gapTargetInfo = {
            name = targetInfo.name,
            role = targetInfo.role,
            currentHP = targetInfo.currentHP,
            maxHP = targetInfo.maxHP,
            pctHP = targetInfo.pctHP,
            deficit = gap,
            recentDps = targetInfo.recentDps,
            isSquishy = targetInfo.isSquishy,
            incomingHotRemaining = 0,
            _isSelf = targetInfo._isSelf,
        }

        local supplementHeal = M.FindEfficientHeal(gapTargetInfo, false, situation)
        if supplementHeal then
            if log then log.info('supplement', '[%s] Selected supplement heal: %s expected=%.0f for gap=%.0f',
                targetInfo.name or '?', supplementHeal.spell or '?', supplementHeal.expected or 0, gap) end
            supplementHeal.details = joinDetails(
                supplementHeal.details,
                string.format('trigger=supplement gap=%.0f %s', gap, supplementDetails or '')
            )
            return supplementHeal
        else
            if log then log.debug('supplement', '[%s] No supplement heal found for gap=%.0f', targetInfo.name or '?', gap) end
        end
    end

    -- Check HoT trust before selecting direct heal
    local ok, HotAnalyzer = pcall(require, 'smartheal.hot_analyzer')
    if ok and HotAnalyzer and HotAnalyzer.shouldTrustHoT then
        local trustHoT, analysis, decision = HotAnalyzer.shouldTrustHoT(targetInfo, situation)
        if trustHoT then
            return nil, 'hot_trusted|' .. (analysis and string.format('projected=%.0f%% threshold=%.0f%%',
                analysis.projectedPct or 0, analysis.threshold or 0) or '')
        end

        -- Use uncovered gap for sizing the heal
        if analysis and analysis.uncoveredGap and analysis.uncoveredGap > 0 then
            deficit = analysis.uncoveredGap
            deficitPct = (deficit / (targetInfo.maxHP or 1)) * 100
        end
    end

    local minHealPct = config.minHealPct or 10
    if lowPressure and nonSquishy and config.lowPressureMinDeficitPct and deficitPct < config.lowPressureMinDeficitPct then
        return nil, 'below_min_pct_low_pressure'
    end
    if nonSquishy and config.nonSquishyMinHealPct and deficitPct < config.nonSquishyMinHealPct then
        return nil, 'below_min_pct_nonsquishy'
    end
    if deficitPct < minHealPct then
        return nil, 'below_min_pct'
    end

    -- Character-specific minimum deficit check
    -- This prevents overhealing when all available heals are too big for the deficit
    -- The threshold is relative to the target's max HP, not just the raw heal amount
    local minExpectedHeal = M.GetMinExpectedHeal()
    local minHealThresholdPct = config.minHealThresholdPct or 70  -- Deficit must be at least 70% of smallest heal's % of maxHP
    local log = getLogger()
    if minExpectedHeal and minExpectedHeal > 0 and targetInfo.maxHP and targetInfo.maxHP > 0 then
        -- What % of target's maxHP is our smallest heal?
        local minHealPctOfMaxHP = (minExpectedHeal / targetInfo.maxHP) * 100

        -- The target needs to be missing at least (minHealPct * threshold%) of their maxHP
        -- This makes the threshold character-specific - tanks with big HP pools have lower % thresholds
        local minDeficitPctNeeded = minHealPctOfMaxHP * (minHealThresholdPct / 100)

        if deficitPct < minDeficitPctNeeded then
            if log then
                log.debug('selection', '[%s] SKIP: DeficitPct %.1f%% < minNeeded %.1f%% (minHeal=%.0f is %.1f%% of maxHP %.0f)',
                    targetInfo.name or '?', deficitPct, minDeficitPctNeeded, minExpectedHeal, minHealPctOfMaxHP, targetInfo.maxHP)
            end
            return nil, string.format('deficit_pct_below_min_heal|deficitPct=%.1f minNeeded=%.1f minHeal=%.0f maxHP=%.0f',
                deficitPct, minDeficitPctNeeded, minExpectedHeal, targetInfo.maxHP)
        else
            if log then
                log.debug('selection', '[%s] PASS: DeficitPct %.1f%% >= minNeeded %.1f%% (minHeal=%.0f is %.1f%% of maxHP %.0f)',
                    targetInfo.name or '?', deficitPct, minDeficitPctNeeded, minExpectedHeal, minHealPctOfMaxHP, targetInfo.maxHP)
            end
        end
    end

    local heal = M.FindEfficientHeal(targetInfo, false, situation)
    if not heal then
        return nil, 'no_efficient_heal'
    end
    local useFast, catchupDetails = shouldUseFastCatchup(targetInfo, heal, situation)
    if useFast then
        local fast = M.FindFastestHeal(deficit, isSelf, targetInfo)
        if fast then
            fast.details = joinDetails(fast.details, 'trigger=high_dps_catchup ' .. catchupDetails)
            return fast
        end
    end
    heal.details = joinDetails(heal.details, 'fast_guard=' .. catchupDetails)
    return heal
end

-- Cache for minimum expected heal (refreshed periodically)
local _minExpectedHealCache = nil
local _minExpectedHealCacheTime = 0
-- 30s expressed in milliseconds to match mq.gettime(); was previously `30`
-- which made the cache effectively miss every 30ms.
local MIN_HEAL_CACHE_TTL = 30 * 1000

function M.GetMinExpectedHeal()
    local now = mq.gettime and mq.gettime() or (os.time() * 1000)
    if _minExpectedHealCache and (now - _minExpectedHealCacheTime) < MIN_HEAL_CACHE_TTL then
        return _minExpectedHealCache
    end

    local config = Config or { spells = {} }
    config.spells = config.spells or {}
    local tracker = HealTracker
    local minExpected = nil

    -- Check all direct heal categories (not HoTs)
    local categories = { 'fast', 'small', 'medium', 'large' }
    if config.selfHealEnabled then
        table.insert(categories, 'selfHeal')
    end
    for _, cat in ipairs(categories) do
        for _, spellName in ipairs(config.spells[cat] or {}) do
            local expected = getExpectedHeal(tracker, spellName)
            if expected and expected > 0 then
                local meta = getSpellMeta(spellName)
                if meta and isSpellUsable(spellName, meta) then
                    if not minExpected or expected < minExpected then
                        minExpected = expected
                    end
                end
            end
        end
    end

    _minExpectedHealCache = minExpected
    _minExpectedHealCacheTime = now
    return minExpected
end

function M.FindFastestHeal(deficit, isSelf, targetInfo)
    local config = Config or { spells = {} }
    config.spells = config.spells or {}
    local tracker = HealTracker
    local candidates = {}
    local categories = { 'fast', 'small', 'medium', 'large' }
    if isSelf and config.selfHealEnabled then
        table.insert(categories, 'selfHeal')
    end

    for _, cat in ipairs(categories) do
        for _, spellName in ipairs(config.spells[cat] or {}) do
            local expected = getExpectedHeal(tracker, spellName)
            if expected and not isCompleteHeal(spellName) then
                local meta = getSpellMeta(spellName)
                if meta and isSpellUsable(spellName, meta) then
                    table.insert(candidates, {
                        spell = spellName,
                        expected = expected,
                        category = cat,
                        castTimeMs = meta.castTimeMs or 0,
                    })
                end
            end
        end
    end

    if #candidates == 0 then
        stashScores('fastest', targetInfo or { name = isSelf and 'self' or 'target', deficit = deficit }, {}, nil, nil)
        return nil
    end

    table.sort(candidates, function(a, b) return a.castTimeMs < b.castTimeMs end)
    local fastest = candidates[1]

    -- Surface the candidate list to the dashboard. There's no real score for
    -- "fastest" — synthesize one as the inverse of cast time so the table
    -- sorts in the same order the selector evaluated them.
    local synthScores = {}
    for _, c in ipairs(candidates) do
        table.insert(synthScores, {
            spell = c.spell,
            score = -((tonumber(c.castTimeMs) or 0) / 1000),
            category = c.category,
            expected = c.expected,
            mana = 0,
            castTime = c.castTimeMs,
        })
    end
    stashScores('fastest', targetInfo or { name = isSelf and 'self' or 'target', deficit = deficit },
        synthScores, fastest.spell, -(fastest.castTimeMs / 1000))

    return {
        spell = fastest.spell,
        expected = fastest.expected,
        category = fastest.category,
        details = formatScoreDetails('fastest', 'single', nil),
    }
end

local function evaluateEfficientHeals(targetInfo, allowFast, situation)
    local config = Config or { spells = {} }
    config.spells = config.spells or {}
    local tracker = HealTracker
    local deficit = targetInfo.deficit
    local dps = targetInfo.recentDps or 0
    local maxHP = targetInfo.maxHP or 1

    local allSpells = {}
    local categories = { 'small', 'medium', 'large' }
    if allowFast then
        table.insert(categories, 1, 'fast')
    end
    if targetInfo._isSelf and config.selfHealEnabled then
        table.insert(categories, 'selfHeal')
    end

    for _, cat in ipairs(categories) do
        for _, spellName in ipairs(config.spells[cat] or {}) do
            table.insert(allSpells, { name = spellName, cat = cat })
        end
    end

    -- If no spells found in small/medium/large, fall back to 'fast' category
    -- This handles cases where all direct heals are "quick heal" type
    if #allSpells == 0 and not allowFast then
        for _, spellName in ipairs(config.spells.fast or {}) do
            table.insert(allSpells, { name = spellName, cat = 'fast' })
        end
    end

    local eligibleSpells = {}
    for _, candidate in ipairs(allSpells) do
        local meta = getSpellMeta(candidate.name)
        local fastAllowed = allowFast or not isFastDirectHeal(meta, candidate.cat)
        if fastAllowed and not isCompleteHeal(candidate.name) then
            table.insert(eligibleSpells, candidate)
        end
    end
    local filtered = preFilterSpells(eligibleSpells, deficit, situation, tracker, config)
    local best = nil
    local bestScore = -999
    local scores = {}

    for _, candidate in ipairs(filtered) do
        local spellName = candidate.name
        local meta = getSpellMeta(spellName)
        if meta and isSpellUsable(spellName, meta) then
            local score, components, weightText = scoreStableEfficiency(meta, candidate.expected, deficit, dps, maxHP)
            table.insert(scores, {
                spell = spellName,
                score = score,
                category = candidate.cat,
                expected = candidate.expected,
                mana = meta.mana,
                castTime = meta.castTimeMs,
                components = components,
                weights = weightText,
            })
            if score > bestScore then
                bestScore = score
                best = {
                    spell = spellName,
                    expected = candidate.expected,
                    category = candidate.cat,
                    score = score,
                    mana = meta.mana,
                    castTime = meta.castTimeMs,
                    components = components,
                    details = formatScoreDetails('stable_efficiency', 'single', components),
                }
            end
        end
    end

    return best, scores, bestScore
end

function M.FindEfficientHeal(targetInfo, allowFast, situation)
    -- Pet override: Complete Heal is the ideal pet heal — full heal for its
    -- mana, and the CH drawbacks (10s cast, overheal risk on players getting
    -- spot-healed) don't apply to a pet. Always use it when memorized and
    -- ready; otherwise fall through to normal scoring.
    if targetInfo and targetInfo.role == 'pet' then
        local chName = 'Complete Heal'
        local meta = getSpellMeta(chName)
        if meta and isSpellUsable(chName, meta) then
            return {
                spell = chName,
                expected = tonumber(targetInfo.deficit) or tonumber(targetInfo.maxHP) or 0,
                details = 'pet_complete_heal_override',
            }
        end
    end

    local best, scores, bestScore = evaluateEfficientHeals(targetInfo, allowFast, situation)

    stashScores('efficient', targetInfo, scores, best and best.spell or nil, bestScore)

    local log = getLogger()
    if log and log.logSpellSelection then
        log.logSpellSelection(targetInfo, 'single', M._lastScores.scores, best and best.spell or nil, bestScore)
    end

    return best
end

-- Calculate the strongest stable single-target direct-heal alternative without
-- replacing the dashboard's most recent scoring snapshot. Group selection uses
-- this to compare like-for-like value instead of automatically winning.
local function bestSingleDirectScore(targetInfo, situation)
    local best, _, bestScore = evaluateEfficientHeals(targetInfo, false, situation)
    return best, best and bestScore or nil
end

-- Group spells are centered on the healer; Range is only the target range.
function M.groupTargetsInRange(spellName, targets)
    local spell = mq.TLO.Spell(spellName)
    local radius = spell and spell() and tonumber(spell.AERange()) or 0
    local affected = {}
    if radius <= 0 then return affected end
    for _, t in ipairs(targets or {}) do
        local distance = t._isSelf and 0 or tonumber(t.distance3D)
        if t.role ~= 'pet' and not t.actorReported and not t.dead and not t.hovering
            and distance and distance <= radius then
            affected[#affected + 1] = t
        end
    end
    return affected
end

function M.ShouldUseGroupHeal(targets, situation)
    local config = Config or { spells = {} }
    config.spells = config.spells or {}
    local tracker = HealTracker
    if not config or not config.spells then return false, nil end

    local hasEmergency = false
    local hurtTargets = {}
    for _, t in ipairs(targets or {}) do
        if (t.pctHP or 100) < config.getEmergencyPct() then
            hasEmergency = true
        end
        if t.deficit and t.deficit > 0 then
            table.insert(hurtTargets, t)
        end
    end

    if hasEmergency then
        return false, nil
    end

    -- Check for AE damage pattern
    local aeDetected = false
    for _, t in ipairs(hurtTargets) do
        if t.isInAE then
            aeDetected = true
            break
        end
    end

    -- Lower threshold if AE detected (damage pattern will continue)
    local minCount = config.groupHealMinCount or 3
    if aeDetected then
        minCount = math.max(2, minCount - 1)
    end

    local best = nil
    local bestScore = -math.huge
    local allScores = {}

    for _, spellName in ipairs(config.spells.group or {}) do
        local expected = getExpectedHeal(tracker, spellName)
        if expected and expected > 0 then
            local meta = getSpellMeta(spellName)
            if meta and isSpellUsable(spellName, meta) then
                local castSec = meta.castTimeMs / 1000
                local predictedTotal = 0
                local eligibleTargets = {}
                local affected = M.groupTargetsInRange(spellName, targets)
                for _, t in ipairs(affected) do
                    local predicted = predictedDeficit(t.deficit, t.recentDps, castSec, t.maxHP)
                    if (t.deficit or 0) > 0 and predicted >= expected then
                        table.insert(eligibleTargets, t)
                        predictedTotal = predictedTotal + predicted
                    end
                end

                local eligibleCount = #eligibleTargets
                if eligibleCount >= minCount then
                    local totalHealing = expected * eligibleCount
                    local thresholdDeficit = predictedTotal > 0 and predictedTotal or totalHealing
                    if totalHealing >= thresholdDeficit * 0.7 then
                        -- The eligibility gate only needs the sufficiently hurt
                        -- members, but the spell lands on the entire local group.
                        -- Score all affected members so incidental useful healing
                        -- and overheal are both represented in effective HPM.
                        local score, components = scoreGroup(meta, expected, affected)
                        table.insert(allScores, { name = spellName, score = score, expected = expected, mana = meta.mana, castTime = meta.castTimeMs })
                        if score > bestScore then
                            bestScore = score
                            best = {
                                spell = spellName,
                                expected = expected,
                                targets = eligibleCount,
                                score = score,
                                components = components,
                                details = formatScoreDetails('group_score', 'group', components),
                            }
                        end
                    end
                end
            end
        end
    end

    -- Compare the best group heal with the strongest stable single-target
    -- direct heal available for any hurt member. High-DPS catch-up remains a
    -- single-target responsibility: the fast-heal guard in SelectHeal will
    -- then choose the quickest safe landing rather than an efficient spell.
    local bestSingle, bestSingleTarget, catchupReason = nil, nil, nil
    if best then
        for _, t in ipairs(hurtTargets) do
            local single, singleScore = bestSingleDirectScore(t, situation)
            if single and (not bestSingle or singleScore > bestSingle.score) then
                bestSingle = single
                bestSingleTarget = t
            end
            if single then
                local needsCatchup, reason = shouldUseFastCatchup(t, single, situation)
                if needsCatchup then
                    catchupReason = string.format('%s:%s', tostring(t.name or '?'), tostring(reason or 'high_dps'))
                end
            end
        end
    end

    local comparisonWinner = best and best.spell or nil
    local comparisonScore = best and best.score or nil
    if best then
        local singleScore = bestSingle and bestSingle.score or -math.huge
        if bestSingle then
            table.insert(allScores, {
                name = 'single:' .. tostring(bestSingle.spell),
                score = singleScore,
                expected = bestSingle.expected,
                mana = bestSingle.mana,
                castTime = bestSingle.castTime,
                category = 'single_comparison',
            })
        end
        best.details = joinDetails(best.details, string.format(
            'compare=group_vs_single groupHpm=%.3f singleHpm=%s single=%s target=%s minLand=%.1f%%',
            tonumber(best.score) or 0,
            bestSingle and string.format('%.3f', singleScore) or 'none',
            tostring(bestSingle and bestSingle.spell or '-'),
            tostring(bestSingleTarget and bestSingleTarget.name or '-'),
            tonumber(best.components and best.components.minLandingPct) or 100))

        if catchupReason then
            best.details = joinDetails(best.details, 'lost=fast_catchup ' .. catchupReason)
            comparisonWinner = 'fast_catchup:' .. catchupReason
            comparisonScore = nil
            best = nil
        elseif bestSingle and singleScore >= (tonumber(best.score) or -math.huge) then
            best.details = joinDetails(best.details, 'lost=single_effective_hpm')
            comparisonWinner = 'single:' .. tostring(bestSingle.spell)
            comparisonScore = singleScore
            best = nil
        end
    end

    stashScores('group', { name = 'group', deficit = 0 },
        allScores, comparisonWinner, comparisonScore)

    local log = getLogger()
    if log and log.logSpellSelection then
        log.logSpellSelection({ name = 'group' }, 'group', M._lastScores.scores,
            comparisonWinner, comparisonScore)
    end

    return best ~= nil, best
end

function M.SelectBestHot(targetInfo, useLight, allowFallback)
    local config = Config
    local tracker = HealTracker
    local list = {}

    local spells = config.spells or {}

    if useLight and spells.hotLight then
        for _, spellName in ipairs(spells.hotLight) do
            table.insert(list, spellName)
        end
    end
    if (not useLight or allowFallback) and spells.hot then
        for _, spellName in ipairs(spells.hot) do
            table.insert(list, spellName)
        end
    end

    local best = nil
    local bestScore = -999
    local allScores = {}

    for _, spellName in ipairs(list) do
        local meta = getSpellMeta(spellName)
        if meta and isSpellUsable(spellName, meta) then
            local ticks = math.max(meta.durationTicks, 1)
            local fallbackTick = math.max(1, math.floor(targetInfo.deficit / ticks))
            local expectedTick = getExpectedWithFallback(tracker, spellName, fallbackTick, true)
            if expectedTick then
                local score, components = scoreHot(meta, expectedTick, targetInfo.deficit, targetInfo.recentDps, targetInfo.maxHP)
                table.insert(allScores, { name = spellName, score = score, expected = expectedTick, mana = meta.mana, castTime = meta.castTimeMs })
                if score > bestScore then
                    bestScore = score
                    best = {
                        spell = spellName,
                        expected = expectedTick,
                        details = formatScoreDetails('hot', 'hot', components),
                    }
                end
            end
        end
    end

    stashScores('hot', targetInfo, allScores, best and best.spell or nil, bestScore)

    local log = getLogger()
    if log and log.logSpellSelection then
        log.logSpellSelection(targetInfo, 'hot', M._lastScores.scores, best and best.spell or nil, bestScore)
    end

    return best
end

function M.SelectBestGroupHot(targets, totalDeficit, hurtCount)
    local config = Config
    local tracker = HealTracker
    local best = nil
    local bestScore = -999
    local allScores = {}

    local spells = config.spells or {}
    local proactive = getProactive()
    for _, spellName in ipairs(spells.groupHot or {}) do
        local affected = M.groupTargetsInRange(spellName, targets)
        local eligibleCount, eligibleDeficit = 0, 0
        local conflict = false
        for _, t in ipairs(affected) do
            local refreshable = not proactive or not proactive.ShouldRefreshHot
                or proactive.ShouldRefreshHot(t.name or t.id, spellName)
            -- A group cast cannot exclude a covered member. Do not clip their
            -- single or group HoT just because enough other members are hurt.
            if not refreshable then conflict = true end
            if (t.deficit or 0) > 0 and refreshable then
                eligibleCount = eligibleCount + 1
                eligibleDeficit = eligibleDeficit + t.deficit
            end
        end
        local meta = getSpellMeta(spellName)
        if not conflict and eligibleCount >= (config.groupHealMinCount or 3)
            and meta and isSpellUsable(spellName, meta) then
            local ticks = math.max(meta.durationTicks, 1)
            local fallbackTick = math.max(1, math.floor(eligibleDeficit / (ticks * eligibleCount)))
            local expectedTick = getExpectedWithFallback(tracker, spellName, fallbackTick, true)
            if expectedTick then
                local totalExpected = expectedTick * ticks * eligibleCount
                local score, components = scoreHot(meta, expectedTick, eligibleDeficit, 0, math.max(eligibleDeficit, 1))
                table.insert(allScores, { name = spellName, score = score, expected = totalExpected, mana = meta.mana, castTime = meta.castTimeMs })
                if score > bestScore then
                    bestScore = score
                    best = {
                        spell = spellName,
                        expected = expectedTick,
                        targets = eligibleCount,
                        affectedTargets = affected,
                        details = formatScoreDetails('groupHot', 'groupHot', components),
                    }
                end
            end
        end
    end

    stashScores('groupHot', { name = 'group', deficit = totalDeficit or 0 },
        allScores, best and best.spell or nil, bestScore)

    local log = getLogger()
    if log and log.logSpellSelection then
        log.logSpellSelection({ name = 'group' }, 'groupHot', M._lastScores.scores, best and best.spell or nil, bestScore)
    end

    return best
end

-- Compatibility wrappers
function M.selectHeal(target, tier)
    return nil, nil, nil
end

function M.findHealTarget()
    if not TargetMonitor then return nil, nil end
    local config = Config or {}
    local injured = TargetMonitor.getInjuredTargets(100 - (config.minHealPct or 10))
    if #injured == 0 then return nil, nil end
    local target = injured[1]
    local tier = (target.pctHP < config.getEmergencyPct()) and 'emergency' or 'normal'
    return target, tier
end

function M.checkGroupHeal()
    local ok, best = M.ShouldUseGroupHeal(TargetMonitor and TargetMonitor.getInjuredTargets and TargetMonitor.getInjuredTargets(100) or {})
    return ok, best and best.spell or nil
end

function M.recordLastAction(spellName, targetName, expected)
    _lastAction = { spell = spellName, target = targetName, expected = expected, time = os.time() }
end

function M.getLastAction()
    return _lastAction
end

--- Snapshot of the most recent FindEfficientHeal scoring pass. Used by the
--- dashboard to surface which alternate spells were considered and why the
--- winner won. Returns nil if no scoring has happened this session.
function M.getLastScores()
    return M._lastScores
end

--- Most recent target-specific scoring pass. Group probes intentionally do not
--- replace this snapshot because they have no meaningful Max HP provenance.
function M.getLastTargetScores()
    return M._lastTargetScores
end

return M
