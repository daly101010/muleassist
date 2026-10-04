-- luajit tests/med_test.lua   (from lua/muleassist)
package.path = './?.lua;./?/init.lua;' .. package.path
local Stub = require('tests.stub_mq')
local mq = Stub.new({})
local World = require('tests.world')
local Ini = require('core.ini')
local Config = require('core.config')
local Timers = require('core.timers')
local State = require('core.state')
local T = require('core.tlo')
local Med = require('modules.med')

-- GroupWatchOn forms
do
    local g = Med.parseGroupWatch('3|25|CLR,SHM', 90)
    assert(g.mode == 3 and g.pct == 25 and g.classes == 'CLR,SHM' and g.resume == 90, '3|pct|classes')
    assert(Med.parseGroupWatch('1', 90).mode == 1 and Med.parseGroupWatch('1', 90).pct == 20, 'bare 1')
    assert(Med.parseGroupWatch('2|95', 90).resume == 95, 'resume raised to the pause pct')
    assert(Med.parseGroupWatch('0', 90).mode == 0, 'off')
end

local data = { ['MuleAssist_srv_Bob.ini'] = { General = { MedOn = '1', MedStart = '20' } } }
Ini.use(Ini.tableBackend(data))
Config.iniFile = 'MuleAssist_srv_Bob.ini'
Config.condFile = Config.iniFile
Config.rankFn = function(n) return n end
Config.zoneId = function() return 0 end
local now = 0
Timers.setClock(function() return now end)
local w = World.build(mq, { me = { class = 'CLR', mana = 10 }, groupN = 2,
    group = { [0] = { id = 1, name = 'Bob', class = 'CLR' }, [1] = { id = 7, name = 'Al', class = 'CLR', sitting = true, mana = 50 }, [2] = { id = 8, name = 'Cy', class = 'WAR', sitting = true, endurance = 100 } } })
w.spawns[7] = { id = 7, name = 'Al', class = 'CLR' }
State.role = 'assist'
State.mainAssist = 'Cy'
Med:LoadSettings()

-- DoWeMed: sit under the line, stand when done, leave on XTarget without standing
do
    mq.cmds = {}
    Med:GiveTime({})
    assert(Med.medding and State.medding and World.count(mq, '/target clear') == 1, 'under MedStart: medding')
    Med:GiveTime({})
    assert(World.count(mq, '^/sit$') == 1, 'sits')
    now = now + 5000
    Med:GiveTime({})
    assert(World.count(mq, '^/sit$') == 1, 'already sitting: no second /sit')
    World.set(mq, 'Me.PctMana', 100)
    Med:GiveTime({})
    assert(not Med.medding and World.count(mq, '^/stand$') == 1, 'done: stands')
    World.set(mq, 'Me.PctMana', 10)
    now = now + 5000
    mq.cmds = {}
    Med:GiveTime({})
    assert(Med.medding, 'medding again')
    World.set(mq, 'Me.XTarget', function(i) if i then return mq.build({ TargetType = '', Type = '', ID = 0 }) end return 2 end)
    Med:GiveTime({})
    assert(not Med.medding and World.count(mq, '^/stand$') == 0, 'XTarget populated: leaves without standing')
    World.set(mq, 'Me.XTarget', function(i) if i then return mq.build({ TargetType = '', Type = '', ID = 0 }) end return 0 end)
    -- a puller with PullerNoSelfMed never sits for itself
    State.role = 'puller'
    Med.cfg.PullerNoSelfMed = 1
    Med:GiveTime({})
    assert(not Med.medding, 'PullerNoSelfMed')
    Med.cfg.PullerNoSelfMed = 0
    State.role = 'assist'
    World.set(mq, 'Me.PctMana', 100)
end

-- CountMedders
do
    Med.cfg.WaitForMeddersSkipMA = 0
    local n, first = Med:countMedders()
    assert(n == 1 and first == 'Al', 'Al sits under 100% mana; Cy is full: ' .. n)
    State.mainAssist = 'Al'
    Med.cfg.WaitForMeddersSkipMA = 2
    assert(Med:countMedders() == 0, 'SkipMA=2 skips the MA')
    Med.cfg.WaitForMeddersSkipMA = 0
    State.mainAssist = 'Cy'
end

-- WaitForMedders: sit while Al meds, stand when he is up
do
    Med.cfg.WaitForMedders = 1
    Med.cfg.WaitForMeddersMax = 300
    mq.cmds = {}
    now = now + 5000
    Med:GiveTime({})
    assert(Med.wfm and State.medding, 'waiting for medders')
    Med:GiveTime({})
    assert(World.count(mq, '^/sit$') == 1, 'sits with the medders')
    w.group[1].sitting = false
    Med:GiveTime({})
    assert(not Med.wfm and not State.medding and World.count(mq, '^/stand$') == 1, 'medders up: stands')
    -- the cap: give up and cool down
    w.group[1].sitting = true
    now = now + 5000
    mq.cmds = {}
    Med:GiveTime({})
    assert(Med.wfm, 'waiting again')
    now = now + 301000
    Med:GiveTime({})
    assert(not Med.wfm and Timers.running('med:wfmcooldown'), 'gave up after the cap, cooling down')
    Med:GiveTime({})
    assert(not Med.wfm, 'no new hold during the cooldown')
    Med.cfg.WaitForMedders = 0
    w.group[1].sitting = false
end

-- GroupWatch: hold for a member under the line, resume above GroupWatchResume
do
    Med.cfg.GroupWatchOn = '1|20'
    Med.gw = Med.parseGroupWatch('1|20', 90)
    w.group[1].mana = 10
    now = now + 400000
    mq.cmds = {}
    Med:GiveTime({})
    assert(Med.watch and Med.watch.name == 'Al' and World.count(mq, '/target id 7') == 1, 'watching Al')
    Med:GiveTime({})
    assert(World.count(mq, '^/sit$') == 1, 'sits while waiting')
    w.group[1].mana = 95
    Med:GiveTime({})
    assert(not Med.watch and World.count(mq, '^/stand$') == 1 and not State.medding, 'Al above resume: stands')
    -- a stalled stat gives up after 2 minutes (the idle group scans run once a second)
    w.group[1].mana = 10
    now = now + 1100
    Med:GiveTime({})
    assert(Med.watch, 'watching again')
    Med:GiveTime({})            -- records the baseline
    now = now + 121000
    Med:GiveTime({})
    assert(not Med.watch, 'stalled 2m: gave up')
    Med.gw = Med.parseGroupWatch('0', 90)
    w.group[1].mana = 100
end

print('med_test OK')
