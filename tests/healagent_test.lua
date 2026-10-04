-- lua tests/healagent_test.lua   (from lua/muleassist)
-- modules/healagent.lua: the heal ledger snapshot built from bot state (not macro variables), its 250 ms /
-- 1 Hz parts, events from counter deltas and /whynot, and the send to the brain.
package.path = './?.lua;./?/init.lua;' .. package.path
local Stub = require('tests.stub_mq')
local mq = Stub.new({})
local World = require('tests.world')
local Ini = require('core.ini')
local Config = require('core.config')
local Timers = require('core.timers')
local State = require('core.state')
local Stats = require('core.stats')
local Log = require('core.log')
local T = require('core.tlo')

local sent = {}
package.loaded.actors = { register = function(name, fn)
    return { name = name, fn = fn, unregister = function() end,
        send = function(_, addr, payload) sent[#sent + 1] = { addr = addr, payload = payload } end }
end }

local data = { ['MuleAssist_srv_Bob.ini'] = {
    General = { MainAssist = 'Tank' },
    Heals = { HealsOn = '1', HealsSize = '4', Heals1 = 'Remedy|60', Heals2 = 'Word of Vivification|70',
        Heals3 = 'Light Healing|85|MA', Heals4 = 'Vampiric Touch|50|tap', HealBrainOn = '1', XTarHeal = '0', HealGroupPetsOn = '0' },
} }
Ini.use(Ini.tableBackend(data))
Config.iniFile = 'MuleAssist_srv_Bob.ini'
Config.condFile = Config.iniFile
Config.rankFn = function(n) return n end
Config.zoneId = function() return 100 end
Timers.setClock(function() return mq.now end)
local w = World.build(mq, {
    dannet = true, me = { class = 'CLR', curMana = 2000, x = 0, y = 0 }, groupN = 1,
    gems = { [1] = 'Remedy', [2] = 'Word of Vivification', [3] = 'Light Healing' },
    spells = {
        ['Remedy'] = { tt = 'Single', range = 150, dur = 0, castMs = 2000, mana = 100, heal = 50 },
        ['Word of Vivification'] = { tt = 'Group v2', aerange = 80, dur = 0, castMs = 2000, mana = 300, heal = 40 },
        ['Light Healing'] = { tt = 'Single', range = 100, dur = 0, castMs = 1000, mana = 50, heal = 30 },
        ['Vampiric Touch'] = { tt = 'Single', range = 100, dur = 0, castMs = 1000, mana = 50 },
    },
    group = { [0] = { id = 1, name = 'Bob', class = 'CLR' }, [1] = { id = 7, name = 'Tank', class = 'WAR' } },
})
w.spawns[7] = { id = 7, name = 'Tank', type = 'PC', dist = 20, hp = 80, x = 10, y = 0 }

local Heals = require('modules.heals')
Heals:LoadSettings({})
require('modules.cures').lines = { { name = 'Remove Poison', types = { poison = true }, any = false },
    { name = 'Pure Blood', types = {}, any = true } }
State.mainAssist, State.healTank, State.healTankId = 'Tank', 'Tank', 7
State.healsOn, State.curesOn = true, true

local A = require('modules.healagent')
A.reset()
A:LoadSettings({})
local function at(ms) mq.now = mq.now + (ms or 0) T.xtargetReset() end
local function find(list, pred) for _, v in ipairs(list or {}) do if pred(v) then return v end end end
local function target(s, id) return s.targets and (s.targets[id] or s.targets[tostring(id)]) end

-- 1: the setting
assert(State.healBrainOn == true, 'HealBrainOn read')

-- 2: a full (1 Hz) snapshot from bot state
local s = A:snapshot(mq.now, true)
assert(s.v == 1 and s.from == 'Bob' and s.id == 1 and type(s.seq) == 'number', 'header')
assert(s.me and s.me.class == 'CLR' and type(s.me.hp) == 'number' and type(s.me.mana) == 'number', 'me')
local rem = find(s.lines.direct, function(l) return l.name == 'Remedy' end)
assert(rem and rem.pct == 60 and rem.range == 150, 'direct line from heals.single, range = MyRange')
assert(find(Heals.single, function(l) return l.name == 'Vampiric Touch' end), 'the tap line is a single line')
assert(not find(s.lines.direct, function(l) return l.name == 'Vampiric Touch' end), 'tap-tagged line dropped')
assert(find(s.lines.direct, function(l) return l.name == 'Light Healing' end), 'MA-tagged single line kept')
local grp = find(s.lines.group, function(l) return l.name == 'Word of Vivification' end)
assert(grp and grp.pct == 70 and grp.range == 80, 'group line from heals.group, range = AERange')
assert(s.lines.cures[1] and s.lines.cures[1].name == 'Remove Poison' and s.lines.cures[1].types.poison, 'cure line')
assert(s.lines.cures[2] and s.lines.cures[2].name == 'Pure Blood' and next(s.lines.cures[2].types) == nil, 'any cure: empty types')
assert(s.macro.healPets == false, 'healPets is a boolean')
local tk = target(s, 7)
assert(tk and tk.name == 'Tank' and tk.hp == 80, 'group target')
assert(s.macro.healsOn == 1 and s.macro.curesOn == 1, 'booleans sent as 1/0')
assert(s.macro.healLine == State.singleHealPoint and s.macro.tankLine == State.singleHealPointMA, 'heal lines')
assert(s.macro.healTank == 'Tank' and s.macro.healTankId == 7 and not s.macro.isMA, 'heal tank, not MA')
assert(s.stats and s.stats.single == Stats.hs.single and type(s.stats.line) == 'string' and type(s.stats.sinceSec) == 'number', 'stats')

-- 3: a 250 ms snapshot carries no 1 Hz parts
local p = A:snapshot(mq.now, false)
assert(p.lines == nil and p.stats == nil and p.macro == nil and p.me ~= nil, 'partial snapshot')

-- 4: events - none on the first pass, then from counter deltas and /whynot
A.reset()
A:LoadSettings({})
local first = A:snapshot(mq.now, true)
assert(#(first.events or {}) == 0, 'first pass seeds, no events')
Stats.bump('intHeal')
local e1 = A:snapshot(mq.now, true)
assert(find(e1.events, function(e) return e.kind == 'interrupt' end), 'interrupt event from intHeal')
Stats.bump('groupRange')
local e2 = A:snapshot(mq.now, true)
assert(find(e2.events, function(e) return e.kind == 'withheld' and e.spell == 'group heal' end), 'group heal withheld')
Stats.cureUnready('Remove Poison')
local e3 = A:snapshot(mq.now, true)
assert(find(e3.events, function(e) return e.kind == 'withheld' and e.spell == 'Remove Poison' end), 'cure unready withheld')
Log.whyNot('SingleHeal', 'Remedy', '7', 'no line')
local e4 = A:snapshot(mq.now, true)
local wn = find(e4.events, function(e) return e.kind == 'withheld' and e.spell == 'Remedy' end)
assert(wn and tonumber(wn.targetId) == 7 and wn.targetName == 'Tank' and tostring(wn.reason):find('no line'), 'whynot withheld, id resolved')
local e5 = A:snapshot(mq.now, true)
assert(not find(e5.events, function(e) return e.spell == 'Remedy' end), 'a whynot entry is reported once')

-- 5: one send per 250 ms to the brain address
sent = {}
at(250) A:Tick({})
assert(#sent == 1 and sent[1].addr.mailbox == 'heal_brain' and sent[1].addr.script == 'muleassist' and sent[1].payload.from == 'Bob', 'sent to the brain')
A:Tick({})
assert(#sent == 1, 'not twice in one window')
at(250) A:Tick({})
assert(#sent == 2, 'next window')
assert(sent[1].payload.lines ~= nil and sent[2].payload.lines == nil, '1 Hz parts on the first send only')
at(250) A:Tick({}) at(250) A:Tick({}) at(250) A:Tick({})
assert(#sent == 5 and sent[3].payload.lines == nil and sent[4].payload.lines == nil and sent[5].payload.lines ~= nil, 'full again 1000 ms later')

-- 5b: on a 250 ms grid - main-loop passes every 100 ms give ~4 sends a second, not ~3.3
sent = {}
for _ = 1, 40 do at(100) A:Tick({}) end
assert(#sent >= 15 and #sent <= 17, '4 s of 100 ms passes: ~16 sends, got ' .. #sent)

-- 6: the MA flag
State.mainAssist = 'Bob'
assert(A:snapshot(mq.now, true).macro.isMA == true, 'MA flag')
State.mainAssist = 'Tank'

-- 7: /healbrainon off stops sending and saves the setting
A.Binds['/healbrainon'](A, 'off')
assert(State.healBrainOn == false and data['MuleAssist_srv_Bob.ini'].Heals.HealBrainOn == '0', 'off saved')
sent = {}
at(500) A:Tick({})
assert(#sent == 0, 'nothing sent while off')
A.Binds['/healbrainon'](A)
assert(State.healBrainOn == true, 'bare toggle flips back on')

-- 8: snapshots keep flowing while the cast engine waits on a cast (its interrupt hooks)
local Cast = require('core.cast')
assert(type(Cast.interruptHooks.healagent) == 'function', 'interrupt hook installed')
A:LoadSettings({})
local hook = Cast.interruptHooks.healagent
assert(type(hook) == 'function', 'LoadSettings again is harmless')
local ctx = { name = 'Remedy', targetId = 7, from = 'SingleHeal', facts = require('core.spell').facts('Remedy'), timeLeftMs = 1500, kind = 'spell' }
World.set(mq, 'Me.Casting', 'Remedy')
World.set(mq, 'Me.CastTimeLeft', 1500)
sent = {}
at(250)
assert(hook(ctx) == nil, 'the hook never interrupts')
assert(#sent == 1, 'a snapshot sent from inside the cast wait')
local cst = sent[1].payload.me.casting
assert(cst and cst.spell == 'Remedy' and tonumber(cst.targetId) == 7 and cst.kind == 'direct' and cst.landsAt > mq.now, 'cast in flight from the hook ctx')
assert(hook(ctx) == nil and #sent == 1, 'the hook is throttled to 250 ms')
Stats.bump('intHeal')
at(250) hook(ctx)
local ie = find(sent[2].payload.events, function(e) return e.kind == 'interrupt' end)
assert(ie and ie.spell == 'Remedy' and tonumber(ie.targetId) == 7, 'interrupt event names the cast')
local realSnap = A.snapshot
A.snapshot = function() error('boom') end
at(250)
assert(hook(ctx) == nil, 'an agent error never reaches the cast')
A.snapshot = realSnap
World.set(mq, 'Me.Casting', nil)
World.set(mq, 'Me.CastTimeLeft', 0)

-- 8a: the cast engine's tick hook samples outside the cast bar too (the post-cast cooldown wait), never twice in 250 ms
assert(type(Cast.tickHooks.healagent) == 'function', 'tick hook installed')
w.spells['Slow Nuke'] = { st = 'Detrimental', tt = 'Single', range = 200, dur = 0, castMs = 1000, mana = 10 }
w.gems[4] = 'Slow Nuke'
w.spawns[9] = { id = 9, name = 'a rat', type = 'NPC', dist = 20, hp = 100 }
require('core.spell').clearCache()
local lastDelay
mq.onDelay = function(ms) lastDelay = ms end
local sends = {}
local realSend = A.dropbox.send
A.dropbox.send = function(box, addr, payload)
    sends[#sends + 1] = { at = mq.now, delay = lastDelay, cast = World.count(mq, '^/cast "Slow Nuke"') }
    return realSend(box, addr, payload)
end
mq.cmds = {}
local castRes = Cast.cast('Slow Nuke', 9, 'DPS')
A.dropbox.send = realSend
mq.onDelay = nil
assert(castRes == 'CAST_SUCCESS', 'the cast ran: ' .. tostring(castRes))
local postCast = false
for _, s8 in ipairs(sends) do if s8.cast > 0 and s8.delay == 2000 then postCast = true end end
assert(postCast, 'a snapshot sent from the post-cast cooldown wait')
for i = 2, #sends do assert(sends[i].at - sends[i - 1].at >= 250, 'never two sends inside 250 ms') end

-- 8b: back-to-back casts of one spell (no empty Me.Casting sample between) are separate casts
w.spawns[21] = { id = 21, name = 'Healee', type = 'PC', dist = 30, hp = 50, x = 3, y = 0 }
local function castCtx(id, left) return { name = 'Remedy', targetId = id, from = 'SingleHeal', facts = ctx.facts, timeLeftMs = left, kind = 'spell' } end
local function castNow() return sent[#sent].payload.me.casting end
World.set(mq, 'Me.Casting', 'Remedy')
sent = {}
World.set(mq, 'Me.CastTimeLeft', 2000)
at(250) hook(castCtx(7, 2000))
local c1 = castNow()
assert(#sent == 1 and c1 and tonumber(c1.targetId) == 7, 'first Remedy on 7')
World.set(mq, 'Me.CastTimeLeft', 1900)
at(250) hook(castCtx(21, 1900))
local c2 = castNow()
assert(#sent == 2 and tonumber(c2.targetId) == 21 and c2.targetName == 'Healee', 'second Remedy on its own target')
assert(c2.startedAt > c1.startedAt and c2.landsAt > c1.landsAt, 'second Remedy has its own start')
World.set(mq, 'Me.CastTimeLeft', 2000)
at(250) hook(castCtx(21, 2000))
local c3 = castNow()
assert(#sent == 3 and c3.startedAt > c2.startedAt, 'a fresh cast bar on the same target is a new cast')
World.set(mq, 'Me.CastTimeLeft', 1700)
at(250) hook(castCtx(21, 1700))
assert(#sent == 4 and castNow().startedAt == c3.startedAt, 'the same cast keeps its start')
World.set(mq, 'Me.Casting', nil)
World.set(mq, 'Me.CastTimeLeft', 0)

-- 9: no stale events after off/on
A.Binds['/healbrainon'](A, 'off')
at(250) A:Tick({})
Stats.bump('intHeal')
Log.whyNot('SingleHeal', 'Remedy', '7', 'stale entry')
at(250) A:Tick({})
A.Binds['/healbrainon'](A, 'on')
sent = {}
at(250) A:Tick({})
assert(#sent == 1 and #(sent[1].payload.events or {}) == 0, 'first snapshot after on has no stale events')

-- 10: no heal tank is nil, not ''
State.healTank = ''
assert(A:snapshot(mq.now, true).macro.healTank == nil, 'empty heal tank sent as nil')
State.healTank = 'Tank'

-- 11: the MA's raid roster: names / groups / classes cached, HP and position every pass
local raid = { { name = 'Tank', id = 7, class = 'WAR', group = 1 }, { name = 'Cleric2', id = 20, class = 'CLR', group = 2 } }
w.spawns[20] = { id = 20, name = 'Cleric2', type = 'PC', hp = 55, x = 5, y = 5 }
w.spawns[30] = { id = 30, name = 'Druid3', type = 'PC', hp = 90, x = 1, y = 1 }
local nameReads = 0
rawget(mq.TLO.Raid, '__children').Members = mq.build({ _ = function() return #raid end })
rawget(mq.TLO.Raid, '__children').Member = mq.callable(function(i)
    local r = type(i) == 'number' and raid[i] or nil
    if not r then return mq.build({ ID = 0, Name = '', Group = 0, Class = { ShortName = '' } }) end
    local sp = w.spawns[r.id]
    return mq.build({ _ = r.name, Name = { _ = function() nameReads = nameReads + 1 return r.name end }, Group = r.group,
        Class = { ShortName = r.class },
        Spawn = { _ = sp and true or nil, ID = sp and sp.id or 0, PctHPs = { _ = function() return sp and sp.hp end },
            X = sp and sp.x or 0, Y = sp and sp.y or 0, Z = 0, CleanName = r.name, Class = { ShortName = r.class } } })
end)
assert(target(A:snapshot(mq.now, true), 20) == nil, 'no raid roster when not the MA')
State.mainAssist = 'Bob'
local r1 = A:snapshot(mq.now, true)
local c2 = target(r1, 20)
assert(c2 and c2.name == 'Cleric2' and c2.hp == 55 and c2.group == 'raid:2' and c2.class == 'CLR' and c2.x == 5, 'raider record')
assert(target(r1, 7).group ~= 'raid:1', 'a group member keeps its group record')
local reads = nameReads
w.spawns[20].hp = 40
at(1000)
assert(target(A:snapshot(mq.now, true), 20).hp == 40, 'raider hp read every pass')
assert(nameReads == reads, 'roster names cached')
raid[1], raid[2] = raid[2], raid[1]
at(1000)
assert(target(A:snapshot(mq.now, true), 20).name == 'Cleric2', 'a reordered roster keeps names right')
raid[3] = { name = 'Druid3', id = 30, class = 'DRU', group = 3 }
reads = nameReads
at(1000)
local r3 = A:snapshot(mq.now, true)
assert(nameReads > reads and target(r3, 30) and target(r3, 30).name == 'Druid3' and target(r3, 30).group == 'raid:3', 'a roster change refreshes at once')
reads = nameReads
at(1000) A:snapshot(mq.now, true)
assert(nameReads == reads, 'cached again')
at(10000) A:snapshot(mq.now, true)
assert(nameReads > reads, 'refreshed after 10 s')
State.mainAssist = 'Tank'

-- no actors.register from inside a tick hook (an mq.delay condition: a dead coroutine)
do
    local Cst = require('core.cast')
    if A.dropbox then pcall(function() A.dropbox:unregister() end) end
    A.dropbox, A.registerFailed = nil, false
    local got = 'unset'
    Cst.addTickHook('test_ha_register', function() got = A:register() end)
    Cst.tickDelay(1)
    Cst.removeTickHook('test_ha_register')
    assert(got == nil and A.dropbox == nil, 'the agent does not register its mailbox from a tick hook')
    assert(A:register() ~= nil, 'and does from the main loop')
end

print('healagent_test OK')
