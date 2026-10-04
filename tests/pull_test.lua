-- luajit tests/pull_test.lua   (from lua/muleassist): the pull range, the scan, validation and the skip set,
-- a cast pull with the walk home, the chain probe, the pull arc and the binds
package.path = './?.lua;./?/init.lua;' .. package.path
local Stub = require('tests.stub_mq')
local mq = Stub.new({})
local World = require('tests.world')
local Ini = require('core.ini')
local Config = require('core.config')
local Timers = require('core.timers')
local State = require('core.state')
local Spell = require('core.spell')
local Cast = require('core.cast')
local T = require('core.tlo')
local Heals = require('modules.heals')
local Rez = require('modules.rez')
local HA = require('modules.healeraggro')
local Combat = require('modules.combat')
local Mv = require('modules.movement')
local Pet = require('modules.pet')
local Pull = require('modules.pull')

local data = { ['MuleAssist_srv_Bob.ini'] = {
    General = { MainAssist = 'Bob', CampRadius = '30', ReturnToCamp = '1', CampRadiusExceed = '400', ChaseAssist = '0', MedOn = '0' },
    Melee = { MeleeDistance = '30', AssistRange = '200' },
    Pull = { PullWith = 'Pull Spell', MaxRadius = '350', MaxZRange = '50', PullWait = '5', ChainPull = '0', ChainPullHP = '90', PullLevel = '0|0' },
    Heals = { XTarHeal = '0' },
} }
Ini.use(Ini.tableBackend(data))
Config.iniFile = 'MuleAssist_srv_Bob.ini'
Config.condFile = Config.iniFile
Config.rankFn = function(n) return n end
Config.zoneId = function() return 100 end
Timers.setClock(function() return mq.now end)
local function tick(ms) mq.now = (mq.now or 0) + (ms or 500) T.xtargetReset() end
local w = World.build(mq, {
    dannet = true, nav = true, peers = 'Bob|Zed', me = { class = 'SHM', x = 0, y = 0, curMana = 5000, aggro = 10 }, groupN = 0,
    spells = { ['Pull Spell'] = { st = 'Detrimental', tt = 'Single', range = 200, dur = 0, castMs = 1000, mana = 10, pulls = true } },
    gems = { [1] = 'Pull Spell' },
    group = { [0] = { id = 1, name = 'Bob', class = 'SHM' } },
})
w.spawns[1] = { id = 1, name = 'Bob', type = 'PC', dist = 0 }
w.spawns[9] = { id = 9, name = 'a rat', type = 'NPC', dist = 100, hp = 100, level = 50, x = 100, y = 0 }
Spell.clearCache()
State.role = 'puller'
State.mainAssist, State.mainAssistType = 'Bob', 'PC'
Cast.LoadSettings()
Cast.registerEvents()
for _, m in ipairs({ Heals, Rez, HA, Combat, Mv, Pet, Pull }) do m:Init() end
for _, m in ipairs({ Heals, Rez, HA, Combat, Mv, Pet, Pull }) do m:LoadSettings() end
State.mainAssistId = 1
assert(State.returnToCamp and State.campX == 0 and State.campY == 0, 'camp at the start loc')

-- ------------------------------------------------------------- the pull range from PullWith
do
    Pull:setPullRange(1)
    assert(Pull.pullType == 'Pull Spell' and Pull.pullRange == 180, 'a spell pull: range / 1.11 -> ' .. tostring(Pull.pullRange))
    Pull.cfg.PullWith = 'Melee'
    Pull:setPullRange(1)
    assert(Pull.pullType == 'Melee' and Pull.pullRange == 15, 'melee is 15')
    Pull.cfg.PullWith = 'Pull Spell'
end

-- ------------------------------------------------------------- the pull arc
do
    Pull.Binds['/setpullarc'](Pull, '90', 's')
    assert(Pull.cfg.PullArcWidth == '90' and Pull.arc.l == 135 and Pull.arc.r == 225, 'south arc: ' .. Pull.arc.l .. '-' .. Pull.arc.r)
    assert(Pull:mobInArc(9), 'the rat (south of camp in the fixture) is in a south arc')
    Pull.Binds['/setpullarc'](Pull, '90', 'n')
    assert(Pull.arc.l == 315 and Pull.arc.r == 45, 'a north arc wraps: ' .. Pull.arc.l .. '-' .. Pull.arc.r)
    assert(not Pull:mobInArc(9), 'and the rat is outside it')
    assert(not Pull:pullValidate(9, 1, false), 'PullValidate honours the arc')
    Pull.Binds['/setpullarc'](Pull, '0')
    assert(Pull.cfg.PullArcWidth == '0', 'arc off')
end

-- ------------------------------------------------------------- a mob that is not at full health is not pulled; PullWait holds the next scan
do
    w.spawns[9].hp = 90
    tick()
    mq.cmds = {}
    Pull:findMobToPull(1)
    assert(World.count(mq, '^/cast') == 0, 'no pull on a hurt mob: ' .. table.concat(mq.cmds, ';'))
    assert(Timers.running('pull:wait') and World.count(mq, 'PULLING%-> Waiting') == 0, 'a dry scan: the 1 s rescan wait, no announce yet: ' .. table.concat(mq.cmds, ';'))
    assert(Pull.failCounter == 1, 'one failed scan')
    mq.cmds = {}
    Pull:GiveTime({ inCombat = false })
    assert(World.count(mq, '^/cast') == 0 and Pull.failCounter == 1, 'GiveTime waits out the rescan timer')
    -- the third dry scan in a row (FailMax) announces the PullWait respawn wait
    for _ = 1, 2 do Timers.clear('pull:wait') tick() Pull:findMobToPull(1) end
    assert(World.count(mq, 'PULLING%-> Waiting 5 seconds') == 1 and Pull.failCounter == 0 and Timers.left('pull:wait') > 1000, 'FailMax: the respawn wait: ' .. table.concat(mq.cmds, ';'))
    Timers.clear('pull:wait')
    w.spawns[9].hp = 100
    mq.cmd('/squelch /target clear')
end

-- ------------------------------------------------------------- a stranger next to the mob puts it in the skip set; three dry scans clear the set
do
    w.spawns[30] = { id = 30, name = 'Stranger', type = 'PC', dist = 100, x = 105, y = 0 }
    tick()
    mq.cmds = {}
    Pull:findMobToPull(1)
    assert(World.count(mq, '^/cast') == 0, 'no pull with a stranger on it: ' .. table.concat(mq.cmds, ';'))
    assert(Timers.running('pull:skip:9'), 'the rat is skipped')
    assert(not State.pulling and State.myTargetId == 0, 'pull state cleared')
    assert(Pull.failCounter == 1, 'the rejected scan counts as a failure: ' .. Pull.failCounter)
    w.spawns[30] = nil
    tick()
    Timers.clear('pull:wait')
    mq.cmds = {}
    Pull:findMobToPull(1)
    assert(World.count(mq, '^/cast') == 0 and Timers.running('pull:skip:9'), 'the skipped rat is not pulled on the next scan')
    tick()
    Timers.clear('pull:wait')
    Pull:findMobToPull(1)
    -- the third failure in a row (FailMax) clears the skip set
    assert(Pull.failCounter == 0 and not Timers.running('pull:skip:9'), 'FailMax clears the skip set: ' .. Pull.failCounter .. ' ' .. tostring(Timers.running('pull:skip:9')))
    Timers.clearPrefix('pull:skip:')
    Timers.clear('pull:wait')
    Pull.failCounter = 0
    mq.cmd('/squelch /target clear')
end

-- ------------------------------------------------------------- a cast pull: the rat is pulled, then we walk home and wait for it to arrive
do
    tick()
    mq.cmds = {}
    w.xtargets = {}
    local delays = 0
    mq.onDelay = function()
        delays = delays + 1
        -- once the rat is on XTarget it runs to camp: a few delays later it is next to us
        if #w.xtargets > 0 and delays > 20 then w.spawns[9].x = 5 w.spawns[9].dist = 5 end
    end
    Pull:findMobToPull(1)
    mq.onDelay = nil
    assert(World.count(mq, '^/cast "Pull Spell"') == 1, 'the pull cast: ' .. table.concat(mq.cmds, ';'))
    assert(w.xtargets[1] == 9, 'the rat hates us')
    assert(State.myTargetId == 9 and State.myTargetName == 'a rat', 'the pulled mob is the kill target: ' .. tostring(State.myTargetId))
    assert(not State.pulled and not State.pulling, 'back in camp: the combat module takes it from here')
    assert(w.spawns[9].dist == 5, 'the rat came home')
    assert(not Timers.running('pull:waittimer'), 'the wait timer is cleared')
    -- with a hater in camp nothing more is pulled
    tick()
    mq.cmds = {}
    Pull:findMobToPull(1)
    assert(World.count(mq, '^/cast') == 0, 'no pull while a mob hates us')
end

-- ------------------------------------------------------------- an aborted pull restores AutoFire and the pull state
do
    local Combat = require('modules.combat')
    w.xtargets = {}
    w.spawns[9] = { id = 9, name = 'a rat', type = 'NPC', dist = 100, hp = 100, level = 50, x = 100, y = 0 }
    State.myTargetId, State.myTargetName = 0, ''
    Combat.cfg.AutoFireOn = 1
    tick()
    mq.cmds = {}
    -- the nav path to the rat is longer than MaxRadius: abortHome on the first pass
    local nav = rawget(mq.TLO.Navigation, '__children').PathLength
    local pathLen = rawget(nav, '__value')
    rawset(nav, '__value', function() return 900 end)
    Pull:findMobToPull(1)
    rawset(nav, '__value', pathLen)
    assert(World.count(mq, '^/cast') == 0, 'no cast: ' .. table.concat(mq.cmds, ';'))
    assert(Combat.cfg.AutoFireOn == 1, 'AutoFire restored on the abort')
    assert(not State.pulling and not State.pulled and Timers.running('pull:skip:9'), 'pull state cleared, the rat skipped')
    Combat.cfg.AutoFireOn = 0
    Timers.clearPrefix('pull:skip:')
    Timers.clear('pull:wait')
    Pull.failCounter = 0
end

-- ------------------------------------------------------------- the one-time pull bind for a non-puller
do
    State.role = 'assist'
    w.xtargets = {}
    w.spawns[9] = { id = 9, name = 'a rat', type = 'NPC', dist = 100, hp = 100, level = 50, x = 100, y = 0 }
    State.myTargetId, State.myTargetName = 0, ''
    tick()
    mq.cmds = {}
    Pull:GiveTime({ inCombat = false })
    assert(World.count(mq, '^/cast') == 0, 'an assist never pulls on its own')
    Pull.Binds['/pull'](Pull)
    mq.onDelay = function() if #w.xtargets > 0 then w.spawns[9].x = 5 w.spawns[9].dist = 5 end end
    Pull:GiveTime({ inCombat = false })
    mq.onDelay = nil
    assert(World.count(mq, '^/cast "Pull Spell"') == 1 and not Pull.pullOnce, '/pull pulls once: ' .. table.concat(mq.cmds, ';'))
    State.role = 'puller'
end

-- ------------------------------------------------------------- the chain probe from the fight
do
    Pull.cfg.ChainPull = 1
    State.chainPull = 1
    State.chainPullHold = 0
    w.xtargets = { 9 }
    w.spawns[9] = { id = 9, name = 'a rat', type = 'NPC', dist = 5, hp = 50, level = 50, x = 5, y = 0 }
    w.spawns[10] = { id = 10, name = 'a bat', type = 'NPC', dist = 150, hp = 100, level = 52, x = 150, y = 0 }
    State.myTargetId, State.myTargetName = 9, 'a rat'
    State.attacking = true
    mq.cmd('/squelch /target id 9')
    tick()
    mq.cmds = {}
    assert(Pull:chainProbe(9), 'the rat is under ChainPullHP and the bat is free: probe fires')
    assert(State.chainPull == 2 and State.myTargetId == 0 and not State.attacking, 'chain pull 2: the fight is handed off')
    assert(World.count(mq, '/attack off') == 1, 'attack off: ' .. table.concat(mq.cmds, ';'))
    assert(Pull.chainTemp == 10, 'the next mob is the bat')
    -- a healthy current mob does not fire the probe
    w.spawns[9].hp = 95
    State.chainPull = 1
    tick()
    assert(not Pull:chainProbe(9), 'not under ChainPullHP')
    -- a named is never chain pulled past
    w.spawns[9].hp = 50
    w.spawns[9].named = true
    tick()
    assert(not Pull:chainProbe(9), 'a named holds the chain')
    w.spawns[9].named = false
    -- ChainPullPause: the hold comes on after a minutes and goes off after b
    Pull.cfg.ChainPullPause = '30|2'
    Timers.clear('pull:chain1') Timers.clear('pull:chain2')
    tick()
    Pull:chainPauseTick()
    assert(Timers.running('pull:chain1') and State.chainPullHold == 0, 'the schedule is armed')
    -- pulling keeps the second timer alive, so after a minutes of pulling the hold comes on
    local n = 0
    for _ = 1, 16 do tick(2 * 60000) Timers.set('pull:chain2', 3 * 60000) Pull:chainPauseTick() n = n + 1 if State.chainPullHold == 2 then break end end
    assert(State.chainPullHold == 2 and n == 15, 'paused after 30 minutes of pulling: ' .. n)
    tick(3 * 60000)
    Pull:chainPauseTick()
    assert(State.chainPullHold == 0 and Timers.running('pull:chain1'), 'resumed after the b-minute pause and re-armed')
    -- b idle minutes with no pull reset the clock instead
    for _ = 1, 16 do tick(2 * 60000) Pull:chainPauseTick() end
    assert(State.chainPullHold == 0, 'idle: no pause')
    State.chainPull = 0
    Pull.cfg.ChainPull = 0
end

-- ------------------------------------------------------------- the binds
do
    Pull.Binds['/maxradius'](Pull, '200')
    assert(Pull.cfg.MaxRadius == 200 and data['MuleAssist_srv_Bob.ini'].Pull.MaxRadius == '200' and State.roleDefaults.campRadiusExceed == 400, 'maxradius saved')
    Pull.Binds['/maxzrange'](Pull, '20')
    assert(Pull.cfg.MaxZRange == 20, 'maxzrange')
    Pull.Binds['/masspull'](Pull, 'Pull Spell', '2', '1', '60', '300')
    assert(Pull.massPull and Pull.massPull.num == 2 and Pull.massPull.max == 60, 'masspull queued')
    Pull.massPull = nil
end

-- ------------------------------------------------------------- the rampage-pet hold (up to 60 s) keeps the cast engine's tick hooks running
do
    w.spawns[50] = { id = 50, name = 'Bob`s_pet00', type = 'NPC', dist = 10 }
    local ticks, t0 = 0, mq.now
    Cast.addTickHook('pulltest', function() ticks = ticks + 1 end)
    Pull:checkRampPets()
    Cast.removeTickHook('pulltest')
    w.spawns[50] = nil
    assert(ticks > 0 and mq.now - t0 >= 60000, 'the hold ran the tick hooks (' .. ticks .. ') and kept its 60 s')
end

-- ------------------------------------------------------------- zoning clears the pull state
do
    Timers.set('pull:skip:9', 10000)
    State.pulling, State.pulled = true, true
    Pull:OnZone()
    assert(not Timers.running('pull:skip:9') and not State.pulling and not State.pulled, 'reset on zone')
end

print('pull OK')
