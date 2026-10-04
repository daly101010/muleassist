-- luajit tests/combat_test.lua   (from lua/muleassist)
package.path = './?.lua;./?/init.lua;' .. package.path
local Stub = require('tests.stub_mq')
local mq = Stub.new({})
local World = require('tests.world')
local Ini = require('core.ini')
local Config = require('core.config')
local Timers = require('core.timers')
local State = require('core.state')
local T = require('core.tlo')
local Combat = require('modules.combat')
local Mv = require('modules.movement')
local Pet = require('modules.pet')

-- ------------------------------------------------------------- the pure rules
-- CANSTARTCOMBAT
do
    local base = { targetId = 9, targetType = 'NPC', hp = 90, dist = 20, meleeDistance = 30, assistAt = 95, campRadius = 30, still = false, reach = 14 }
    local function with(t) local f = {} for k, v in pairs(base) do f[k] = v end for k, v in pairs(t) do f[k] = v end return f end
    assert(Combat.canStartCombat(base), 'under AssistAt and inside MeleeDistance')
    assert(not Combat.canStartCombat(with({ hp = 100 })), 'full health waits for the MA')
    assert(not Combat.canStartCombat(with({ targetType = 'PC' })), 'never a PC')
    assert(not Combat.canStartCombat(with({ dist = 50 })), 'too far')
    assert(Combat.canStartCombat(with({ dist = 50, distToMA = 10, maIsPuller = false })), 'far from me but next to the MA')
    assert(not Combat.canStartCombat(with({ dist = 50, distToMA = 10, maIsPuller = true })), 'the puller MA still brings it in')
    assert(Combat.canStartCombat(with({ dist = 17, still = true, reach = 14 })), 'a parked mob within its reach * 1.3')
    assert(Combat.canStartCombat(with({ hp = 100, killOrderTarget = 9 })), 'the kill order target ignores AssistAt')
    assert(Combat.canStartCombat(with({ hp = 100, dist = 90, manualOn = true, meCombat = true })), 'manual: attack is on')
    assert(not Combat.canStartCombat(with({ targetId = 0 })), 'no target')
end

-- the MA's ranking
do
    local rat = { id = 9, named = false, level = 60, hp = 100, dist = 20, dist3d = 20, distToCamp = 20, inCamp = true }
    local bat = { id = 10, named = true, level = 62, hp = 100, dist = 10, dist3d = 10, distToCamp = 10, inCamp = true }
    local cat = { id = 11, named = false, level = 65, hp = 100, dist = 25, dist3d = 25, distToCamp = 25, inCamp = true, mezImmune = true }
    assert(Combat.rankCandidates({ rat, bat }, 30, 30) == 10, 'the named in melee range first')
    assert(Combat.rankCandidates({ rat, cat }, 30, 30) == 11, 'then the mez-immune one')
    assert(Combat.rankCandidates({ rat, { id = 12, named = false, level = 60, hp = 100, dist = 5, dist3d = 5, distToCamp = 5, inCamp = true } }, 30, 30) == 12, 'else the closest to camp')
    assert(Combat.rankCandidates({ rat, { id = 13, named = false, level = 70, hp = 100, dist = 28, dist3d = 28, distToCamp = 28, inCamp = true } }, 30, 30) == 13, 'a higher level in camp wins over the closest')
    assert(Combat.rankCandidates({ rat, { id = 14, named = false, level = 60, hp = 40, dist = 28, dist3d = 28, distToCamp = 28, inCamp = true } }, 30, 30) == 14, 'the most hurt in camp wins over the closest')
    assert(Combat.rankCandidates({}, 30, 30) == 0, 'nothing')
end

-- ------------------------------------------------------------- the world
local data = { ['MuleAssist_srv_Bob.ini'] = {
    General = { ReturnToCamp = '0', CampRadius = '30', ChaseAssist = '0', MainAssist = 'Tank', MobsToIgnore = 'NULL' },
    Melee = { MeleeOn = '1', AssistAt = '95', MeleeDistance = '30', StickHow = 'snaproll rear', FaceMobOn = '1' },
} }
Ini.use(Ini.tableBackend(data))
Config.iniFile = 'MuleAssist_srv_Bob.ini'
Config.condFile = Config.iniFile
Config.rankFn = function(n) return n end
Config.zoneId = function() return 100 end
local now = 0
Timers.setClock(function() return now end)
local function tick(ms)
    now = now + (ms or 500)
    mq.now = now
    T.xtargetReset()
end
local w = World.build(mq, { nav = true, dannet = true, me = { class = 'WAR', x = 0, y = 0 }, groupN = 1,
    group = { [0] = { id = 1, name = 'Bob', class = 'WAR' }, [1] = { id = 5, name = 'Tank', class = 'WAR' } } })
w.spawns[1] = { id = 1, name = 'Bob', type = 'PC', dist = 0 }
w.spawns[5] = { id = 5, name = 'Tank', type = 'PC', x = 10, y = 10, dist = 14 }
w.spawns[9] = { id = 9, name = 'a rat', type = 'NPC', x = 20, y = 0, dist = 20, hp = 90 }
w.spawns[10] = { id = 10, name = 'a bat', type = 'NPC', x = 10, y = 0, dist = 10, hp = 100, named = true }
w.spawns[20] = { id = 20, name = 'a corpse', type = 'Corpse', dist = 5 }
w.spawns[21] = { id = 21, name = 'a guard', type = 'NPC', dist = 120, protected = true }

State.role = 'assist'
Combat:Init()
Combat:LoadSettings()
Mv:LoadSettings()
Pet:LoadSettings()
assert(State.mainAssist == 'Tank' and State.meleeOn and State.assistAt == 95, 'settings: ' .. tostring(State.mainAssist))
assert(State.healTank == 'Tank' and State.healTankId == 5, 'the heal tank defaults to the MA')

-- ValidateTarget
do
    local ok, why = Combat:validateTarget(5)
    assert(not ok and why == 'PC', 'a PC: ' .. tostring(why))
    ok, why = Combat:validateTarget(20)
    assert(not ok and why == 'BadTargetType', 'a corpse: ' .. tostring(why))
    ok, why = Combat:validateTarget(21)
    assert(not ok and why == 'MobProtected', 'the protect list: ' .. tostring(why))
    ok, why = Combat:validateTarget(999)
    assert(not ok and why == 'NoTarget', 'gone: ' .. tostring(why))
    assert(Combat:validateTarget(9), 'a plain NPC is fine')
    State.mobsToIgnore = { 'a rat' }
    ok, why = Combat:validateTarget(9)
    assert(not ok and why == 'MobOnIgnoreList', 'ignore list: ' .. tostring(why))
    State.mobsToIgnore = {}
    State.buffMode = true
    ok, why = Combat:validateTarget(9)
    assert(why == 'BuffMode', 'buff mode')
    State.buffMode = false
end

-- ------------------------------------------------------------- a follower's fight, start to finish
do
    -- idle: nothing hates us, nothing in camp
    mq.cmds = {}
    Combat:GiveTime({})
    assert(State.myTargetId == 0 and not State.combatStart, 'idle')
    assert(State.mainAssistId == 5, 'the MA id refreshed')
    -- the rat comes in on the MA: it is on XTarget and the MA targets it
    w.xtargets = { 9 }
    w.maTarget = 9
    tick()
    mq.cmds = {}
    Combat:GiveTime({})
    assert(State.myTargetId == 9, 'copied the MA target: ' .. tostring(State.myTargetId))
    assert(World.count(mq, '^/squelch /target id 9') == 1, 'targeted it: ' .. table.concat(mq.cmds, ';'))
    assert(State.combatStart and State.attacking, 'the fight started')
    assert(World.count(mq, '^/attack on') >= 1, 'attack on: ' .. table.concat(mq.cmds, ';'))
    assert(World.count(mq, '^/stick snaproll rear id 9') == 1, 'stuck to it: ' .. table.concat(mq.cmds, ';'))
    assert(World.count(mq, '^/face fast nolook') == 1, 'faced it')
    assert(World.count(mq, 'TANKING') == 0, 'a follower does not announce TANKING')
    -- next pass: nothing new is issued
    tick()
    mq.cmds = {}
    Combat:GiveTime({})
    assert(World.count(mq, '^/attack on') == 0 and World.count(mq, '^/stick') == 0, 'a steady fight re-issues nothing: ' .. table.concat(mq.cmds, ';'))
    -- the rat dies: the fight ends with a reset
    w.spawns[9].type = 'Corpse'
    w.xtargets = {}
    tick()
    mq.cmds = {}
    Combat:GiveTime({})
    assert(State.myTargetId == 0 and not State.combatStart and not State.attacking, 'reset after the kill')
    assert(World.count(mq, '/attack off') == 1 and World.count(mq, '/target clear') == 1 and World.count(mq, '^/stick off') == 1, 'attack, target and stick cleared: ' .. table.concat(mq.cmds, ';'))
    assert(not T.bool(function() return mq.TLO.Me.Combat() end), 'attack is off in the world too')
    w.spawns[9].type = 'NPC'
end

-- the attack gate: a follower waits for AssistAt - 5 before swinging
do
    w.spawns[9].hp = 100
    w.xtargets = { 9 }
    w.maTarget = 9
    tick(2500)
    mq.cmds = {}
    Combat:GiveTime({})
    assert(State.myTargetId == 9 and not State.combatStart, 'targeted but not engaged at 100%: ' .. tostring(State.combatStart))
    assert(World.count(mq, '^/attack on') == 0, 'no attack yet')
    w.spawns[9].hp = 93
    tick()
    Combat:GiveTime({})
    assert(State.combatStart, 'engaged once the MA brought it under AssistAt')
    w.spawns[9].hp = 90
    w.spawns[9].type = 'Corpse'
    w.xtargets = {}
    tick()
    Combat:GiveTime({})
    w.spawns[9].type = 'NPC'
    assert(State.myTargetId == 0, 'cleaned up')
end

-- the TANKING event names the MA's kill target; /maswitch from the MA pauses and resumes us
do
    mq.events['ma_tanktarget1'].fn("Tank tells the group, 'TANKING-> a rat <- ID:9'", 'Tank', '9', 'a rat')
    assert(State.assistId == 9, 'assist id from the broadcast')
    mq.events['ma_tanktarget1'].fn('x', 'Someone', '10', 'a bat')
    assert(State.assistId == 9, 'only the MA sets it')
    State.assistId = 0
    Combat.Binds['/maswitch'](Combat, 'Tank', '100', 'backoff')
    assert(State.dpsPaused, 'backoff pauses dps')
    Combat.Binds['/maswitch'](Combat, 'Tank', '100', 'resume')
    assert(not State.dpsPaused, 'resume')
    Combat.Binds['/maswitch'](Combat, 'Other', '100', 'backoff')
    assert(not State.dpsPaused, 'another box cannot')
    mq.events['ma_gothit3'].fn('a rat hits YOU for 12 points of damage.', 'a rat')
    assert(State.meleeHit and Combat.hitBy == 'a rat', 'got hit')
    State.meleeHit = false
end

-- ------------------------------------------------------------- the tank picks: the named in range first, then announces
do
    State.role = 'tank'
    State.mainAssist = ''
    data['MuleAssist_srv_Bob.ini'].General.MainAssist = 'NULL'
    Combat:LoadSettings()
    assert(State.mainAssist == 'Bob' and Combat.cfg.AssistAt == 100 and State.assistAt == 100, 'a tank is its own MA at 100: ' .. State.mainAssist)
    w.spawns[9].hp, w.spawns[10].hp = 100, 100
    w.xtargets = { 9, 10 }
    w.maTarget = 0
    State.mainAssistId = 1
    tick(2500)
    mq.cmds = {}
    Combat:GiveTime({})
    assert(State.mobCount == 2, 'two in camp: ' .. State.mobCount)
    assert(State.myTargetId == 10, 'the named bat first: ' .. tostring(State.myTargetId))
    assert(State.combatStart, 'a tank engages at once')
    assert(World.count(mq, 'TANKING%-> a bat <%- ID:10') == 1, 'announced over DanNet: ' .. table.concat(mq.cmds, ';'))
    assert(World.count(mq, '^/dgt') == 1, 'the announcement went to the group chat (not /dgae)')
    -- /switchnow as the MA: hop to the other hater and tell the zone
    mq.cmds = {}
    Combat.Binds['/switchnow'](Combat, '')
    assert(State.myTargetId == 9, 'switched to the rat: ' .. tostring(State.myTargetId))
    assert(World.count(mq, '^/dgze /maswitch Bob 100 backoff') == 1 and World.count(mq, '^/dgze /maswitch Bob 100 resume') == 1, 'maswitch to the zone: ' .. table.concat(mq.cmds, ';'))
    assert(World.count(mq, 'TANKING%-> a rat <%- ID:9') == 1, 'announced the switch')
    -- all dead
    w.spawns[9].type, w.spawns[10].type = 'Corpse', 'Corpse'
    w.xtargets = {}
    tick()
    Combat:GiveTime({})
    assert(State.myTargetId == 0 and not State.combatStart, 'reset')
    w.spawns[9].type, w.spawns[10].type = 'NPC', 'NPC'
end

-- a tank with the MA's own target out of camp: OutofCampRadius
do
    w.spawns[10].dist = 80
    w.xtargets = { 10 }
    tick()
    local ok, why = Combat:validateTarget(10)
    assert(not ok and why == 'OutofCampRadius', 'out of camp: ' .. tostring(why))
    w.spawns[10].dist = 10
end

-- ------------------------------------------------------------- roles feed the movement module
do
    State.role = 'puller'
    State.mainAssist = ''
    data['MuleAssist_srv_Bob.ini'].General.MainAssist = 'Tank'
    Combat:LoadSettings()
    Mv:LoadSettings()
    assert(State.roleDefaults.returnToCamp == true and State.roleDefaults.campRadiusExceed == 550, 'puller forces ReturnToCamp and a 550 leash')
    assert(State.returnToCamp and Mv.cfg.CampRadiusExceed == 550 and not State.chaseAssist, 'movement applied them')
    State.role = 'assist'
    State.mainAssist = 'Tank'
    Combat:LoadSettings()
    Mv:LoadSettings()
end

-- ------------------------------------------------------------- HomogenizeMainTarget reads the MA's target from an observer
do
    w.peers = 'Bob|Tank'
    w.xtargets = { 9, 10 }
    w.observed = { ['Tank|MuleAssist.Target'] = '10' }
    State.myTargetId, State.myTargetName = 9, 'a rat'
    Combat.cfg.SwitchWithMA = 0
    Timers.clear('combat:hmt')
    tick()
    mq.cmds = {}
    Combat:homogenize()
    assert(World.count(mq, '^/dobserve Tank %-q "MuleAssist.Target"') == 1, 'one observer on the MA: ' .. table.concat(mq.cmds, ';'))
    assert(World.count(mq, '^/dquery') == 0, 'no blocking query')
    assert(State.myTargetId == 10, 'adopted the bat from the observed value: ' .. tostring(State.myTargetId))
    w.observed = nil
    w.xtargets = {}
    State.myTargetId, State.myTargetName = 0, ''
    require('core.observe').release('hmt')
end

-- ------------------------------------------------------------- /lua run muleassist <role> <MA>: the launch MA wins over the INI
do
    State.launchMainAssist = 'Zed'
    Combat:LoadSettings()
    assert(State.mainAssist == 'Zed', 'launch MA: ' .. tostring(State.mainAssist))
    State.launchMainAssist = nil
    Combat:LoadSettings()
    assert(State.mainAssist == 'Tank', 'back to the INI MA: ' .. tostring(State.mainAssist))
end

-- ------------------------------------------------------------- the dead and the zone
do
    mq.events['ma_imdead2'].fn('You died.')
    Combat:Tick({})
    assert(State.iAmDead, 'dead')
    State.campZone = 100
    Combat:OnZone()
    assert(not State.iAmDead, 'back in the camp zone')
end

-- [Aggro] AggroCOn: a line's condition gates it only with AggroCOn on (the macro's ConditionsOn && AggroCOn)
do
    World.build(mq, { spells = { ['Bellow'] = { tt = 'Single', dur = 0 } }, me = { aggro = 100 } })
    local Cast = require('core.cast')
    local realCast, casts = Cast.cast, {}
    Cast.cast = function(name, id, from) casts[#casts + 1] = name return 'CAST_SUCCESS' end
    State.buffMode, State.zombieMode, State.aggroPaused = false, false, false
    State.myTargetId = 0
    Combat.cfg = Combat.cfg or {}
    Combat.aggroLines = { { name = 'Bellow', pct = 50, op = '>', target = 'me', cond = 'FALSE' } }
    Combat.cfg.AggroCOn = 0
    Combat:aggroCheck()
    assert(#casts == 1, 'AggroCOn off: the FALSE condition is not read, the line fires')
    casts = {}
    Combat.cfg.AggroCOn = 1
    Combat:aggroCheck()
    assert(#casts == 0, 'AggroCOn on: the FALSE condition holds the line')
    Combat.aggroLines[1].cond = 'TRUE'
    Combat:aggroCheck()
    assert(#casts == 1, 'AggroCOn on: a TRUE condition fires')
    Cast.cast = realCast
    Combat.aggroLines, Combat.cfg.AggroCOn = {}, 0
end

-- [Rogue] BackstabSwapSync: the swap-in waits for the primary's swing line
do
    assert(Combat.weaponVerb('1H Slashing') == 'slash' and Combat.weaponVerb('Piercing') == 'pierce'
        and Combat.weaponVerb('2H Blunt') == 'crush' and Combat.weaponVerb('Hand to Hand') == 'punch'
        and Combat.weaponVerb('Shield') == nil, 'weapon type to swing verb')
    World.build(mq, {})
    World.set(mq, 'Me.Combat', true)
    local hands = { mainhand = { Type = '1H Slashing', ItemDelay = 25 }, offhand = { Type = 'Piercing', ItemDelay = 20 } }
    World.set(mq, 'InvSlot', function(slot) return mq.build({ ID = 1, Item = hands[slot] or { Type = '', ItemDelay = 0 } }) end)
    -- a live kill target
    State.myTargetId = 9
    local realSpawn = T.spawn
    T.spawn = function(id) if id == 9 then return mq.build({ ID = 9, Type = 'NPC' }) end return realSpawn(id) end
    -- the swing line arrives after three polls
    local polls, realDo = 0, mq.doevents
    mq.doevents = function(ev)
        if ev == 'ma_bsswing_slash' then
            polls = polls + 1
            if polls == 3 then Combat.rogue.swingSeen = Combat.rogue.swingVerb == 'slash' end
        end
    end
    local t0 = mq.now
    Combat:waitPrimarySwing()
    assert(polls == 3 and Combat.rogue.swingSeen, 'waited for the primary swing line')
    assert(mq.now - t0 < 2600, 'and stopped at it, not at the weapon delay')
    assert(Combat.rogue.swingVerb == nil, 'the swing watch is off after the wait')
    -- no line: gives up after the weapon delay + 0.5 s
    polls = 0
    mq.doevents = function() end
    t0 = mq.now
    Combat:waitPrimarySwing()
    assert(mq.now - t0 >= 3000 and mq.now - t0 <= 3200, 'gives up after ItemDelay + 5 tenths: ' .. (mq.now - t0))
    -- the same damage type in both hands: no wait, warned once
    hands.offhand = { Type = '1H Slashing', ItemDelay = 25 }
    t0 = mq.now
    Combat:waitPrimarySwing()
    assert(mq.now == t0 and Combat.rogue.syncWarned, 'same verb in the offhand: unsynced, warned')
    mq.doevents, T.spawn = realDo, realSpawn
    World.set(mq, 'Me.Combat', false)
    State.myTargetId = 0
end

-- get away: a /getaway taken during an aggro line's cast stops the aggro list; the attack step does nothing
-- (no stick, no attack) while it is on
do
    World.build(mq, { spells = { ['Bellow'] = { tt = 'Single', dur = 0 }, ['Roar'] = { tt = 'Single', dur = 0 } }, me = { aggro = 100 } })
    local Cast = require('core.cast')
    local realCast, casts = Cast.cast, {}
    -- a resisted line: the list moves on to the next one, unless a get away arrived during the cast
    Cast.cast = function(name) casts[#casts + 1] = name State.getAwayOn = true return 'CAST_RESIST' end
    State.buffMode, State.zombieMode, State.aggroPaused, State.getAwayOn = false, false, false, false
    State.myTargetId = 0
    Combat.cfg.AggroCOn = 0
    Combat.aggroLines = {
        { name = 'Bellow', pct = 50, op = '>', target = 'me', cond = 'TRUE' },
        { name = 'Roar', pct = 50, op = '>', target = 'me', cond = 'TRUE' },
    }
    Combat:aggroCheck()
    assert(#casts == 1 and casts[1] == 'Bellow', 'aggro list stops after the get away: ' .. table.concat(casts, ','))
    Cast.cast = realCast
    Combat.aggroLines = {}

    -- the attack step during a get away: no stick, no /attack
    local w = World.build(mq, {})
    w.spawns[9] = { id = 9, name = 'a rat', type = 'NPC', dist = 10, hp = 50 }
    w.xtargets = { 9 }
    State.getAwayOn, State.myTargetId, State.combatStart = true, 9, true
    mq.cmds = {}
    assert(Combat:attackPass(9) == false, 'attack pass ends at once')
    assert(World.count(mq, '/stick') == 0 and World.count(mq, '/attack on') == 0, 'no stick / attack: ' .. table.concat(mq.cmds, ';'))
    State.getAwayOn, State.myTargetId, State.combatStart = false, 0, false
end

print('combat_test OK')
