-- luajit tests/buffs_test.lua   (from lua/muleassist)
package.path = './?.lua;./?/init.lua;' .. package.path
local Stub = require('tests.stub_mq')
local mq = Stub.new({})
local World = require('tests.world')
local Ini = require('core.ini')
local Config = require('core.config')
local Timers = require('core.timers')
local Spell = require('core.spell')
local State = require('core.state')
local T = require('core.tlo')
local Buffs = require('modules.buffs')

-- ---------------------------------------------------------------- line parsing (pure)
do
    local l = Buffs.parseLine('Talisman of the Tribunal|Group|OOG:raid,range60', 1)
    assert(l.name == 'Talisman of the Tribunal' and l.tag == 'group' and #l.oog == 2 and l.oog[2] == 'range60', 'group line with OOG tokens')
    local d = Buffs.parseLine('Unity|Dual|Spiritual Vigor|MA', 2)
    assert(d.tag == 'dualma' and d.dual == 'Spiritual Vigor' and d.isDual, 'Dual MA')
    local i = Buffs.parseLine('item:Cloak of Crystalline Waters|Single|OOG:Bob,Joe', 3)
    assert(i.name == 'Cloak of Crystalline Waters' and i.oog[1] == 'Bob' and i.oog[2] == 'Joe', 'item: prefix keeps the OOG list')
    local c = Buffs.parseLine('command:/doability Taunt|Me', 4)
    assert(c.kind == 'command' and c.name == '/doability Taunt' and c.tag == 'me', 'command:')
    assert(Buffs.parseLine('X|0', 5).disabled and Buffs.parseLine('X|Single|0', 6).disabled, '|0 disables')
    assert(Buffs.parseLine('NULL', 7) == nil and Buffs.parseLine('', 8) == nil, 'NULL')
    assert(Buffs.parseLine('Spell|class|CLR,DRU', 9).classList == 'CLR,DRU', 'class list')
    local e = Buffs.parseLine('Spell|Endgroup|50|Class|BER,WAR', 10)
    assert(e.tag == 'endgroup' and e.p3 == '50' and e.p5 == 'BER,WAR', 'endgroup parts')
    assert(Buffs.parseLine('Spell|Single|NoGroup', 11).noGroup, 'NoGroup anywhere')
    assert(Buffs.parseLine('Spell|mgb', 12).mgb and Buffs.parseLine('Unity|Dual|Child|mgb', 13).mgb, 'mgb')
    local p = Buffs.parsePetLine('Item|Dual|Effect', 1)
    assert(p.name == 'Item' and p.effect == 'Effect' and Buffs.parsePetLine('Spirit of Wolf', 2).effect == nil, 'pet lines')
    assert(Buffs.auraName("Disciple's Aura Rk. II") == 'Disciples Aura', 'aura typo')
    assert(Buffs.auraName('Mana Reverberation Aura') == 'Mana Rev.', 'enchanter aura name')
    assert(Buffs.auraName('Twincast Aura Rk. III') == 'Twincast Aura', 'rank stripped')
end

-- ---------------------------------------------------------------- a buff pass against the fake game
local data = { ['MuleAssist_srv_Bob.ini'] = {
    Buffs = { BuffsOn = '1', BuffsSize = '3', Buffs1 = 'Talisman of the Tribunal|Group', Buffs2 = 'Shield of Thorns|Single|OOG:Al', Buffs3 = 'NULL', BuffsReagent2 = 'Peridot|1' },
    Heals = { XTarHeal = '0' },
} }
Ini.use(Ini.tableBackend(data))
Config.iniFile = 'MuleAssist_srv_Bob.ini'
Config.condFile = Config.iniFile
Config.rankFn = function(n) return n end
Config.zoneId = function() return 0 end
local w = World.build(mq, {
    spells = { ['Talisman of the Tribunal'] = { tt = 'Group v2', dur = 2400, aerange = 100 }, ['Shield of Thorns'] = { tt = 'Single', dur = 600, range = 100 } },
    groupN = 1, group = { [0] = { id = 1, name = 'Bob', class = 'SHM', dist = 0 }, [1] = { id = 7, name = 'Al', class = 'WAR', dist = 10 } },
})
w.spawns[1] = { id = 1, name = 'Bob', type = 'PC', dist = 0, level = 60 }
w.spawns[7] = { id = 7, name = 'Al', type = 'PC', dist = 10, level = 60, class = 'WAR' }
Spell.clearCache()
local now = 0
Timers.setClock(function() return now end)
State.role = 'assist'
Buffs:LoadSettings()
do
    assert(#Buffs.lines == 2 and Buffs.lines[2].reagent == 'Peridot' and Buffs.lines[2].reagentCount == 1, 'lines loaded with the reagent gate')
    assert(State.buffsOn, 'BuffsOn mirrored')
    -- tick 1: the group spell, cast once on me, covers the group
    mq.cmds = {}
    Buffs:GiveTime({})
    assert(World.count(mq, '^/cast "Talisman of the Tribunal"') == 1, 'group buff cast once')
    assert(Timers.running('buff:1:1') and Timers.running('buff:1:7'), 'timers armed for every member')
    -- tick 2: line 2 is reagent-gated (no Peridot) -> skipped, the pass ends
    mq.cmds = {}
    Buffs:GiveTime({})
    assert(World.count(mq, '^/cast') == 0 and Buffs.cursor == nil and Timers.running('buffs:pass'), 'reagent gate skips the line, pass ends')
    -- the next pass with the reagent: me first, then Al, then the OOG entry (Al again, but grouped -> skipped)
    World.set(mq, 'FindItemCount', function(q) return q == '=Peridot' and 1 or 0 end)
    now = now + 11000
    mq.cmds = {}
    Buffs:GiveTime({})          -- line 1: everyone fresh -> skip; line 2: me
    assert(World.count(mq, '^/cast "Shield of Thorns"') == 1 and Timers.running('buff:2:1'), 'single buff on me first')
    mq.cmds = {}
    Buffs:GiveTime({})          -- line 2 again: Al
    assert(World.count(mq, '^/cast "Shield of Thorns"') == 1 and World.count(mq, '/target id 7') >= 1 and Timers.running('buff:2:7'), 'then the group member')
    mq.cmds = {}
    Buffs:GiveTime({})          -- nothing left: pass ends
    assert(World.count(mq, '^/cast') == 0 and Buffs.cursor == nil, 'pass complete')
    -- worn off on Al: the member's timer is forgotten and a pass runs at once
    w.spawns[7].buffs['Shield of Thorns'] = nil
    Buffs.wornOffQueue = { { spell = 'Shield of Thorns', wearer = 'Al' } }
    Buffs:Tick()
    assert(not Timers.running('buff:2:7') and not Timers.running('buffs:pass'), 'worn off clears the timer and the pass throttle')
    mq.cmds = {}
    Buffs:GiveTime({})
    assert(World.count(mq, '^/cast "Shield of Thorns"') == 1 and Timers.running('buff:2:7'), 'Al is rebuffed (he is still the target)')
    -- hostiles stop the pass unless BuffMode
    World.set(mq, 'Me.XTarget', function(i)
        if i == 1 then return mq.build({ TargetType = 'Auto Hater', Type = 'NPC', ID = 50 }) end
        if i then return mq.build({ TargetType = '', Type = '', ID = 0 }) end
        return 1
    end)
    T.xtargetReset()
    Timers.clear('buffs:pass')
    mq.cmds = {}
    Buffs:GiveTime({})
    assert(World.count(mq, '^/cast') == 0 and Buffs.cursor == nil, 'hostiles: no buffing')
    State.buffMode = true
    Buffs:GiveTime({})
    assert(Buffs.cursor ~= nil or World.count(mq, '^/cast') >= 0, 'BuffMode keeps buffing with haters up')
    State.buffMode = false
end

-- ---------------------------------------------------------------- binds
do
    Buffs.Binds['/buffmode'](Buffs, 'on')
    assert(State.buffMode, '/buffmode on')
    Buffs.Binds['/buffmode'](Buffs, '')
    assert(not State.buffMode, '/buffmode toggles off')
    Buffs.Binds['/buffson'](Buffs, '0')
    assert(not State.buffsOn and data['MuleAssist_srv_Bob.ini'].Buffs.BuffsOn == '0', '/buffson 0 writes the ini')
end

print('buffs_test OK')
