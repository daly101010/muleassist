-- healing/target_monitor.lua
local mq = require('mq')
local lazy = require('smartheal.util.lazy_require')

local M = {}

local Config = nil

-- Lazy-load DamageParser
local getDamageParser = lazy.once('smartheal.damage_parser')

-- Lazy-load DamageAttribution
local getDamageAttribution = lazy.once('smartheal.damage_attribution')

-- Target data cache
local _targets = {}
local _lastActorScan = 0
local _lastFullScan = 0
local _actorDamage = {}       -- [spawnId] = { samples = {}, lastCurrentHP, lastMaxHP, lastPctHP }

-- Rolling damage window (seconds) - updated from Config in init()
local DAMAGE_WINDOW_SEC = 6

-- DanNet max HP cache
local _remoteMaxHP = {}      -- { [charName] = maxHP }
local _remoteMaxHPAt = {}    -- { [charName] = lastQueryTime }
local _danNetObservers = {}  -- { [charName..propName] = true }
local _danNetAvailable = nil -- Cached DanNet availability

-- Check if DanNet plugin is available
local function isDanNetAvailable()
    if _danNetAvailable ~= nil then
        return _danNetAvailable
    end
    local dnPlugin = mq.TLO.Plugin('mq2dannet')
    _danNetAvailable = dnPlugin and dnPlugin.IsLoaded and dnPlugin.IsLoaded() == true
    return _danNetAvailable
end

-- Ensure DanNet observer is set up for a property
local function ensureDanNetObserver(charName, propName)
    if not charName or charName == '' then return end
    local key = charName .. '|' .. propName
    if _danNetObservers[key] then return end

    -- Set up observer via DanNet command
    mq.cmdf('/dobserve %s -q %s', charName, propName)
    _danNetObservers[key] = true
end

-- Get max HP from DanNet observer (cached)
local function getRemoteMaxHP(targetName)
    if not targetName or targetName == '' then
        return nil
    end

    local now = mq.gettime()
    local successTtl = 120000  -- Cache successful lookups for 2 minutes
    local failureTtl = 5000    -- Retry failed lookups every 5 seconds

    -- Check if we have a cached successful value
    local cachedValue = _remoteMaxHP[targetName]
    local lastAt = _remoteMaxHPAt[targetName] or 0
    local ttl = cachedValue and successTtl or failureTtl

    if (now - lastAt) < ttl then
        return cachedValue
    end

    -- Mark that we're attempting a lookup
    _remoteMaxHPAt[targetName] = now

    -- Check DanNet availability
    if not isDanNetAvailable() then
        return cachedValue
    end

    -- Query DanNet for Me.MaxHPs on the target character
    local propName = 'Me.MaxHPs'
    ensureDanNetObserver(targetName, propName)

    local rawVal = mq.TLO.DanNet(targetName).Observe(propName)()
    if rawVal == 'NULL' or rawVal == '' then
        return cachedValue
    end
    local num = tonumber(rawVal)
    if num and num > 0 then
        _remoteMaxHP[targetName] = num
        return num
    end

    -- Failed lookup - will retry in 5 seconds
    return cachedValue
end

function M.init(config)
    Config = config
    _targets = {}
    _lastActorScan = 0
    _actorDamage = {}
    _remoteMaxHP = {}
    _remoteMaxHPAt = {}
    _danNetObservers = {}
    _danNetAvailable = nil  -- Re-check on init
    -- Update damage window from config
    if Config and Config.damageWindowSec then
        DAMAGE_WINDOW_SEC = Config.damageWindowSec
    end
end

function M.getTarget(spawnId)
    return _targets[spawnId]
end

function M.getAllTargets()
    return _targets
end

local function isSquishy(classShort)
    if not Config or not Config.squishyClasses then return false end
    return Config.squishyClasses[classShort] == true
end

local function getRole(spawn)
    if not spawn or not spawn() then return 'dps' end

    -- Check if it's a pet
    local spawnType = spawn.Type and spawn.Type() or ''
    if spawnType:lower() == 'pet' then
        return 'pet'
    end

    local classShort = spawn.Class and spawn.Class.ShortName and spawn.Class.ShortName() or ''
    classShort = classShort:upper()

    -- Tank classes
    if classShort == 'WAR' or classShort == 'PAL' or classShort == 'SHD' then
        return 'tank'
    end

    -- Healer classes
    if classShort == 'CLR' or classShort == 'DRU' or classShort == 'SHM' then
        return 'healer'
    end

    return 'dps'
end

local function safeBool(fn, fallback)
    local ok, value = pcall(fn)
    if not ok or value == nil then return fallback == true end
    return value == true
end

function M.updateConfig(config)
    Config = config or Config
    if Config and Config.damageWindowSec then
        DAMAGE_WINDOW_SEC = Config.damageWindowSec
    end
end

local function updateTargetData(spawnId, spawn, roleOverride, healthOverride)
    if not spawn or not spawn() then
        _targets[spawnId] = nil
        return nil
    end

    -- Use mq.gettime() for wall-clock accuracy (os.clock() can drift)
    local now = mq.gettime()
    local existing = _targets[spawnId] or {}

    -- For non-targeted group members, CurrentHPs/MaxHPs return placeholder values (100/100)
    -- PctHPs is always accurate regardless of targeting
    healthOverride = healthOverride or {}
    local currentHP = tonumber(healthOverride.currentHP) or tonumber(spawn.CurrentHPs()) or 0
    local maxHP = tonumber(healthOverride.maxHP) or tonumber(spawn.MaxHPs()) or 1
    local pctHP = tonumber(healthOverride.pctHP) or tonumber(spawn.PctHPs()) or 100

    -- Get target name for DanNet lookup
    local targetName = spawn.CleanName() or spawn.Name() or ''

    local overrideMax = tonumber(healthOverride.maxHP)
    local spawnMax = tonumber(spawn.MaxHPs()) or 1
    local remoteMax = nil
    if not (overrideMax and overrideMax > 100) then
        remoteMax = getRemoteMaxHP(targetName)
    end

    -- For self, we can get MaxHP directly
    local fallbackMax = nil
    if targetName == mq.TLO.Me.Name() then
        fallbackMax = tonumber(mq.TLO.Me.MaxHPs()) or nil
    end

    local maxHPKnown = false
    local maxHPSource = 'unknown'

    -- Use real values in priority order. Actor and DanNet are the most useful
    -- for untargeted/group characters where MQ spawn HP may be 100/100.
    local resolvedMax = nil
    if overrideMax and overrideMax > 100 then
        resolvedMax = overrideMax
        maxHPKnown = true
        maxHPSource = healthOverride.actorReported and 'actor' or 'override'
        _remoteMaxHP[targetName] = overrideMax
        _remoteMaxHPAt[targetName] = now
    elseif fallbackMax and fallbackMax > 100 then
        resolvedMax = fallbackMax
        maxHPKnown = true
        maxHPSource = 'self'
    elseif remoteMax and remoteMax > 100 then
        resolvedMax = remoteMax
        maxHPKnown = true
        maxHPSource = 'dannet'
    elseif spawnMax and spawnMax > 100 then
        resolvedMax = spawnMax
        maxHPKnown = true
        maxHPSource = 'spawn'
    elseif existing.maxHPKnown and existing.maxHP and existing.maxHP > 100 then
        resolvedMax = existing.maxHP
        maxHPKnown = true
        maxHPSource = existing.maxHPSource or 'cached'
    end

    if resolvedMax and resolvedMax > 0 then
        maxHP = resolvedMax
        -- If spawn returned placeholder values (100/100), calculate real currentHP from pctHP
        -- This is the key calculation: currentHP = (pctHP / 100) * maxHP
        if currentHP <= 100 then
            currentHP = math.floor((pctHP / 100) * maxHP)
        end
    elseif maxHP <= 100 and currentHP <= 100 then
        -- Untargeted PCs commonly expose placeholder 100/100 values. Reuse a
        -- previously resolved maximum when possible, otherwise use the
        -- configurable estimate so pctHP still produces a meaningful deficit.
        maxHP = (Config and Config.defaultRemoteMaxHP) or 100000
        maxHPKnown = false
        maxHPSource = 'estimate'
        currentHP = math.floor(maxHP * pctHP / 100)
    end

    local dead = healthOverride.dead == true
        or safeBool(function() return spawn.Dead and spawn.Dead() end, false)
        or pctHP <= 0
    local hovering = healthOverride.hovering == true
        or safeBool(function() return spawn.Hovering and spawn.Hovering() end, false)
    local distance3D = tonumber(spawn.Distance3D and spawn.Distance3D()) or 0
    local lineOfSight = safeBool(function()
        return not spawn.LineOfSight or spawn.LineOfSight()
    end, true)

    local deficit = math.max(0, maxHP - currentHP)
    local classShort = spawn.Class and spawn.Class.ShortName and spawn.Class.ShortName() or ''
    classShort = classShort:upper()

    -- Track damage for DPS calculation using percentage changes
    -- This avoids issues when maxHP changes (e.g., DanNet kicking in)
    local recentDamage = existing.recentDamage or {}
    local prevPctHP = existing.pctHP or pctHP

    -- Only record damage if HP% dropped (not when maxHP changed causing currentHP to jump)
    if pctHP < prevPctHP then
        -- Calculate actual damage based on current maxHP
        local pctDrop = prevPctHP - pctHP
        local dmg = math.floor((pctDrop / 100) * maxHP)
        if dmg > 0 then
            table.insert(recentDamage, { time = now, amount = dmg })
        end
    end

    -- Prune old damage entries
    local cutoff = now - (DAMAGE_WINDOW_SEC * 1000)
    local newDamage = {}
    for _, entry in ipairs(recentDamage) do
        if entry.time >= cutoff then
            table.insert(newDamage, entry)
        end
    end
    recentDamage = newDamage

    -- Calculate DPS from HP delta window
    local totalDamage = 0
    for _, entry in ipairs(recentDamage) do
        totalDamage = totalDamage + entry.amount
    end
    local windowDurationSec = math.max(1, #recentDamage > 0 and ((now - recentDamage[1].time) / 1000) or DAMAGE_WINDOW_SEC)
    local hpDeltaDps = totalDamage / windowDurationSec

    -- Get log-based DPS
    local logDps = 0
    local dp = getDamageParser()
    if dp and dp.getLogDps then
        logDps = dp.getLogDps(spawnId)
    end

    -- Get attribution data if available
    local da = getDamageAttribution()
    local attrInfo = da and da.getTargetDamageInfo(spawnId) or nil
    local validation = da and da.validateDps(spawnId, hpDeltaDps) or nil

    -- Use attributed DPS when reliable, fall back to weighted combo when drifting
    local combinedDps
    if validation and validation.isReliable then
        combinedDps = attrInfo.totalDps
    else
        -- Fall back to weighted combo
        local hpDpsWeight = (Config and Config.hpDpsWeight ~= nil) and Config.hpDpsWeight or 0.6
        local attrDps = attrInfo and attrInfo.totalDps or logDps
        combinedDps = (hpDeltaDps * hpDpsWeight) + (attrDps * (1 - hpDpsWeight))
    end

    -- Actor snapshots contain real CurrentHP/MaxHP values even when local
    -- Spawn members expose placeholder 100/100. Preserve their rolling DPS
    -- across the subsequent local group scan and never dilute it by weighting
    -- it against a missing combat-log source.
    local actorDps = tonumber(healthOverride.actorDps)
    local actorDpsAt = tonumber(healthOverride.actorDpsAt)
    if actorDps == nil and existing.actorDpsAt
        and (now - existing.actorDpsAt) <= (DAMAGE_WINDOW_SEC * 1000) then
        actorDps = tonumber(existing.actorDps) or 0
        actorDpsAt = existing.actorDpsAt
    end
    if actorDps and actorDps > combinedDps then
        combinedDps = actorDps
    end

    -- Statistical burst detection
    local burstDetected = false
    if dp and dp.checkBurst then
        burstDetected = dp.checkBurst(spawnId, combinedDps)
    end

    local data = {
        id = spawnId,
        name = spawn.CleanName() or spawn.Name() or 'Unknown',
        class = classShort,
        role = roleOverride or getRole(spawn),
        isSquishy = isSquishy(classShort),

        currentHP = currentHP,
        maxHP = maxHP,
        maxHPKnown = maxHPKnown,
        maxHPSource = maxHPSource,
        pctHP = pctHP,
        deficit = deficit,
        dead = dead,
        hovering = hovering,
        distance3D = distance3D,
        lineOfSight = lineOfSight,
        actorReported = healthOverride.actorReported == true,

        recentDamage = recentDamage,
        recentDps = combinedDps,
        actorDps = actorDps or 0,
        actorDpsAt = actorDpsAt or 0,
        hpDeltaDps = hpDeltaDps,
        logDps = logDps,
        burstDetected = burstDetected,

        -- Attribution data
        sourceCount = attrInfo and attrInfo.sourceCount or 0,
        isMultiSource = attrInfo and attrInfo.isMultiSource or false,
        isInAE = attrInfo and attrInfo.isInAE or false,
        dpsValidation = validation,

        -- Placeholders for incoming heal tracking
        incomingTotal = existing.incomingTotal or 0,
        effectiveDeficit = deficit - (existing.incomingTotal or 0),

        activeHoTs = existing.activeHoTs or {},
        incomingHoTRemaining = existing.incomingHoTRemaining or 0,

        lastUpdate = now,
    }

    _targets[spawnId] = data
    return data
end

--- Merge health snapshots reported by SideKick peers in the same zone.
--- A local Spawn is still required because the character must be targetable.
function M.updateActorTargets(remoteCharacters)
    if type(remoteCharacters) ~= 'table' then return end
    local now = mq.gettime()
    if (now - _lastActorScan) < 100 then return end
    _lastActorScan = now
    local myZone = tostring(mq.TLO.Zone and mq.TLO.Zone.ShortName and mq.TLO.Zone.ShortName() or '')
    local myId = tonumber(mq.TLO.Me.ID()) or 0
    for _, remote in pairs(remoteCharacters) do
        local spawnId = tonumber(remote.id) or 0
        local sameZone = myZone ~= '' and tostring(remote.zone or '') == myZone
        if sameZone and spawnId > 0 and spawnId ~= myId then
            local spawn = mq.TLO.Spawn(spawnId)
            if spawn and spawn() then
                local currentHP = tonumber(remote.currentHP) or 0
                local maxHP = tonumber(remote.maxHP) or 0
                local pctHP = tonumber(remote.hp) or tonumber(spawn.PctHPs()) or 100
                local history = _actorDamage[spawnId] or { samples = {} }

                local damage = 0
                if currentHP > 0 and history.lastCurrentHP and history.lastCurrentHP > currentHP
                    and maxHP > 100 and history.lastMaxHP == maxHP then
                    damage = history.lastCurrentHP - currentHP
                elseif maxHP > 100 and history.lastPctHP and history.lastPctHP > pctHP then
                    damage = math.floor(((history.lastPctHP - pctHP) / 100) * maxHP)
                end
                if damage > 0 then
                    table.insert(history.samples, { time = now, amount = damage })
                end

                local cutoff = now - (DAMAGE_WINDOW_SEC * 1000)
                local samples = {}
                local totalDamage = 0
                for _, sample in ipairs(history.samples or {}) do
                    if sample.time >= cutoff then
                        table.insert(samples, sample)
                        totalDamage = totalDamage + sample.amount
                    end
                end
                history.samples = samples
                history.lastCurrentHP = currentHP > 0 and currentHP or history.lastCurrentHP
                history.lastMaxHP = maxHP > 0 and maxHP or history.lastMaxHP
                history.lastPctHP = pctHP
                history.lastAt = now
                _actorDamage[spawnId] = history

                local windowSec = math.max(1,
                    #samples > 0 and ((now - samples[1].time) / 1000) or DAMAGE_WINDOW_SEC)
                local actorDps = totalDamage / windowSec
                updateTargetData(spawnId, spawn, remote.role, {
                    currentHP = currentHP,
                    maxHP = maxHP,
                    pctHP = pctHP,
                    dead = remote.dead,
                    hovering = remote.hovering,
                    actorReported = true,
                    actorDps = actorDps,
                    actorDpsAt = now,
                })
            end
        end
    end

    for spawnId, history in pairs(_actorDamage) do
        if (now - (history.lastAt or 0)) > (DAMAGE_WINDOW_SEC * 2000) then
            _actorDamage[spawnId] = nil
        end
    end
end

function M.tick()
    -- Use mq.gettime() for wall-clock accuracy (os.clock() can drift).
    -- Returns milliseconds — the throttle threshold below must also be in ms.
    local now = mq.gettime()

    -- Full scan every 100ms (was `< 0.1`, which treated a 100ms threshold as
    -- 0.1ms and effectively disabled throttling — the full group scan ran
    -- every frame).
    if (now - _lastFullScan) < 100 then return end
    _lastFullScan = now

    local me = mq.TLO.Me
    if not me or not me() then return end

    -- Track self
    updateTargetData(me.ID(), me)

    -- Track group members
    local groupCount = tonumber(mq.TLO.Group.Members()) or 0
    for i = 1, groupCount do
        local member = mq.TLO.Group.Member(i)
        if member and member() and member.ID then
            local spawnId = member.ID()
            if spawnId and spawnId > 0 then
                local spawn = mq.TLO.Spawn(spawnId)
                if spawn and spawn() then
                    updateTargetData(spawnId, spawn)
                else
                    updateTargetData(spawnId, member)
                end
            end
        end
    end

    -- Track group pets if enabled (scope: group + pets only, not XTarget/raid)
    if Config and Config.healPetsEnabled then
        local petMinPct = Config.petHealMinPct or 40
        -- Check my pet
        local myPet = mq.TLO.Me.Pet
        if myPet and myPet() and myPet.ID() > 0 then
            local pctHP = tonumber(myPet.PctHPs()) or 100
            if pctHP < petMinPct then
                updateTargetData(myPet.ID(), myPet, 'pet')
            else
                _targets[myPet.ID()] = nil -- recovered pets must not retain emergency HP
            end
        end
        -- Check group member pets
        local groupSize = tonumber(mq.TLO.Group.Members()) or 0
        for i = 1, groupSize do
            local member = mq.TLO.Group.Member(i)
            if member and member() then
                local pet = member.Pet
                if pet and pet() and pet.ID() > 0 then
                    local pctHP = tonumber(pet.PctHPs()) or 100
                    if pctHP < petMinPct then
                        updateTargetData(pet.ID(), pet, 'pet')
                    else
                        _targets[pet.ID()] = nil
                    end
                end
            end
        end
    end

    -- Prune stale targets (not seen in 5 seconds).
    local staleThreshold = now - 5000
    for id, data in pairs(_targets) do
        if data.lastUpdate < staleThreshold then
            _targets[id] = nil
        end
    end
end

function M.getPriority(target)
    if not target then return 99 end

    local emergencyPct = Config.getEmergencyPct()

    if target.role == 'pet' then return 6 end  -- Even an emergency pet follows every player
    if target.pctHP < emergencyPct then return 1 end  -- Emergency
    if target.role == 'tank' then return 2 end
    if target.role == 'healer' then return 3 end
    if target.isSquishy then return 4 end
    return 5  -- Non-squishy DPS
end

function M.getInjuredTargets(maxPctHP)
    maxPctHP = maxPctHP or 100
    local injured = {}
    for _, target in pairs(_targets) do
        if target.pctHP < maxPctHP and target.deficit > 0 then
            table.insert(injured, target)
        end
    end
    -- Sort by priority then by HP%
    table.sort(injured, function(a, b)
        local pa, pb = M.getPriority(a), M.getPriority(b)
        if pa ~= pb then return pa < pb end
        return a.pctHP < b.pctHP
    end)
    return injured
end

function M.updateIncoming(targetId, incomingTotal)
    local target = _targets[targetId]
    if target then
        target.incomingTotal = incomingTotal or 0
        target.effectiveDeficit = target.deficit - target.incomingTotal
    end
end

return M
