-- luajit tests/report_test.lua   (from lua/muleassist)
package.path = './?.lua;./?/init.lua;' .. package.path
local Stub = require('tests.stub_mq')
local mq = Stub.new({
    Plugin = { _ = function(name) if name == 'MQ2DanNet' then return 'MQ2DanNet' end return nil end },
    Me = { CleanName = 'Bob', ID = 1, Class = { ShortName = 'CLR' } },
})
local Stats = require('core.stats')
local State = require('core.state')
local Log = require('core.log')
local Report = require('modules.report')

local t = 0
Stats.clock = function() return t end

-- ---------------------------------------------------------------- build (HealStatsBuild format)
do
    Stats.reset()
    assert(Stats.build('Bob') == 'Bob: 0 heals (tank 0 grp 0 self 0 pet 0 oog 0) [0 fights, 0m0s]', 'empty: ' .. Stats.build('Bob'))
    t = 125
    Stats.bump('single', 7); Stats.bump('tank', 4); Stats.bump('groupT', 2); Stats.bump('self', 1)
    Stats.bump('group', 3); Stats.bump('groupRange', 1)
    Stats.bump('smart', 2); Stats.bump('smartFail', 1)
    Stats.bump('cure', 5); Stats.cureUnready('Cure Poison'); Stats.cureUnready('Cure Poison')
    Stats.bump('intHeal'); Stats.bump('intMob'); Stats.bump('dpsCut', 2)
    Stats.fail('CAST_INTERRUPTED', 'Remedy')
    Stats.low('Al', 35); Stats.low('Cy', 60)       -- only a new low replaces
    Stats.tankLow(0); Stats.tankLow(42); Stats.tankLow(50)
    Stats.bump('fights', 2)
    local want = 'Bob: 7 heals (tank 4 grp 2 self 1 pet 0 oog 0), 3 group heals (1 withheld: nobody in range), 2 smart heals (1 failed), 5 cures (2 not ready), 2 interrupted, 2 nukes cut for a heal, 1 failed casts, lowest Al 35%, tank low 42% [2 fights, 2m5s]'
    assert(Stats.build('Bob') == want, 'full line:\n' .. Stats.build('Bob') .. '\n' .. want)
    assert(Stats.hs.failLast == 'CAST_INTERRUPTED Remedy' and Stats.hs.cureUnreadyLast == 'Cure Poison', 'last fields')
    Stats.reset()
    assert(Stats.hs.single == 0 and Stats.hs.lowPct == 100 and Stats.hs.since == 125, 'reset zeroes and restarts the window')
    local ok = pcall(Stats.bump, 'nosuch')
    assert(not ok, 'unknown key is an error')
end

-- ---------------------------------------------------------------- /whynot feeds HSSkip once per new key
do
    Stats.reset()
    Log.whyNot('Heal', 'Remedy', 'Bob', 'no line')
    Log.whyNot('Heal', 'Remedy', 'Bob', 'no line')
    Log.whyNot('Cure', 'Cure Poison', 'Al', 'not ready')
    assert(Stats.hs.skip == 2, 'skip counts new keys only, got ' .. Stats.hs.skip)
end

-- ---------------------------------------------------------------- status line (MAStatusTick)
do
    local S = { mainAssist = 'Tank', healTankMode = 'off' }
    assert(Report.statusLine(S) == 'idle', 'idle')
    S.raidModeOn = true; S.markAssistOn = true; S.raidMarkNum = 2
    S.xtarTanks = true; S.xtarTankOwned = 'a|b|c'
    S.aggroPaused = true; S.aeOn = true; S.manualOn = true; S.manualMAOn = true; S.killOrderOn = true
    S.getAwayOn = true; S.getAwayFollow = true
    S.chaseAssist = true; S.chaseLeftBehind = true
    S.buffMode = true; S.zombieMode = true
    S.healTankMode = 'auto'; S.healTank = 'Raidtank'
    local want = 'Raid | Mark 2 | XTarTanks 3 | Aggro paused | AE | Manual | Follow | KillOrder | GetAway (following) | Chase: left behind | BuffMode | Zombie | Tank Raidtank (raid MA)'
    assert(Report.statusLine(S) == want, 'all on:\n' .. Report.statusLine(S) .. '\n' .. want)
    local S2 = { mainAssist = 'Tank', healTankMode = 'Tank', healTank = 'Tank', chaseAssist = true, chaseStuckTries = 2, xtarTanks = true, xtarTankOwned = '' }
    assert(Report.statusLine(S2) == 'XTarTanks 0 | Chase: stuck | Tank Tank (the MA)', 'named tank = the MA: ' .. Report.statusLine(S2))
end

-- ---------------------------------------------------------------- fight end + binds
do
    Stats.reset()
    Report.cfg = { HealReportOnEnd = 0 }
    State.healsOn, State.curesOn = false, false
    Report:fightEnd()
    assert(Stats.hs.fights == 0 and State.healStats == '', 'no heals/cures: no report')
    State.curesOn = true
    Report:fightEnd()
    assert(Stats.hs.fights == 1 and State.healStats:find('^Bob: 0 heals'), 'fight counted and HealStats rebuilt')
    -- /healreport bc broadcasts the one-liner to the DanNet channel; all fans out to the zone
    mq.cmds = {}
    Report.Binds['/healreport'](Report, 'bc')
    assert(#mq.cmds == 1 and mq.cmds[1]:find('^/dgt \\ag') and mq.cmds[1]:find('Bob: 0 heals'), 'bc -> /dgt: ' .. tostring(mq.cmds[1]))
    mq.cmds = {}
    Report.Binds['/healreport'](Report, 'all')
    assert(mq.cmds[1] == '/dgze /healreport bc', 'all -> zone: ' .. tostring(mq.cmds[1]))
    State.curesOn = false
    mq.cmds = {}
    Report.Binds['/healreport'](Report, 'bc')
    assert(#mq.cmds == 0, 'bc with nothing on is silent')
    -- the full report
    State.curesOn = true
    State.healLines = { { name = 'Remedy', pct = 85 }, { name = 'Complete Heal', pct = 40 } }
    State.groupHealLines = { { name = 'Word of Vivification', pct = 70 } }
    Stats.bumpLine(2); Stats.bumpLine(2); Stats.bumpGLine(1)
    local lines = Report:fullReport()
    assert(lines[1]:find('Bob %(CLR%)') and lines[1]:find('1 fights') and lines[1]:find('%(HealsOn=0%)') and not lines[1]:find('CuresOn=0'), 'header: ' .. lines[1])
    local byLine
    for _, l in ipairs(lines) do if l:find('By line:') then byLine = l end end
    assert(byLine == '  By line: Complete Heal|40 2 | Word of Vivification|70 1 (group)', 'by line: ' .. tostring(byLine))
    -- reset
    Report.Binds['/healreport'](Report, 'reset')
    assert(Stats.hs.fights == 0 and State.healStats == '', 'reset')
    -- the tick refreshes State.status once a second
    local Timers = require('core.timers')
    local now = 0
    Timers.setClock(function() return now end)
    State.aeOn = true
    Report:Tick()
    assert(State.status == 'AE', 'status after tick: ' .. State.status)
    State.aeOn = false
    Report:Tick()
    assert(State.status == 'AE', 'not refreshed within the second')
    now = 1000
    Report:Tick()
    assert(State.status == 'idle', 'refreshed after a second')
end

print('report_test OK')
