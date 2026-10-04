-- luajit tests/dps_test.lua   (from lua/muleassist): dps, ae, burn, debuffs, mez and charm
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
local Combat = require('modules.combat')
local Dps = require('modules.dps')
local Debuffs = require('modules.debuffs')
local Mez = require('modules.mez')
local Charm = require('modules.charm')
local Heals = require('modules.heals')

-- ------------------------------------------------------------- pure: the entry parse
do
    local e = Dps.parseEntry('Ice Comet|90', 'TRUE')
    assert(e.name == 'Ice Comet' and e.pct == 90 and e.part3 == '', 'plain')
    e = Dps.parseEntry('Haste|100|Me|notifme|Haste')
    assert(e.part3 == 'me' and e.part4 == 'notifme' and e.part5 == 'Haste', 'me with a condition: ' .. e.part3 .. e.part4)
    e = Dps.parseEntry('Haste|100|if|Haste')
    assert(e.part3 == '' and e.part4 == 'if' and e.part5 == 'Haste', 'the shorthand condition')
    e = Dps.parseEntry('Slow|99|debuffall|slow|always')
    assert(e.part3 == 'debuffall' and e.tag1 == 'slow' and e.tag2 == 'always', 'a debuff line')
    assert(Dps.parseEntry('NULL') == nil and Dps.parseEntry('') == nil, 'empty')
end

-- ------------------------------------------------------------- the world
local data = { ['MuleAssist_srv_Bob.ini'] = {
    General = { MainAssist = 'Tank', CampRadius = '30', CastingInterruptOn = '1' },
    Melee = { MeleeDistance = '30', AssistAt = '95' },
    DPS = { DPSOn = '1', DPSSize = '6', DPS1 = 'Ice Comet|90', DPS2 = 'Rune|100|Me', DPS3 = 'Slow Spell|99|debuffall|slow', DPSInterval = '2', TTDOn = '0', DebuffAllOn = '1' },
    AE = { AEOn = '1', AESize = '2', AE1 = 'Burning Rain|2|Mob', AERadius = '50' },
    Burn = { BurnSize = '2', Burn1 = 'Big Burn|Mob', BurnAllNamed = '1' },
    Mez = { MezOn = '1', MezRadius = '50', MezSpell = 'Mesmerize', MezStopHPs = '80', MezMinLevel = '1', MezMaxLevel = '100', MezAESpell = 'Wave|3' },
    Charm = { CharmAutoOn = '0', CharmWatchSec = '15' },
} }
Ini.use(Ini.tableBackend(data))
Config.iniFile = 'MuleAssist_srv_Bob.ini'
Config.condFile = Config.iniFile
Config.rankFn = function(n) return n end
Config.zoneId = function() return 100 end
Timers.setClock(function() return mq.now end)
local function tick(ms) mq.now = (mq.now or 0) + (ms or 500) T.xtargetReset() end
local w = World.build(mq, {
    dannet = true, me = { class = 'ENC', curMana = 5000, x = 0, y = 0 }, groupN = 1,
    spells = {
        ['Ice Comet'] = { st = 'Detrimental', tt = 'Single', range = 200, dur = 0, castMs = 2000, mana = 100, spa = { [0] = true } },
        ['Rune'] = { tt = 'Self', dur = 600, castMs = 1000, mana = 50 },
        ['Slow Spell'] = { st = 'Detrimental', tt = 'Single', range = 200, dur = 120, castMs = 2000, mana = 100, spa = { [11] = true } },
        ['Burning Rain'] = { st = 'Detrimental', tt = 'PB AE', aerange = 40, dur = 0, castMs = 2000, mana = 200, spa = { [0] = true } },
        ['Big Burn'] = { st = 'Detrimental', tt = 'Single', range = 200, dur = 0, castMs = 0, mana = 0 },
        ['Mesmerize'] = { st = 'Detrimental', tt = 'Single', range = 200, dur = 24, castMs = 2000, mana = 100, spa = { [31] = true }, maxLevel = 100 },
        ['Wave'] = { st = 'Detrimental', tt = 'PB AE', aerange = 30, dur = 18, castMs = 2000, mana = 300, spa = { [31] = true } },
        ['Charm Spell'] = { st = 'Detrimental', tt = 'Single', range = 200, dur = 600, castMs = 3000, mana = 300, spa = { [22] = true }, maxLevel = 70 },
    },
    gems = { [1] = 'Ice Comet', [2] = 'Rune', [3] = 'Slow Spell', [4] = 'Mesmerize', [5] = 'Wave', [6] = 'Charm Spell' },
    group = { [0] = { id = 1, name = 'Bob', class = 'ENC' }, [1] = { id = 5, name = 'Tank', class = 'WAR' } },
})
w.spawns[1] = { id = 1, name = 'Bob', type = 'PC', dist = 0 }
w.spawns[5] = { id = 5, name = 'Tank', type = 'PC', dist = 15 }
w.spawns[9] = { id = 9, name = 'a rat', type = 'NPC', dist = 20, hp = 85, level = 50, x = 20, y = 0 }
w.spawns[10] = { id = 10, name = 'a bat', type = 'NPC', dist = 25, hp = 100, level = 52, x = 25, y = 0 }
Spell.clearCache()
State.role = 'assist'
State.mainAssist, State.mainAssistType = 'Tank', 'PC'
Cast.LoadSettings()
Cast.registerEvents()
for _, m in ipairs({ Heals, Combat, Mez, Debuffs, Dps, Charm }) do m:Init() end
for _, m in ipairs({ Heals, Combat, Mez, Debuffs, Dps, Charm }) do m:LoadSettings() end
w.xtargets = { 9 }
State.myTargetId = 9
State.combatStart = true

-- the DPS list split
do
    assert(#Dps.lines == 2 and Dps.lines[1].name == 'Rune' and Dps.lines[2].name == 'Ice Comet', 'descending by pct, debuffs out: ' .. Dps.lines[1].name)
    assert(#Dps.debuffLines == 1 and Dps.debuffLines[1].name == 'Slow Spell', 'the debuff line')
    assert(State.dpsOn and State.mezOn and State.aeOn, 'flags')
    assert(Mez.aeSpell == 'Wave' and Mez.aeNeed == 3, 'the AE mez spell|count')
end

-- a DPS pass: the self rune first, then the nuke under 90%; timers hold them; the rune waits for its buff
do
    Mez.cfg.MezOn = 0   -- no CC hold for this block
    tick()
    mq.cmds = {}
    Dps:combatCast(9)
    assert(World.count(mq, '^/cast "Rune"') == 1, 'the Me line: ' .. table.concat(mq.cmds, ';'))
    assert(World.count(mq, '^/cast "Ice Comet"') == 1, 'the nuke: ' .. table.concat(mq.cmds, ';'))
    assert(Timers.running('dps:ab:2') and Timers.running('dps:1:9'), 'timers armed')
    tick()
    mq.cmds = {}
    Dps:combatCast(9)
    assert(World.count(mq, '^/cast') == 0, 'held by the timers: ' .. table.concat(mq.cmds, ';'))
    tick(2500)
    mq.cmds = {}
    Dps:combatCast(9)
    assert(World.count(mq, '^/cast "Ice Comet"') == 1 and World.count(mq, '^/cast "Rune"') == 0, 'the nuke again, the rune still up: ' .. table.concat(mq.cmds, ';'))
    -- the mob is above the line: nothing
    w.spawns[9].hp = 95
    tick(2500)
    mq.cmds = {}
    Dps:combatCast(9)
    assert(World.count(mq, '^/cast "Ice Comet"') == 0, 'above 90%: no nuke')
    w.spawns[9].hp = 85
    Mez.cfg.MezOn = 1
end

-- a charm spell listed in [DPS] is never cast by the rotation (charm.lua owns charming), logged once
do
    Mez.cfg.MezOn = 0
    local saved = Dps.lines
    local charm = Dps.parseEntry('Charm Spell|99', 'TRUE')
    charm.index = 10
    local nuke = Dps.parseEntry('Ice Comet|90', 'TRUE')
    nuke.index = 1
    Dps.lines = { charm, nuke }
    local lines = {}
    local realPrint = print
    print = function(s) lines[#lines + 1] = tostring(s) end
    local casts, nukes = 0, 0
    for _ = 1, 4 do
        tick(3000)
        mq.cmds = {}
        Dps:combatCast(9)
        casts = casts + World.count(mq, '^/cast "Charm Spell"')
        nukes = nukes + World.count(mq, '^/cast "Ice Comet"')
    end
    print = realPrint
    local warned = 0
    for _, l in ipairs(lines) do if l:find('skipping Charm Spell', 1, true) and l:find('charm', 1, true) then warned = warned + 1 end end
    assert(casts == 0, 'the charm entry is never cast: ' .. casts)
    assert(nukes >= 1, 'the nuke beside it still casts: ' .. nukes)
    assert(warned == 1, 'logged once over the passes, got ' .. warned)
    Dps.lines = saved
    Mez.cfg.MezOn = 1
end

-- TTD over an injected clock: a mob losing 10% every 6 s dies in ~51 s at 85%
do
    local sec = 0
    Dps.clock = function() return sec end
    Dps.cfg.TTDOn = 1
    assert(Dps:ttdEstimate(9, 100) == -1, 'first sight')
    sec = 6
    assert(Dps:ttdEstimate(9, 90) == 54, 'fight average: ' .. tostring(Dps:ttdEstimate(9, 90)))
    sec = 12
    local est = Dps:ttdEstimate(9, 80)
    assert(est == 48, 'window estimate: ' .. tostring(est))
    sec = 18
    assert(Dps:ttdEstimate(9, 80) == 72, 'window slid, back to the fight average: ' .. tostring(Dps:ttdEstimate(9, 80)))
    Dps:ttdSummary('test')
    assert(Dps.ttd.skipCount == 0 and Dps.ttd.lastEst == -1, 'summary resets')
    Dps.cfg.TTDOn = 0
    Dps.clock = nil
end

-- the DPS interrupt: a dead target cuts the cast
do
    mq.cmd('/target id 9')
    w.spawns[9].hp = 0
    local reason = Dps.interruptHook({ from = 'DPS', name = 'Ice Comet', facts = Spell.facts('Ice Comet'), timeLeftMs = 900 })
    assert(reason == 'target is dead', 'cut: ' .. tostring(reason))
    w.spawns[9].hp = 85
    assert(Dps.interruptHook({ from = 'DPS', name = 'Ice Comet', facts = Spell.facts('Ice Comet'), timeLeftMs = 900 }) == nil, 'alive: keep casting')
    mq.cmd('/target clear')
end

-- AE: two haters in radius fire the AE line, one does not
do
    w.xtargets = { 9, 10 }
    tick()
    mq.cmds = {}
    Dps:aeCheck()
    assert(World.count(mq, '^/cast "Burning Rain"') == 1, 'AE on two: ' .. table.concat(mq.cmds, ';'))
    w.xtargets = { 9 }
    tick()
    mq.cmds = {}
    Dps:aeCheck()
    assert(World.count(mq, '^/cast "Burning Rain"') == 0, 'one mob: no AE')
end

-- burn: /burn announces and walks the list; a named triggers it once per fight
do
    State.campZone = 100
    mq.cmds = {}
    Dps.Binds['/burn'](Dps)
    assert(World.count(mq, 'BURN ACTIVATED') == 1 and World.count(mq, '^/cast "Big Burn"') == 1, 'burn: ' .. table.concat(mq.cmds, ';'))
    w.spawns[9].named = true
    State.namedCheck = false
    mq.cmds = {}
    Dps:namedWatch(9)
    assert(State.namedCheck and World.count(mq, '^/cast "Big Burn"') == 1, 'named burn: ' .. table.concat(mq.cmds, ';'))
    w.spawns[9].named = false
end

-- debuffs: the slow lands on the kill target once, then the line is listed until its timer runs out
do
    tick()
    mq.cmds = {}
    Debuffs:doDebuffStuff(9)
    assert(World.count(mq, '^/cast "Slow Spell"') == 1, 'slowed: ' .. table.concat(mq.cmds, ';'))
    assert(Debuffs.lists[1] and Debuffs.lists[1][9] and Timers.running('dbo:1'), 'listed and timed')
    tick()
    mq.cmds = {}
    Debuffs:doDebuffStuff(9)
    assert(World.count(mq, '^/cast "Slow Spell"') == 0, 'not again: ' .. table.concat(mq.cmds, ';'))
    assert(Debuffs.isDispel('Ice Comet') == false, 'not a dispel')
end

-- mez: the second hater is mezzed with the claim broadcasts; a peer's claim keeps me off a mob
do
    w.xtargets = { 9, 10 }
    tick()
    assert(Mez:needed(), 'a loose add: mez needed')
    mq.cmds = {}
    Mez:doMezStuff()
    assert(World.count(mq, '^/cast "Mesmerize"') == 1, 'mezzed the bat: ' .. table.concat(mq.cmds, ';'))
    assert(World.count(mq, 'MEZZING2%-> a bat <%- ID:10') == 1 and World.count(mq, 'CCCLAIM%-> a bat <%- ID:10 BY:Bob') == 1, 'claims: ' .. table.concat(mq.cmds, ';'))
    local row = nil
    for i, r in ipairs(Mez.array) do if r.id == 10 then row = i end end
    assert(#Mez.array == 2 and row and Timers.running('mez:' .. row), 'the table holds both haters and my timer runs on the bat: ' .. #Mez.array)
    w.spawns[10].anim = 26
    tick()
    assert(not Mez:needed(), 'mezzed: no longer needed')
    -- a peer claims a third mob: I leave it alone
    w.spawns[11] = { id = 11, name = 'a cat', type = 'NPC', dist = 20, hp = 100, level = 50, x = 15, y = 10 }
    w.xtargets = { 9, 10, 11 }
    mq.events['ma_ccclaim1'].fn('x', 'Enc2', 'a cat', '11', 'Enc2', '20')
    assert(Mez.ccHeldByOther(11) == nil, 'the holder must be a live PC in zone')
    w.spawns[12] = { id = 12, name = 'Enc2', type = 'PC', dist = 30 }
    assert(Mez.ccHeldByOther(11) == 'Enc2', 'held by Enc2')
    tick()
    mq.cmds = {}
    Mez:doMezStuff()
    assert(World.count(mq, '^/cast "Mesmerize"') == 0, 'a claimed mob is left alone: ' .. table.concat(mq.cmds, ';'))
    mq.events['ma_ccrelease1'].fn('x', 'Enc2', 'a cat', '11')
    assert(Mez.ccHeldByOther(11) == nil, 'released')
    -- the awaken line resets my timer and re-mezzes
    tick()
    mq.cmds = {}
    w.spawns[10].anim = 0
    mq.events['ma_mezbroke'].fn('x', 'a bat', 'Al')
    assert(World.count(mq, '^/cast "Mesmerize"') >= 1, 'awakened: re-mezzed: ' .. table.concat(mq.cmds, ';'))
    assert(World.count(mq, 'has awakened') == 1, 'announced')
    -- an awaken line that arrives while I am casting waits for the cast to end (never a cast inside Cast.wait)
    tick()
    w.spawns[10].anim = 0
    Timers.clear('mez:2') Timers.clear('mez:1')
    w.castEndsAt = mq.now + 2000
    mq.cmds = {}
    mq.events['ma_mezbroke'].fn('x', 'a bat', 'Al')
    assert(World.count(mq, '^/cast') == 0 and Mez.brokePending and Mez.brokePending.mob == 'a bat', 'queued while casting: ' .. table.concat(mq.cmds, ';'))
    w.castEndsAt = -1
    tick()
    mq.cmds = {}
    Mez:GiveTime({ inCombat = true })
    assert(Mez.brokePending == nil and World.count(mq, 'has awakened') == 1, 'run from the next pass: ' .. table.concat(mq.cmds, ';'))
    -- immune: the chat line adds the mob to the zone list
    mq.cmd('/target id 11')
    mq.events['ma_mezimmune'].fn('x')
    assert(Mez.immuneIds[11] and data['MuleAssist_srv_Bob.ini'] and Ini.read('KissAssist_Info.ini', 'commonlands', 'MezImmune') == 'a cat', 'immune persisted: ' .. tostring(Ini.read('KissAssist_Info.ini', 'commonlands', 'MezImmune')))
    assert(State.mezImmuneNames['a cat'], 'the combat ranking sees it')
    mq.cmd('/target clear')
    w.xtargets = { 9 }
end

-- charm: /charmthis protects the mob group-wide and adopts it; the charmed line registers the pet
do
    w.spawns[20] = { id = 20, name = 'a wolf', type = 'NPC', dist = 20, hp = 100, level = 60 }
    mq.cmds = {}
    Charm.Binds['/charmthis'](Charm, '20', '', '')
    assert(State.charmPetIds[20] and Charm.petId == 20, 'protected and adopted')
    assert(World.count(mq, '^/squelch /dex Tank /charmthis 20 Box') == 1, 'fanned out to the group: ' .. table.concat(mq.cmds, ';'))
    -- the recharm casts the charm spell on it
    tick()
    mq.cmds = {}
    Charm:maintenance()
    assert(World.count(mq, '^/cast "Charm Spell"') >= 1 and World.count(mq, '^/cast "Charm Spell"') <= 3, 'charm cast, at most three tries: ' .. table.concat(mq.cmds, ';'))
    assert(World.count(mq, '^/dgge /charmping 20 Bob') == 1, 'the heartbeat')
    -- it lands: the pet is mine
    w.spawns[20].type = 'Pet'
    World.set(mq, 'Me.Pet.ID', 20)
    mq.cmds = {}
    mq.events['ma_charmed1'].fn('x', 'a wolf')
    assert(Charm.petId == 20 and World.count(mq, 'is my new pet') == 1, 'registered: ' .. table.concat(mq.cmds, ';'))
    -- /charmdel from a peer drops it from the list
    Charm.Binds['/charmdel'](Charm, '20')
    assert(not State.charmPetIds[20] and Charm.petId == 0, 'deleted')
    World.set(mq, 'Me.Pet.ID', 0)
    -- a mob that cannot be charmed is skipped and persisted
    w.spawns[21] = { id = 21, name = 'a golem', type = 'NPC', dist = 20, hp = 100, level = 60 }
    Charm.Binds['/charmthis'](Charm, '21', 'Box', '')
    mq.cmd('/target id 21')
    mq.events['ma_cannotcharm'].fn('x')
    assert(Mez.charmSkipIds[21] and Ini.read('KissAssist_Info.ini', 'commonlands', 'CharmImmune') == 'a golem' and Charm.petId == 0, 'cannot charm handled')
    mq.cmd('/target clear')
end

-- a burn runs the heal check before every entry
do
    local Heals = require('modules.heals')
    local orig, n = Heals.checkHealthIfOn, 0
    Heals.checkHealthIfOn = function() n = n + 1 end
    State.campZone = T.zoneId()
    State.myTargetId = 9
    w.spawns[9] = w.spawns[9] or { id = 9, name = 'a rat', type = 'NPC', dist = 20, hp = 85 }
    Dps:burnPass()
    Heals.checkHealthIfOn = orig
    assert(n >= #Dps.burn, 'a heal check per burn entry: ' .. n .. ' for ' .. #Dps.burn)
end

-- the |Burn this| event follows BurnText once settings load; tribute goes off after the burn window
do
    assert(mq.events['ma_burn'].pattern == '[MQ2] |Burn this|', 'the default burn text')
    Dps.cfg.BurnText = 'Nuke it'
    Dps:registerBurnEvent()
    assert(mq.events['ma_burn'].pattern == '[MQ2] |Nuke it|', 'a custom BurnText: ' .. tostring(mq.events['ma_burn'].pattern))
    Dps.cfg.BurnText = 'Burn this'
    Dps:registerBurnEvent()
    -- /muleassist reload runs LoadSettings from a bind coroutine: the event waits for the main-loop Tick
    Cast.captureMainCoroutine()
    Dps.cfg.BurnText = 'Smash it'
    coroutine.wrap(function() Dps:registerBurnEvent() end)()
    assert(mq.events['ma_burn'].pattern == '[MQ2] |Burn this|' and Dps.burnEventPending, 'not registered from a bind coroutine')
    Dps:Tick()
    assert(mq.events['ma_burn'].pattern == '[MQ2] |Smash it|' and not Dps.burnEventPending, 'registered by the next Tick')
    Dps.cfg.BurnText = 'Burn this'
    Dps:registerBurnEvent()
    Dps.cfg.UseTribute = 1
    Dps.tributeOn = true
    World.set(mq, 'Me.TributeActive', true)
    Timers.set('dps:tribute', 1000)
    w.xtargets = {}
    tick()
    mq.cmds = {}
    Dps:GiveTime({ inCombat = false })
    assert(World.count(mq, 'tribute personal off') == 0, 'the window is still running')
    tick(2000)
    Dps:GiveTime({ inCombat = false })
    assert(World.count(mq, '/squelch /tribute personal off') == 1 and not Dps.tributeOn, 'tribute off after the window: ' .. table.concat(mq.cmds, ';'))
    World.set(mq, 'Me.TributeActive', false)
    Dps.cfg.UseTribute = 0
end

-- a /getaway taken mid-pass (through the pass's own doevents) stops the DPS list there: the get away clears the
-- kill target, and the pass must not keep nuking its own copy of the mob id (necros kept casting DoTs)
do
    Mez.cfg.MezOn = 0
    tick(60000)
    State.myTargetId, State.getAwayOn = 9, false
    local realDo = mq.doevents
    mq.doevents = function()
        State.getAwayOn, State.myTargetId = true, 0   -- /getaway go <MA> arrives
    end
    mq.cmds = {}
    Dps:combatCast(9)
    mq.doevents = realDo
    assert(World.count(mq, '^/cast') == 0, 'no cast after the get away arrived: ' .. table.concat(mq.cmds, ';'))
    -- and a pass that starts during a get away does nothing
    mq.cmds = {}
    State.myTargetId = 9
    Dps:combatCast(9)
    assert(World.count(mq, '^/cast') == 0, 'no DPS pass while get away is on')
    State.getAwayOn, State.myTargetId = false, 9
end

-- ... and inside an entry: a /getaway taken by the mez / heal passes (after the entry's first check) or during
-- the entry's own cast stops the pass before the next action - no cast, no next entry, no weave
do
    Mez.cfg.MezOn = 0
    local H = require('modules.heals')
    local realHeal, realCast = H.checkHealthIfOn, Cast.cast
    local calls = {}
    Cast.cast = function(name, id, from, o) calls[#calls + 1] = name return realCast(name, id, from, o) end

    tick(60000)
    State.myTargetId, State.getAwayOn = 9, false
    H.checkHealthIfOn = function() State.getAwayOn, State.myTargetId = true, 0 end
    calls = {}
    Dps:combatCast(9)
    H.checkHealthIfOn = realHeal
    assert(#calls == 0, 'get away during the heal check: no cast reached: ' .. table.concat(calls, ','))

    tick(60000)
    State.myTargetId, State.getAwayOn = 9, false
    calls = {}
    Cast.cast = function(name, id, from, o)
        calls[#calls + 1] = name
        local r = realCast(name, id, from, o)
        State.getAwayOn, State.myTargetId = true, 0   -- arrives during this cast's wait
        World.set(mq, 'Me.SpellInCooldown', true)       -- the global cooldown after a spell
        return r
    end
    -- the weave / mash step that follows an entry's cast must not run on the old mob either
    local Cmb = require('modules.combat')
    local realWeave, realMash, realW, realM = Cmb.weaveStuff, Cmb.mashButtons, Cmb.weave, Cmb.mash
    local weaved = 0
    Cmb.weave, Cmb.mash = { { name = 'Weave Nuke', pct = 100, cond = 'TRUE' } }, { 'Mash' }
    Cmb.weaveStuff = function() if State.getAwayOn then weaved = weaved + 1 end end
    Cmb.mashButtons = function() if State.getAwayOn then weaved = weaved + 1 end end
    World.set(mq, 'Me.SpellInCooldown', false)
    Dps:combatCast(9)
    Cmb.weaveStuff, Cmb.mashButtons, Cmb.weave, Cmb.mash = realWeave, realMash, realW, realM
    World.set(mq, 'Me.SpellInCooldown', false)
    assert(#calls == 1, 'get away during a cast: the pass ends after it: ' .. table.concat(calls, ','))
    assert(weaved == 0, 'no weave / mash on the old mob after a get away taken during the cast')

    Cast.cast = realCast
    State.getAwayOn, State.myTargetId = false, 9
end

-- the debuff pass: a /getaway taken inside a line (the mez pass, or the retarget / buff / cooldown waits) stops
-- it before that line's cast; one taken during a cast stops the pass before the adds
do
    local realCast, realMez = Cast.cast, Debuffs.hooks.mezPass
    local calls = {}
    Cast.cast = function(name, id, from, o) calls[#calls + 1] = name return realCast(name, id, from, o) end
    Debuffs.cfg.DebuffAllOn = 1
    Debuffs.lists = {}
    Timers.clear('dbo:1')
    State.myTargetId, State.getAwayOn = 9, false

    Debuffs.hooks.mezPass = function() State.getAwayOn, State.myTargetId = true, 0 end
    calls = {}
    Debuffs:doDebuffStuff(9)
    assert(#calls == 0, 'get away during the mez pass: no debuff cast: ' .. table.concat(calls, ','))
    Debuffs.hooks.mezPass = realMez

    -- inside the retarget / buff waits: the pass reaches the cast point after them
    State.getAwayOn, State.myTargetId = false, 9
    Debuffs.lists = {}
    Timers.clear('dbo:1')
    local Buffcheck = require('core.buffcheck')
    local realWait = Buffcheck.cacheBuffs
    Buffcheck.cacheBuffs = function(...) State.getAwayOn, State.myTargetId = true, 0 return realWait(...) end
    calls = {}
    Debuffs:doDebuffStuff(9)
    Buffcheck.cacheBuffs = realWait
    assert(#calls == 0, 'get away during the buff wait: no debuff cast: ' .. table.concat(calls, ','))

    Cast.cast, Debuffs.hooks.mezPass = realCast, realMez
    State.getAwayOn, State.myTargetId = false, 9
end

-- a burn pass stops when a get away arrives mid-list (no cooldowns spent on the way out)
do
    local realCast = Cast.cast
    local calls = {}
    Cast.cast = function(name) calls[#calls + 1] = name State.getAwayOn = true return 'CAST_SUCCESS' end
    local realBurn = Dps.burn
    Dps.burn = { { index = 1, name = 'Big Burn', target = 'me', cond = 'TRUE', part3 = '', part4 = '' },
        { index = 2, name = 'Bigger Burn', target = 'me', cond = 'TRUE', part3 = '', part4 = '' } }
    State.getAwayOn = false
    Dps:burnPass()
    assert(#calls == 1, 'burn stops after the get away: ' .. table.concat(calls, ','))
    calls = {}
    Dps:burnPass()
    assert(#calls == 0, 'no burn pass while get away is on')
    Dps.burn, Cast.cast = realBurn, realCast
    State.getAwayOn = false
end

-- MezAESpell / MezAEStunSpell are 'Spell|count': the name part is ranked like every other spell setting, or
-- "Wake of Subdual" never matches the "Wake of Subdual Rk. II" in the gem and the AE mez is never ready
do
    w.spells['Wake of Subdual Rk. II'] = { st = 'Detrimental', tt = 'Targeted AE', aerange = 25, dur = 54, castMs = 4000, mana = 1000, spa = { [31] = true } }
    w.spells['Color Shift Rk. III'] = { st = 'Detrimental', tt = 'PB AE', aerange = 30, dur = 0, castMs = 2000, mana = 200 }
    local realMez, realStun = data['MuleAssist_srv_Bob.ini'].Mez.MezAESpell, data['MuleAssist_srv_Bob.ini'].Mez.MezAEStunSpell
    data['MuleAssist_srv_Bob.ini'].Mez.MezAESpell = 'Wake of Subdual|3'
    data['MuleAssist_srv_Bob.ini'].Mez.MezAEStunSpell = 'Color Shift|5'
    Mez:LoadSettings()
    assert(Mez.aeSpell == 'Wake of Subdual Rk. II' and Mez.aeNeed == 3, 'AE mez name ranked: ' .. Mez.aeSpell)
    assert(Mez.aeStunSpell == 'Color Shift Rk. III' and Mez.aeStunNeed == 5, 'AE stun name ranked: ' .. Mez.aeStunSpell)
    data['MuleAssist_srv_Bob.ini'].Mez.MezAESpell, data['MuleAssist_srv_Bob.ini'].Mez.MezAEStunSpell = realMez, realStun
    Mez:LoadSettings()
    assert(Mez.aeSpell == 'Wave', 'an unranked spell is left alone')
end

print('dps_test OK')
