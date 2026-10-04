-- luajit tests/core_test.lua   (from lua/muleassist)
package.path = './?.lua;./?/init.lua;' .. package.path
local Stub = require('tests.stub_mq')
local mq = Stub.new({})

-- ---------------------------------------------------------------- lines
local Lines = require('core.lines')
do
    local l = Lines.parse('Complete Heal|40|MA, buff!=Divine Aura')
    assert(l.name == 'Complete Heal' and l.pct == 40, 'name/pct')
    assert(l.tags.ma == true, 'ma tag')
    assert(l.buff == 'Divine Aura' and l.buffOp == '!=', 'buff!= name: ' .. tostring(l.buff))
    assert(Lines.has(l, 'MA') and not Lines.has(l, '!ma'), 'exact membership')
    assert(Lines.landsOnTank(l), 'MA line lands on the tank')
    local r = Lines.parse('Remedy|85|!MA')
    assert(not Lines.landsOnTank(r), '!MA line does not')
    assert(Lines.landsOnTank(Lines.parse('Remedy|85')), 'untagged lands')
    assert(not Lines.landsOnTank(Lines.parse('Touch|50|Tap')), 'tap does not')
    assert(Lines.parse('NULL') == nil and Lines.parse('') == nil, 'NULL entries')
    local m = Lines.parse('Pious|80|buff==Pious Elixir, ME')
    assert(m.buff == 'Pious Elixir' and m.buffOp == '==' and m.tags.me, 'buff== with a second tag')
    assert(not Lines.has(Lines.parse('X|50|Mana Flare'), 'ma'), '"Mana Flare" is not the MA tag')
    local all = Lines.parseAll({ 'A|10', 'NULL', 'B|20|MA' })
    assert(#all == 2 and all[2].index == 3, 'parseAll keeps indexes')
end

-- ---------------------------------------------------------------- timers
local Timers = require('core.timers')
do
    local t = 0
    Timers.setClock(function() return t end)
    Timers.set('a', 1000)
    assert(Timers.running('a') and Timers.left('a') == 1000, 'armed')
    t = 999; assert(Timers.running('a'), 'still running')
    t = 1000; assert(Timers.expired('a') and Timers.left('a') == 0, 'expired at 1000')
    assert(Timers.expired('never'), 'never set = expired')
    Timers.set('b', '30s'); assert(Timers.left('b') == 30000, '30s string')
    Timers.set('b', '500ms'); assert(Timers.left('b') == 500, '500ms string')
    Timers.set('gm:1', 10); Timers.set('gm:2', 10); Timers.clearPrefix('gm:')
    assert(Timers.expired('gm:1') and Timers.expired('gm:2'), 'clearPrefix')
end

-- ---------------------------------------------------------------- config (LoadIni semantics)
local Ini = require('core.ini')
local Config = require('core.config')
do
    local data = { ['MuleAssist_srv_Bob.ini'] = {
        Heals = { HealsOn = '1', HealsSize = '5', Heals1 = 'Remedy|85', Heals2 = 'Complete Heal|40|MA', Heals3 = 'NULL', Heals4 = 'NULL', Heals5 = 'NULL' },
        Cures = { CuresSize = '3', Cures1 = 'Cure Poison|poison', Cures2 = 'NULL', Cures3 = 'Radiant Cure' },
    } }
    local b = Ini.tableBackend(data)
    Ini.use(b)
    Config.iniFile = Config.fileName('srv', 'Bob')
    Config.condFile = Config.iniFile
    Config.rankFn = function(n) if n == 'Remedy' then return 'Remedy Rk. II' end return n end
    assert(Config.iniFile == 'MuleAssist_srv_Bob.ini', 'file name')
    local v = Config.scalar({ section = 'Heals', key = 'HealsOn', type = 'int', default = 0 })
    assert(v == 1, 'HealsOn read')
    local d = Config.scalar({ section = 'Heals', key = 'XTarHeal', type = 'string', default = '1|2', rank = false })
    assert(d == '1|2' and data['MuleAssist_srv_Bob.ini'].Heals.XTarHeal == '1|2', 'default written back')
    local e, c, n = Config.array({ section = 'Heals', name = 'Heals', size = { key = 'HealsSize', default = 20 }, cond = 'HealsCond' })
    assert(n == 2, 'trailing NULLs shrink the size, got ' .. n)
    assert(data['MuleAssist_srv_Bob.ini'].Heals.HealsSize == '2', 'HealsSize written back')
    assert(e[1] == 'Remedy Rk. II|85', 'rank applied to the name only: ' .. e[1])
    assert(e[2] == 'Complete Heal|40|MA', 'second entry')
    assert(c[1] == 'TRUE' and data['MuleAssist_srv_Bob.ini'].Heals.HealsCond1 == 'TRUE', 'conditions default TRUE')
    -- a blank in the middle: size stays, blank reported, entries kept
    local e2, _, n2 = Config.array({ section = 'Cures', name = 'Cures', size = { key = 'CuresSize', default = 10 }, cond = 'CuresCond' })
    assert(n2 == 3 and e2[2] == 'NULL' and e2[3] == 'Radiant Cure', 'blank in the middle kept')
    -- heal pct scaling in 795/796
    Config.zoneId = function() return 795 end
    local e3 = Config.array({ section = 'Heals', name = 'Heals', size = { key = 'HealsSize', default = 20 } })
    assert(e3[1] == 'Remedy Rk. II|59', 'pct scaled by 0.7 in 795: ' .. e3[1])
    Config.zoneId = function() return 0 end
    -- schema load
    local out = Config.load({ scalars = { { section = 'Heals', key = 'HealsOn', type = 'int', default = 0 } },
        arrays = { { section = 'Heals', name = 'Heals', cond = 'HealsCond' } } })
    assert(out.HealsOn == 1 and #out.Heals == 2 and out.HealsSize == 2 and out.HealsCond[2] == 'TRUE', 'schema load')
end

-- ---------------------------------------------------------------- whynot ring
local Log = require('core.log')
do
    Log.whyNot('Heal', 'Remedy', 'Bob', 'no line')
    Log.whyNot('Heal', 'Remedy', 'Bob', 'no line')
    Log.whyNot('Cure', 'Cure Poison', 'Al', 'not ready')
    local list = Log.whyNotList()
    assert(#list == 2 and list[1]:find('Cure Poison') and list[2]:find('%(x2%)'), 'ring dedupes and orders newest first')
end

-- ---------------------------------------------------------------- comms (peer list)
local Comms = require('core.comms')
do
    local spawns = { ['pc =Al'] = { _ = true, ID = 5, CleanName = 'Al', Type = 'PC' } }
    mq.TLO = mq.build({
        Plugin = { _ = function(name) if name == 'MQ2DanNet' then return 'MQ2DanNet' end return nil end },
        Me = { CleanName = 'Bob', ID = 1 },
        DanNet = { Peers = { _ = function() return 'Bob|Al|Cy' end }, PeerCount = { _ = function() return 3 end } },
        Spawn = { _ = function(q) return mq.build(spawns[q] or { _ = nil }) end },
    })
    local peers = Comms.peers()
    assert(#peers == 2 and peers[1] == 'Al' and peers[2] == 'Cy', 'peers excludes me')
    assert(Comms.isPeer('al') and not Comms.isPeer('Bob2') and not Comms.isPeer(''), 'isPeer case-insensitive')
    local inZone = Comms.peersInZone()
    assert(#inZone == 1 and inZone[1] == 'Al', 'peersInZone needs a PC spawn')
    assert(#Comms.peersInZone(function(sp) return sp.ID() == 99 end) == 0, 'predicate filters')
    -- ${Plugin[x]} is the plugin's name, never TRUE
    local T = require('core.tlo')
    assert(T.pluginLoaded('MQ2DanNet') and not T.pluginLoaded('MQ2Nav'), 'a loaded plugin reads as its name, a missing one as nil')
    -- [General] DanNetOn=0 switches DanNet off even with the plugin loaded
    local State = require('core.state')
    assert(Comms.danNet(), 'plugin loaded and DanNetOn: on')
    State.danNetOn = false
    assert(not Comms.danNet() and #Comms.peers() == 0, 'DanNetOn=0: off')
    State.danNetOn = true
    -- no DanNet: nothing, never an error
    mq.TLO = mq.build({ Plugin = { _ = function() return nil end }, Me = { CleanName = 'Bob' } })
    assert(#Comms.peers() == 0 and not Comms.isPeer('Al'), 'no DanNet = no peers')
end

-- ---------------------------------------------------------------- a thrown read yields the default, never the error string
do
    local T = require('core.tlo')
    assert(T.num(function() error('boom') end) == 0, 'num: thrown read -> 0')
    assert(T.num(function() error('boom') end, 7) == 7, 'num: thrown read -> the default')
    assert(T.num(function() return '12' end) == 12 and T.num(function() return 'x' end, 3) == 3, 'num: parse and fallback')
end

-- ---------------------------------------------------------------- line timers reset when a reload changes the list
do
    local Timers = require('core.timers')
    assert(not Timers.resetOnChange('t', 'A|B', { 'x:' }), 'first load: nothing to clear')
    Timers.set('x:1:9', 60000)
    assert(not Timers.resetOnChange('t', 'A|B', { 'x:' }) and Timers.running('x:1:9'), 'same list: timers kept')
    assert(Timers.resetOnChange('t', 'C|B', { 'x:' }) and not Timers.running('x:1:9'), 'a replaced line: its position timers cleared')
end

-- ---------------------------------------------------------------- log (pm flag vs function)
do
    assert(type(Log.pm) == 'function' and Log.pmOn == true, 'pm is the breadcrumb function, pmOn the flag')
    Log.pmOn = false
    Log.pm('silent %d', 1)
    Log.pmOn = true
end

-- ---------------------------------------------------------------- launch line
local Launch = require('core.launch')
do
    local l = Launch.parse({ 'pullertank', 'Tanky', 'rmark', '2' })
    assert(l.role == 'pullertank' and l.mainAssist == 'Tanky' and l.rmark == 2, 'role MA rmark N')
    l = Launch.parse({ 'Assist', 'rmark', '3', 'Tanky' })
    assert(l.role == 'assist' and l.mainAssist == 'Tanky' and l.rmark == 3, 'rmark N before the MA; N is never the MA')
    l = Launch.parse({ 'assist', 'rmark', '7' })
    assert(l.rmark == nil and l.rmarkBad and l.mainAssist == nil, 'bad N: mark stays off, 7 is not the MA')
    l = Launch.parse({ 'tank', 'NULL' })
    assert(l.role == 'tank' and l.mainAssist == nil and l.rmark == nil, 'NULL MA')
    l = Launch.parse({})
    assert(l.role == nil and l.mainAssist == nil, 'bare launch keeps the INI')
end

print('core_test OK')
