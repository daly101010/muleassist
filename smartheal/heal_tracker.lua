-- healing/heal_tracker.lua (DeficitHealer logic)
local mq = require('mq')
local Persistence = require('smartheal.persistence')

local M = {
    heals = {},
    recentHeals = {},
    learningMode = true,
}

local Config = nil
local _dirty = false
local _lastSaveCheck = 0

-- Healing Gift AA crit chance lookup by rank
local HEALING_GIFT_CRIT_PCT = {
    [0] = 0,
    [1] = 2, [2] = 4, [3] = 7, [4] = 10, [5] = 13,
    [6] = 16, [7] = 18, [8] = 20, [9] = 22, [10] = 24,
    [11] = 26, [12] = 28,
    [13] = 30, [14] = 32, [15] = 34, [16] = 36, [17] = 38,
    [18] = 40, [19] = 42, [20] = 44, [21] = 46, [22] = 48,
    [23] = 50, [24] = 52, [25] = 54, [26] = 56, [27] = 58,
    [28] = 60, [29] = 62, [30] = 64, [31] = 66, [32] = 68,
    [33] = 70, [34] = 72, [35] = 74, [36] = 76,
}

-- Healing Adept AA (direct heal bonus)
local HEALING_ADEPT_BONUS_PCT = {
    [0] = 0,
    [1] = 2, [2] = 5, [3] = 8, [4] = 11, [5] = 14,
    [6] = 17, [7] = 20, [8] = 23, [9] = 26, [10] = 29,
    [11] = 32, [12] = 35, [13] = 38, [14] = 41, [15] = 44,
    [16] = 47, [17] = 50, [18] = 53, [19] = 56, [20] = 59,
    [21] = 62, [22] = 65, [23] = 68, [24] = 71, [25] = 74,
    [26] = 77, [27] = 80, [28] = 83, [29] = 86, [30] = 89,
    [31] = 92, [32] = 95, [33] = 98, [34] = 101, [35] = 104,
    [36] = 107, [37] = 110, [38] = 113, [39] = 116, [40] = 119,
}

-- Healing Boon AA (HoT bonus)
local HEALING_BOON_BONUS_PCT = {
    [0] = 0,
    [1] = 3, [2] = 6, [3] = 9, [4] = 12, [5] = 15,
    [6] = 18, [7] = 21, [8] = 24, [9] = 27, [10] = 30,
    [11] = 33, [12] = 36, [13] = 39, [14] = 42, [15] = 45,
    [16] = 48, [17] = 51, [18] = 54, [19] = 57, [20] = 60,
}

local aaCache = {
    healingGift = nil,
    healingAdept = nil,
    healingBoon = nil,
    lastCheck = 0,
}

local function refreshAACache()
    local now = os.time()
    if aaCache.lastCheck and (now - aaCache.lastCheck) < 60 then
        return
    end

    local giftAA = mq.TLO.Me.AltAbility('Healing Gift')
    local giftRank = (giftAA and giftAA()) and giftAA.Rank() or 0
    local giftPct = HEALING_GIFT_CRIT_PCT[giftRank]
    if not giftPct then
        giftPct = 76 + ((giftRank - 36) * 2)
        giftPct = math.min(giftPct, 100)
    end
    aaCache.healingGift = giftPct / 100

    local adeptAA = mq.TLO.Me.AltAbility('Healing Adept')
    local adeptRank = (adeptAA and adeptAA()) and adeptAA.Rank() or 0
    local adeptPct = HEALING_ADEPT_BONUS_PCT[adeptRank]
    if not adeptPct then
        adeptPct = 119 + ((adeptRank - 40) * 3)
    end
    aaCache.healingAdept = 1 + (adeptPct / 100)

    local boonAA = mq.TLO.Me.AltAbility('Healing Boon')
    local boonRank = (boonAA and boonAA()) and boonAA.Rank() or 0
    local boonPct = HEALING_BOON_BONUS_PCT[boonRank]
    if not boonPct then
        boonPct = 60 + ((boonRank - 20) * 3)
    end
    aaCache.healingBoon = 1 + (boonPct / 100)

    aaCache.lastCheck = now
end

local function updateLearningMode()
    local reliableCount = 0
    for _, data in pairs(M.heals) do
        if data.count and data.count >= 10 then
            reliableCount = reliableCount + 1
        end
    end
    M.learningMode = reliableCount < 3
end

function M.init(config)
    Config = config
    local loaded = Persistence.loadHealData()
    M.heals = (loaded and loaded.spells) or {}
    updateLearningMode()
    _lastSaveCheck = mq.gettime()
end

function M.shutdown()
    if _dirty then
        Persistence.data.spells = M.heals
        Persistence.saveHealData()
        _dirty = false
    end
end

function M.GetHealingGiftCritRate()
    refreshAACache()
    return aaCache.healingGift or 0
end

function M.GetHealingAdeptMultiplier()
    refreshAACache()
    return aaCache.healingAdept or 1
end

function M.GetHealingBoonMultiplier()
    refreshAACache()
    return aaCache.healingBoon or 1
end

function M.getHealingGiftCritRate()
    return M.GetHealingGiftCritRate()
end

function M.getHealingAdeptMultiplier()
    return M.GetHealingAdeptMultiplier()
end

function M.getHealingBoonMultiplier()
    return M.GetHealingBoonMultiplier()
end

function M.GetAAModifiers()
    refreshAACache()
    return {
        critRate = aaCache.healingGift or 0,
        critPct = (aaCache.healingGift or 0) * 100,
        directHealMult = aaCache.healingAdept or 1,
        directHealBonusPct = ((aaCache.healingAdept or 1) - 1) * 100,
        hotMult = aaCache.healingBoon or 1,
        hotBonusPct = ((aaCache.healingBoon or 1) - 1) * 100,
    }
end

function M.CalculateExpectedFromBase(spellBaseHeal, isHot)
    refreshAACache()
    local critRate = aaCache.healingGift or 0
    local adeptMult = aaCache.healingAdept or 1
    local boonMult = aaCache.healingBoon or 1
    local bonusMult = isHot and boonMult or adeptMult
    local boostedBase = (spellBaseHeal or 0) * bonusMult
    return boostedBase * (1 + critRate)
end

function M.RecordHeal(spellName, amount, isCrit, isHot)
    if not spellName or type(spellName) ~= 'string' or spellName == '' then
        return false
    end
    amount = tonumber(amount) or 0
    if amount <= 0 then return false end

    isCrit = isCrit or false
    isHot = isHot == true

    if not M.heals[spellName] then
        M.heals[spellName] = {
            avg = amount,
            count = 1,
            trend = 0,
            min = amount,
            max = amount,
            baseAvg = isCrit and 0 or amount,
            baseCount = isCrit and 0 or 1,
            critAvg = isCrit and amount or 0,
            critCount = isCrit and 1 or 0,
            isHoT = isHot or false,
            tickAvg = isHot and amount or nil,
        }
    else
        local data = M.heals[spellName]
        local weight = (Config and Config.learningWeight) or 0.1
        local oldAvg = data.avg or amount

        data.avg = (oldAvg * (1 - weight)) + (amount * weight)
        data.count = (data.count or 0) + 1
        data.min = math.min(data.min or amount, amount)
        data.max = math.max(data.max or amount, amount)
        data.trend = data.avg - oldAvg

        if isHot then
            data.isHoT = true
            local tickAvg = data.tickAvg or data.baseAvg or amount
            data.tickAvg = (tickAvg * (1 - weight)) + (amount * weight)
        end

        if isCrit then
            data.critCount = (data.critCount or 0) + 1
            if (data.critCount or 0) == 1 then
                data.critAvg = amount
            else
                data.critAvg = ((data.critAvg or 0) * (1 - weight)) + (amount * weight)
            end
        else
            data.baseCount = (data.baseCount or 0) + 1
            if (data.baseCount or 0) == 1 then
                data.baseAvg = amount
            else
                data.baseAvg = ((data.baseAvg or 0) * (1 - weight)) + (amount * weight)
            end
        end
    end

    table.insert(M.recentHeals, {
        spell = spellName,
        amount = amount,
        isCrit = isCrit,
        time = os.time(),
    })
    -- Bulk-trim rather than repeatedly `table.remove(,1)` (which is O(n) per
    -- call because it shifts the whole array). We let the list grow a bit past
    -- 100 and then drop the oldest 50 in one `table.move` operation.
    if #M.recentHeals > 150 then
        local n = #M.recentHeals
        table.move(M.recentHeals, n - 99, n, 1, M.recentHeals)
        for i = 101, n do M.recentHeals[i] = nil end
    end

    if M.learningMode then
        updateLearningMode()
    end

    _dirty = true
    return true
end

function M.GetExpectedHeal(spellName)
    local data = M.heals[spellName]
    if not data or (data.count or 0) < 3 then
        return nil
    end

    local critRate = M.GetHealingGiftCritRate()
    local baseAvg = data.baseAvg
    if not baseAvg or baseAvg <= 0 then
        if data.critAvg and data.critAvg > 0 and (data.baseCount or 0) == 0 then
            baseAvg = data.critAvg / 2
        else
            baseAvg = data.avg
        end
    end

    if data.isHoT and data.tickAvg and data.tickAvg > 0 then
        return data.tickAvg
    end

    local critAvg = baseAvg * 2
    if data.critAvg and data.critAvg > 0 then
        critAvg = data.critAvg
    end

    return (baseAvg * (1 - critRate)) + (critAvg * critRate)
end

function M.GetCritRate(spellName)
    local data = M.heals[spellName]
    if not data then return 0 end
    local baseCount = data.baseCount or 0
    local critCount = data.critCount or 0
    local totalCount = baseCount + critCount
    if totalCount < 3 then return 0 end
    return critCount / totalCount
end

function M.GetDetailedStats(spellName)
    local data = M.heals[spellName]
    if not data then return nil end
    local baseCount = data.baseCount or 0
    local critCount = data.critCount or 0
    local totalCount = baseCount + critCount
    local empiricalCritRate = totalCount > 0 and (critCount / totalCount) or 0
    local aaCritRate = M.GetHealingGiftCritRate()
    return {
        baseAvg = data.baseAvg or data.avg,
        critAvg = data.critAvg or 0,
        critRate = aaCritRate,
        critPct = aaCritRate * 100,
        empiricalCritRate = empiricalCritRate,
        empiricalCritPct = empiricalCritRate * 100,
        totalCount = totalCount,
        baseCount = baseCount,
        critCount = critCount,
        expected = M.GetExpectedHeal(spellName),
        min = data.min,
        max = data.max,
    }
end

function M.GetHealData(spellName)
    return M.heals[spellName]
end

function M.GetAllData()
    return M.heals
end

function M.IsLearning()
    return M.learningMode
end

function M.GetData()
    return M.heals
end

function M.Reset()
    M.heals = {}
    M.recentHeals = {}
    M.learningMode = true
    _dirty = true
end

function M.ResetSpell(spellName)
    if M.heals[spellName] then
        M.heals[spellName] = nil
        updateLearningMode()
        _dirty = true
    end
end

-- SideKick compatibility helpers
function M.getExpected(spellName, mode)
    local expected = M.GetExpectedHeal(spellName) or 0
    if mode == 'tick' then
        local data = M.heals[spellName]
        if data and data.isHoT and data.tickAvg then
            return data.tickAvg
        end
    end
    return expected
end

function M.isReliable(spellName)
    local data = M.heals[spellName]
    return data and (data.count or 0) >= ((Config and Config.minSamplesForReliable) or 10) or false
end

function M.recordHeal(spellName, amount, isCrit, isHoT)
    return M.RecordHeal(spellName, amount, isCrit, isHoT)
end

-- Save no more often than every 60s when dirty. mq.gettime() is milliseconds,
-- so the threshold must also be in ms — a bare `60` previously fired a disk
-- write every 60 milliseconds when state was dirty.
local SAVE_INTERVAL_MS = 60 * 1000

function M.tick()
    local now = mq.gettime()
    if _dirty and (now - _lastSaveCheck) > SAVE_INTERVAL_MS then
        _lastSaveCheck = now
        Persistence.data.spells = M.heals
        Persistence.saveHealData()
        _dirty = false
    end
end

return M
