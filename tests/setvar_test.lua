-- lua tests/setvar_test.lua   (from lua/muleassist): /changevarint and /togglevariable, the two macro binds
-- the operator's MacroQuest.ini [Aliases] route 63 commands onto (/chaseon=/changevarint General ChaseAssist 1).
-- Driven through Modules.bindAll and the stub's mq.binds, as MQ dispatches them.
package.path = './?.lua;./?/init.lua;' .. package.path
local Stub = require('tests.stub_mq')
local mq = Stub.new({})
local World = require('tests.world')
local Ini = require('core.ini')
local Config = require('core.config')
local Timers = require('core.timers')
local State = require('core.state')
local Cast = require('core.cast')
local Modules = require('core.modules')

local data = { ['MuleAssist_srv_Bob.ini'] = {
    General = { MainAssist = 'Tank', ReturnToCamp = '0', CampRadius = '30', ChaseAssist = '0', ChaseDistance = '25', CastingInterruptOn = '0' },
    Melee = { MeleeOn = '0', AssistAt = '80', MeleeDistance = '30', StickHow = 'snaproll rear' },
    Aggro = { AggroOn = '0' },
    Buffs = { BuffsOn = '1', BuffsSize = '1', Buffs1 = 'NULL' },
    DPS = { DPSOn = '1', DPSCOn = '1', DPSSize = '1', DPS1 = 'NULL' },
} }
Ini.use(Ini.tableBackend(data))
Config.iniFile = 'MuleAssist_srv_Bob.ini'
Config.condFile = Config.iniFile
Config.rankFn = function(n) return n end
Config.zoneId = function() return 100 end
Timers.setClock(function() return mq.now end)
local w = World.build(mq, { dannet = true, me = { class = 'WAR', x = 10, y = 20 } })
w.spawns[5] = { id = 5, name = 'Tank', type = 'PC', dist = 10 }
w.spawns[6] = { id = 6, name = 'Pal', type = 'PC', dist = 20 }
State.role = 'assist'

local Combat = Modules.register(require('modules.combat'))
local Movement = Modules.register(require('modules.movement'))
local Buffs = Modules.register(require('modules.buffs'))
local Dps = Modules.register(require('modules.dps'))
local SetVar = Modules.register(require('modules.setvar'))
Cast.LoadSettings()
Modules.execAll('LoadSettings')
Modules.bindAll(mq)

local out = {}
local realPrint = print
print = function(s) out[#out + 1] = tostring(s) end
local function said(pat)
    for _, l in ipairs(out) do if l:find(pat, 1, true) then return true end end
    return false
end
local function run(cmd, ...)
    local fn = mq.binds[cmd]
    assert(fn, cmd .. ' is bound')
    out, mq.cmds = {}, {}
    fn(...)
end
local ini = data['MuleAssist_srv_Bob.ini']

assert(mq.binds['/changevarint'] and mq.binds['/togglevariable'], 'both binds registered by bindAll')
assert(not State.chaseAssist and not State.returnToCamp, 'start: no chase, no camp')

-- /chaseon = /changevarint General ChaseAssist 1
run('/changevarint', 'General', 'ChaseAssist', '1')
assert(State.chaseAssist and Movement.cfg.ChaseAssist == 1, 'chase on')
assert(ini.General.ChaseAssist == '1', 'ChaseAssist persisted: ' .. tostring(ini.General.ChaseAssist))
assert(State.chaseName == 'Tank', 'chases the MA by default')

-- /chaseon Pal = /changevarint General ChaseAssist 1 Pal
run('/changevarint', 'General', 'ChaseAssist', '1', 'Pal')
assert(State.chaseAssist and State.chaseName == 'Pal', 'chase name from the extra word: ' .. State.chaseName)

-- /chaseoff = /changevarint General ChaseAssist 0: off, stick stopped
World.set(mq, 'Stick.Active', true)
run('/changevarint', 'General', 'ChaseAssist', '0')
assert(not State.chaseAssist and Movement.cfg.ChaseAssist == 0, 'chase off')
assert(World.count(mq, '/stick off') == 1, 'stick stopped: ' .. table.concat(mq.cmds, ';'))
assert(ini.General.ChaseAssist == '0', 'ChaseAssist off persisted')
World.set(mq, 'Stick.Active', false)

-- /camphere = /togglevariable ReturnToCamp: flips, sets the camp here
State.campX, State.campY = 0, 0
run('/togglevariable', 'ReturnToCamp')
assert(State.returnToCamp and Movement.cfg.ReturnToCamp == 1, 'camp on')
assert(State.campX == 10 and State.campY == 20, 'camp set at my loc')
run('/togglevariable', 'ReturnToCamp')
assert(not State.returnToCamp and Movement.cfg.ReturnToCamp == 0, 'camp toggled off')
run('/togglevariable', 'ReturnToCamp', 'on')
assert(State.returnToCamp, 'camp on by word')
run('/togglevariable', 'ReturnToCamp', '0')
assert(not State.returnToCamp, 'camp off by 0')

-- /buffson off = /togglevariable BuffsOn off
assert(State.buffsOn, 'buffs start on')
run('/togglevariable', 'BuffsOn', 'off')
assert(not State.buffsOn and Buffs.cfg.BuffsOn == 0, 'BuffsOn off')
run('/togglevariable', 'BuffsOn')
assert(State.buffsOn and Buffs.cfg.BuffsOn == 1, 'BuffsOn toggled back on')

-- /assistat 95 = /changevarint Melee AssistAt 95: the live value, every module that reads it, the INI
run('/changevarint', 'Melee', 'AssistAt', '95')
assert(State.assistAt == 95 and Combat.cfg.AssistAt == 95, 'AssistAt live: ' .. tostring(State.assistAt))
assert(Dps.cfg.AssistAt == 95, 'dps copy of AssistAt synced: ' .. tostring(Dps.cfg.AssistAt))
assert(ini.Melee.AssistAt == '95', 'AssistAt persisted: ' .. tostring(ini.Melee.AssistAt))
-- a section typo still lands in the setting's real section
run('/changevarint', 'melee', 'assistat', '90')
assert(State.assistAt == 90 and ini.Melee.AssistAt == '90', 'case-insensitive names')
-- no value: report, no change
run('/changevarint', 'Melee', 'AssistAt')
assert(State.assistAt == 90 and ini.Melee.AssistAt == '90' and said('AssistAt'), 'no value: unchanged, reported')
-- a word for a number setting is refused
run('/changevarint', 'Melee', 'AssistAt', 'lots')
assert(State.assistAt == 90 and said('number'), 'word refused for a number')

-- on/off words only for 0/1 flags; a word for any other number is refused
run('/changevarint', 'Melee', 'AssistAt', 'on')
assert(State.assistAt == 90 and ini.Melee.AssistAt == '90' and said('number'), 'on refused for AssistAt: ' .. tostring(State.assistAt))
-- a string setting with no dedicated bind is refused (writing the INI alone would not change the live value)
run('/changevarint', 'General', 'MainAssist', 'Pal')
assert(ini.General.MainAssist == 'Tank' and State.mainAssist == 'Tank' and said('MainAssist'), 'string setting refused: ' .. tostring(ini.General.MainAssist))

-- unknown names and internal state are refused
run('/changevarint', 'General', 'NoSuchThing', '1')
assert(said('unknown') and ini.General.NoSuchThing == nil, 'unknown changevarint refused')
run('/togglevariable', 'NoSuchThing')
assert(said('unknown'), 'unknown togglevariable refused')
State.myTargetId = 77
run('/changevarint', 'General', 'MyTargetID', '5')
assert(said('internal') and State.myTargetId == 77 and ini.General.MyTargetID == nil, 'internal changevarint refused')
State.iAmDead = false
run('/togglevariable', 'IAmDead')
assert(said('internal') and State.iAmDead == false, 'internal togglevariable refused')
-- togglevariable only flips on/off settings
run('/togglevariable', 'StickHow')
assert(said('on/off') and Combat.cfg.StickHow == 'snaproll rear', 'string setting not toggled')

-- MeleeOn: /assist on|off
run('/togglevariable', 'MeleeOn', 'on')
assert(State.meleeOn and Combat.cfg.MeleeOn == 1 and Movement.cfg.MeleeOn == 1, 'MeleeOn on, synced')
assert(World.count(mq, '^/assist on') == 1, '/assist on: ' .. table.concat(mq.cmds, ';'))
run('/togglevariable', 'MeleeOn')
assert(not State.meleeOn and World.count(mq, '^/assist off') == 1, 'MeleeOn toggled off with /assist off')

-- a setting with no dedicated bind: /aggrotime = /togglevariable AggroOn (session only, as the macro)
run('/togglevariable', 'AggroOn')
assert(Combat.cfg.AggroOn == 1 and ini.Aggro.AggroOn == '0', 'AggroOn flipped live, INI untouched')
run('/changevarint', 'Aggro', 'AggroOn', '0')
assert(Combat.cfg.AggroOn == 0 and ini.Aggro.AggroOn == '0', 'AggroOn set and persisted')
run('/changevarint', 'Aggro', 'AggroOn', 'on')
assert(Combat.cfg.AggroOn == 1 and ini.Aggro.AggroOn == '1', 'on/off words still work for a 0/1 flag')
run('/changevarint', 'Aggro', 'AggroOn', 'off')
assert(Combat.cfg.AggroOn == 0 and ini.Aggro.AggroOn == '0', 'off for a flag')
-- /interrupton reaches the cast engine's settings
run('/togglevariable', 'CastingInterruptOn')
assert(Cast.cfg.CastingInterruptOn == 1 and Dps.cfg.CastingInterruptOn == 1, 'CastingInterruptOn in cast and dps')

-- /conditions dps off = /togglevariable conditions dps off; on/off alone leaves conditions on (macro)
run('/togglevariable', 'conditions', 'dps', 'off')
assert(Dps.cfg.DPSCOn == 0, 'DPSCOn off')
run('/togglevariable', 'conditions', 'all', 'on')
assert(Dps.cfg.DPSCOn == 1 and Buffs.cfg.BuffsCOn == 1 and Dps.cfg.BurnCOn == 1 and Dps.cfg.GoMCOn == 1, 'all conditions on')
run('/togglevariable', 'conditions', 'off')
assert(Dps.cfg.DPSCOn == 1 and said('conditions'), 'conditions off alone is the macro no-op')

-- /pethold names PetHold: renamed to PetHoldOn, refused here only because no pet module is registered
run('/togglevariable', 'PetHold')
assert(said('PetHoldOn'), 'PetHold renamed to PetHoldOn')

-- the bot registers the module (its binds go live through bindAll)
do
    local f = assert(io.open('init.lua', 'r'))
    local src = f:read('a')
    f:close()
    assert(src:find("Modules.register(require('modules.setvar'))", 1, true), 'init.lua registers modules.setvar')
end

print = realPrint
print('setvar_test ok')
