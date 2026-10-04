-- Offline integration of the real selector, target monitor, HoT ledgers and
-- healing orchestrator. Only MQ and persistence/analytics dependencies are faked.
package.path = './?.lua;./?/init.lua;' .. package.path
local function noop() end
local function value(v) return function() return v end end
local function object(t, v) return setmetatable(t, { __call = value(v == nil and true or v) }) end
local now, petHP = 10000, 20
local group = {}
local function spawn(id, name, pct, role)
    return object({ ID = value(id), Name = value(name), CleanName = value(name),
        PctHPs = pct, CurrentHPs = function() return pct() * 100 end,
        MaxHPs = value(10000), Type = value(role or 'PC'), Distance3D = value(20),
        LineOfSight = value(true), Class = { ShortName = value('CLR') } })
end
local me = spawn(1, 'Healer', value(100))
local pet = spawn(9, 'Pet', function() return petHP end, 'Pet')
me.Pet = pet
local spells = {}
local function addSpell(name, hot)
    spells[name] = object({ Name = value(name), Mana = value(100), CastTime = value(2000),
        RecastTime = value(1000), Range = value(200), AERange = value(100),
        Duration = object({ TotalSeconds = value(hot and 18 or 0) }, hot and 3 or 0),
        Base = function() return value(hot and 100 or 4000) end,
        Calc = function() return value(hot and 100 or 4000) end,
        Subcategory = value(hot and 'Heals over Time' or 'Direct Heals'),
        HasSPA = function(spa) return value(hot and spa == 79) end })
end
addSpell('Direct', false); addSpell('Group', false)
addSpell('Hot', true); addSpell('GroupHot', true); addSpell('Hot Rk. II', true)
me.Book = function() return value(true) end
me.SpellReady = function() return value(true) end
me.CurrentMana = value(10000)
me.Buff = function() return object({}, false) end
me.Song = me.Buff
local mq = { gettime = function() return now end, event = noop, unevent = noop, cmdf = noop,
    TLO = { Me = me, Time = {}, Plugin = function() return { IsLoaded = value(false) } end,
        Group = { Members = function() return #group end, Member = function(i) return group[i] end },
        Spell = function(name) return spells[name] or object({}, false) end,
        Spawn = function(id)
            if id == 1 or id == 'pc Healer' then return me end
            if id == 9 then return pet end
            return object({ ID = value(0) }, false)
        end } }
package.loaded.mq = mq
local config = { healPetsEnabled = true, petHealMinPct = 40, hotEnabled = true,
    emergencyPct = 45, minHealPct = 10, groupHealMinCount = 3,
    spells = { regular = { 'Direct' }, fast = { 'Direct' }, group = { 'Group' },
        hot = { 'Hot' }, groupHot = { 'GroupHot' } },
    getEmergencyPct = function() return 45 end,
    load = noop, HasConfiguredSpells = value(true) }
local tracker = { init = noop, recordHeal = noop,
    getExpected = function(name) return name:find('Hot') and 100 or 4000 end }
local incomingCount, castCount = 0, 0
local incoming = { init = noop, sumForTarget = value(0),
    registerMyCast = function() incomingCount = incomingCount + 1 end }
local analytics = { init = noop, recordHotCast = function() castCount = castCount + 1 end }
local combat = { init = noop, getState = value({}) }
local logger = setmetatable({}, { __index = function() return noop end })
for name, module in pairs({ config = config, heal_tracker = tracker, incoming_heals = incoming,
    analytics = analytics, combat_assessor = combat, logger = logger,
    damage_parser = {}, damage_attribution = { getTargetDamageInfo = noop, validateDps = noop },
    hot_analyzer = {} }) do
    package.loaded['smartheal.' .. name] = module
end
package.loaded['smartheal.util.debug_log'] = { tagged = function() return noop end }
package.loaded['smartheal.util.actors_coordinator'] = {}
package.loaded['smartheal.util.sk_lib'] = { getSettings = value({ CombatMode = 'off' }) }

local Healing = require('smartheal')
for phase = 1, 3 do Healing.initPhased(phase) end
local TM, HS, SE = Healing.TargetMonitor, Healing.HealSelector, Healing.SpellEvents
local P = require('smartheal.proactive')
P.init(config, tracker, TM, combat)
local passed = 0
local function check(condition, description)
    assert(condition, description); passed = passed + 1
end

TM.tick()
check(TM.getTarget(9).pctHP == 20, 'injured pet is tracked')
petHP = 100; now = now + 200; TM.tick()
check(TM.getTarget(9) == nil, 'recovered pet is removed immediately, not after five seconds')
check(TM.getPriority({ role = 'pet', pctHP = 1 }) > TM.getPriority({ role = 'dps', pctHP = 99 }),
    'critical pet ranks below any player')

local function target(id, pct, role, distance)
    return { id = id, name = 'Player' .. id, pctHP = pct, currentHP = pct * 100,
        maxHP = 10000, deficit = (100 - pct) * 100, role = role or 'dps',
        distance3D = distance or 20, lineOfSight = true, recentDps = 0 }
end
local targets = { target(2, 60), target(3, 60), target(4, 60) }
for _, t in ipairs(targets) do t.distance3D = 1000 end
check(not HS.ShouldUseGroupHeal(targets, {}), 'distant players cannot trigger group healing')
check(HS.SelectBestGroupHot(targets, 12000, 3) == nil, 'distant players cannot trigger group HoTs')
for _, t in ipairs(targets) do t.distance3D = 20 end
check(HS.ShouldUseGroupHeal(targets, {}), 'three in-range players can trigger group healing')
local hot = HS.SelectBestGroupHot(targets, 12000, 3)
check(hot and hot.targets == 3, 'three uncovered in-range players can trigger group HoT')
for _, t in ipairs(targets) do P.recordHoT(t.name, 'GroupHot', 18) end
check(HS.SelectBestGroupHot(targets, 12000, 3) == nil, 'active group HoT is not repeatedly selected')
now = now + 17000
check(HS.SelectBestGroupHot(targets, 12000, 3) ~= nil, 'group HoT can refresh in final two seconds')

SE.registerHotCast('Solo', 'Hot Rk. II', 100, 18)
P.recordHoT('Solo', 'Hot Rk. II', 18)
check(P.getIncomingHotRemaining('Solo') == 300, 'cast ledger plus active cache counts one HoT')
SE.onHealLanded('Solo', 100, 'Hot Rk. II', false, true)
check(P.getIncomingHotRemaining('Solo') == 200, 'early observed tick reduces remaining healing')
SE.registerGroupHotCast({ 'GroupMember', 'HealthyMember' }, 'GroupHot', 100, 18)
P.recordHoT('GroupMember', 'GroupHot', 18)
check(P.getIncomingHotRemaining('GroupMember') == 300, 'group cast and active cache count once')
check(SE.getIncomingHotRemaining('HealthyMember') == 300, 'healthy group recipients also have coverage')
now = now + 6000
SE.onHealLanded('GroupMember', 100, 'GroupHot', false, true)
check(P.getIncomingHotRemaining('GroupMember') == 200, 'group and observed tick ledgers count once')
now = now + 12000
check(P.getIncomingHotRemaining('GroupMember') == 0, 'observed group tick does not extend cast duration')
SE.registerGroupHotCast({ 'GroupMember' }, 'GroupHot', 100, 18)
P.recordHoT('GroupMember', 'GroupHot', 18)
check(P.getIncomingHotRemaining('GroupMember') == 300, 'group refresh replaces expired per-target tick ledger')

-- Single and group HoTs occupy one slot, even when their spell names differ.
SE.registerHotCast('Overlap', 'Hot', 400, 18)
P.recordHoT('Overlap', 'Hot', 18)
SE.registerGroupHotCast({ 'Overlap', 'Unaffected' }, 'GroupHot', 100, 18)
check(SE.getIncomingHotRemaining('Overlap') == 300, 'group replaces stronger single instead of adding healing')
check(P.getIncomingHotRemaining('Overlap') == 300, 'old single cache cannot add to new group coverage')
check(not P.ShouldRefreshHot('Overlap', 'Hot'), 'active group blocks single HoT refresh')
SE.registerHotCast('Overlap', 'Hot', 200, 18)
check(SE.getIncomingHotRemaining('Overlap') == 600, 'single replaces group for its recipient')
check(SE.getIncomingHotRemaining('Unaffected') == 300, 'single replacement leaves other group recipients intact')
check(not P.ShouldRefreshHot('Overlap', 'GroupHot'), 'active single blocks group HoT refresh')
SE.registerGroupHotCast({ 'Overlap' }, 'GroupHot', 50, 18)
check(SE.getIncomingHotRemaining('Overlap') == 150, 'later group replaces single with its own tick amount')
check(SE.getIncomingHotRemaining('Unaffected') == 300, 'partial group refresh preserves other recipients')
SE.onHealLanded('Overlap', 200, 'Hot', false, true)
check(SE.getIncomingHotRemaining('Overlap') == 400, 'observed single tick replaces group ledger')
check(P.getIncomingHotRemaining('Overlap') == 400, 'observed replacement overrides stale cached spell')
SE.onHealLanded('Overlap', 50, 'GroupHot', false, true)
check(SE.getIncomingHotRemaining('Overlap') == 100, 'observed group tick replaces single ledger')

local mixed = { target(20, 60), target(21, 60), target(22, 60), target(23, 100) }
P.recordHoT('Player23', 'Hot', 18)
check(HS.SelectBestGroupHot(mixed, 12000, 3) == nil,
    'group HoT cannot clip a healthy member single HoT to heal three others')
mixed[4].distance3D = 1000
check(HS.SelectBestGroupHot(mixed, 12000, 3) ~= nil, 'out-of-range conflicting HoT does not block group')

-- Self-buff checks must inspect both kinds, even before any cast/tick was seen.
local normalBuff = me.Buff
local buffSpell = 'GroupHot'
me.Buff = function(name)
    if name == buffSpell then
        return object({ ID = value(100), Duration = { TotalSeconds = value(12) } })
    end
    return normalBuff(name)
end
check(P.HasActiveHot('Healer'), 'self group HoT detected without a cached cast')
check(not P.ShouldRefreshHot('Healer', 'Hot'), 'self group buff blocks proposed single spell')
buffSpell = 'Hot'
check(not P.ShouldRefreshHot('Healer', 'GroupHot'), 'self single buff blocks proposed group spell')
me.Buff = normalBuff

local contextTargets = { target(1, 100), target(2, 60), target(3, 60), target(4, 60),
    target(5, 100), target(6, 60, 'dps', 1000), target(9, 5, 'pet') }
TM.getAllTargets = function() return contextTargets end
config.spells.group = {} -- allow the group HoT path to run before direct singles
local groupAction = Healing.buildHealAction({ skipIfCasting = false, pcHealPct = 90 })
check(groupAction and groupAction.tier == 'groupHot', 'critical pet does not block player group HoT')
check(#groupAction.groupHotTargets == 5 and #groupAction.groupHotTargetIds == 5,
    'group action tracks healthy recipients but excludes distant members and pets')

-- Exercise real orchestration with deterministic single-target choices.
local list = { target(2, 60, 'tank'), target(9, 5, 'pet') }
TM.getAllTargets = function() return list end
HS.ShouldUseGroupHeal = value(false)
P.ShouldApplyGroupHot = value(false)
local reason
HS.SelectHeal = function()
    if reason then return nil, reason end
    return { spell = 'Direct', expected = 4000 }
end
local opts = { skipIfCasting = false, pcHealPct = 90 }
check(Healing.buildHealAction(opts).targetId == 2, 'injured tank precedes emergency pet')
list[1].role = 'dps'
check(Healing.buildHealAction(opts).targetId == 2, 'injured DPS precedes emergency pet')
reason = 'incoming_hot_cover'
local action, why = Healing.buildHealAction(opts)
check(action == nil and why == 'no_heal_needed', 'intentional HoT wait neither heals pet nor requests fallback')
reason = 'emergency_no_heal'; list[1].pctHP = 20
action, why = Healing.buildHealAction(opts)
check(action == nil and why == 'unserviceable', 'unserviceable emergency requests legacy healing')
reason = 'no_efficient_heal'; list[1].pctHP = 60
action, why = Healing.buildHealAction(opts)
check(action == nil and why == 'unserviceable', 'unserviceable nonemergency requests legacy healing')
reason = nil; list[1].distance3D = 1000
action, why = Healing.buildHealAction(opts)
check(action == nil and why == 'unserviceable', 'out-of-range player takes precedence over pet and requests fallback')
list[1] = target(2, 100)
check(Healing.buildHealAction(opts).targetId == 9, 'pet heals when players no longer need healing')
config.healPetsEnabled = false
check(Healing.buildHealAction(opts) == nil, 'disabling pet heals is honored immediately')

local beforeCast = castCount
Healing.registerHealCast({ spellName = 'GroupHot', targetId = 1, targetName = 'Healer',
    confirmedLanded = true, isHoT = true, expected = 100, hotTickAmount = 100, hotDuration = 18,
    groupHotTargets = { 'Recipient', 'HealthyRecipient' } })
check(incomingCount == 0, 'confirmed cast does not register another future heal')
check(castCount == beforeCast + 1, 'group HoT records one cast for analytics')
check(P.HasActiveHot('HealthyRecipient'), 'all group recipients get active HoT tracking')
check(P.getIncomingHotRemaining('Recipient') == 300, 'registered group cast counts once end to end')

local coordinator = package.loaded['smartheal.util.actors_coordinator']
coordinator.getHoTStates = value({ [1] = {
    A = { Hot = { spellName = 'Hot', expiresAt = os.time() + 18 } },
    B = { GroupHot = { spellName = 'GroupHot', expiresAt = os.time() + 12 } },
} })
local peerEstimate = P.getIncomingHotRemaining('Healer')
check(peerEstimate > 0 and peerEstimate <= 200, 'uncertain single/group peer records never add together')
SE.registerHotCast('Healer', 'Hot', 200, 18)
check(P.getIncomingHotRemaining('Healer') == 600, 'known active slot wins over conflicting peer estimates')

mq.TLO.Time.MillisecondsSinceEpoch = function() return 1700000000000 + now end
SE.registerGroupHotCast({ 'EpochClock' }, 'GroupHot', 100, 18)
check(not P.ShouldRefreshHot('EpochClock', 'Hot'), 'cross-kind refresh respects ledger using an epoch clock')
check(P.GetHotData('EpochClock').expireTime == now + 18000,
    'ledger duration is translated onto the MQ clock without changing expiry')
print(string.format('smartheal_regression_test: %d checks passed', passed))
