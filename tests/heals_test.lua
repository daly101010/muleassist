-- luajit tests/heals_test.lua   (from lua/muleassist)
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
local Stats = require('core.stats')
local Log = require('core.log')
local T = require('core.tlo')
local Heals = require('modules.heals')
local Rez = require('modules.rez')
local HA = require('modules.healeraggro')
local OhShit = require('modules.ohshit')
local Combat = require('modules.combat')

local data = { ['MuleAssist_srv_Bob.ini'] = {
    General = { MainAssist = 'Tank', CampRadius = '30' },
    Melee = { MeleeDistance = '30' },
    Heals = { HealsOn = '1', HealsSize = '6', Heals1 = 'Word of Vivification|70', Heals2 = 'Remedy|60', Heals3 = 'Reviviscence|1|rez',
        Heals4 = 'Light Healing|85|MA', Heals5 = 'Pet Mend|50|pet', InterruptHeals = '100', AutoRezOn = '1', XTarHeal = '0' },
    HealerAggro = { HealerAggroOn = '1', HealerAggroSize = '2', HealerAggro1 = 'Taunt|Mob', HealerAggroDelay = '3' },
    OhShit = { OhShitOn = '1', OhShitSize = '2', OhShit1 = 'Divine Aura|Me' },
    ManaFeed = { ManaFeedSize = '1', ManaFeed1 = 'Quiet Miracle' },
} }
Ini.use(Ini.tableBackend(data))
Config.iniFile = 'MuleAssist_srv_Bob.ini'
Config.condFile = Config.iniFile
Config.rankFn = function(n) return n end
Config.zoneId = function() return 100 end
local now = 0
Timers.setClock(function() return now end)
local function tick(ms) now = math.max(now, mq.now or 0) + (ms or 500) mq.now = now T.xtargetReset() end
local w = World.build(mq, {
    dannet = true, me = { class = 'CLR', curMana = 2000, x = 0, y = 0 }, groupN = 2,
    spells = {
        ['Remedy'] = { tt = 'Single', range = 100, dur = 0, castMs = 2000, mana = 100, heal = 50 },
        ['Word of Vivification'] = { tt = 'Group v2', aerange = 80, dur = 0, castMs = 2000, mana = 300, heal = 40 },
        ['Reviviscence'] = { tt = 'Corpse', range = 100, dur = 0, castMs = 5000, mana = 400 },
        ['Light Healing'] = { tt = 'Single', range = 100, dur = 0, castMs = 1000, mana = 50, heal = 30 },
        ['Pet Mend'] = { tt = 'Single', range = 100, dur = 0, castMs = 1000, mana = 50 },
        ['Divine Aura'] = { tt = 'Self', dur = 18, castMs = 0, mana = 0 },
        ['Quiet Miracle'] = { tt = 'Single', range = 100, dur = 0, castMs = 3000, mana = 10 },
    },
    gems = { [1] = 'Remedy', [2] = 'Word of Vivification', [3] = 'Reviviscence', [4] = 'Light Healing', [5] = 'Pet Mend', [6] = 'Divine Aura', [8] = 'Yaulp' },
    group = { [0] = { id = 1, name = 'Bob', class = 'CLR' }, [1] = { id = 5, name = 'Tank', class = 'WAR' }, [2] = { id = 7, name = 'Al', class = 'ROG', mana = 10 } },
})
w.spawns[1] = { id = 1, name = 'Bob', type = 'PC', dist = 0, hp = 100 }
w.spawns[5] = { id = 5, name = 'Tank', type = 'PC', dist = 15, hp = 100 }
w.spawns[7] = { id = 7, name = 'Al', type = 'PC', dist = 20, hp = 100 }
w.spawns[9] = { id = 9, name = 'a rat', type = 'NPC', dist = 25, hp = 100 }
Spell.clearCache()
State.role = 'assist'
State.mainAssist, State.mainAssistType = 'Tank', 'PC'
Cast.LoadSettings()
Cast.registerEvents()
Combat:LoadSettings()
Heals:Init() Rez:Init() HA:Init() OhShit:Init()
Heals:LoadSettings() Rez:LoadSettings() HA:LoadSettings() OhShit:LoadSettings()
State.ohShitOn = false

-- the line split
do
    assert(#Heals.single == 3, 'three single lines: ' .. #Heals.single)
    assert(Heals.single[1].name == 'Pet Mend' and Heals.single[2].name == 'Remedy' and Heals.single[3].name == 'Light Healing', 'ascending by pct: ' .. Heals.single[1].name)
    assert(#Heals.group == 1 and Heals.group[1].name == 'Word of Vivification', 'the group spell')
    assert(#Heals.rezCombat == 1 and Heals.rezCombat[1] == 'Reviviscence' and #Heals.rezOOC == 1, 'the rez ladder')
    assert(Heals.singlePoint == 85 and Heals.singlePointMA == 85 and Heals.singleRange == 100, string.format('points %d %d %d', Heals.singlePoint, Heals.singlePointMA, Heals.singleRange))
    assert(State.healsOn and State.healTank == 'Tank', 'heals on, tank known: ' .. tostring(State.healTank))
end

-- a hurt rogue gets the direct heal; the heal is announced; a per-target timer stops a second one
do
    w.spawns[7].hp = 40
    mq.cmds = {}
    Heals:GiveTime({})
    assert(World.count(mq, '^/cast "Remedy"') == 1, 'Remedy on Al: ' .. table.concat(mq.cmds, ';'))
    assert(World.count(mq, 'Remedy on >> Al <<') == 1, 'announced over DanNet')
    assert(Stats.hs.single == 1 and Stats.hs.groupT == 1, 'counted as a group heal')
    assert(Stats.hs.lowName == 'Al' and Stats.hs.lowPct == 40, 'the lowest seen')
    w.spawns[7].hp = 100
end

-- out of mana with a hurt member: one pass, not six (HealAgain only follows a landed heal)
do
    w.spawns[7].hp = 40
    World.set(mq, 'Me.CurrentMana', 10)
    local passes, orig = 0, Heals.mostHurt
    Heals.mostHurt = function(self, ...) passes = passes + 1 return orig(self, ...) end
    tick()
    mq.cmds = {}
    Heals:checkHealth()
    Heals.mostHurt = orig
    assert(World.count(mq, '^/cast') == 0, 'no mana: nothing cast')
    assert(passes == 1, 'one pass when nothing landed: ' .. passes)
    World.set(mq, 'Me.CurrentMana', 2000)
    w.spawns[7].hp = 100
end

-- the heal tank line: |MA only lands on the tank, and the tank is healed at the MA point
do
    w.spawns[5].hp = 80
    tick(3000)
    mq.cmds = {}
    Heals:GiveTime({})
    assert(World.count(mq, '^/cast "Light Healing"') == 1, 'the MA line on the tank: ' .. table.concat(mq.cmds, ';'))
    assert(World.count(mq, '^/cast "Remedy"') == 0, 'Remedy (60) not needed at 80')
    assert(Stats.hs.tank == 1, "counted as a tank heal: tank=" .. Stats.hs.tank .. " groupT=" .. Stats.hs.groupT .. " oog=" .. Stats.hs.oog .. " self=" .. Stats.hs.self)
    w.spawns[5].hp = 100
    -- the same line never lands on a non-tank
    w.spawns[7].hp = 80
    tick(3000)
    mq.cmds = {}
    Heals:GiveTime({})
    assert(World.count(mq, '^/cast "Light Healing"') == 0, 'Light Healing is |MA: not for Al: ' .. table.concat(mq.cmds, ';'))
    w.spawns[7].hp = 100
end

-- a group heal when two are hurt (me and Al at 68: above Remedy's 60, under the group line's 70)
do
    w.spawns[1].hp, w.spawns[7].hp = 68, 68
    World.set(mq, 'Me.PctHPs', 68)
    tick(3000)
    mq.cmds = {}
    Heals:GiveTime({})
    assert(World.count(mq, '^/cast "Word of Vivification"') == 1, 'group heal: ' .. table.concat(mq.cmds, ';'))
    assert(World.count(mq, '^/cast') == 1, 'and nothing else')
    assert(Stats.hs.group == 1, 'counted')
    w.spawns[1].hp, w.spawns[7].hp = 100, 100
    World.set(mq, 'Me.PctHPs', 100)
end

-- a buff or a nuke on a healer is cut when a group member drops under the emergency line
do
    Heals.cfg.CastingInterruptOn = 1
    local ctx = { name = 'Shield', targetId = 1, from = 'Buffs', facts = {}, timeLeftMs = 2500, kind = 'spell' }
    assert(Heals.interruptHook(ctx) == nil, 'nobody hurt: the buff runs')
    w.spawns[7].hp = 30
    local why = Heals.interruptHook(ctx)
    assert(why and why:find('Al at 30', 1, true), 'Al at 30%: cut: ' .. tostring(why))
    ctx.timeLeftMs = 300
    assert(Heals.interruptHook(ctx) == nil, 'almost done: let it land')
    ctx.timeLeftMs, ctx.from = 2500, 'SingleHeal'
    w.spawns[7].hp = 100
    Heals.cfg.CastingInterruptOn = 0
end

-- the interrupt rule: the target climbed past the heal line in the last 0.8 s
do
    State.castTag = 'Heal'
    Heals.curLinePct = 60
    Heals.cfg.CastingInterruptOn = 1
    mq.cmd('/target id 7')
    w.spawns[7].hp = 95
    local reason = Heals.interruptHook({ from = 'SingleHeal', name = 'Remedy', facts = Spell.facts('Remedy'), timeLeftMs = 500 })
    assert(reason and reason:find('past 60%%'), 'interrupted: ' .. tostring(reason))
    assert(Stats.hs.intHeal == 1, 'counted as interrupted')
    assert(Heals.interruptHook({ from = 'SingleHeal', name = 'Remedy', facts = Spell.facts('Remedy'), timeLeftMs = 1500 }) == nil, 'not in the last 0.8 s')
    assert(Heals.interruptHook({ from = 'Buffs', name = 'Remedy', facts = Spell.facts('Remedy'), timeLeftMs = 100 }) == nil, 'only heal casts')
    Heals.cfg.CastingInterruptOn = 0
    w.spawns[7].hp = 100
    mq.cmd('/target clear')
end

-- smart heals: a fresh engine pick is cast; a stale heartbeat falls back
do
    package.loaded['modules.smartheal'] = { wanted = function() return true end, Tick = function() end, onResult = function() end }
    Heals.cfg.SmartHealsOn = 1
    State.smartHealsOn = true
    Heals.smartSet({ spell = 'Remedy', targetId = 7, tier = 'single', seq = 1, beat = 1, fallback = 0 })
    w.spawns[7].hp = 50
    tick(3000)
    mq.cmds = {}
    Heals:GiveTime({})
    assert(World.count(mq, '^/cast "Remedy"') == 1 and World.count(mq, '%(smart%)') == 1, 'smart pick cast: ' .. table.concat(mq.cmds, ';'))
    assert(Heals.smart.ack == 1 and Heals.smart.result == 'CAST_SUCCESS' and Stats.hs.smart == 1, 'acked')
    tick(6000)
    w.spawns[7].hp = 50
    mq.cmds = {}
    Heals:GiveTime({})
    assert(Heals.smart.warned and World.count(mq, '^/cast "Remedy"') == 1, 'stale bridge: legacy heals take over: ' .. table.concat(mq.cmds, ';'))
    package.loaded['modules.smartheal'] = nil
    Heals.cfg.SmartHealsOn = 0
    State.smartHealsOn = false
    w.spawns[7].hp = 100
end

-- rez: a group member's corpse is battle-rezzed with the ladder spell
do
    w.group[2].dead = true
    w.spawns[7] = { id = 7, name = 'Al', type = 'PC', dist = 20, hp = 100 }
    w.spawns[70] = { id = 70, name = "Al's corpse", owner = 'Al', type = 'Corpse', dist = 30, pc = true, group = true }
    assert(T.corpseOf('Al') and T.corpseOf('Al').ID() == 70, "the corpse is found by the pccorpse <name> form")
    assert(T.corpseOf('A') == nil, 'a substring hit on another name is rejected by the clean name')
    assert(T.spawnByName('Al', 'pccorpse') and T.spawnByName('Al', 'pccorpse').ID() == 70, 'spawnByName routes pccorpse to the corpse search')
    State.autoRezOn = true
    tick(3000)
    mq.cmds = {}
    Rez:GiveTime({})
    assert(World.count(mq, '^/cast "Reviviscence"') == 1, 'rezzed: ' .. table.concat(mq.cmds, ';'))
    assert(World.count(mq, 'BATTLE REZZED =>> Al') == 1, 'announced')
    assert(Timers.running('rez:battle:2'), 'the 3 m timer')
    -- a REZCLAIM from a peer holds my rez on that corpse
    mq.events['ma_rezclaim1'].fn('x', 'Nec', "Al's corpse", '70', 'Nec', '5')
    assert(Rez.claimHolder(70) == 'Nec', 'claim held')
    mq.events['ma_rezdone1'].fn('x', 'Nec', "Al's corpse", '70')
    assert(Rez.claimHolder(70) == nil, 'released')
    w.spawns[70] = nil
    w.group[2].dead = false
end

-- healer aggro: the healer reports a mob chewing on it, the tank spends a taunt on it
do
    w.spawns[9].aggro = 100
    w.spawns[9].dist = 10
    w.xtargets = { 9 }
    tick(3000)
    mq.cmds = {}
    Combat.hooks.gotHit('a rat')
    assert(World.count(mq, 'HEALERAGGRO%-> a rat <%- ID:9') == 1, 'reported: ' .. table.concat(mq.cmds, ';'))
    assert(Timers.running('ha:send'), 'send throttle')
    mq.cmds = {}
    Combat.hooks.gotHit('a rat')
    assert(World.count(mq, 'HEALERAGGRO') == 0, 'throttled')
    -- the tank side
    State.role = 'tank'
    State.mainAssist = 'Bob'
    w.abilities.Taunt = true
    w.spawns[9].aggro = 50
    mq.events['ma_healeraggro1'].fn('x', 'Cleric', '9')
    assert(HA.aggroId == 9 and Timers.running('ha:timer'), 'the report landed')
    mq.cmds = {}
    local r = HA:switch()
    assert(r == 0, 'default mode keeps the kill target: ' .. tostring(r))
    assert(World.count(mq, 'Taunt') >= 1, 'the taunt fired: ' .. table.concat(mq.cmds, ';'))
    assert(Timers.running('ha:burst'), 'one tool per delay')
    mq.events['ma_healeraggro_taunt'].fn('x', 'a rat')
    assert(not Timers.running('ha:timer'), 'taunt landed: holding the list')
    State.role = 'assist'
    State.mainAssist = 'Tank'
    w.xtargets = {}
    w.spawns[9].aggro = 0
end

-- fresh add hold: a loose hater away from the tank holds heals on non-tanks for 6 s
do
    w.spawns[9].x, w.spawns[9].y, w.spawns[9].dist = 50, 50, 40
    w.spawns[5].x, w.spawns[5].y = 0, 0
    w.xtargets = { 9 }
    tick(3000)
    assert(HA:freshAdd() == 9, 'the rat is a fresh add')
    w.spawns[7].hp = 60
    mq.cmds = {}
    Heals:GiveTime({})
    assert(World.count(mq, '^/cast') == 0, 'heal held: ' .. table.concat(mq.cmds, ';'))
    tick(7000)
    assert(HA:freshAdd() == 0, 'hold expired')
    mq.cmds = {}
    Heals:GiveTime({})
    assert(World.count(mq, '^/cast "Remedy"') == 1, 'healed after the hold')
    w.spawns[7].hp = 100
    w.xtargets = {}
end

-- ohshit: an entry with a TRUE condition fires on me
do
    State.ohShitOn = true
    tick(3000)
    mq.cmds = {}
    OhShit:check('test')
    assert(World.count(mq, '^/cast "Divine Aura"') == 1, 'ohshit cast: ' .. table.concat(mq.cmds, ';'))
    local e = OhShit.parseEntry('command:/say help me|Tank', 'TRUE')
    assert(e.command == '/say help me' and e.target == 'Tank', 'command entry parsed: ' .. tostring(e.command))
    State.ohShitOn = false
end

-- mana feed: /manafeed mems the feed spell over gem 1 and restores it when done
do
    w.group[2].class = 'ENC'
    mq.cmds = {}
    Heals.Binds['/manafeed'](Heals)
    assert(Heals.manaFeedOn and World.count(mq, '^/memspell 1 "Quiet Miracle"') == 1, 'feed memmed: ' .. table.concat(mq.cmds, ';'))
    assert(Heals.manaFeedOldGems[1] == 'Remedy', 'old gem remembered')
    mq.cmds = {}
    Heals:GiveTime({})
    assert(World.count(mq, '^/cast "Quiet Miracle"') == 1 and World.count(mq, 'MANA FEED >> Al') == 1, 'fed Al: ' .. table.concat(mq.cmds, ';'))
    w.group[2].mana = 90
    mq.cmds = {}
    Heals:GiveTime({})
    assert(not Heals.manaFeedOn and World.count(mq, '^/memspell 1 "Remedy"') == 1, 'done and restored: ' .. table.concat(mq.cmds, ';'))
end

-- smart heals report every cast / skip back to modules/smartheal (no mailbox)
do
    local reported = {}
    package.loaded['modules.smartheal'] = { onResult = function(seq, res) reported[#reported + 1] = { seq = seq, res = res } end }
    Heals.cfg.SmartHealsOn = 1
    State.smartHealsOn = true
    Heals.smart.ack = 0
    Heals.smartSet({ spell = 'Remedy', targetId = 7, tier = 'single', seq = 5, beat = 99, fallback = 0 })
    w.spawns[7].hp = 50
    tick(3000)
    mq.cmds = {}
    Heals:GiveTime({})
    assert(#reported >= 1 and reported[1].seq == 5 and reported[1].res == 'CAST_SUCCESS', 'cast reported: ' .. tostring(reported[1] and reported[1].res))
    Heals.smartSet({ spell = '', targetId = 0, tier = 'none', seq = 6, beat = 100, fallback = 0 })
    tick(500)
    Heals:GiveTime({})
    local last = reported[#reported]
    assert(last.seq == 6 and last.res == 'SKIP_NOTARGET', 'skip reported: ' .. tostring(last.res))
    assert(Heals.mailbox == nil, 'no smartheal mailbox')
    package.loaded['modules.smartheal'] = nil
    Heals.cfg.SmartHealsOn = 0
    State.smartHealsOn = false
    w.spawns[7].hp = 100
end

-- smart heals: no stale warning at startup (no beat yet) or for an engine that is not wanted (non-healer class)
do
    local stale = 0
    local realErr = Log.error
    Log.error = function(fmt, ...) if tostring(fmt):find('picks stale') then stale = stale + 1 end end
    local function fresh()
        Timers.reset()
        Heals.smart.beat, Heals.smart.beatLast, Heals.smart.armed, Heals.smart.warned, Heals.smart.fallback = 0, 0, nil, false, 1
        Heals.cfg.SmartHealsOn = 1
        State.smartHealsOn = true
        tick(3000)
    end
    fresh()
    package.loaded['modules.smartheal'] = { wanted = function() return true end, Tick = function() end, onResult = function() end }
    Heals:checkHealth()
    assert(stale == 0, 'first checkHealth with no beat yet does not warn')
    tick(2000) Heals:checkHealth()
    assert(stale == 0, 'still within 5 s of the first check')
    tick(4000) Heals:checkHealth()
    assert(stale == 1 and Heals.smart.warned, 'a wanted engine with no beat for 5 s warns once: ' .. stale)
    fresh()
    package.loaded['modules.smartheal'] = { wanted = function() return false end, Tick = function() end, onResult = function() end }
    Heals:checkHealth() tick(8000) Heals:checkHealth()
    assert(stale == 1, 'an engine that is not wanted never warns')
    fresh()
    package.loaded['modules.smartheal'] = nil
    Heals:checkHealth() tick(8000) Heals:checkHealth()
    assert(stale == 1, 'no engine module never warns')
    Log.error = realErr
    Heals.cfg.SmartHealsOn = 0
    State.smartHealsOn = false
end

-- smart heals: the engine keeps beating through the bot's blocking casts (checkHealth ticks it each pass)
do
    local stale, ticks = 0, 0
    local realErr = Log.error
    Log.error = function(fmt, ...) if tostring(fmt):find('picks stale') then stale = stale + 1 end end
    Timers.reset()
    package.loaded['modules.smartheal'] = {
        wanted = function() return true end, onResult = function() end,
        Tick = function() ticks = ticks + 1 Heals.smartSet({ beat = Heals.smart.beat + 1, fallback = 0 }) end,
    }
    Heals.cfg.SmartHealsOn = 1
    State.smartHealsOn = true
    Heals.smart.warned, Heals.smart.armed = false, nil
    Heals.smart.ack = 0
    Heals.smartSet({ spell = 'Remedy', targetId = 7, tier = 'single', seq = 40, beat = Heals.smart.beat + 1, fallback = 0 })
    w.spawns[7].hp = 10   -- still hurt after the 50-point heal lands, so a legacy pass would heal again
    tick(3000)
    Heals:smartHeartbeat()
    mq.cmds = {}
    local t0 = mq.now
    Timers.setClock(function() return mq.now end)
    Heals:checkHealth()
    Timers.setClock(function() return now end)
    now = mq.now
    assert(mq.now - t0 >= 1500, 'the smart cast blocked past the freshness window: ' .. (mq.now - t0))
    assert(World.count(mq, '^/cast "Remedy"') == 1 and World.count(mq, '%(smart%)') == 1, 'pass 2 stays on the smart path: ' .. table.concat(mq.cmds, ';'))
    assert(stale == 0, 'no stale warning')
    assert(ticks >= 2, 'the engine ticked at the top of each pass: ' .. ticks)
    Log.error = realErr
    package.loaded['modules.smartheal'] = nil
    Heals.cfg.SmartHealsOn = 0
    State.smartHealsOn = false
    w.spawns[7].hp = 100
end

-- a heal-for-other condition that reads the current target is skipped, macro or native form
do
    local saved = Heals.cfg.HealsCOn
    Heals.cfg.HealsCOn = 1
    assert(Heals.condOk('${Target.PctHPs}<50', true) == false, 'macro ${Target. skipped for others')
    assert(Heals.condOk('mq.TLO.Target.PctHPs() < 50', true) == false, 'native TLO.Target skipped for others')
    assert(Heals.condOk('mq.TLO.Me.PctMana() >= 0', true) == true, 'a native condition without Target still runs for others')
    Heals.cfg.HealsCOn = saved
end

print('heals_test OK')
