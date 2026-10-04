-- luajit tests/movement_test.lua   (from lua/muleassist)
package.path = './?.lua;./?/init.lua;' .. package.path
local Stub = require('tests.stub_mq')
local mq = Stub.new({})
local World = require('tests.world')
local Ini = require('core.ini')
local Config = require('core.config')
local Timers = require('core.timers')
local State = require('core.state')
local Cast = require('core.cast')
local Mv = require('modules.movement')

assert(Mv.leash(10) == 25 and Mv.leash(25) == 50 and Mv.leash(14) == 29 and Mv.leash(15) == 30, 'buff leash')

local data = { ['MuleAssist_srv_Bob.ini'] = { General = { ReturnToCamp = '1', CampRadius = '30', CampRadiusExceed = '400', ChaseAssist = '0', ChaseDistance = '25' } } }
Ini.use(Ini.tableBackend(data))
Config.iniFile = 'MuleAssist_srv_Bob.ini'
Config.condFile = Config.iniFile
Config.rankFn = function(n) return n end
Config.zoneId = function() return 100 end
local now = 0
Timers.setClock(function() return now end)
local w = World.build(mq, { nav = true, dannet = true, me = { x = 0, y = 0 } })
State.role = 'assist'
State.mainAssist = 'Tank'
State.mainAssistType = 'PC'
w.spawns[5] = { id = 5, name = 'Tank', type = 'PC', x = 10, y = 10, dist = 14 }
w.spawns[9] = { id = 9, name = 'a rat', type = 'NPC', x = 20, y = 0, z = 0, dist = 20 }
Mv:LoadSettings()
Mv:Init()
assert(State.returnToCamp and State.campZone == 100 and State.campX == 0, 'camp set at the start loc')
assert(Cast.hooks.chaseLagging() == false, 'hooks installed')

-- in camp / distance to camp with ReturnToCamp
do
    assert(Mv.inCamp(9) and Mv.distToCamp(9) == 20, 'rat 20 from the camp loc is in a 30 camp')
    w.spawns[9].x = 50
    assert(not Mv.inCamp(9), 'rat 50 out is not')
    assert(Mv.distToCamp(999) == 99999, 'gone spawn')
end

-- return to camp: far from camp -> a nav leg; on it -> nothing more; arrived -> done
do
    World.set(mq, 'Me.X', 60)
    mq.cmds = {}
    assert(Mv.doWeMove('test'), 'moving')
    assert(World.count(mq, '^/nav locyxz 0 0 0') == 1, 'nav back to camp: ' .. table.concat(mq.cmds, ';'))
    mq.cmds = {}
    assert(Mv.doWeMove('test') and #mq.cmds == 0, 'a running leg is left alone')
    World.set(mq, 'Me.X', 5)
    mq.cmd('/nav stop')
    mq.cmds = {}
    assert(not Mv.doWeMove('test'), 'within 11 of camp: nothing')
    -- the camp leash: an assist box 500 out gives the camp up
    World.set(mq, 'Me.X', 500)
    mq.cmds = {}
    Mv.doWeMove('test')
    assert(not State.returnToCamp, 'leash exceeded turns ReturnToCamp off')
    World.set(mq, 'Me.X', 0)
end

-- chase: follow the MA past ChaseDistance, hold inside it, left behind past the leash
do
    Mv.Binds['/chase'](Mv, 'on')
    assert(State.chaseAssist and not State.returnToCamp and State.chaseName == 'Tank', '/chase on')
    w.spawns[5].dist = 60
    mq.cmds = {}
    assert(Mv.doWeMove('test') and World.count(mq, '^/nav id 5') == 1, 'nav to the MA: ' .. table.concat(mq.cmds, ';'))
    mq.cmd('/nav stop')
    w.spawns[5].dist = 10
    mq.cmds = {}
    assert(not Mv.doWeMove('test') and #mq.cmds == 0, 'inside ChaseDistance: stay')
    assert(not Mv.chaseLagging(), 'not lagging at 10')
    w.spawns[5].dist = 60
    assert(Mv.chaseLagging(), 'lagging at 60 (leash 50)')
    -- past the leash without a mesh: left behind, broadcast once a minute
    w.spawns[5].dist = 500
    World.set(mq, 'Navigation.MeshLoaded', false)
    now = now + 30000
    mq.cmds = {}
    Mv.doWeMove('test')
    assert(State.chaseLeftBehind and World.count(mq, '^/dgt') == 1, 'left behind + broadcast')
    assert(not Mv.chaseLagging(), 'a parked box buffs as if not chasing')
    mq.cmds = {}
    Mv.doWeMove('test')
    assert(World.count(mq, '^/dgt') == 0, 'broadcast throttled')
    -- back within 80% of the leash: following again
    w.spawns[5].dist = 100
    World.set(mq, 'Navigation.MeshLoaded', true)
    mq.cmds = {}
    Mv.doWeMove('test')
    assert(not State.chaseLeftBehind and World.count(mq, '^/nav id 5') == 1, 'back in range: following')
    World.set(mq, 'Navigation.Active', true)
    mq.cmds = {}
    Mv.Binds['/chaseoff'](Mv)
    assert(not State.chaseAssist, '/chaseoff')
    assert(World.count(mq, '^/nav stop') == 1, '/chaseoff stops the running nav leg: ' .. table.concat(mq.cmds, ';'))
    World.set(mq, 'Navigation.Active', false)
end

-- run to tank: only when something hates me and is on me; nav to the MA
do
    Mv.cfg.RunToTankOn = 1
    State.role = 'assist'
    State.mainAssist = 'Tank'
    w.spawns[5] = { id = 5, name = 'Tank', type = 'PC', x = 60, y = 0, dist = 60 }
    w.spawns[9] = { id = 9, name = 'a rat', type = 'NPC', x = 5, y = 0, dist = 5, assistName = 'Bob' }
    w.xtargets = {}
    World.set(mq, 'Navigation.MeshLoaded', true)
    World.set(mq, 'Navigation.Active', false)
    mq.cmds = {}
    Mv:runToTank()
    assert(World.count(mq, '^/nav id 5') == 0, 'nothing hates me: stay')
    w.xtargets = { 9 }
    require('core.tlo').xtargetReset()
    mq.cmds = {}
    Mv:runToTank()
    assert(World.count(mq, '^/nav id 5 distance=10') == 1 and Mv.runToTankNav, 'the rat is on me: run to the tank: ' .. table.concat(mq.cmds, ';'))
    w.spawns[9].assistName = 'Tank'
    require('core.tlo').xtargetReset()
    World.set(mq, 'Navigation.Active', true)
    mq.cmds = {}
    Mv:runToTank()
    assert(World.count(mq, '^/nav stop') == 1 and not Mv.runToTankNav, 'the rat left me: stop')
    World.set(mq, 'Navigation.Active', false)
    w.xtargets = {}
    Mv.cfg.RunToTankOn = 0
    require('core.tlo').xtargetReset()
end

-- /camphere sets the camp where I stand and turns chase off
do
    World.set(mq, 'Me.X', 33)
    World.set(mq, 'Me.Y', 44)
    Mv.Binds['/camphere'](Mv, '')
    assert(State.returnToCamp and State.campX == 33 and State.campY == 44, 'camp here')
    Mv.Binds['/camphere'](Mv, 'off')
    assert(not State.returnToCamp, 'camphere off')
end

print('movement_test OK')
