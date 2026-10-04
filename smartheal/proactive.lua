-- healing/proactive.lua
local mq = require('mq')
local lazy = require('smartheal.util.lazy_require')

local M = {}

---@class HealingConfig
---@field groupHealMinCount number|nil
---@field hotEnabled boolean|nil
---@field emergencyPct number|nil
---@field duckHotThreshold number|nil
---@field hotMinFightDurationPct number|nil
---@field hotMinCoverageRatio number|nil
---@field hotUselessRatio number|nil
---@field hotRefreshWindowPct number|nil
---@field promisedSafetyFloorPct number|nil
---@field promisedSurvivalSafetyFloorPct number|nil

---@type HealingConfig
local Config = nil
local HealTracker = nil
local TargetMonitor = nil
local CombatAssessor = nil

-- Lazy-load ActorsCoordinator for peer HoT tracking
local getActorsCoordinator = lazy('smartheal.util.actors_coordinator')
local getSpellEvents = lazy.once('smartheal.spell_events')

-- Track active HoTs we've applied
local _activeHoTs = {}  -- [targetName] = { spell, castTime, duration, expireTime }
local _activePromised = {}  -- [targetName] = { spell, castTime, delay, landingTime, expireTime, expectedHeal }

-- Short-TTL cache of name → spawn ID. The hot HoT query paths used to do
-- `mq.TLO.Spawn('pc <name>')` on every call; in a 6-player group this fired
-- 6+ spawn searches per heal-context build. Cache for 2s with explicit
-- invalidation helpers exposed to consumers that know better (e.g. on group
-- member change or zone-in).
local _pcIdCache = {}  -- [lowerName] = { id, at }
local _PC_ID_TTL_MS = 2000

local function resolvePcSpawnId(targetName)
    if not targetName or targetName == '' then return 0 end
    local key = targetName:lower()
    local now = mq.gettime()
    local entry = _pcIdCache[key]
    if entry and (now - entry.at) < _PC_ID_TTL_MS then
        return entry.id
    end
    local spawn = mq.TLO.Spawn('pc ' .. targetName)
    local id = spawn and spawn() and spawn.ID and tonumber(spawn.ID()) or 0
    _pcIdCache[key] = { id = id, at = now }
    return id
end

function M.invalidatePcIdCache()
    _pcIdCache = {}
end

local function resolveTargetName(targetIdOrName)
    if not targetIdOrName then return nil end
    if type(targetIdOrName) == 'string' then
        return targetIdOrName
    end
    local id = tonumber(targetIdOrName) or 0
    if id <= 0 then return nil end
    local spawn = mq.TLO.Spawn(id)
    if spawn and spawn() then
        return spawn.CleanName() or spawn.Name()
    end
    return nil
end

function M.init(config, healTracker, targetMonitor, combatAssessor)
    Config = config
    HealTracker = healTracker
    TargetMonitor = targetMonitor
    CombatAssessor = combatAssessor
end

function M.recordHoT(targetIdOrName, spellName, duration)
    local targetName = resolveTargetName(targetIdOrName)
    if not targetName then return end
    local now = mq.gettime()  -- milliseconds
    local durSec = duration or 18
    local durMs = durSec * 1000
    _activeHoTs[targetName] = {
        spell = spellName,
        castTime = now,
        duration = durSec,           -- kept in seconds for external consumers
        durationMs = durMs,          -- canonical ms form used internally
        expireTime = now + durMs,    -- ms, matches mq.gettime()
    }
end

-- Observed ticks and confirmed casts share one authoritative non-stacking slot.
-- Mirror its remaining duration onto the MQ clock for legacy cache consumers.
local function trackedHot(targetName)
    local events = getSpellEvents()
    local info, remaining
    if events and events.getActiveHot then info, remaining = events.getActiveHot(targetName) end
    if info then
        local now = mq.gettime()
        local durationMs = info.durationMs or 0
        _activeHoTs[targetName] = { spell = info.spell, duration = durationMs / 1000,
            durationMs = durationMs, expireTime = now + remaining,
            castTime = now + remaining - durationMs }
    end
    return _activeHoTs[targetName]
end

function M.GetHotData(targetName)
    return trackedHot(targetName)
end

-- Check if target has a named HoT active, via authoritative game-client state.
--
-- Only self can be checked this way: mq.TLO.Me.Song/Buff are the caster's own
-- windows, so they reflect *our* buff state but never another player's.
-- Group.Member.Buff only exposes buffs the server broadcasts to the group
-- window (songs/target-only debuffs aren't in that list), so it was
-- misleading for HoT checks — it would return false even when the HoT was
-- active. For non-self targets we return false here and let callers fall
-- through to _activeHoTs (HoTs we recorded casting) + actor peer data.
--
-- Returns: hasBuff (bool), remainingSeconds (number)
local function targetHasHoTBuff(targetId, hotSpellName)
    if not targetId or not hotSpellName then return false end

    local spawn = mq.TLO.Spawn(targetId)
    if not spawn or not spawn() then return false end

    local targetName = spawn.CleanName() or spawn.Name()
    if not targetName then return false end

    local myName = mq.TLO.Me.CleanName() or mq.TLO.Me.Name()
    if targetName ~= myName then
        -- Non-self: no reliable client-side source. Caller's fallback handles it.
        return false
    end

    -- Self path: HoTs typically land in the Song window; some may land in Buff.
    local song = mq.TLO.Me.Song(hotSpellName)
    if song and song() and song.ID() then
        ---@diagnostic disable-next-line: undefined-field
        return true, song.Duration and song.Duration.TotalSeconds and tonumber(song.Duration.TotalSeconds()) or 0
    end
    local buff = mq.TLO.Me.Buff(hotSpellName)
    if buff and buff() and buff.ID() then
        ---@diagnostic disable-next-line: undefined-field
        return true, buff.Duration and buff.Duration.TotalSeconds and tonumber(buff.Duration.TotalSeconds()) or 0
    end
    return false
end

-- Checking only the proposed spell misses a conflicting single/group HoT.
local function targetHasAnyHoTBuff(targetId, candidate)
    if targetId ~= tonumber(mq.TLO.Me.ID()) then return false, 0 end
    local names, seen = {}, {}
    local function add(name)
        if name and name ~= '' and not seen[name] then
            seen[name] = true
            names[#names + 1] = name
        end
    end
    add(candidate)
    for _, category in ipairs({ 'hot', 'hotLight', 'groupHot' }) do
        for _, name in ipairs((Config and Config.spells and Config.spells[category]) or {}) do add(name) end
    end
    local best, activeSpell = 0, nil
    for _, name in ipairs(names) do
        local present, remaining = targetHasHoTBuff(targetId, name)
        if present and remaining > best then best, activeSpell = remaining, name end
    end
    return activeSpell ~= nil, best, activeSpell
end

function M.hasActiveHoT(targetIdOrName)
    local targetName = resolveTargetName(targetIdOrName)
    if not targetName then return false end

    local hasBuff, seconds, buffSpell = targetHasAnyHoTBuff(resolvePcSpawnId(targetName))
    if hasBuff then return true, buffSpell, seconds * 1000 end
    local now = mq.gettime()
    local data = trackedHot(targetName)
    if data and data.expireTime and data.expireTime > now then
        local hasBuff = true
        local remaining = data.expireTime - now
        return hasBuff, data.spell, remaining
    end

    -- Check peer-reported HoTs via actors (if available).
    -- Peer HoT timestamps are wall-clock epoch seconds (os.time()), NOT
    -- mq.gettime() ms — the two clocks can't be compared directly. Use
    -- os.time() locally and convert the result back to ms so the return
    -- type (remaining in ms) matches the self-path above.
    local ac = getActorsCoordinator()
    if ac and ac.getHoTStates then
        local tid = resolvePcSpawnId(targetName)
        local perTarget = tid > 0 and ac.getHoTStates()[tid] or nil
        if perTarget then
            local nowSec = os.time()
            local bestSec, bestSpell = 0, nil
            -- Nested shape: perTarget[from][spellName] = { expiresAt, ... }
            for _, perSpell in pairs(perTarget) do
                for _, info in pairs(perSpell) do
                    local exp = tonumber(info.expiresAt) or 0
                    local remSec = exp - nowSec
                    if remSec > bestSec then
                        bestSec = remSec
                        bestSpell = info.spellName or bestSpell
                    end
                end
            end
            if bestSec > 0 then
                return true, bestSpell or 'unknown', bestSec * 1000
            end
        end
    end

    return false
end

function M.HasActiveHot(targetIdOrName)
    return M.hasActiveHoT(targetIdOrName)
end

-- Hard floor for HoT refresh: never overwrite an existing HoT that has
-- more than this many milliseconds left. HoT ticks fire every 6 seconds,
-- so a 2s floor guarantees we don't clobber a HoT that still has at least
-- one more tick coming. Applies in addition to hotRefreshWindowPct.
local HOT_REFRESH_MIN_REMAINING_MS = 2000

-- shouldRefreshHoT(target, hotSpellName)
--   hotSpellName may be nil. Self checks cover every configured single/group
--   HoT; other targets use the shared cast/tick slot and cached/peer duration.
--   Any conflicting HoT must reach the refresh window before replacement.
function M.shouldRefreshHoT(targetIdOrName, hotSpellName)
    local targetName = resolveTargetName(targetIdOrName)
    if not targetName then return false end
    local targetId = resolvePcSpawnId(targetName)

    local hasBuff, buffRemaining = targetHasAnyHoTBuff(targetId, hotSpellName)
    if not hasBuff then
        -- Fallback: use cached/peer-reported remaining time if buff lookup failed
        local now = mq.gettime()
        local bestRemaining = 0  -- milliseconds

        local data = trackedHot(targetName)
        if data and data.expireTime and data.expireTime > now then
            bestRemaining = math.max(bestRemaining, data.expireTime - now)
        end

        local ac = getActorsCoordinator()
        if ac and ac.getHoTStates and targetId > 0 then
            local perTarget = ac.getHoTStates()[targetId]
            if perTarget then
                -- Peer HoT expiresAt is epoch seconds; convert remaining to ms
                -- before comparing with self-tracked (mq.gettime-based) values.
                local nowSec = os.time()
                for _, perSpell in pairs(perTarget) do
                    for _, info in pairs(perSpell) do
                        local exp = tonumber(info.expiresAt) or 0
                        local remMs = (exp - nowSec) * 1000
                        if remMs > bestRemaining then bestRemaining = remMs end
                    end
                end
            end
        end

        if bestRemaining > 0 then
            -- Absolute floor: don't clobber a HoT with a remaining tick.
            if bestRemaining > HOT_REFRESH_MIN_REMAINING_MS then
                return false
            end
            local refreshPct = Config and Config.hotRefreshWindowPct or 0
            if refreshPct <= 0 then
                -- Inside the 2s floor window and no pct policy → refresh.
                return true
            end
            local spell = mq.TLO.Spell(hotSpellName)
            local durationSec = 0
            if spell and spell() and spell.Duration and spell.Duration.TotalSeconds then
                durationSec = tonumber(spell.Duration.TotalSeconds()) or 0
            end
            if durationSec > 0 then
                local remainingPct = (bestRemaining / (durationSec * 1000)) * 100
                return remainingPct <= refreshPct
            end
            return true
        end

        -- No known HoT remaining, safe to cast
        return true
    end

    -- Buff is on target — `buffRemaining` is in SECONDS (from Duration.TotalSeconds).
    local remaining = buffRemaining or 0
    if remaining <= 0 then return true end

    -- Absolute floor: HoT still has a live tick — don't overwrite.
    if (remaining * 1000) > HOT_REFRESH_MIN_REMAINING_MS then
        return false
    end

    -- Inside the 2s floor window — optional pct gate, else refresh.
    local refreshPct = Config and Config.hotRefreshWindowPct or 0
    if refreshPct <= 0 then return true end

    -- Get spell duration to calculate percentage remaining
    local spell = mq.TLO.Spell(hotSpellName)
    if not spell or not spell() then return true end

    local duration = 0
    if spell.Duration and spell.Duration.TotalSeconds then
        duration = tonumber(spell.Duration.TotalSeconds()) or 0
    end

    if duration <= 0 then return true end

    local remainingPct = (remaining / duration) * 100
    return remainingPct <= refreshPct
end

function M.ShouldRefreshHot(targetIdOrName, hotSpellName)
    return M.shouldRefreshHoT(targetIdOrName, hotSpellName)
end

function M.getHotRemainingPct(targetIdOrName)
    local targetName = resolveTargetName(targetIdOrName)
    if not targetName then return 0 end
    local data = trackedHot(targetName)
    if not data or not data.duration or data.duration <= 0 then
        return 0
    end
    -- All math in ms (matches mq.gettime() and data.castTime / data.durationMs).
    local now = mq.gettime()
    local durationMs = data.durationMs or (data.duration * 1000)
    local elapsedMs = now - (data.castTime or now)
    local remainingMs = math.max(0, durationMs - elapsedMs)
    return (remainingMs / durationMs) * 100
end

function M.GetHotRemainingPct(targetIdOrName)
    return M.getHotRemainingPct(targetIdOrName)
end

function M.recordPromised(targetIdOrName, spellName, duration, expectedHeal, delaySeconds)
    local targetName = resolveTargetName(targetIdOrName)
    if not targetName then return end
    local now = os.time()
    local delay = delaySeconds or 18
    _activePromised[targetName] = {
        spell = spellName,
        castTime = now,
        delay = delay,
        landingTime = now + delay,
        expireTime = now + (duration or 18),
        expectedHeal = expectedHeal or 0,
    }
end

function M.hasActivePromised(targetIdOrName)
    local targetName = resolveTargetName(targetIdOrName)
    if not targetName then return false end
    local data = _activePromised[targetName]
    return data and data.expireTime and data.expireTime > os.time() or false
end

function M.getPromisedLandingInfo(targetIdOrName)
    local targetName = resolveTargetName(targetIdOrName)
    if not targetName then return nil end
    local data = _activePromised[targetName]
    if not data then return nil end

    local now = os.time()
    if now >= (data.landingTime or 0) then
        return nil
    end

    local timeRemaining = (data.landingTime or 0) - now
    return {
        timeRemaining = timeRemaining,
        expectedHeal = data.expectedHeal or 0,
        spell = data.spell,
        landingTime = data.landingTime,
    }
end

function M.GetPromisedLandingInfo(targetIdOrName)
    return M.getPromisedLandingInfo(targetIdOrName)
end

function M.getHotHealingInWindow(targetIdOrName, windowSec)
    local targetName = resolveTargetName(targetIdOrName)
    if not targetName then return 0 end
    local data = trackedHot(targetName)
    if not data then return 0 end

    local tracker = HealTracker
    if not tracker then return 0 end

    local hpPerTick = tracker.getExpected(data.spell, 'tick') or 0
    if hpPerTick <= 0 then return 0 end

    -- Keep all arithmetic in milliseconds: castTime/expireTime come from
    -- mq.gettime() and the older code here mixed os.time() (seconds) with
    -- ms values, making this function always return 0.
    local now = mq.gettime()
    local elapsedMs = now - (data.castTime or now)
    local durationMs = data.durationMs or ((data.duration or 0) * 1000)
    local remainingMs = math.max(0, durationMs - elapsedMs)
    local tickIntervalMs = 6000
    local windowMs = (windowSec or 0) * 1000
    local windowRemainingMs = math.min(windowMs, remainingMs)
    local ticksInWindow = math.floor(windowRemainingMs / tickIntervalMs)
    return ticksInWindow * hpPerTick
end

function M.GetHotHealingInWindow(targetIdOrName, windowSec)
    return M.getHotHealingInWindow(targetIdOrName, windowSec)
end

function M.getIncomingHotRemaining(targetIdOrName)
    local targetName = resolveTargetName(targetIdOrName)
    if not targetName then return 0 end

    local data = trackedHot(targetName)
    local total = 0
    local now = mq.gettime()

    -- Single and group HoTs do not stack. A tracked effect takes precedence
    -- over stale cache/peer entries, even when its remaining healing is zero.
    local events = getSpellEvents()
    if events and events.getIncomingHotRemaining then
        local amount, _, ledger = events.getIncomingHotRemaining(targetName)
        if ledger and next(ledger) then return amount or 0 end
    end

    -- All time math in milliseconds; `now` = mq.gettime(). `expiresAt` and
    -- `castTime` come from mq.gettime() too. `durationMs` is the canonical
    -- internal duration; fall back to `duration * 1000` for older entries.
    local function addRemaining(spellName, expiresAt, castTime, durationMs)
        if not spellName then return end
        local remainingMs = 0
        if expiresAt and expiresAt > now then
            remainingMs = expiresAt - now
        elseif castTime and durationMs then
            local elapsedMs = now - castTime
            remainingMs = math.max(0, durationMs - elapsedMs)
        end
        if remainingMs <= 0 then return end

        local tick = HealTracker and HealTracker.getExpected(spellName, 'tick') or 0
        if tick <= 0 then
            local spell = mq.TLO.Spell(spellName)
            if spell and spell() then
                ---@diagnostic disable-next-line: undefined-field
                local calcVal = tonumber(spell.Calc and spell.Calc(1) and spell.Calc(1)()) or 0
                if calcVal > 0 then
                    tick = math.abs(calcVal)
                end
            end
        end
        if tick <= 0 then return end

        local ticksRemaining = math.floor(remainingMs / 6000)
        if ticksRemaining <= 0 then return end
        -- Unknown peer ordering must never add incompatible effects together.
        -- Use the smaller estimate when the active source cannot be determined.
        local amount = tick * ticksRemaining
        total = total > 0 and math.min(total, amount) or amount
    end

    if data then
        local dms = data.durationMs or ((data.duration or 0) * 1000)
        addRemaining(data.spell, data.expireTime, data.castTime, dms)
    end

    local ac = getActorsCoordinator()
    if ac and ac.getHoTStates then
        local tid = resolvePcSpawnId(targetName)
        local perTarget = tid > 0 and ac.getHoTStates()[tid] or nil
        if perTarget then
            -- Peer HoT expiresAt is epoch seconds. addRemaining() computes in
            -- mq.gettime() ms, so project peer's expiresAt onto the local
            -- ms-clock by taking (exp - os.time()) * 1000 and adding `now`.
            local nowSec = os.time()
            for _, perSpell in pairs(perTarget) do
                for _, info in pairs(perSpell) do
                    local expSec = tonumber(info.expiresAt) or 0
                    local remMs = (expSec - nowSec) * 1000
                    if remMs > 0 then
                        addRemaining(info.spellName, now + remMs)
                    end
                end
            end
        end
    end

    return total
end

function M.GetIncomingHotRemaining(targetIdOrName)
    return M.getIncomingHotRemaining(targetIdOrName)
end

-- Calculate projected HP considering HoT + Promised + incoming DPS
function M.CalculateProjectedHP(targetInfo, promisedInfo)
    if not promisedInfo or not promisedInfo.timeRemaining then
        return nil
    end

    local windowSec = promisedInfo.timeRemaining
    local currentHP = targetInfo.currentHP or 0
    local maxHP = targetInfo.maxHP or 1
    local dps = targetInfo.recentDps or 0

    local expectedDamage = dps * windowSec
    local hotHealing = M.GetHotHealingInWindow(targetInfo.name, windowSec)
    local promisedHealing = promisedInfo.expectedHeal or 0

    local projectedHP = currentHP - expectedDamage + hotHealing + promisedHealing
    projectedHP = math.min(projectedHP, maxHP)
    projectedHP = math.max(projectedHP, 0)

    local projectedPct = (projectedHP / maxHP) * 100

    local details = string.format(
        'projHP=%.0f projPct=%.1f curHP=%.0f dmg=%.0f hotHeal=%.0f promHeal=%.0f window=%ds',
        projectedHP, projectedPct, currentHP, expectedDamage, hotHealing, promisedHealing, windowSec
    )

    return {
        projectedHP = projectedHP,
        projectedPct = projectedPct,
        expectedDamage = expectedDamage,
        hotHealing = hotHealing,
        promisedHealing = promisedHealing,
        windowSec = windowSec,
        details = details,
    }
end

-- Check if it's safe to wait for Promised
function M.IsSafeToWaitForPromised(targetInfo)
    if not targetInfo then return false, nil end

    local promisedInfo = M.GetPromisedLandingInfo(targetInfo.name)
    if not promisedInfo then
        return false, nil
    end

    local projection = M.CalculateProjectedHP(targetInfo, promisedInfo)
    if not projection then
        return false, nil
    end

    local safetyFloorPct = (CombatAssessor and CombatAssessor.GetPromisedSafetyFloor and CombatAssessor.GetPromisedSafetyFloor())
        or (Config and Config.promisedSafetyFloorPct or 35)

    local minHPDuringWait = (targetInfo.currentHP or 0) - projection.expectedDamage + projection.hotHealing
    local minPctDuringWait = ((targetInfo.maxHP or 1) > 0) and (minHPDuringWait / targetInfo.maxHP * 100) or 0

    local isSafe = minPctDuringWait >= safetyFloorPct

    projection.minHPDuringWait = minHPDuringWait
    projection.minPctDuringWait = minPctDuringWait
    projection.safetyFloorPct = safetyFloorPct
    projection.isSafe = isSafe
    projection.details = projection.details .. string.format(
        ' minPct=%.1f safetyFloor=%d%% safe=%s timeToLand=%ds',
        minPctDuringWait, safetyFloorPct, tostring(isSafe), promisedInfo.timeRemaining or 0
    )

    return isSafe, projection
end

-- Group HoT selection (DeficitHealer behavior)
function M.ShouldApplyGroupHot(targets, situation)
    if Config and Config.hotEnabled == false then
        return false, nil, nil, nil
    end

    if situation and situation.hasEmergency then
        return false, nil, nil, nil
    end

    local hurtCount = 0
    local totalDeficit = 0
    for _, t in ipairs(targets or {}) do
        if t.deficit and t.deficit > 0 then
            hurtCount = hurtCount + 1
            totalDeficit = totalDeficit + t.deficit
        end
    end

    local cfg = Config or {}
    if hurtCount < (cfg.groupHealMinCount or 2) then
        return false, nil, nil, nil
    end

    local selector = nil
    local ok, hs = pcall(require, 'smartheal.heal_selector')
    if ok then selector = hs end

    if selector and selector.SelectBestGroupHot then
        local best = selector.SelectBestGroupHot(targets, totalDeficit, hurtCount)
        if best then
            return true, best, totalDeficit, best.targets or hurtCount
        end
    end

    return false, nil, nil, nil
end

function M.calculateProjectedHP(targetInfo, promisedInfo)
    if not promisedInfo or not promisedInfo.timeRemaining then
        return nil
    end

    local windowSec = promisedInfo.timeRemaining
    local currentHP = targetInfo.currentHP or 0
    local maxHP = targetInfo.maxHP or 1
    local dps = targetInfo.recentDps or 0

    local expectedDamage = dps * windowSec
    local hotHealing = M.getHotHealingInWindow(targetInfo.name, windowSec)
    local promisedHealing = promisedInfo.expectedHeal or 0

    local projectedHP = currentHP - expectedDamage + hotHealing + promisedHealing
    projectedHP = math.min(projectedHP, maxHP)
    projectedHP = math.max(projectedHP, 0)

    local projectedPct = (projectedHP / maxHP) * 100
    local details = string.format(
        'projHP=%.0f projPct=%.1f curHP=%.0f dmg=%.0f hotHeal=%.0f promHeal=%.0f window=%ds',
        projectedHP, projectedPct, currentHP, expectedDamage, hotHealing, promisedHealing, windowSec
    )

    return {
        projectedHP = projectedHP,
        projectedPct = projectedPct,
        expectedDamage = expectedDamage,
        hotHealing = hotHealing,
        promisedHealing = promisedHealing,
        windowSec = windowSec,
        details = details,
    }
end

function M.isSafeToWaitForPromised(targetInfo)
    if not Config then return false, nil end

    local promisedInfo = M.getPromisedLandingInfo(targetInfo.name)
    if not promisedInfo then return false, nil end

    local projection = M.calculateProjectedHP(targetInfo, promisedInfo)
    if not projection then return false, nil end

    local safetyFloorPct = (Config and Config.promisedSafetyFloorPct) or 35
    local combatState = CombatAssessor and CombatAssessor.getState and CombatAssessor.getState() or {}
    if combatState and combatState.survivalMode then
        safetyFloorPct = (Config and Config.promisedSurvivalSafetyFloorPct) or safetyFloorPct
    end
    local minHPDuringWait = (targetInfo.currentHP or 0) - projection.expectedDamage + projection.hotHealing
    local minPctDuringWait = ((targetInfo.maxHP or 1) > 0) and (minHPDuringWait / targetInfo.maxHP * 100) or 0

    local isSafe = minPctDuringWait >= safetyFloorPct

    projection.minHPDuringWait = minHPDuringWait
    projection.minPctDuringWait = minPctDuringWait
    projection.safetyFloorPct = safetyFloorPct
    projection.isSafe = isSafe
    projection.details = projection.details .. string.format(
        ' minPct=%.1f safetyFloor=%d%% safe=%s timeToLand=%ds',
        minPctDuringWait, safetyFloorPct, tostring(isSafe), promisedInfo.timeRemaining or 0
    )

    return isSafe, projection
end

function M.shouldApplyHoT(target, hotSpellName)
    if not Config or not Config.hotEnabled then
        return false, 'disabled'
    end

    -- No HoTs during emergency (cheap check first)
    if target.pctHP < Config.getEmergencyPct() then
        return false, 'emergency'
    end

    -- Don't cast HoT if target is above duck threshold (would just be ducked anyway)
    -- Use the HoT-specific duck threshold (defaults to 92%)
    local duckThreshold = Config.duckHotThreshold
    if duckThreshold == nil then duckThreshold = 92 end
    if target.pctHP >= duckThreshold then
        return false, string.format('above_duck_threshold|hp=%d>=thresh=%d', target.pctHP, duckThreshold)
    end

    -- Use HotAnalyzer for TTK and DPS ratio gates (expensive, run after cheap guards)
    local ok, HotAnalyzer = pcall(require, 'smartheal.hot_analyzer')
    if ok and HotAnalyzer and HotAnalyzer.shouldApplyHoT then
        local shouldApply, analysis, reason = HotAnalyzer.shouldApplyHoT(target, hotSpellName, nil)
        if not shouldApply then
            return false, reason
        end
        -- Analysis passed new gates, continue with existing checks
    end

    local combatState = CombatAssessor and CombatAssessor.getState() or {}

    -- Check fight duration
    local spell = mq.TLO.Spell(hotSpellName)
    local hotDuration = 0
    if spell and spell() and spell.Duration and spell.Duration.TotalSeconds then
        hotDuration = tonumber(spell.Duration.TotalSeconds()) or 0
    end

    local minFightPct = Config.hotMinFightDurationPct or 50
    local fightRemaining = combatState.estimatedTTK or 999
    if fightRemaining < hotDuration * (minFightPct / 100) then
        return false, 'fight_ending'
    end

    -- Check if already has active HoT
    local hasHoT, existingSpell = M.hasActiveHoT(target.id)
    if hasHoT and not M.shouldRefreshHoT(target.id, existingSpell) then
        return false, 'hot_active'
    end

    -- Check HoT coverage ratio vs incoming DPS
    local tickAmount = HealTracker and HealTracker.getExpected(hotSpellName, 'tick') or 0
    local tickInterval = 6  -- Default tick interval

    if tickAmount <= 0 then
        -- Try to get from spell data
        if spell and spell() and spell.Base then
            tickAmount = math.abs(tonumber(spell.Base(1)()) or 0)
        end
    end

    if tickAmount <= 0 then
        return false, 'no_tick_data'
    end

    local hotHps = tickAmount / tickInterval
    local incomingDps = target.recentDps or 0

    if incomingDps <= 0 then
        -- No damage = no HoT. HoTs are for countering sustained damage, not topping off.
        return false, 'no_damage'
    end

    local coverageRatio = hotHps / incomingDps

    -- Multiple sources = more sustained damage pattern, HoT more valuable
    local sourceCount = target.sourceCount or 1
    if sourceCount >= 2 then
        coverageRatio = coverageRatio * 1.2  -- Effective 20% boost to coverage
    end

    local minRatio = Config.hotMinCoverageRatio or 0.3
    local uselessRatio = Config.hotUselessRatio or 0.1

    if coverageRatio >= minRatio then
        return true, 'sustained_damage'
    elseif coverageRatio >= uselessRatio then
        return true, 'supplement'
    end

    return false, 'hot_insufficient'
end

function M.tick()
    -- Prune expired HoTs (use mq.gettime() for wall-clock accuracy)
    local now = mq.gettime()
    for name, data in pairs(_activeHoTs) do
        if data.expireTime and data.expireTime <= now then
            _activeHoTs[name] = nil
        end
    end

    -- Clean promised heals
    local nowSec = os.time()
    for name, data in pairs(_activePromised) do
        if data.expireTime and data.expireTime <= nowSec then
            _activePromised[name] = nil
        end
    end
end

return M
