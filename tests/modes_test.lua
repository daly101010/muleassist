-- luajit tests/modes_test.lua   (from lua/muleassist): kill order, mark assist, manual, get away, the lists, raid mode, XTarTanks
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
local Modes = require('modules.modes')
local Raid = require('modules.raid')
local Pet = require('modules.pet')
local Heals = require('modules.heals')
local Rez = require('modules.rez')

local data = { ['MuleAssist_srv_Bob.ini'] = {
    General = { MainAssist = 'Bob', CampRadius = '30' },
    Melee = { MeleeDistance = '30', KillOrderMaxDist = '300', AssistRange = '200' },
    Heals = { XTarHeal = '0', XTarTanks = '0' },
} }
Ini.use(Ini.tableBackend(data))
Config.iniFile = 'MuleAssist_srv_Bob.ini'
Config.condFile = Config.iniFile
Config.rankFn = function(n) return n end
Config.zoneId = function() return 100 end
Timers.setClock(function() return mq.now end)
local function tick(ms) mq.now = (mq.now or 0) + (ms or 500) T.xtargetReset() end
local w = World.build(mq, {
    dannet = true, nav = true, peers = 'Bob|Tank|Zed', me = { class = 'WAR', x = 0, y = 0 }, groupN = 1,
    group = { [0] = { id = 1, name = 'Bob', class = 'WAR' }, [1] = { id = 5, name = 'Tank', class = 'CLR' } },
})
w.spawns[1] = { id = 1, name = 'Bob', type = 'PC', dist = 0 }
w.spawns[5] = { id = 5, name = 'Tank', type = 'PC', dist = 15, x = 10, y = 10 }
w.spawns[9] = { id = 9, name = 'a rat', type = 'NPC', dist = 20, hp = 100, level = 50 }
w.spawns[10] = { id = 10, name = 'a bat', type = 'NPC', dist = 25, hp = 100, level = 52 }
w.spawns[21] = { id = 21, name = 'a guard', type = 'NPC', dist = 120, hp = 100 }
State.role = 'tank'
State.mainAssist, State.mainAssistType = 'Bob', 'PC'
for _, m in ipairs({ Heals, Rez, Combat, Modes, Raid }) do m:Init() end
for _, m in ipairs({ Heals, Rez, Combat, Modes, Raid }) do m:LoadSettings() end
State.mainAssistId = 1

-- ------------------------------------------------------------- kill order on the MA
do
    mq.cmds = {}
    Modes.Binds['/killorder'](Modes, 'add', '9')
    Modes.Binds['/killorder'](Modes, 'add', '10')
    Modes.Binds['/killorder'](Modes, 'add', 'a', 'cat')
    assert(#Modes.ko.list == 3 and Modes.ko.list[3].name == 'a cat', 'queued two ids and a waiting name: ' .. #Modes.ko.list)
    Modes.Binds['/killorder'](Modes, 'on')
    assert(State.killOrderOn and World.count(mq, 'KILLORDER%-> on %(3 mobs%)') == 1, 'on and announced: ' .. table.concat(mq.cmds, ';'))
    assert(Modes:koPick() == 9 and State.killOrderTarget == 9, 'the rat first')
    Timers.set('kounreach:9', 10000)
    assert(Modes:koPick() == 10, 'an unreachable mob is skipped: ' .. tostring(State.killOrderTarget))
    Timers.clear('kounreach:9')
    Modes.Binds['/killorder'](Modes, 'del', '9')
    assert(#Modes.ko.list == 2 and Modes:koPick() == 10, 'deleted')
    -- the waiting name resolves when a live one is within range
    w.spawns[11] = { id = 11, name = 'a cat', type = 'NPC', dist = 50, hp = 100 }
    Modes.Binds['/killorder'](Modes, 'del', '10')
    assert(Modes:koPick() == 11 and Modes.ko.list[1].id == 11, 'the cat is up: ' .. tostring(State.killOrderTarget))
    w.spawns[11].type = 'Corpse'
    mq.cmds = {}
    assert(Modes:koPick() == 0 and not State.killOrderOn and World.count(mq, 'KILLORDER%-> done') == 1, 'queue empty: back to normal')
    -- a follower forwards to the MA
    State.mainAssist = 'Tank'
    mq.cmds = {}
    Modes.Binds['/killorder'](Modes, 'add', '9')
    assert(World.count(mq, '^/squelch /dex Tank /killorder add 9') == 1, 'forwarded: ' .. table.concat(mq.cmds, ';'))
    State.mainAssist = 'Bob'
end

-- ------------------------------------------------------------- the macro-variable view MALua reads (${MuleAssist.Var[Name]})
do
    local Vars = require('core.vars')
    local saved = Modes.ko.list
    Modes.ko.list = { { id = 9 }, { name = 'a cat' } }
    State.killOrderOn, State.killOrderTarget, State.manualOn, State.chaseAssist = true, 9, false, true
    assert(Vars.get('KillOrderList') == '|9|~a cat|', 'the macro list format: ' .. tostring(Vars.get('KillOrderList')))
    assert(Vars.get('KillOrderOn') == '1' and Vars.get('KillOrderTarget') == '9' and Vars.get('ManualOn') == '0', 'flags as 0/1')
    assert(Vars.get('ChaseAssist') == '1' and Vars.get('Role') == State.role and Vars.get('KillOrderMaxDist') == '300', 'scalars')
    assert(Vars.get('NoSuchVar') == nil, 'unknown names read as NULL')
    Modes.ko.list = {}
    assert(Vars.get('KillOrderList') == '|', 'empty list is the macro sentinel')
    Modes.ko.list = saved
    State.killOrderOn, State.killOrderTarget, State.chaseAssist = false, 0, false
end

-- ------------------------------------------------------------- the mode target resets touch the DPS timers only
do
    local dps, pull = false, false
    Combat.addResetHook('dps', function() dps = true end)
    Combat.addResetHook('pull', function() pull = true end)
    Modes.hooks.resetDPS('Mark')
    assert(dps and not pull, 'DPSTimerReset: the dps hook only')
    Combat.resetHooks.dps, Combat.resetHooks.pull = nil, nil
end

-- ------------------------------------------------------------- mark assist
do
    Modes.Binds['/markassist'](Modes, 'on', '2')
    assert(State.markAssistOn and State.raidMarkNum == 2, 'mark on 2')
    w.xtargets = { 9, 10 }
    w.marks.raid[2] = 10
    State.mobCount = 2
    tick()
    mq.cmds = {}
    local id = Modes:markAssistPick()
    assert(id == 10 and State.myTargetId == 10 and World.count(mq, '/target id 10') >= 1, 'the raid mark 2 is the target: ' .. tostring(id))
    assert(World.count(mq, 'TANKING') == 0, 'the first engage is announced by the fight, not here')
    -- the mark moves to a PC: a get away starts on the marked player
    w.marks.raid[2] = 5
    tick()
    mq.cmds = {}
    assert(Modes:markAssistPick() == 0 and State.getAwayOn and Modes.getAway.src == 'mark', 'a mark on a player starts a get away')
    w.marks.raid[2] = 0
    Modes:getAwayTick()
    assert(not State.getAwayOn, 'the mark moved off the player: get away ends')
    Modes.Binds['/markassist'](Modes, 'off')
    assert(not State.markAssistOn, 'mark off')
    w.xtargets = {}
    State.mobCount = 0
    State.myTargetId = 0
end

-- ------------------------------------------------------------- manual mode on the MA, manual follow on a follower
do
    mq.cmd('/target id 9')
    mq.cmds = {}
    Modes.Binds['/manual'](Modes, 'on')
    assert(State.manualOn and State.myTargetId == 9, 'holding the rat')
    assert(World.count(mq, '^/squelch /dex Tank /manualma on 9 0 Bob 100') == 1, 'sent to the follower: ' .. table.concat(mq.cmds, ';'))
    mq.cmd('/attack on')
    tick(2500)
    mq.cmds = {}
    Modes:manualTick()
    assert(World.count(mq, '/manualma on 9 1 Bob 100') == 1, 'attack on travels: ' .. table.concat(mq.cmds, ';'))
    mq.cmd('/attack off')
    Modes.Binds['/manual'](Modes, 'off')
    assert(not State.manualOn and World.count(mq, '/manualma off') == 1, 'off')
    mq.cmd('/target clear')
    -- the follower side
    State.role = 'assist'
    State.mainAssist = 'Tank'
    Modes.Binds['/manualma'](Modes, 'on', '9', '1', 'Tank', '100')
    assert(State.manualMAOn and State.manualMATarget == 9 and State.manualMAAttack, 'following')
    mq.cmds = {}
    Modes:followTick()
    assert(State.myTargetId == 9 and World.count(mq, '/target id 9') == 1, 'adopted the MA target: ' .. tostring(State.myTargetId))
    Modes.Binds['/manualma'](Modes, 'on', '9', '1', 'Other', '100')
    assert(State.manualMATarget == 9, 'only my MA is followed')
    tick(6000)
    Modes:followTick()
    assert(not State.manualMAOn, 'the lease expired: follow cleared, the normal pick takes over')
    State.myTargetId = 0
    State.role = 'tank'
    State.mainAssist = 'Bob'
end

-- ------------------------------------------------------------- get away
do
    State.myTargetId = 9
    mq.cmd('/attack on')
    mq.cmds = {}
    Modes.Binds['/getaway'](Modes, '')
    assert(State.getAwayOn and not State.getAwayFollow and State.myTargetId == 0, 'the MA disengages')
    assert(World.count(mq, '/attack off') >= 1 and World.count(mq, '^/squelch /dex Tank /getaway go Bob 100') == 1, 'followers told: ' .. table.concat(mq.cmds, ';'))
    mq.cmds = {}
    Modes.Binds['/getaway'](Modes, '')
    assert(not State.getAwayOn and World.count(mq, '/getaway end Bob 100') == 1, 'ended and released')
    -- a follower near the mob runs to the MA
    State.role = 'assist'
    State.mainAssist = 'Tank'
    State.myTargetId = 9
    w.spawns[5].dist = 40
    mq.cmds = {}
    Modes.Binds['/getaway'](Modes, 'go', 'Tank', '100')
    assert(State.getAwayOn and State.getAwayFollow, 'following the MA')
    Modes:getAwayTick()
    assert(World.count(mq, '^/squelch /nav id 5 distance=15') == 1, 'running to the MA: ' .. table.concat(mq.cmds, ';'))
    Modes.Binds['/getaway'](Modes, 'end', 'Tank', '100')
    assert(not State.getAwayOn, 'released')
    w.spawns[5].dist = 15
    State.role = 'tank'
    State.mainAssist = 'Bob'
end

-- ------------------------------------------------------------- get away: bards (medley backs off itself)
do
    w.peers = 'Bob|Tank|Zed|Lyra'
    w.spawns[7] = { id = 7, name = 'Lyra', type = 'PC', class = 'BRD', dist = 5, x = 1, y = 1 }
    -- Group.Members is fixed at build (1): the bard takes slot 1 for this block
    local slot1 = w.group[1]
    w.group[1] = { id = 7, name = 'Lyra', class = 'BRD' }
    tick()
    State.myTargetId = 9
    mq.cmds = {}
    Modes.Binds['/getaway'](Modes, '')
    assert(World.count(mq, '^/squelch /dex Lyra /mdgetaway go Bob$') == 1, 'near-mob bard told by medley bind: ' .. table.concat(mq.cmds, ';'))
    assert(World.count(mq, '/dex Lyra /getaway') == 0, 'a bard never gets the macro bind')
    mq.cmds = {}
    Modes.Binds['/getaway'](Modes, '')
    assert(World.count(mq, '^/squelch /dex Lyra /mdgetaway end Bob$') == 1, 'bard released with the MA name: ' .. table.concat(mq.cmds, ';'))
    assert(World.count(mq, '/mdassist') == 0 and World.count(mq, '/mdchaseon') == 0, 'no chase/assist rewrites')
    -- a mark on a player: medley reads marks itself, the MA sends bards nothing
    Modes.Binds['/markassist'](Modes, 'on', '1')
    w.xtargets = { 9 }
    State.mobCount = 1
    State.myTargetId = 9
    w.marks.raid[1] = 5
    tick()
    mq.cmds = {}
    Modes:markAssistPick()
    Modes:getAwayTick()
    assert(State.getAwayOn and World.count(mq, '/dex Lyra') == 0, 'no bard sends on a player mark: ' .. table.concat(mq.cmds, ';'))
    assert(Modes.markBards == nil and Modes.bardWatch == nil, 'the MA bard watch is gone')
    w.marks.raid[1] = 0
    Modes:getAwayTick()
    Modes.Binds['/markassist'](Modes, 'off')
    w.xtargets = {}
    State.mobCount = 0
    State.myTargetId = 0
    w.peers = 'Bob|Tank|Zed'
    w.spawns[7] = nil
    w.group[1] = slot1
    tick()
end

-- ------------------------------------------------------------- the protect list
do
    mq.cmds = {}
    Modes.Binds['/addprotect'](Modes, '21')
    assert(Ini.read('KissAssist_Info.ini', 'commonlands', 'MobsToProtect') == 'a guard', 'persisted: ' .. tostring(Ini.read('KissAssist_Info.ini', 'commonlands', 'MobsToProtect')))
    assert(State.mobsToProtect[1] == 'a guard' and World.count(mq, '/alert add 5 "=a guard"') == 1, 'in the list and on alert 5')
    assert(Pet.isProtected(21), 'the pet module sees it by name')
    State.myTargetId = 21
    mq.cmds = {}
    Modes:protectWatch()
    assert(State.myTargetId == 0, 'a protected kill target is dropped')
    Modes:zoneLists()
    assert(#State.mobsToProtect == 1, 'reloads from the ini')
end

-- ------------------------------------------------------------- raid mode (a WAR) and XTarTanks (a CLR)
do
    State.aeOn = true
    Raid.Binds['/raidmode'](Raid, 'on', '3')
    assert(State.raidModeOn and State.markAssistOn and State.raidMarkNum == 3 and State.aggroPaused and not State.aeOn, 'raid on: mark 3, aggro paused, AE off')
    Raid.Binds['/raidmode'](Raid, 'off')
    assert(not State.raidModeOn and not State.markAssistOn and not State.aggroPaused and State.aeOn, 'restored')
    -- a raid pauses a warrior's aggro tools by itself
    w.raid = { { name = 'Bob', class = 'WAR', group = 1 }, { name = 'Zed', class = 'WAR', group = 2 } }
    Raid:aggroRaidTick()
    assert(State.aggroPaused and Raid.aggroRaid.auto, 'in a raid: paused')
    w.raid = {}
    Raid:aggroRaidTick() tick(11000) Raid:aggroRaidTick()
    assert(not State.aggroPaused, 'left the raid: back on')
    -- XTarTanks on a cleric: the raid warrior outside my group gets an empty slot and the heal list
    World.set(mq, 'Me.Class.ShortName', 'CLR')
    w.raid = { { name = 'Bob', class = 'CLR', group = 1 }, { name = 'Zed', class = 'WAR', group = 2 } }
    w.spawns[30] = { id = 30, name = 'Zed', type = 'PC', dist = 40 }
    w.xtSlots[2] = { type = 'Empty Target', name = '' }
    mq.cmds = {}
    Raid.Binds['/xtartanks'](Raid, 'on')
    assert(State.xtarTanks and World.count(mq, '^/xtarget set 2 Zed') == 1, 'pinned Zed to slot 2: ' .. table.concat(mq.cmds, ';'))
    assert(#Raid.pins == 1 and Raid.pins[1].slot == 2 and Heals.xtarOverride == '2', 'the heal list follows: ' .. tostring(Heals.xtarOverride))
    mq.cmds = {}
    Raid.Binds['/xtartanks'](Raid, 'off')
    assert(#Raid.pins == 0 and World.count(mq, '^/xtarget remove 2') == 1 and Heals.xtarOverride == '0', 'released: ' .. table.concat(mq.cmds, ';'))
    World.set(mq, 'Me.Class.ShortName', 'WAR')
end

print('modes_test OK')
