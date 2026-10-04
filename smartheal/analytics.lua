-- healing/analytics.lua
local mq = require('mq')
local lazy = require('smartheal.util.lazy_require')

local M = {}

-- Lazy-load Logger to avoid circular requires
local getLogger = lazy.once('smartheal.logger')

local _stats = {
    totalCasts = 0,
    completedCasts = 0,
    duckedCasts = 0,
    interruptedCasts = 0,

    totalHealed = 0,
    totalOverheal = 0,
    overHealPct = 0,

    totalManaSpent = 0,
    healPerMana = 0,

    duckSavingsEstimate = 0,

    incomingHealHonored = 0,
    incomingHealExpired = 0,

    -- HoT tick tracking
    hotTicksLanded = 0,
    hotTicksUseless = 0,  -- Ticks that healed 0 (target at full)
    hotTicksMissed = 0,   -- Ticks that never fired (HoT ended early or no event)
    hotTotalHealed = 0,

    bySpell = {},

    sessionStart = 0,
    lastUpdate = 0,
}

function M.init()
    _stats.sessionStart = os.time()
    _stats.lastUpdate = os.time()
end

function M.getStats()
    return _stats
end

function M.recordHealComplete(spellName, targetId, healed, overhealed, manaCost, isCrit)
    if not spellName then return end  -- Guard against nil spellName

    healed = tonumber(healed) or 0
    overhealed = tonumber(overhealed) or 0
    manaCost = tonumber(manaCost) or 0

    local log = getLogger()
    if log then
        log.info('analytics', 'DIRECT_HEAL: %s healed=%d overheal=%d full=%d mana=%d crit=%s | totals: casts=%d healed=%d overheal=%d',
            tostring(spellName), healed, overhealed, healed + overhealed, manaCost, tostring(isCrit),
            _stats.completedCasts + 1, _stats.totalHealed + healed, _stats.totalOverheal + overhealed)
    end

    _stats.totalCasts = _stats.totalCasts + 1
    _stats.completedCasts = _stats.completedCasts + 1
    _stats.totalHealed = _stats.totalHealed + healed
    _stats.totalOverheal = _stats.totalOverheal + overhealed
    _stats.totalManaSpent = _stats.totalManaSpent + manaCost

    -- Update rolling percentages
    if _stats.totalHealed > 0 then
        _stats.overHealPct = (_stats.totalOverheal / _stats.totalHealed) * 100
    end
    if _stats.totalManaSpent > 0 then
        _stats.healPerMana = _stats.totalHealed / _stats.totalManaSpent
    end

    -- Per-spell tracking
    _stats.bySpell[spellName] = _stats.bySpell[spellName] or {
        casts = 0,
        healed = 0,
        overhealed = 0,
        ducked = 0,
        manaSpent = 0,
        minHeal = nil,
        maxHeal = 0,
        critCount = 0,
    }
    local spell = _stats.bySpell[spellName]
    spell.casts = spell.casts + 1
    spell.healed = spell.healed + healed
    spell.overhealed = spell.overhealed + overhealed
    spell.manaSpent = spell.manaSpent + manaCost

    -- Track min/max heal amounts using full potential (healed + overhealed)
    local fullHeal = healed + overhealed
    if fullHeal > 0 then
        if not spell.minHeal or fullHeal < spell.minHeal then
            spell.minHeal = fullHeal
        end
        if fullHeal > (spell.maxHeal or 0) then
            spell.maxHeal = fullHeal
        end
    end

    -- Track crits
    if isCrit then
        spell.critCount = (spell.critCount or 0) + 1
    end

    _stats.lastUpdate = os.time()
end

function M.recordDuck(spellName, manaCost)
    if not spellName then return end  -- Guard against nil spellName

    _stats.totalCasts = _stats.totalCasts + 1
    _stats.duckedCasts = _stats.duckedCasts + 1
    _stats.duckSavingsEstimate = _stats.duckSavingsEstimate + (tonumber(manaCost) or 0)

    _stats.bySpell[spellName] = _stats.bySpell[spellName] or {
        casts = 0,
        healed = 0,
        overhealed = 0,
        ducked = 0,
        manaSpent = 0,
    }
    _stats.bySpell[spellName].ducked = _stats.bySpell[spellName].ducked + 1

    _stats.lastUpdate = os.time()
end

function M.recordInterrupt(spellName, reason)
    _stats.totalCasts = _stats.totalCasts + 1
    _stats.interruptedCasts = _stats.interruptedCasts + 1
    _stats.lastUpdate = os.time()
end

function M.recordIncomingHonored()
    _stats.incomingHealHonored = _stats.incomingHealHonored + 1
end

function M.recordIncomingExpired()
    _stats.incomingHealExpired = _stats.incomingHealExpired + 1
end

function M.recordHotCast(spellName, manaCost)
    if not spellName then return end

    local log = getLogger()
    if log then
        log.info('analytics', 'HOT_CAST: %s mana=%d', tostring(spellName), tonumber(manaCost) or 0)
    end

    _stats.totalCasts = _stats.totalCasts + 1
    _stats.completedCasts = _stats.completedCasts + 1
    _stats.totalManaSpent = _stats.totalManaSpent + (tonumber(manaCost) or 0)

    _stats.bySpell[spellName] = _stats.bySpell[spellName] or {
        casts = 0,
        healed = 0,
        overhealed = 0,
        ducked = 0,
        manaSpent = 0,
        hotTicks = 0,
        hotTicksUseless = 0,
        hotTicksMissed = 0,
        minHeal = nil,
        maxHeal = 0,
        critCount = 0,
    }
    local spell = _stats.bySpell[spellName]
    spell.casts = spell.casts + 1
    spell.manaSpent = spell.manaSpent + (tonumber(manaCost) or 0)

    _stats.lastUpdate = os.time()
end

function M.recordHotTick(spellName, amount, overhealed, isCrit)
    amount = tonumber(amount) or 0
    overhealed = tonumber(overhealed) or 0

    local log = getLogger()
    local isUseless = amount <= 0
    local spellData = spellName and _stats.bySpell[spellName] or nil
    local prevTicks = spellData and (spellData.hotTicks or 0) or 0

    if log then
        log.info('analytics', 'HOT_TICK: %s amount=%d overheal=%d full=%d crit=%s useless=%s | totals: hotTicks=%d hotUseless=%d hotHealed=%d spell_ticks=%d',
            tostring(spellName), amount, overhealed, amount + overhealed, tostring(isCrit), tostring(isUseless),
            _stats.hotTicksLanded + 1, _stats.hotTicksUseless + (isUseless and 1 or 0), _stats.hotTotalHealed + amount,
            prevTicks + 1)
    end

    _stats.hotTicksLanded = _stats.hotTicksLanded + 1

    if amount <= 0 then
        _stats.hotTicksUseless = _stats.hotTicksUseless + 1
    else
        _stats.hotTotalHealed = _stats.hotTotalHealed + amount
        -- Also add to global totals so HoT healing is included in overall stats
        _stats.totalHealed = _stats.totalHealed + amount
    end

    -- Track HoT overheal in global stats
    if overhealed > 0 then
        _stats.totalOverheal = _stats.totalOverheal + overhealed
        -- Update overheal percentage
        if _stats.totalHealed > 0 then
            _stats.overHealPct = (_stats.totalOverheal / _stats.totalHealed) * 100
        end
    end

    -- Track per-spell HoT ticks
    if spellName then
        _stats.bySpell[spellName] = _stats.bySpell[spellName] or {
            casts = 0,
            healed = 0,
            overhealed = 0,
            ducked = 0,
            manaSpent = 0,
            hotTicks = 0,
            hotTicksUseless = 0,
            hotTicksMissed = 0,
            minHeal = nil,
            maxHeal = 0,
            critCount = 0,
        }
        local spell = _stats.bySpell[spellName]
        spell.hotTicks = (spell.hotTicks or 0) + 1
        if amount <= 0 then
            spell.hotTicksUseless = (spell.hotTicksUseless or 0) + 1
        else
            spell.healed = spell.healed + amount
        end
        -- Track per-spell HoT overheal
        if overhealed > 0 then
            spell.overhealed = (spell.overhealed or 0) + overhealed
        end
        -- Track min/max for HoT ticks using full potential (amount + overhealed)
        local fullHeal = amount + overhealed
        if fullHeal > 0 then
            if not spell.minHeal or fullHeal < spell.minHeal then
                spell.minHeal = fullHeal
            end
            if fullHeal > (spell.maxHeal or 0) then
                spell.maxHeal = fullHeal
            end
        end
        -- Track crits for HoTs
        if isCrit then
            spell.critCount = (spell.critCount or 0) + 1
        end
    end

    _stats.lastUpdate = os.time()
end

function M.recordHotMissed(spellName, missedCount, potentialPerTick)
    if missedCount <= 0 then return end

    local log = getLogger()
    if log then
        log.info('analytics', 'HOT_MISSED: %s count=%d potential=%d each (total wasted=%d)',
            tostring(spellName), missedCount, potentialPerTick or 0, missedCount * (potentialPerTick or 0))
    end

    _stats.hotTicksMissed = _stats.hotTicksMissed + missedCount

    -- Track per-spell missed ticks
    if spellName then
        _stats.bySpell[spellName] = _stats.bySpell[spellName] or {
            casts = 0,
            healed = 0,
            overhealed = 0,
            ducked = 0,
            manaSpent = 0,
            hotTicks = 0,
            hotTicksUseless = 0,
            hotTicksMissed = 0,
            minHeal = nil,
            maxHeal = 0,
            critCount = 0,
        }
        local spell = _stats.bySpell[spellName]
        spell.hotTicksMissed = (spell.hotTicksMissed or 0) + missedCount
    end

    _stats.lastUpdate = os.time()
end

function M.getHotStats()
    local totalExpected = _stats.hotTicksLanded + _stats.hotTicksMissed
    return {
        ticksLanded = _stats.hotTicksLanded,
        ticksUseless = _stats.hotTicksUseless,
        ticksMissed = _stats.hotTicksMissed,
        ticksExpected = totalExpected,
        totalHealed = _stats.hotTotalHealed,
        usefulPct = _stats.hotTicksLanded > 0 and
            ((_stats.hotTicksLanded - _stats.hotTicksUseless) / _stats.hotTicksLanded * 100) or 100,
        efficiencyPct = totalExpected > 0 and
            ((_stats.hotTicksLanded - _stats.hotTicksUseless) / totalExpected * 100) or 100,
    }
end

function M.getSessionDuration()
    return os.time() - _stats.sessionStart
end

function M.getEfficiencyPct()
    if _stats.totalHealed <= 0 then return 100 end
    return 100 - _stats.overHealPct
end

function M.getSummary()
    local duration = M.getSessionDuration()
    local mins = math.floor(duration / 60)

    return string.format(
        'Session: %dm | Casts: %d | Ducked: %d (%.0f%%)\nEfficiency: %.1f%% | Overheal: %.1f%%\nHPM: %.1f | Mana Saved: ~%dk',
        mins,
        _stats.totalCasts,
        _stats.duckedCasts,
        _stats.totalCasts > 0 and (_stats.duckedCasts / _stats.totalCasts * 100) or 0,
        M.getEfficiencyPct(),
        _stats.overHealPct,
        _stats.healPerMana,
        math.floor(_stats.duckSavingsEstimate / 1000)
    )
end

return M
