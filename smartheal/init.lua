-- healing/init.lua (full implementation)
-- Submodules loaded incrementally via initPhased() to avoid blocking MQ frames.
-- Each initPhased(n) call loads a batch of submodules, spreading ~6s of disk I/O
-- across multiple main loop ticks with frame yields between them.
local mq = require('mq')
local lazy = require('smartheal.util.lazy_require')
local HealerClasses = require('smartheal.util.healer_classes')

local debugLog = require('smartheal.util.debug_log').tagged('Heal', 'SideKick_HealDebug.log')

-- Submodule references (nil until their init phase runs)
local Config = nil
local HealTracker = nil
local TargetMonitor = nil
local IncomingHeals = nil
local CombatAssessor = nil
local HealSelector = nil
local Analytics = nil
local SpellEvents = nil
local Logger = nil

-- Lazy-load UI modules
local getMonitor = lazy.once('smartheal.ui.monitor')
local getSettings = lazy.once('smartheal.ui.settings')

-- Lazy-load Proactive module (may not exist yet)
local getProactive = lazy.once('smartheal.proactive')

-- Lazy-load shared lib (Core settings access for combat-mode gating)
local getSkLib = lazy.once('smartheal.util.sk_lib')

-- Lazy-load HotAnalyzer (HoT trust calculations)
local getHotAnalyzer = lazy.once('smartheal.hot_analyzer')

-- Lazy-load MobAssessor (named mob detection and consider-based tier assessment)
local MobAssessor = nil
local function getMobAssessor()
    if MobAssessor == nil then
        local ok, ma = pcall(require, 'smartheal.mob_assessor')
        if ok and ma then
            MobAssessor = ma
            ma.init()
        else
            MobAssessor = false
        end
    end
    return MobAssessor or nil
end

local M = {}

-- Phased init: 5 phases spread across separate main loop ticks
-- Phase 1: Config + Logger (~1100 lines)
-- Phase 2: HealTracker + TargetMonitor + IncomingHeals + CombatAssessor (~1600 lines)
-- Phase 3: Analytics + SpellEvents + HealSelector + callbacks (~2500 lines) → _initialized = true
-- Phase 4: Proactive + HotAnalyzer + DamageParser + DamageAttribution + ActorsCoordinator
-- Phase 5: MobAssessor + UI modules + exposed references → _optionalReady = true
M.TOTAL_INIT_PHASES = 5

local _initialized = false
local _optionalReady = false  -- True after all optional modules loaded (phases 4-5)
local _lastHealAttempt = 0
local _priorityActive = false
local ActorsCoordinator = nil
local _configReloadPending = false
local _lastClaimMetrics = nil

-- Lazy-load DamageParser (optional dual-source DPS tracking)
local DamageParser = nil
local function getDamageParser()
    if DamageParser == nil then
        local ok, dp = pcall(require, 'smartheal.damage_parser')
        if ok and dp then
            DamageParser = dp
            dp.init(Config)
        else
            DamageParser = false  -- Mark as unavailable
        end
    end
    return DamageParser or nil
end

-- Lazy-load DamageAttribution (mob-specific damage attribution)
local DamageAttribution = nil
local function getDamageAttribution()
    if DamageAttribution == nil then
        local ok, da = pcall(require, 'smartheal.damage_attribution')
        if ok and da then
            DamageAttribution = da
            da.init(Config)
            da.registerEvents()
        else
            DamageAttribution = false  -- Mark as unavailable
        end
    end
    return DamageAttribution or nil
end

-- Check if we're a healing class
local function isHealerClass()
    local me = mq.TLO.Me
    if not me or not me() then return false end
    local classShort = me.Class and me.Class.ShortName and me.Class.ShortName() or ''
    return HealerClasses.isSupported(classShort)
end

local function isCastingValueActive(casting)
    casting = tostring(casting or '')
    return casting ~= '' and casting ~= 'NULL'
end

-- Check if we can heal right now
local function canHealNow(opts)
    opts = opts or {}
    local me = mq.TLO.Me
    if not me or not me() then
        debugLog('[CanHealNow] FAIL: no me')
        return false
    end

    -- Dead or hovering
    if me.Hovering and me.Hovering() then
        debugLog('[CanHealNow] FAIL: hovering')
        return false
    end

    -- Already casting (Casting() returns spell name string, empty if not casting)
    local casting = me.Casting and me.Casting() or ''
    if isCastingValueActive(casting) then
        debugLog('[CanHealNow] FAIL: casting spell=%s', casting)
        return false
    end

    -- Moving
    if me.Moving and me.Moving() then
        debugLog('[CanHealNow] FAIL: moving')
        return false
    end

    -- Check spell engine busy (optional for non-SpellEngine callers)
    if not opts.ignoreSpellEngine then
        local ok, SpellEngine = pcall(require, 'smartheal.util.spell_engine')
        if ok and SpellEngine and SpellEngine.isBusy and SpellEngine.isBusy() then
            debugLog('[CanHealNow] FAIL: spell engine busy')
            return false
        end
    end

    debugLog('[CanHealNow] PASS: can heal now')
    return true
end

-- Check if we should duck the current cast
local function shouldDuck(castInfo)
    if not Config or not Config.duckEnabled then return false end
    if not castInfo then return false end

    local target = TargetMonitor.getTarget(castInfo.targetId)
    if not target then return false end

    local now = mq.gettime()
    local castAgeMs = now - (tonumber(castInfo.startTime) or now)
    local incomingGraceMs = (Config and Config.duckIncomingGraceMs ~= nil) and Config.duckIncomingGraceMs or 900

    -- Ducking is not a second HP-threshold system. Heal selection already
    -- right-sizes by expected heal amount versus uncovered missing HP. Once a
    -- heal has started, only cancel if that missing HP has become covered by
    -- another healer's incoming cast or by an active HoT that is keeping up
    -- with the target's current damage intake.
    local rawDeficit = tonumber(target.deficit) or 0

    if IncomingHeals and IncomingHeals.sumForTarget and IncomingHeals.getMyId then
        local myId = IncomingHeals.getMyId()
        local incomingFromOthers = IncomingHeals.sumForTarget(castInfo.targetId, myId)
        if incomingFromOthers > 0 and (rawDeficit - incomingFromOthers) <= 0 then
            if castAgeMs < incomingGraceMs then
                return false, nil, nil
            end
            return true, 'incoming_covers', nil
        end
    end

    local me = mq.TLO.Me
    local invisible = false
    if me and me() and me.Invis then
        local value = me.Invis()
        invisible = value == true or (tonumber(value) or 0) > 0
    end
    if invisible and not (Config and Config.breakInvisOOC == true) then
        debugLog('[CanHealNow] FAIL: invisible')
        return false
    end

    if Config.considerIncomingHot then
        local proactive = getProactive()
        local hotRemaining = 0
        if proactive and proactive.getIncomingHotRemaining then
            hotRemaining = tonumber(proactive.getIncomingHotRemaining(target.name or castInfo.targetName or castInfo.targetId)) or 0
        end

        if hotRemaining > 0 then
            local hotTarget = {}
            for k, v in pairs(target) do hotTarget[k] = v end
            hotTarget.incomingHotRemaining = hotRemaining

            local hotAnalyzer = getHotAnalyzer()
            if hotAnalyzer and hotAnalyzer.shouldTrustHoT then
                local trustHoT = hotAnalyzer.shouldTrustHoT(hotTarget, {
                    urgency = castInfo.tier,
                    duckCheck = true,
                })
                if trustHoT then
                    if castAgeMs < incomingGraceMs then
                        return false, nil, nil
                    end
                    return true, 'hot_covers', nil
                end
            else
                local castRemainingSec = math.max(0, ((tonumber(castInfo.expectedEnd) or now) - now) / 1000)
                local projectedDeficit = rawDeficit + ((tonumber(target.recentDps) or 0) * castRemainingSec)
                if hotRemaining >= projectedDeficit then
                    if castAgeMs < incomingGraceMs then
                        return false, nil, nil
                    end
                    return true, 'hot_covers', nil
                end
            end
        end
    end

    return false, nil, nil
end

local function is_hot_spell(spellName)
    if not spellName or spellName == '' then return false end
    local spell = mq.TLO.Spell(spellName)
    if not spell or not spell() then return false end
    local isDetrimental = tostring(spell.SpellType and spell.SpellType() or ''):lower() == 'detrimental'
    if isDetrimental then return false end
    if spell.HasSPA and spell.HasSPA(79) then
        local okSpa, vSpa = pcall(function() return spell.HasSPA(79)() end)
        return okSpa and vSpa == true
    end
    return false
end

-- Execute a heal
local function executeHeal(spellName, targetId, tier, isHoT)
    local spell = mq.TLO.Spell(spellName)
    if not spell or not spell() then return false end

    local me = mq.TLO.Me
    ---@diagnostic disable-next-line: undefined-field
    local mySpell = me and me() and me.Spell and me.Spell(spellName)
    local castTimeMs = mySpell and tonumber(mySpell.MyCastTime()) or tonumber(spell.CastTime()) or 2000
    local manaCost = tonumber(spell.Mana()) or 0
    local expected = HealTracker.getExpected(spellName)

    -- Get target name for logging
    local targetName = 'Unknown'
    local targetInfo = TargetMonitor.getTarget(targetId)
    if targetInfo and targetInfo.name then
        targetName = targetInfo.name
    else
        -- Fallback to spawn lookup
        local ok, spawn = pcall(function() return mq.TLO.Spawn(targetId) end)
        if ok and spawn and spawn() and spawn.CleanName then
            targetName = spawn.CleanName() or 'Unknown'
        end
    end

    -- Set cast info for ducking (before cast attempt)
    local startTime = mq.gettime()
    SpellEvents.setCastInfo({
        spellName = spellName,
        targetId = targetId,
        targetName = targetName,
        tier = tier,
        isHoT = isHoT,
        manaCost = manaCost,
        startTime = startTime,  -- Use mq.gettime() for wall-clock accuracy
        expectedEnd = startTime + castTimeMs + 1000,
    })

    -- Use SpellEngine if available
    local ok, SpellEngine = pcall(require, 'smartheal.util.spell_engine')
    local success = false

    if ok and SpellEngine and SpellEngine.cast then
        success = SpellEngine.cast(spellName, targetId, { spellCategory = 'heal' })
    else
        -- Fallback to direct command
        mq.cmdf('/cast "%s"', spellName)
        success = true  -- Assume success for direct command
    end

    -- IMPORTANT: Only register incoming heal AFTER cast was accepted
    if success then
        local castSec = castTimeMs / 1000
        local hotTickAmount = nil
        local hotDuration = nil

        if isHoT then
            hotTickAmount = HealTracker.getExpected(spellName, 'tick')
            if hotTickAmount <= 0 then
                ---@diagnostic disable-next-line: undefined-field
                local calcVal = tonumber(spell.Calc and spell.Calc(1) and spell.Calc(1)()) or 0
                if calcVal > 0 then
                    hotTickAmount = math.abs(calcVal)
                end
            end
            if spell.Duration and spell.Duration.TotalSeconds then
                hotDuration = tonumber(spell.Duration.TotalSeconds()) or 0
            end
        end

        IncomingHeals.registerMyCast(targetId, spellName, expected, castSec, isHoT, hotTickAmount, hotDuration)
        M.broadcastIncoming(targetId, spellName, expected, castTimeMs, isHoT)

        -- Track HoT presence for proactive logic + peers
        if isHoT then
            local proactive = getProactive()
            if proactive and proactive.recordHoT then
                proactive.recordHoT(targetName, spellName, hotDuration or 18)
            end
            if SpellEvents and SpellEvents.registerHotCast then
                SpellEvents.registerHotCast(targetName, spellName, hotTickAmount, hotDuration, mq.gettime())
            end
            if ActorsCoordinator and ActorsCoordinator.publish and Config and Config.broadcastEnabled then
                -- Wall-clock epoch seconds for cross-peer comparison.
                local castTimeSec = (castTimeMs or 0) / 1000
                local exp = os.time() + castTimeSec + (hotDuration or 18)
                ActorsCoordinator.publish('heal:hots', {
                    targetId = targetId,
                    spellName = spellName,
                    expiresAt = exp,
                })
            end
        end

        -- Track promised heals
        local subcat = tostring(spell.Subcategory and spell.Subcategory() or ''):lower()
        if subcat == 'delayed' then
            local proactive = getProactive()
            if proactive and proactive.recordPromised then
                local promisedDelay = (Config and Config.promisedDelaySeconds) or 18
                local duration = 0
                if spell.Duration and spell.Duration.TotalSeconds then
                    duration = tonumber(spell.Duration.TotalSeconds()) or 0
                end
                proactive.recordPromised(targetName, spellName, duration, expected, promisedDelay)
            end
        end

        -- Record for UI display
        HealSelector.recordLastAction(spellName, targetName, expected)
    else
        -- Cast failed, clear cast info
        SpellEvents.setCastInfo(nil)
    end

    return success
end

local function cloneTarget(t)
    local out = {}
    for k, v in pairs(t or {}) do out[k] = v end
    return out
end

local function resolveHealTargetId(targetInfo)
    local targetId = tonumber(targetInfo and targetInfo.id) or 0
    if targetId > 0 then return targetId end

    local targetName = tostring(targetInfo and targetInfo.name or '')
    if targetName == '' then return 0 end
    local expected = targetName:lower()
    for _, query in ipairs({
        'pc =' .. targetName,
        'mercenary =' .. targetName,
        'pet =' .. targetName,
    }) do
        local ok, spawn = pcall(function() return mq.TLO.Spawn(query) end)
        if ok and spawn and spawn() then
            local nameOk, cleanName = pcall(function() return spawn.CleanName() end)
            local idOk, resolvedId = pcall(function() return spawn.ID() end)
            resolvedId = idOk and tonumber(resolvedId) or 0
            if nameOk and tostring(cleanName or ''):lower() == expected and resolvedId > 0 then
                return resolvedId
            end
        end
    end
    return 0
end

local function buildHealingContext(opts)
    local proactive = getProactive()
    local allTargets = {}
    local localTargets = {}
    local priorityTargets = {}
    local groupTargets = {}
    local petTargets = {}
    local playerNeedsHeal = false

    local targets = TargetMonitor.getAllTargets() or {}
    for _, t in pairs(targets) do
        if not t.dead and not t.hovering and (t.pctHP or 0) > 0
            and (Config.healPetsEnabled or t.role ~= 'pet') then
            local entry = cloneTarget(t)
            entry._isSelf = entry.id == tonumber(mq.TLO.Me.ID())
            local incomingTotal = IncomingHeals.sumForTarget(entry.id)
            entry.incomingTotal = incomingTotal
            entry.deficit = math.max(0, (entry.deficit or 0) - incomingTotal)
            entry.effectiveDeficit = entry.deficit
            if proactive and proactive.getIncomingHotRemaining then
                entry.incomingHotRemaining = proactive.getIncomingHotRemaining(entry.name or entry.id)
            end
            if entry.role == 'pet' then
                table.insert(petTargets, entry)
            else
                table.insert(allTargets, entry)
                if not entry.actorReported then table.insert(localTargets, entry) end
                local healPct = tonumber(opts.pcHealPct) or (100 - (Config.minHealPct or 10))
                if (entry.pctHP or 100) <= healPct then playerNeedsHeal = true end
            end
            if entry.role == 'tank' then
                table.insert(priorityTargets, entry)
            elseif entry.role ~= 'pet' then
                table.insert(groupTargets, entry)
            end
        end
    end

    table.sort(allTargets, function(a, b)
        local pa = TargetMonitor.getPriority(a) or 99
        local pb = TargetMonitor.getPriority(b) or 99
        if pa ~= pb then return pa < pb end
        return (a.pctHP or 100) < (b.pctHP or 100)
    end)

    local function targetOrder(a, b)
        local pa = TargetMonitor.getPriority(a) or 99
        local pb = TargetMonitor.getPriority(b) or 99
        if pa ~= pb then return pa < pb end
        return (a.pctHP or 100) < (b.pctHP or 100)
    end
    table.sort(priorityTargets, targetOrder)
    table.sort(groupTargets, targetOrder)
    table.sort(petTargets, targetOrder)

    local situation = {
        hasEmergency = false,
        multipleHurt = 0,
    }

    for _, t in ipairs(allTargets) do
        if (t.pctHP or 100) < Config.getEmergencyPct() then
            situation.hasEmergency = true
        end
        if (t.deficit or 0) > 0 then
            situation.multipleHurt = situation.multipleHurt + 1
        end
    end
    situation.multipleHurt = situation.multipleHurt > 1

    local combatState = CombatAssessor and CombatAssessor.getState and CombatAssessor.getState() or {}
    local activeMobs = math.max(0, (combatState.activeMobCount or 0) - (combatState.mezzedMobCount or 0))
    local maxLowMobs = Config.lowPressureMobCount or 1
    situation.lowPressure = (not situation.hasEmergency) and (not situation.multipleHurt) and (activeMobs <= maxLowMobs)
    situation.combatAssessment = combatState
    situation.survivalMode = combatState.survivalMode == true
    situation.fightPhase = combatState.fightPhase or 'none'
    situation.estimatedFightDuration = combatState.estimatedTTK or 0

    -- Raid/named fight detection
    situation.hasRaidMob = combatState.hasRaidMob == true
    situation.hasNamedMob = combatState.hasNamedMob == true
    situation.mobDpsMultiplier = combatState.mobDpsMultiplier or 1.0
    situation.raidFight = situation.hasRaidMob or situation.hasNamedMob

    return {
        proactive = proactive,
        allTargets = allTargets,
        localTargets = localTargets,
        priorityTargets = priorityTargets,
        groupTargets = groupTargets,
        petTargets = petTargets,
        playerNeedsHeal = playerNeedsHeal,
        situation = situation,
    }
end

local function buildHealActionForTarget(targetInfo, heal, tier, reason)
    if not targetInfo or not heal then return nil end
    local spellName = heal.spell
    if not spellName or spellName == '' then return nil end
    local spell = mq.TLO.Spell(spellName)
    local range = spell and spell() and tonumber(spell.Range()) or 0
    if range > 0 and (tonumber(targetInfo.distance3D) or 0) > (range + 5) then
        return nil
    end
    if targetInfo.lineOfSight == false then return nil end
    local targetId = resolveHealTargetId(targetInfo)
    if targetId <= 0 then return nil end
    return {
        spellName = spellName,
        targetId = targetId,
        targetName = targetInfo.name,
        tier = tier,
        isHoT = is_hot_spell(spellName),
        expected = heal.expected,
        details = heal.details,
        reason = reason,
    }
end

local function localGroupClaimId()
    local best = tonumber(mq.TLO.Me.ID()) or 0
    local count = tonumber(mq.TLO.Group.Members()) or 0
    for i = 1, count do
        local member = mq.TLO.Group.Member(i)
        if member and member() then
            local id = tonumber(member.ID()) or 0
            if id > 0 and (best <= 0 or id < best) then best = id end
        end
    end
    return best
end

local function buildHealAction(opts)
    opts = opts or {}

    -- DoHeals gate lives in sk_healing.lua:onTick which already returns
    -- early before ever calling buildHealAction. Re-checking here would be
    -- redundant and would require this module to import Core just for that.
    if not isHealerClass() then
        return nil, 'not_healer'
    end

    -- A tanking character's job is aggro, not top-offs. Restrict its healing
    -- to genuine emergencies (below emergencyPct) so hate tools and
    -- defensives keep the cast/claim budget.
    if opts.excludeEmergency ~= true then
        local ok, core = pcall(function() return getSkLib().getSettings() end)
        if ok and type(core) == 'table'
            and tostring(core.CombatMode or 'off'):lower() == 'tank' then
            opts.onlyEmergency = true
        end
    end

    if opts.requireCanHeal and not canHealNow(opts) then
        return nil, 'cannot_heal'
    end
    if opts.skipIfCasting ~= false and SpellEvents.isCasting() then
        return nil, 'casting'
    end

    local ctx = buildHealingContext(opts)
    local unserviceable = false
    local proactive = ctx.proactive
    local situation = ctx.situation

    if opts.onlyEmergency and not situation.hasEmergency then
        return nil, 'no_emergency'
    end
    if opts.excludeEmergency and situation.hasEmergency then
        return nil, 'emergency_present'
    end

    -- Emergency
    if not opts.excludeEmergency then
        for _, t in ipairs(ctx.allTargets) do
            if (t.pctHP or 100) < Config.getEmergencyPct() then
                local heal, reason = HealSelector.SelectHeal(t, situation)
                if heal then
                    local action = buildHealActionForTarget(t, heal, 'emergency', reason)
                    if action then
                        return action, 'emergency'
                    end
                    unserviceable = true
                elseif reason == 'emergency_no_heal' then
                    unserviceable = true
                end
            end
        end
    end

    if unserviceable then return nil, 'unserviceable' end
    if opts.onlyEmergency then
        return nil, 'no_emergency_action'
    end

    -- Group heal
    local useGroup, groupHeal = HealSelector.ShouldUseGroupHeal(ctx.localTargets, situation)
    if useGroup and groupHeal then
        local myId = mq.TLO.Me.ID()
        if myId and myId > 0 then
            return {
                spellName = groupHeal.spell,
                targetId = tonumber(myId) or 0,
                targetName = mq.TLO.Me.CleanName() or mq.TLO.Me.Name() or 'Me',
                tier = 'group',
                isHoT = false,
                expected = groupHeal.expected,
                details = groupHeal.details,
                reason = 'group_heal',
                claimTargetId = localGroupClaimId(),
            }, 'group_heal'
        end
    end

    -- Group HoT
    if proactive and proactive.ShouldApplyGroupHot then
        local useGroupHot, groupHot, _, _ = proactive.ShouldApplyGroupHot(ctx.localTargets, situation)
        if useGroupHot and groupHot then
            local myId = mq.TLO.Me.ID()
            if myId and myId > 0 then
                local targetNames = {}
                local targetIds = {}
                for _, t in ipairs(groupHot.affectedTargets or HealSelector.groupTargetsInRange(groupHot.spell, ctx.localTargets)) do
                    if t.id then table.insert(targetIds, t.id) end
                    if t.name then
                        table.insert(targetNames, t.name)
                    end
                end
                return {
                    spellName = groupHot.spell,
                    targetId = tonumber(myId) or 0,
                    targetName = mq.TLO.Me.CleanName() or mq.TLO.Me.Name() or 'Me',
                    tier = 'groupHot',
                    isHoT = true,
                    expected = groupHot.expected,
                    details = groupHot.details,
                    reason = 'group_hot',
                    groupHotTargets = targetNames,
                    groupHotTargetIds = targetIds,
                    claimTargetId = localGroupClaimId(),
                }, 'group_hot'
            end
        end
    end

    local function tryHealList(list, tier)
        for _, t in ipairs(list) do
            if (t.deficit or 0) > 0 then
                local heal, reason = HealSelector.SelectHeal(t, situation)
                if not heal and (reason == 'emergency_no_heal' or reason == 'no_efficient_heal') then
                    unserviceable = true
                end
                if heal then
                    if heal.category == 'hot' and proactive and proactive.HasActiveHot and proactive.HasActiveHot(t.name) then
                        -- Post-selection: heal.spell is the HoT we'd cast, so pass it
                        -- so the self-buff check can match (targetHasHoTBuff is self-only).
                        local canRefresh = proactive.ShouldRefreshHot and proactive.ShouldRefreshHot(t.name, heal.spell) or false
                        if not canRefresh then
                            local deficitPct = (t.maxHP and t.maxHP > 0) and (t.deficit / t.maxHP * 100) or 0
                            local fallbackMinPct = Config.minHealPct or 10
                            if not t.isSquishy and Config.nonSquishyMinHealPct then
                                fallbackMinPct = math.max(fallbackMinPct, Config.nonSquishyMinHealPct)
                            end
                            if deficitPct < fallbackMinPct then
                                heal = nil
                            else
                                heal = HealSelector.FindEfficientHeal(t, false, situation)
                                if not heal then unserviceable = true end
                            end
                        end
                    end
                end

                if heal then
                    local isHoT = is_hot_spell(heal.spell)
                    if isHoT and proactive and proactive.shouldApplyHoT then
                        local shouldApply, hotReason = proactive.shouldApplyHoT(t, heal.spell)
                        if not shouldApply then
                            Logger.logHotDecision(t.name, heal.spell, false, hotReason)
                            heal = nil
                        else
                            Logger.logHotDecision(t.name, heal.spell, true, hotReason)
                        end
                    end

                    if heal then
                        local action = buildHealActionForTarget(t, heal, tier or 'priority', reason)
                        if action then
                            return action
                        end
                        unserviceable = true
                    end
                end
            end
        end
        return nil
    end

    local action = tryHealList(ctx.priorityTargets)
    if action then
        return action, 'priority_targets'
    end

    action = tryHealList(ctx.groupTargets)
    if action then
        return action, 'group_targets'
    end

    if unserviceable then return nil, 'unserviceable' end
    -- Players waiting for a HoT or incoming heal still outrank pets.
    if not ctx.playerNeedsHeal then
        action = tryHealList(ctx.petTargets, 'pet')
        if action then return action, 'pet_targets' end
    end
    return nil, 'no_heal_needed'
end

local function prepareHealCast(action)
    if not action then return nil end
    local spellName = action.spellName or action.name
    if not spellName or spellName == '' then return nil end
    local spell = mq.TLO.Spell(spellName)
    if not spell or not spell() then return nil end

    local me = mq.TLO.Me
    ---@diagnostic disable-next-line: undefined-field
    local mySpell = me and me() and me.Spell and me.Spell(spellName)
    local castTimeMs = mySpell and tonumber(mySpell.MyCastTime()) or tonumber(spell.CastTime()) or 2000
    local manaCost = tonumber(spell.Mana()) or 0

    local expected = action.expected
    if expected == nil then
        expected = HealTracker and HealTracker.getExpected and HealTracker.getExpected(spellName) or 0
    end

    local targetId = tonumber(action.targetId) or 0
    local targetName = action.targetName
    if not targetName or targetName == '' then
        local targetInfo = TargetMonitor.getTarget(targetId)
        if targetInfo and targetInfo.name then
            targetName = targetInfo.name
        else
            local ok, spawn = pcall(function() return mq.TLO.Spawn(targetId) end)
            if ok and spawn and spawn() and spawn.CleanName then
                targetName = spawn.CleanName() or 'Unknown'
            end
        end
    end

    local startTime = mq.gettime()
    local info = {
        spellName = spellName,
        targetId = targetId,
        targetName = targetName,
        tier = action.tier or 'heal',
        isHoT = action.isHoT == true,
        manaCost = manaCost,
        expected = expected,
        castTimeMs = castTimeMs,
        startTime = startTime,
        expectedEnd = startTime + castTimeMs + 1000,
        groupHotTargets = action.groupHotTargets,
        groupHotTargetIds = action.groupHotTargetIds,
    }

    if info.isHoT then
        local hotTickAmount = HealTracker.getExpected(spellName, 'tick')
        if hotTickAmount <= 0 then
            ---@diagnostic disable-next-line: undefined-field
            local calcVal = tonumber(spell.Calc and spell.Calc(1) and spell.Calc(1)()) or 0
            if calcVal > 0 then
                hotTickAmount = math.abs(calcVal)
            end
        end
        local hotDuration = nil
        if spell.Duration and spell.Duration.TotalSeconds then
            hotDuration = tonumber(spell.Duration.TotalSeconds()) or 0
        end
        info.hotTickAmount = hotTickAmount
        info.hotDuration = hotDuration
    end

    info.subcategory = tostring(spell.Subcategory and spell.Subcategory() or ''):lower()
    return info
end

local function registerHealCast(castInfo)
    if not castInfo then return end
    local targetId = castInfo.targetId
    local spellName = castInfo.spellName
    if not spellName or spellName == '' then return end

    local castSec = (castInfo.castTimeMs or 2000) / 1000
    local expected = castInfo.expected or 0
    local isHoT = castInfo.isHoT == true
    local hotTickAmount = castInfo.hotTickAmount
    local hotDuration = castInfo.hotDuration

    if not castInfo.confirmedLanded then
        IncomingHeals.registerMyCast(targetId, spellName, expected, castSec, isHoT, hotTickAmount, hotDuration)
        M.broadcastIncoming(targetId, spellName, expected, castInfo.castTimeMs or 0, isHoT)
    end

    local proactive = getProactive()
    if isHoT then
        if proactive and proactive.recordHoT then
            for _, name in ipairs(castInfo.groupHotTargets or { castInfo.targetName or targetId }) do
                proactive.recordHoT(name, spellName, hotDuration or 18)
            end
        end
        if not castInfo.groupHotTargets and SpellEvents and SpellEvents.registerHotCast then
            SpellEvents.registerHotCast(castInfo.targetName or '', spellName, hotTickAmount, hotDuration, mq.gettime())
        end
        if ActorsCoordinator and ActorsCoordinator.publish and Config and Config.broadcastEnabled then
            -- Wall-clock epoch seconds so cross-peer receivers can compare.
            local castTimeSec = (castInfo.castTimeMs or 0) / 1000
            local exp = os.time() + castTimeSec + (hotDuration or 18)
            local hotTargetIds = castInfo.groupHotTargetIds or { targetId }
            for _, hotTargetId in ipairs(hotTargetIds) do
                ActorsCoordinator.publish('heal:hots', {
                    targetId = hotTargetId,
                    spellName = spellName,
                    expiresAt = exp,
                    zone = mq.TLO.Zone and mq.TLO.Zone.ShortName and mq.TLO.Zone.ShortName() or '',
                })
            end
        end
    end

    if castInfo.subcategory == 'delayed' then
        if proactive and proactive.recordPromised then
            local promisedDelay = (Config and Config.promisedDelaySeconds) or 18
            local duration = hotDuration or 0
            if duration <= 0 then
                local spell = mq.TLO.Spell(spellName)
                if spell and spell() and spell.Duration and spell.Duration.TotalSeconds then
                    duration = tonumber(spell.Duration.TotalSeconds()) or 0
                end
            end
            proactive.recordPromised(castInfo.targetName or targetId, spellName, duration, expected, promisedDelay)
        end
    end

    if castInfo.groupHotTargets and SpellEvents and SpellEvents.registerGroupHotCast then
        local spell = mq.TLO.Spell(spellName)
        local duration = 0
        if spell and spell() and spell.Duration and spell.Duration.TotalSeconds then
            duration = tonumber(spell.Duration.TotalSeconds()) or 0
        end
        SpellEvents.registerGroupHotCast(castInfo.groupHotTargets, spellName, hotTickAmount or expected, duration, mq.gettime())
    end

    HealSelector.recordLastAction(spellName, castInfo.targetName or '', expected)
end

local function clearHealCast()
    SpellEvents.setCastInfo(nil)
end

local function cancelHealCast(castInfo, reason)
    castInfo = castInfo or SpellEvents.getCastInfo()
    if not castInfo then return end

    IncomingHeals.unregisterMyCast(castInfo.targetId)
    Analytics.recordDuck(castInfo.spellName, castInfo.manaCost)
    SpellEvents.setCastInfo(nil)
    M.broadcastCancelled(castInfo.targetId, castInfo.spellName, reason or 'duck')
    Logger.info('ducking', 'Ducked %s - %s', castInfo.spellName, reason or 'duck')
end

-- Main duck monitoring during cast
local function monitorDuck(opts)
    local castInfo = SpellEvents.getCastInfo()
    if not castInfo then return false end

    local me = mq.TLO.Me
    local currentlyCasting = me and me() and me.Casting and isCastingValueActive(me.Casting())
    if not currentlyCasting then
        -- Cast ended naturally - DON'T clear cast info here!
        -- Let the heal event (onHealLanded) clear it so analytics can record properly.
        -- Add a short timeout (2s) to clear stale cast info if heal event doesn't fire.
        local now = mq.gettime()
        local castStart = castInfo.startTime or now
        local expectedEnd = castInfo.expectedEnd or (castStart + 2.5)
        local staleTimeout = 2000  -- Wait 2 seconds after expected end before clearing
        if now > (expectedEnd + staleTimeout) then
            -- Stale cast info - heal event probably didn't fire, clear it
            SpellEvents.setCastInfo(nil)
        end
        return false
    end

    local duck, reason, threshold = shouldDuck(castInfo)
    if duck then
        pcall(function()
            require('smartheal.util.action_counters').bump('heal_ducked')
        end)
        -- Log duck decision with details
        local targetInfo = TargetMonitor.getTarget(castInfo.targetId)
        local hotRemaining = 0
        local proactive = getProactive()
        if proactive and proactive.getIncomingHotRemaining then
            hotRemaining = tonumber(proactive.getIncomingHotRemaining(
                targetInfo and (targetInfo.name or targetInfo.id) or (castInfo.targetName or castInfo.targetId)
            )) or 0
        end
        local details = string.format('targetHP=%d%% deficit=%d incoming=%d hotRemaining=%d dps=%.1f',
            targetInfo and targetInfo.pctHP or 0,
            targetInfo and targetInfo.deficit or 0,
            targetInfo and targetInfo.incomingTotal or 0,
            hotRemaining,
            targetInfo and targetInfo.recentDps or 0)
        Logger.logDuckDecision(castInfo.spellName, castInfo.targetName or '?', reason, details)

        if opts and opts.deferCancel then
            return true, reason, threshold
        elseif opts and opts.onDuck then
            opts.onDuck(castInfo, reason, threshold)
        else
            mq.cmd('/stopcast')
        end

        -- IMPORTANT: Clear SpellEngine busy state to allow new casts
        local ok, SpellEngine = pcall(require, 'smartheal.util.spell_engine')
        if ok and SpellEngine and SpellEngine.abort then
            SpellEngine.abort()
        end

        cancelHealCast(castInfo, reason)
        return true, reason, threshold
    end
    return false
end

--- Phased initialization: loads submodules in batches across separate main loop ticks.
--- Call initPhased(1), then initPhased(2), etc. with mq.delay() between each call
--- so MQ can process frames and prevent screen lockup.
--- @param phase number Init phase (1..TOTAL_INIT_PHASES)
function M.initPhased(phase)
    if phase == 1 then
        -- Phase 1: Config + Logger (~1100 lines)
        _lastClaimMetrics = nil
        Config = require('smartheal.config')
        Logger = require('smartheal.logger')
        Config.load()
        -- Persisted/imported categories are authoritative. Auto-assignment is
        -- only a first-run fallback; otherwise startup could erase a valid
        -- configuration merely because the spell bar was still being loaded.
        if not Config.HasConfiguredSpells or not Config.HasConfiguredSpells() then
            if not Config.autoAssignFromActiveSpellSet or not Config.autoAssignFromActiveSpellSet() then
                Config.autoAssignFromSpellBar()
            end
        elseif Config.mergeFromSpellBar then
            -- Discover newly memorized heals without replacing the persisted
            -- assignments that were already selected for this character.
            Config.mergeFromSpellBar()
        end
        Logger.init(Config)

    elseif phase == 2 then
        -- Phase 2: Core tracking modules (~1600 lines)
        HealTracker = require('smartheal.heal_tracker')
        TargetMonitor = require('smartheal.target_monitor')
        IncomingHeals = require('smartheal.incoming_heals')
        CombatAssessor = require('smartheal.combat_assessor')
        HealTracker.init(Config)
        TargetMonitor.init(Config)
        IncomingHeals.init(Config, TargetMonitor)
        CombatAssessor.init(Config, TargetMonitor)

    elseif phase == 3 then
        -- Phase 3: Heal selection + events (~2500 lines) → marks _initialized
        Analytics = require('smartheal.analytics')
        SpellEvents = require('smartheal.spell_events')
        HealSelector = require('smartheal.heal_selector')
        Analytics.init()
        SpellEvents.init(HealTracker, IncomingHeals, Analytics, Config)
        SpellEvents.setBroadcastCallbacks(
            function(targetId, spellName) M.broadcastLanded(targetId, spellName) end,
            function(targetId, spellName, reason) M.broadcastCancelled(targetId, spellName, reason) end
        )
        HealSelector.init(Config, HealTracker, TargetMonitor, IncomingHeals, CombatAssessor)

        -- Update exposed module references (external code may access these)
        M.Config = Config
        M.HealTracker = HealTracker
        M.TargetMonitor = TargetMonitor
        M.IncomingHeals = IncomingHeals
        M.CombatAssessor = CombatAssessor
        M.HealSelector = HealSelector
        M.Analytics = Analytics
        M.SpellEvents = SpellEvents
        M.Logger = Logger

        _initialized = true
        Logger.info('session', 'Healing Intelligence core initialized (phased) - fileLogging=%s', tostring(Config.fileLogging))

    elseif phase == 4 then
        -- Phase 4: Optional analysis modules + ActorsCoordinator
        local proactive = getProactive()
        if proactive and proactive.init then
            proactive.init(Config, HealTracker, TargetMonitor, CombatAssessor)
        end
        local ha = getHotAnalyzer()
        if ha and ha.init then
            ha.init(Config, HealTracker, CombatAssessor, proactive)
        end
        getDamageParser()
        getDamageAttribution()

        -- Load ActorsCoordinator for multi-healer coordination
        local acOk, ac = pcall(require, 'smartheal.util.actors_coordinator')
        if acOk and ac then
            ActorsCoordinator = ac
            if ac.registerHealingCallback then
                ac.registerHealingCallback('heal:incoming', function(content, senderName)
                    M.handleActorMessage('heal:incoming', content, senderName)
                end)
                ac.registerHealingCallback('heal:landed', function(content, senderName)
                    M.handleActorMessage('heal:landed', content, senderName)
                end)
                ac.registerHealingCallback('heal:cancelled', function(content, senderName)
                    M.handleActorMessage('heal:cancelled', content, senderName)
                end)
            end
            if ac.registerWorkerCommand then
                ac.registerWorkerCommand('healing',
                    function(command, content, _, _, fromMe)
                    if tostring(command or '') ~= 'reload_config' then return false end
                    if fromMe ~= true then return true end
                    local mine = tostring(mq.TLO.Me.CleanName() or mq.TLO.Me.Name() or ''):lower()
                    local target = tostring(content.character or ''):lower()
                    if target == '' or target == mine then _configReloadPending = true end
                    return true
                end)
            end
        end

    elseif phase == 5 then
        -- Phase 5: MobAssessor + UI modules + finalize
        getMobAssessor()

        local monitor = getMonitor()
        if monitor and monitor.init then
            local mobAssessor = getMobAssessor()
            monitor.init(Config, TargetMonitor, IncomingHeals, CombatAssessor, Analytics, HealTracker, HealSelector, mobAssessor)
        end

        local settings = getSettings()
        if settings and settings.init then
            settings.init(Config)
            if settings.setToggleMonitorCallback then
                settings.setToggleMonitorCallback(function()
                    local mon = getMonitor()
                    if mon and mon.toggle then mon.toggle() end
                end)
            end
        end

        _optionalReady = true
        if Logger then
            Logger.info('session', 'All optional modules loaded')
        end
    end
end

--- Backward-compatible init: runs all phases synchronously.
--- Use initPhased() for non-blocking startup.
function M.init()
    if _initialized then return end
    for phase = 1, M.TOTAL_INIT_PHASES do
        M.initPhased(phase)
    end
end

function M.tick(settings)
    if not _initialized then return false end

    -- Keep monolithic compatibility on the same peer/config sensor inputs as
    -- the coordinated worker's tickSensors() path.
    if _configReloadPending then
        _configReloadPending = false
        Config.load()
        if TargetMonitor.updateConfig then TargetMonitor.updateConfig(Config) end
        Logger.info('config', 'Reloaded healing configuration from peer update')
    end
    if ActorsCoordinator and ActorsCoordinator.getRemoteCharacters and TargetMonitor.updateActorTargets then
        TargetMonitor.updateActorTargets(ActorsCoordinator.getRemoteCharacters())
    end

    -- Enable briefly when diagnosing a specific healing stall; file IO here is expensive in combat.
    local _tickDbg = false
    local function tickLog(msg)
        if _tickDbg then debugLog('[HealTick] %s', msg) end
    end

    -- Update core modules (loaded in phases 1-3)
    tickLog('1-TargetMonitor')
    TargetMonitor.tick()
    tickLog('2-IncomingHeals')
    IncomingHeals.tick()
    tickLog('3-CombatAssessor')
    CombatAssessor.tick({ readOnly = true })
    tickLog('4-SpellEvents')
    SpellEvents.tick()
    tickLog('5-HealTracker')
    HealTracker.tick()

    -- Optional modules: only tick after phases 4-5 have initialized them
    if _optionalReady then
        tickLog('6-Proactive')
        local proactive = getProactive()
        if proactive and proactive.tick then
            proactive.tick()
        end

        tickLog('7-DamageParser')
        local dp = getDamageParser()
        if dp and dp.tick then dp.tick() end

        tickLog('8-DamageAttribution')
        local da = getDamageAttribution()
        if da and da.tick then da.tick() end

        tickLog('9-MobAssessor')
        local ma = getMobAssessor()
        if ma and ma.tick then ma.tick({ readOnly = true }) end
    end
    tickLog('10-OptionalDone')

    -- Check if we're a healer class
    tickLog('12-CheckHealerClass')
    if not isHealerClass() then
        _priorityActive = false
        return false
    end

    -- Monitor for ducking during cast
    tickLog('13-CheckCasting')
    if SpellEvents.isCasting() then
        monitorDuck()
        _priorityActive = true
        return true
    end

    -- Throttle heal attempts (use mq.gettime() for wall-clock accuracy)
    local now = mq.gettime()
    if (now - _lastHealAttempt) < 100 then
        return _priorityActive
    end
    _lastHealAttempt = now

    -- Can we heal?
    tickLog('14-CanHealNow')
    if not canHealNow() then
        return _priorityActive
    end
    tickLog('15-PastCanHealNow')

    local function cloneTarget(t)
        local out = {}
        for k, v in pairs(t) do out[k] = v end
        return out
    end

    local proactive = _optionalReady and getProactive() or nil

    local allTargets = {}
    local priorityTargets = {}
    local groupTargets = {}

    local myId = mq.TLO.Me.ID and mq.TLO.Me.ID() or 0
    local targets = TargetMonitor.getAllTargets() or {}
    tickLog(string.format('16-Targets count=%d', #targets))
    for _, t in pairs(targets) do
        if Config.healPetsEnabled or t.role ~= 'pet' then
            local entry = cloneTarget(t)
            entry._isSelf = (entry.id == myId)
            local incomingTotal = IncomingHeals.sumForTarget(entry.id)
            entry.incomingTotal = incomingTotal
            entry.deficit = math.max(0, (entry.deficit or 0) - incomingTotal)
            entry.effectiveDeficit = entry.deficit
            if proactive and proactive.getIncomingHotRemaining then
                entry.incomingHotRemaining = proactive.getIncomingHotRemaining(entry.name or entry.id)
            end
            table.insert(allTargets, entry)
            if entry.role == 'tank' then
                table.insert(priorityTargets, entry)
            else
                table.insert(groupTargets, entry)
            end
        end
    end

    table.sort(allTargets, function(a, b)
        local pa = TargetMonitor.getPriority(a) or 99
        local pb = TargetMonitor.getPriority(b) or 99
        if pa ~= pb then return pa < pb end
        return (a.pctHP or 100) < (b.pctHP or 100)
    end)

    local situation = {
        hasEmergency = false,
        multipleHurt = 0,
    }

    for _, t in ipairs(allTargets) do
        if (t.pctHP or 100) < Config.getEmergencyPct() then
            situation.hasEmergency = true
        end
        if (t.deficit or 0) > 0 then
            situation.multipleHurt = situation.multipleHurt + 1
        end
    end
    situation.multipleHurt = situation.multipleHurt > 1

    local combatState = CombatAssessor and CombatAssessor.getState and CombatAssessor.getState() or {}
    local activeMobs = math.max(0, (combatState.activeMobCount or 0) - (combatState.mezzedMobCount or 0))
    local maxLowMobs = Config.lowPressureMobCount or 1
    situation.lowPressure = (not situation.hasEmergency) and (not situation.multipleHurt) and (activeMobs <= maxLowMobs)
    situation.combatAssessment = combatState
    situation.survivalMode = combatState.survivalMode == true
    situation.fightPhase = combatState.fightPhase or 'none'
    situation.estimatedFightDuration = combatState.estimatedTTK or 0

    -- Raid/named fight detection
    situation.hasRaidMob = combatState.hasRaidMob == true
    situation.hasNamedMob = combatState.hasNamedMob == true
    situation.mobDpsMultiplier = combatState.mobDpsMultiplier or 1.0
    situation.raidFight = situation.hasRaidMob or situation.hasNamedMob

    -- Log situation summary
    local hurtCount = 0
    local lowestHp = 100
    for _, t in ipairs(allTargets) do
        if (t.deficit or 0) > 0 then hurtCount = hurtCount + 1 end
        if (t.pctHP or 100) < lowestHp then lowestHp = t.pctHP or 100 end
    end
    tickLog(string.format('17-Situation: targets=%d hurt=%d lowestHP=%d emergency=%s',
        #allTargets, hurtCount, lowestHp, tostring(situation.hasEmergency)))

    -- Priority 1: emergency
    tickLog('18-CheckEmergency')
    for _, t in ipairs(allTargets) do
        if (t.pctHP or 100) < Config.getEmergencyPct() then
            tickLog(string.format('19-EmergencyTarget: %s HP=%d', tostring(t.name), t.pctHP or 0))
            local heal, reason = HealSelector.SelectHeal(t, situation)
            tickLog(string.format('20-EmergencyHeal: spell=%s reason=%s', tostring(heal and heal.spell), tostring(reason)))
            if heal then
                local spellInfo = mq.TLO.Spell(heal.spell)
                local isHoT = false
                if spellInfo and spellInfo() and spellInfo.HasSPA then
                    local okSpa, vSpa = pcall(function() return spellInfo.HasSPA(79)() end)
                    isHoT = okSpa and vSpa == true
                end
                if executeHeal(heal.spell, t.id, 'emergency', isHoT) then
                    _priorityActive = true
                    return true
                end
            end
        end
    end

    -- A tanking character stops here: emergencies only (mirrors the
    -- onlyEmergency gate in buildHealAction for the coordinated path).
    do
        local okMode, core = pcall(function() return getSkLib().getSettings() end)
        if okMode and type(core) == 'table'
            and tostring(core.CombatMode or 'off'):lower() == 'tank' then
            return false
        end
    end

    -- Priority 1.5: pre-pull HoT - a pull is inbound, get a HoT ticking on the
    -- tank BEFORE the mob arrives so the first hits land on top of healing.
    -- The tank worker normally owns XTarget detection and broadcasts the result;
    -- a healer scans locally only when no active SideKick tank is available.
    -- Settings (registry): PrePullHotEnabled / PrePullHotEtaSec / PrePullHotBigMult
    local okCore, CoreSettings = pcall(function()
        return require('smartheal.util.core').Settings
    end)
    local skSettings = (okCore and CoreSettings) or {}
    if skSettings.PrePullHotEnabled ~= false then
        -- Pull detection: prefer the tank's broadcast (one monitor per group).
        -- Fall back to scanning locally only when no sidekick tank is active
        -- (tankless groups / solo healer) or when I am the tank myself.
        local inbound = nil
        local okAct, Actors = pcall(require, 'smartheal.util.actors_coordinator')
        local remotePull = okAct and Actors and Actors.getPullState and Actors.getPullState() or nil
        if remotePull then
            if remotePull.phase == 'inbound' then
                inbound = {
                    mobId = remotePull.mobId, mobName = remotePull.mobName,
                    eta = remotePull.eta, mult = remotePull.mult, dist = remotePull.dist,
                }
            end
        else
            local iAmTank = skSettings.CombatMode == 'tank'
            local tankActive = false
            if not iAmTank and okAct and Actors and Actors.getTankState then
                local ts = Actors.getTankState()
                tankActive = ts and ts.tankName and ts.tankName ~= ''
                    and ts.updatedAt and (os.clock() - (ts.updatedAt or 0)) < 15
            end
            local okPM, PullMonitor = pcall(require, 'smartheal.pull_monitor')
            if okPM and PullMonitor then
                if iAmTank then
                    -- tank.tickPullBroadcast already ticks the monitor; just read
                    inbound = PullMonitor.getInbound()
                elseif not tankActive then
                    PullMonitor.tick()
                    inbound = PullMonitor.getInbound()
                end
            end
        end
        do
            if inbound then
                local tank = nil
                for _, t in ipairs(allTargets) do
                    if t.role == 'tank' then tank = t break end
                end
                local etaWindow = tonumber(skSettings.PrePullHotEtaSec) or 8
                if tank and inbound.eta <= etaWindow
                    and not (proactive and proactive.HasActiveHot and proactive.HasActiveHot(tank.name)) then
                    -- Big HoT for raid/named-tier inbound mobs, light HoT for trash
                    local bigMult = tonumber(skSettings.PrePullHotBigMult) or 2.0
                    local useLight = (inbound.mult or 1.0) < bigMult
                    local bestHot = HealSelector.SelectBestHot
                        and HealSelector.SelectBestHot(tank, useLight, true)
                    if bestHot and bestHot.spell then
                        tickLog(string.format('18a-PrePullHot: mob=%s eta=%.1fs mult=%.1f spell=%s',
                            tostring(inbound.mobName), inbound.eta, inbound.mult or 1, bestHot.spell))
                        if executeHeal(bestHot.spell, tank.id, 'prePullHot', true) then
                            _priorityActive = true
                            return true
                        end
                    end
                end
            end
        end
    end

    -- Priority 2: group heal
    local useGroup, groupHeal = HealSelector.ShouldUseGroupHeal(allTargets, situation)
    if useGroup and groupHeal then
        local myId = mq.TLO.Me.ID()
        if executeHeal(groupHeal.spell, myId, 'group', false) then
            _priorityActive = true
            return true
        end
    end

    -- Priority 2.5: group HoT
    if proactive and proactive.ShouldApplyGroupHot then
        local useGroupHot, groupHot, totalDeficit, hurtCount = proactive.ShouldApplyGroupHot(allTargets, situation)
        if useGroupHot and groupHot then
            local myId = mq.TLO.Me.ID()
            if executeHeal(groupHot.spell, myId, 'groupHot', true) then
                if SpellEvents and SpellEvents.registerGroupHotCast then
                    local targetNames = {}
                    for _, t in ipairs(allTargets) do
                        if (t.deficit or 0) > 0 then
                            table.insert(targetNames, t.name)
                        end
                    end
                    local spell = mq.TLO.Spell(groupHot.spell)
                    local duration = 0
                    if spell and spell() and spell.Duration and spell.Duration.TotalSeconds then
                        duration = tonumber(spell.Duration.TotalSeconds()) or 0
                    end
                    SpellEvents.registerGroupHotCast(targetNames, groupHot.spell, groupHot.expected or 0, duration, mq.gettime())
                end
                _priorityActive = true
                return true
            end
        end
    end

    local function tryHealList(list)
        for _, t in ipairs(list) do
            if (t.deficit or 0) > 0 then
                tickLog(string.format('21-TryHeal: %s HP=%d deficit=%d', tostring(t.name), t.pctHP or 0, t.deficit or 0))
                local heal, reason = HealSelector.SelectHeal(t, situation)
                tickLog(string.format('22-HealSelected: spell=%s reason=%s', tostring(heal and heal.spell), tostring(reason)))
                if heal then
                    if heal.category == 'hot' and proactive and proactive.HasActiveHot and proactive.HasActiveHot(t.name) then
                        -- Post-selection: heal.spell is the HoT we'd cast, so pass it
                        -- so the self-buff check can match (targetHasHoTBuff is self-only).
                        local canRefresh = proactive.ShouldRefreshHot and proactive.ShouldRefreshHot(t.name, heal.spell) or false
                        if not canRefresh then
                            local deficitPct = (t.maxHP and t.maxHP > 0) and (t.deficit / t.maxHP * 100) or 0
                            local fallbackMinPct = Config.minHealPct or 10
                            if not t.isSquishy and Config.nonSquishyMinHealPct then
                                fallbackMinPct = math.max(fallbackMinPct, Config.nonSquishyMinHealPct)
                            end
                            if deficitPct < fallbackMinPct then
                                heal = nil
                            else
                                heal = HealSelector.FindEfficientHeal(t, false, situation)
                            end
                        end
                    end
                end

                if heal then
                    local spellInfo = mq.TLO.Spell(heal.spell)
                    local isHoT = false
                    if spellInfo and spellInfo() and spellInfo.HasSPA then
                        local okSpa, vSpa = pcall(function() return spellInfo.HasSPA(79)() end)
                        isHoT = okSpa and vSpa == true
                    end

                    -- Validate HoT with proactive.shouldApplyHoT before executing
                    if isHoT and proactive and proactive.shouldApplyHoT then
                        local shouldApply, hotReason = proactive.shouldApplyHoT(t, heal.spell)
                        if not shouldApply then
                            -- Log the rejection and skip this HoT
                            Logger.logHotDecision(t.name, heal.spell, false, hotReason)
                            heal = nil  -- Clear to fall through to next target
                        else
                            Logger.logHotDecision(t.name, heal.spell, true, hotReason)
                        end
                    end

                    if heal and executeHeal(heal.spell, t.id, 'priority', isHoT) then
                        _priorityActive = true
                        return true
                    end
                end
            end
        end
        return false
    end

    tickLog('23-TryPriorityTargets')
    if tryHealList(priorityTargets) then return true end
    tickLog('24-TryGroupTargets')
    if tryHealList(groupTargets) then return true end

    tickLog('25-NoHealNeeded')
    _priorityActive = false
    return false
end

function M.tickActors()
    if not ActorsCoordinator then return end
    -- Actor message processing happens via handleActorMessage() which is called
    -- by actors_coordinator when heal:incoming/landed/cancelled messages arrive.
    -- Broadcasts are triggered by executeHeal() and SpellEvents on specific events.
    -- IncomingHeals.prune() handles cleanup and runs in M.tick().
    -- This function is kept for potential future periodic health checks or state sync.
end

function M.isPriorityActive()
    return _priorityActive
end

function M.isInitialized()
    return _initialized
end

function M.isCasting()
    return SpellEvents and SpellEvents.isCasting and SpellEvents.isCasting() or false
end

function M.checkDucking(opts)
    if not _initialized then return false end
    return monitorDuck(opts)
end

function M.tickSensors(opts)
    if not _initialized then return end
    opts = type(opts) == 'table' and opts or {}
    -- Sensor ticks are read-only by default. Targeting and /consider are
    -- gameplay mutations and must be represented by a separately leased
    -- action if coordinated healing ever needs to refresh that intelligence.
    if opts.readOnly == nil then opts.readOnly = true end
    if _configReloadPending then
        _configReloadPending = false
        Config.load()
        if TargetMonitor.updateConfig then TargetMonitor.updateConfig(Config) end
        Logger.info('config', 'Reloaded healing configuration from peer update')
    end
    if ActorsCoordinator and ActorsCoordinator.getRemoteCharacters and TargetMonitor.updateActorTargets then
        TargetMonitor.updateActorTargets(ActorsCoordinator.getRemoteCharacters())
    end
    TargetMonitor.tick()
    IncomingHeals.tick()
    CombatAssessor.tick(opts)
    SpellEvents.tick()
    HealTracker.tick()

    if _optionalReady then
        local proactive = getProactive()
        if proactive and proactive.tick then
            proactive.tick()
        end

        local dp = getDamageParser()
        if dp and dp.tick then dp.tick() end

        local da = getDamageAttribution()
        if da and da.tick then da.tick() end

        local ma = getMobAssessor()
        if ma and ma.tick then ma.tick(opts) end
    end
end

function M.buildHealAction(opts)
    return buildHealAction(opts)
end

function M.prepareHealCast(action)
    return prepareHealCast(action)
end

function M.setCastInfo(castInfo)
    if SpellEvents then SpellEvents.setCastInfo(castInfo) end
end

function M.registerHealCast(castInfo)
    if not _initialized then return end
    registerHealCast(castInfo)
end

function M.clearCastInfo()
    if not _initialized then return end
    clearHealCast()
end

function M.cancelHealCast(castInfo, reason)
    cancelHealCast(castInfo, reason)
end

-- Broadcast functions for multi-healer coordination
function M.broadcastIncoming(targetId, spellName, expectedAmount, remainingMs, isHoT)
    if not ActorsCoordinator or not ActorsCoordinator.publish then return end
    if not Config.broadcastEnabled then return end

    ActorsCoordinator.publish('heal:incoming', {
        targetId = targetId,
        spellName = spellName,
        expectedAmount = expectedAmount,
        remainingMs = math.max(0, tonumber(remainingMs) or 0),
        isHoT = isHoT,
        zone = mq.TLO.Zone and mq.TLO.Zone.ShortName and mq.TLO.Zone.ShortName() or '',
    })
end

function M.broadcastLanded(targetId, spellName)
    if not ActorsCoordinator or not ActorsCoordinator.publish then return end
    if not Config.broadcastEnabled then return end

    ActorsCoordinator.publish('heal:landed', {
        targetId = targetId,
        spellName = spellName,
        zone = mq.TLO.Zone and mq.TLO.Zone.ShortName and mq.TLO.Zone.ShortName() or '',
    })
end

function M.broadcastCancelled(targetId, spellName, reason)
    if not ActorsCoordinator or not ActorsCoordinator.publish then return end
    if not Config.broadcastEnabled then return end

    ActorsCoordinator.publish('heal:cancelled', {
        targetId = targetId,
        spellName = spellName,
        reason = reason,
        zone = mq.TLO.Zone and mq.TLO.Zone.ShortName and mq.TLO.Zone.ShortName() or '',
    })
end

-- Handler for incoming messages from other healers
function M.handleActorMessage(msgType, data, senderId)
    if not IncomingHeals then return end
    if msgType == 'heal:incoming' then
        IncomingHeals.add(senderId, data.targetId, data)
    elseif msgType == 'heal:landed' then
        IncomingHeals.remove(senderId, data.targetId)
    elseif msgType == 'heal:cancelled' then
        IncomingHeals.remove(senderId, data.targetId)
    end
end

local function claimMetricsKey(action)
    return string.format('%s:%d:%s', tostring(action.tier or 'heal'),
        tonumber(action.claimTargetId or action.targetId) or 0,
        tostring(action.spellName or action.name or ''))
end

local function buildClaimMetrics(action, reuseBroadcast)
    local key = claimMetricsKey(action)
    if reuseBroadcast and _lastClaimMetrics and _lastClaimMetrics.key == key then
        return _lastClaimMetrics.metrics
    end
    local spellName = tostring(action.spellName or action.name or '')
    local expectedAmount = tonumber(action.expected)
    if expectedAmount == nil and HealTracker and HealTracker.getExpected then
        expectedAmount = tonumber(HealTracker.getExpected(spellName))
    end
    expectedAmount = math.max(0, expectedAmount or 0)

    local castTimeMs = tonumber(action.castTimeMs)
    if not castTimeMs and spellName ~= '' then
        local spell = mq.TLO.Spell(spellName)
        if spell and spell() then
            local me = mq.TLO.Me
            ---@diagnostic disable-next-line: undefined-field
            local mySpell = me and me() and me.Spell and me.Spell(spellName)
            castTimeMs = mySpell and tonumber(mySpell.MyCastTime()) or tonumber(spell.CastTime())
        end
    end
    castTimeMs = math.max(0, castTimeMs or 2000)

    local healTargetId = tonumber(action.targetId) or 0
    local target = TargetMonitor and TargetMonitor.getTarget and TargetMonitor.getTarget(healTargetId) or nil
    local deficit = target and math.max(0,
        tonumber(target.effectiveDeficit) or tonumber(target.deficit) or 0) or 0
    local projectedDamage = target and math.max(0, tonumber(target.recentDps) or 0)
        * (castTimeMs / 1000) or 0
    local projectedNeed = math.max(1, deficit + projectedDamage)

    return {
        spellName = spellName,
        expectedAmount = expectedAmount,
        castTimeMs = castTimeMs,
        projectedNeed = projectedNeed,
        coveragePct = (expectedAmount / projectedNeed) * 100,
    }
end

function M.broadcastClaim(action, ttlMs)
    if not ActorsCoordinator or not ActorsCoordinator.publish or not action then return false end
    if Config and Config.broadcastEnabled == false then return false end
    local targetId = tonumber(action.claimTargetId or action.targetId) or 0
    if targetId <= 0 then return false end
    local tier = tostring(action.tier or 'heal')
    local priority = tier == 'emergency' and 0 or 1
    local metrics = buildClaimMetrics(action, false)
    _lastClaimMetrics = { key = claimMetricsKey(action), metrics = metrics }
    ActorsCoordinator.publish('heal:claim', {
        targetId = targetId,
        spellName = metrics.spellName,
        tier = tier,
        priority = priority,
        expectedAmount = metrics.expectedAmount,
        castTimeMs = metrics.castTimeMs,
        projectedNeed = metrics.projectedNeed,
        coveragePct = metrics.coveragePct,
        claimKey = string.format('%s:%d', tier, targetId),
        expiresAt = os.time() + math.max(2, math.ceil((tonumber(ttlMs) or 1000) / 1000) + 1),
        zone = mq.TLO.Zone and mq.TLO.Zone.ShortName and mq.TLO.Zone.ShortName() or '',
    })
    return true
end

function M.isClaimWinner(action)
    if Config and Config.broadcastEnabled == false then return true end
    if not ActorsCoordinator or not ActorsCoordinator.isHealClaimWinner or not action then return true end
    local targetId = tonumber(action.claimTargetId or action.targetId) or 0
    if targetId <= 0 then return false end
    local tier = tostring(action.tier or 'heal')
    local myName = mq.TLO.Me.CleanName() or mq.TLO.Me.Name() or ''
    -- Reuse the values that were broadcast for this intent. That guarantees
    -- every client sorts the exact same claim even if HP changes while the
    -- short claim-settling window is running.
    local metrics = buildClaimMetrics(action, true)
    return ActorsCoordinator.isHealClaimWinner(targetId, {
        from = myName,
        spellName = metrics.spellName,
        tier = tier,
        priority = tier == 'emergency' and 0 or 1,
        expectedAmount = metrics.expectedAmount,
        castTimeMs = metrics.castTimeMs,
        projectedNeed = metrics.projectedNeed,
        coveragePct = metrics.coveragePct,
    })
end

function M.shutdown()
    if not _initialized then return end

    -- Log session summary before shutdown
    Logger.logSessionSummary({
        duration = Analytics.getSessionDuration and Analytics.getSessionDuration() or '?',
        totalCasts = Analytics.getStats and Analytics.getStats().totalCasts or 0,
        totalHealed = Analytics.getStats and Analytics.getStats().totalHealed or 0,
        overHealPct = Analytics.getStats and Analytics.getStats().overHealPct or 0,
        duckedCasts = Analytics.getStats and Analytics.getStats().duckedCasts or 0,
        duckSavings = Analytics.getStats and Analytics.getStats().duckSavingsEstimate or 0,
        incomingHonored = Analytics.getStats and Analytics.getStats().incomingHealHonored or 0,
        incomingExpired = Analytics.getStats and Analytics.getStats().incomingHealExpired or 0,
    })

    -- Log analytics summary before closing logger
    Logger.info('analytics', 'Session summary: %s', Analytics.getSummary())

    HealTracker.shutdown()
    Config.save()

    -- Shutdown MobAssessor (saves any dirty data)
    local ma = getMobAssessor()
    if ma and ma.shutdown then
        ma.shutdown()
    end

    Logger.shutdown()  -- Close log file
    _lastClaimMetrics = nil
    _initialized = false
end

-- UI functions
function M.toggleMonitor()
    local monitor = getMonitor()
    if monitor and monitor.toggle then
        monitor.toggle()
    end
end

function M.drawMonitor()
    local monitor = getMonitor()
    if monitor and monitor.draw then
        monitor.draw()
    end
end

function M.drawSettings()
    local settings = getSettings()
    if settings and settings.draw then
        settings.draw()
    end
end

function M.isMonitorOpen()
    local monitor = getMonitor()
    return monitor and monitor.isOpen and monitor.isOpen() or false
end

-- Expose modules (nil at load time, populated during initPhased phase 3)
M.Config = nil
M.HealTracker = nil
M.TargetMonitor = nil
M.IncomingHeals = nil
M.CombatAssessor = nil
M.HealSelector = nil
M.Analytics = nil
M.SpellEvents = nil
M.Logger = nil

-- UI modules are exposed via getter functions to allow late binding
function M.getMonitor() return getMonitor() end
function M.getSettings() return getSettings() end
function M.getMobAssessor() return getMobAssessor() end

--- Subscribe to the authoritative healing worker's incoming-damage parser.
-- Used by coordinated diagnostics so the UI does not initialize a duplicate
-- combat-log parser.
function M.addIncomingDamageListener(fn)
    if type(fn) ~= 'function' then return false end
    local dp = getDamageParser()
    if not dp or not dp.addListener then return false end
    dp.addListener(fn)
    return true
end

return M
