-- lua tests/smartdps_test.lua   (from lua/muleassist)
-- modules/smartdps.lua (necrobrain's loop in-process) with the real modules/dps.lua and the forked necrobrain
-- modules: off / parser gates, a pick reaches dps.smart, dps.lua's verdicts come back through onResult with
-- each effect, an engine error withholds the beat, the macro-read replacements, the Cast tick hook, the dps.lua
-- wiring (no muleassist_smartdps mailbox) and the /necrobrain binds.
package.path = './?.lua;./?/init.lua;' .. package.path
local Stub = require('tests.stub_mq')
local mq = Stub.new({})
local TMP = tostring(os.getenv('TEMP') or os.getenv('TMP') or '/tmp'):gsub('\\', '/')
mq.configDir = TMP          -- necrobrain's log, snapshot and the dpslist INI read live here, never F:/Config
mq.pickle = function() end  -- history's snapshot writer (tests swap History.store below anyway)

local registered, unregistered = {}, {}
package.loaded.actors = { register = function(name, fn)
    registered[#registered + 1] = name
    return { send = function() end, unregister = function() unregistered[name] = true end }
end }

local World = require('tests.world')
local Ini = require('core.ini')
local Config = require('core.config')
local Timers = require('core.timers')
local State = require('core.state')
local Spell = require('core.spell')
local Cast = require('core.cast')
local Cond = require('core.cond')
local T = require('core.tlo')

-- the engine's modules; vesagran (and the logger and vesclaim it needs) load on the first Tick whatever SmartDPSOn is
local NB_MODULES = { 'bridge', 'feed', 'history', 'ttd', 'ranker', 'dpslist', 'resist', 'holds', 'procs' }
local function engineLoaded()
    for _, n in ipairs(NB_MODULES) do if package.loaded['necrobrain.' .. n] ~= nil then return n end end
    return nil
end

-- ------------------------------------------------------------- the INI (dps.lua via Ini, dpslist via the file)
local INI = 'smartdps_test_MuleAssist_srv_Bob.ini'
local function dpsSection(cond1)
    local s = { DPSOn = '1', DPSCOn = '1', DPSSize = '2', DPS1 = 'Pyre of Bones|99', DPS2 = 'Bone Bolt|99',
        DPSInterval = '2', TTDOn = '0', SmartDPSOn = '0', SmartDPSDebug = '0' }
    if cond1 then s.DPSCond1 = cond1 end
    return s
end
local function writeIni(cond1)
    local s = dpsSection(cond1)
    local f = assert(io.open(TMP .. '/' .. INI, 'w'))
    f:write('[General]\nConditionsOn=1\n[DPS]\n')
    for _, k in ipairs({ 'DPSOn', 'DPSCOn', 'DPSSize', 'DPS1', 'DPSCond1', 'DPS2', 'DPSInterval', 'TTDOn', 'SmartDPSOn', 'SmartDPSDebug' }) do
        if s[k] then f:write(k, '=', s[k], '\n') end
    end
    f:close()
end
writeIni(nil)
local data = { [INI] = {
    General = { MainAssist = 'Tank', ConditionsOn = '1' },
    Melee = { MeleeDistance = '30', AssistAt = '95' },
    DPS = dpsSection(nil),
} }
Ini.use(Ini.tableBackend(data))
Config.iniFile = INI
Config.condFile = INI
Config.conditionsOn = 1
Config.rankFn = function(n) return n end
Config.zoneId = function() return 100 end
Timers.setClock(function() return mq.now end)

-- ------------------------------------------------------------- the world: a necro on a rat
local w = World.build(mq, {
    dannet = true, me = { class = 'NEC', curMana = 5000, mana = 100 }, groupN = 1,
    spells = {
        ['Pyre of Bones'] = { st = 'Detrimental', tt = 'Single', range = 200, dur = 36, castMs = 3000, mana = 300 },
        ['Bone Bolt'] = { st = 'Detrimental', tt = 'Single', range = 200, dur = 0, castMs = 2000, mana = 200 },
    },
    gems = { [1] = 'Pyre of Bones', [2] = 'Bone Bolt' },
    group = { [0] = { id = 1, name = 'Bob', class = 'NEC' }, [1] = { id = 5, name = 'Tank', class = 'WAR' } },
})
w.spawns[1] = { id = 1, name = 'Bob', type = 'PC', dist = 0 }
w.spawns[5] = { id = 5, name = 'Tank', type = 'PC', dist = 15 }
w.spawns[9] = { id = 9, name = 'a rat', type = 'NPC', dist = 20, hp = 85, level = 50 }
w.spawns[10] = { id = 10, name = 'a bat', type = 'NPC', dist = 25, hp = 85, level = 52 }
-- dpslist reads the damage slot and resist type from the Spell TLO: add them to the world's spell nodes
local DAMAGE = { ['Pyre of Bones'] = { base = -300, resist = 'Fire' }, ['Bone Bolt'] = { base = -1000, resist = 'Disease' } }
do
    local spellLeaf = rawget(mq.TLO, '__children').Spell
    local orig = spellLeaf.__value
    spellLeaf.__value = function(n)
        local node = orig(n)
        local d = DAMAGE[n]
        if d then
            local ch = rawget(node, '__children')
            ch.NumEffects = mq.node(1)
            ch.Attrib = mq.build({ _ = function(i) return (i == 1) and 0 or 254 end })
            ch.Base = mq.build({ _ = function(i) return (i == 1) and d.base or 0 end })
            ch.ResistType = mq.node(d.resist)
        end
        return node
    end
end
-- the parse service scripts: Lua.Script(name).Status
local scripts = {}
rawget(mq.TLO, '__children').Lua = mq.build({ Script = { _ = function(name) return mq.build({ Status = scripts[name] }) end } })

Spell.clearCache()
State.role = 'assist'
State.mainAssist, State.mainAssistType = 'Tank', 'PC'
local Heals = require('modules.heals')
local Combat = require('modules.combat')
local Mez = require('modules.mez')
local Debuffs = require('modules.debuffs')
local Dps = require('modules.dps')
Cast.LoadSettings()
Cast.registerEvents()
for _, m in ipairs({ Heals, Combat, Mez, Debuffs, Dps }) do m:Init() end
for _, m in ipairs({ Heals, Combat, Mez, Debuffs, Dps }) do m:LoadSettings() end
w.xtargets = { 9 }
State.myTargetId = 0
State.combatStart = true
assert(#Dps.lines == 2, 'dps.lua loaded both lines: ' .. #Dps.lines)

-- ------------------------------------------------------------- 1: SmartDPSOn=0 does nothing
local SD = require('modules.smartdps')
local function step(ms) mq.now = mq.now + (ms or 200) T.xtargetReset() SD:Tick({}) end
do
    SD.reset()
    Dps.cfg.SmartDPSOn = 0
    for _ = 1, 5 do step() end
    assert(Dps.smart.beat == 0, '1: no beat while SmartDPSOn=0: ' .. Dps.smart.beat)
    assert(engineLoaded() == nil, '1: no engine module required while off: ' .. tostring(engineLoaded()))
    assert(SD.active ~= true, '1: not active while off')
end

-- ------------------------------------------------------------- 1b: Blade of Vesagran ticks on every pass, SmartDPSOn or not, without the engine
do
    local meNode = rawget(rawget(mq.TLO, '__children').Me, '__children')
    local bobName = meNode.CleanName
    local function setName(n) meNode.CleanName = mq.node(n) end
    local function fresh(name)
        SD:Shutdown()
        SD.reset()
        package.loaded['necrobrain.vesagran'] = nil
        package.loaded['necrobrain.logger'] = nil   -- the log path is fixed from the name at its first write
        setName(name)
        Dps.cfg.SmartDPSOn = 0
    end

    -- a non-participant touches nothing: no bind, no log file (init() would append to the necrobrain log)
    local zorkLog = TMP .. '/necrobrain_srv_Zork.log'
    os.remove(zorkLog)
    fresh('Zork')
    for _ = 1, 4 do step() end
    assert(SD.vesagranOn == false, '1b: Zork is not a participant: ' .. tostring(SD.vesagranOn))
    assert(mq.binds['/vesclaim'] == nil, '1b: and has no /vesclaim bind')
    local zf = io.open(zorkLog, 'r')
    if zf then zf:close() end
    assert(zf == nil, '1b: and writes no necrobrain log file')
    os.remove(zorkLog)

    -- parsaxx is in vesagran's PRIORITY table but runs medley's copy: no second state machine here
    fresh('Parsaxx')
    for _ = 1, 3 do step() end
    assert(SD.vesagranOn == false, '1b: Parsaxx is skipped: ' .. tostring(SD.vesagranOn))
    assert(mq.binds['/vesclaim'] == nil, '1b: and has no /vesclaim bind')

    fresh('Calbuss')
    SD:LoadSettings()
    -- a first Tick from a Cast tick hook (an mq.delay condition) must not bind: deferred to the main loop
    Cast.tickDelay(1)
    assert(SD.vesagranOn == false and mq.binds['/vesclaim'] == nil, '1b: no Vesagran binds from inside a tick hook')
    step()
    assert(SD.vesagranOn == true, '1b: Calbuss is a participant: ' .. tostring(SD.vesagranOn))
    assert(type(mq.binds['/vesclaim']) == 'function', '1b: /vesclaim is bound')
    local ok, err = pcall(mq.binds['/vesclaim'], 'parsaxx', '1')
    assert(ok, '1b: /vesclaim parsaxx 1 is accepted: ' .. tostring(err))
    assert(engineLoaded() == nil, '1b: no SmartDPS engine module for Vesagran: ' .. tostring(engineLoaded()))
    -- the tick runs on every pass, SmartDPSOn=0 and /necrobrain stop included
    local V = package.loaded['necrobrain.vesagran']
    local realTick, ticks = V.tick, 0
    V.tick = function() ticks = ticks + 1 end
    for _ = 1, 3 do step() end
    assert(ticks == 3, '1b: vesagran ticks on every pass with SmartDPSOn=0: ' .. ticks)
    SD.paused = true
    step()
    assert(ticks == 4, '1b: and while /necrobrain stop has paused SmartDPS: ' .. ticks)
    SD.paused = false
    SD:Tick({})   -- inside the 200 ms throttle: still a pass
    assert(ticks == 5, '1b: and on a pass the SmartDPS throttle skips: ' .. ticks)
    SD.busy = true
    SD:Tick({})
    assert(ticks == 6, '1b: and while a step is in flight: ' .. ticks)
    SD.busy = false
    V.tick = function() ticks = ticks + 1 error('boom') end
    ok, err = pcall(step)
    assert(ok, '1b: a vesagran tick error does not escape Tick: ' .. tostring(err))
    V.tick = realTick
    Dps.cfg.SmartDPSOn = 1
    scripts.malua = nil
    V.tick = function() ticks = ticks + 1 end
    local t0 = ticks
    step()
    assert(ticks == t0 + 1, '1b: and with SmartDPSOn=1 it ticks once per pass: ' .. (ticks - t0))
    V.tick = realTick
    SD:Shutdown()
    assert(mq.binds['/vesclaim'] == nil, '1b: Shutdown unbinds /vesclaim')
    assert(SD.vesagranOn == false, '1b: and clears vesagranOn')

    -- Shutdown releases a held claim: I own Spirit of Vesagran, the peers get a /vesdel
    fresh('Calbuss')
    meNode.Song = mq.build({ _ = function() return mq.build({ ID = 1 }) end })
    local tloKids = rawget(mq.TLO, '__children')
    local realPlugin = tloKids.Plugin   -- the world's plugin node has no IsLoaded, so DanNet reads as not loaded
    tloKids.Plugin = mq.build({ _ = function() return mq.build({ IsLoaded = true }) end })
    local sent, realCmdf = {}, mq.cmdf
    mq.cmdf = function(fmt, ...) sent[#sent + 1] = string.format(fmt, ...) return realCmdf(fmt, ...) end
    step()
    local function sentDel() for _, c in ipairs(sent) do if c:find('/vesdel calbuss', 1, true) then return true end end return false end
    assert(not sentDel(), '1b: no release while I hold it')
    SD:Shutdown()
    mq.cmdf = realCmdf
    tloKids.Plugin = realPlugin
    meNode.Song = nil
    assert(sentDel(), '1b: Shutdown fans /vesdel for a held claim: ' .. table.concat(sent, ' | '))
    assert(mq.binds['/vesclaim'] == nil, '1b: and unbinds')

    -- init failing after it bound: the binds are dropped again
    fresh('Calbuss')
    local real = require('necrobrain.vesagran')
    local realInit = real.init
    real.init = function() realInit() error('init boom') end
    step()
    real.init = realInit
    assert(SD.vesagranOn == false, '1b: a failed init leaves vesagranOn off')
    assert(mq.binds['/vesclaim'] == nil, '1b: and unbinds what init bound')

    -- the first Tick of a name is case-insensitive against PRIORITY: CALBUSS counts
    fresh('CALBUSS')
    step()
    assert(SD.vesagranOn == true, '1b: the name is lowercased before the PRIORITY check')

    fresh('Bob')
    meNode.CleanName = bobName
    for _, n in ipairs({ 'Calbuss', 'CALBUSS', 'Zork', 'Parsaxx' }) do os.remove(TMP .. '/necrobrain_srv_' .. n .. '.log') end
    -- the SmartDPSOn=1 pass above loaded the engine under the Calbuss name: drop it so section 2 loads it as Bob
    for _, n in ipairs(NB_MODULES) do package.loaded['necrobrain.' .. n] = nil end
    for _, n in ipairs({ 'logger', 'vesagran', 'vesclaim' }) do package.loaded['necrobrain.' .. n] = nil end
end

-- ------------------------------------------------------------- 2: no parser, no beat; the beat on the next step once it runs
local History
do
    Dps.cfg.SmartDPSOn = 1
    step()
    assert(engineLoaded() ~= nil, '2: the engine loads on the first active tick')
    History = package.loaded['necrobrain.history']
    -- keep the snapshot in memory from here on
    local mem = {}
    History.store = { load = function(p) return mem[p] end, save = function(p, t) mem[p] = t end }
    assert(SD.active == true, '2: active once the engine runs')
    for _ = 1, 3 do step() end
    assert(Dps.smart.beat == 0, '2: no beat without a parse service: ' .. Dps.smart.beat)
    assert(SD.parserUp() == false, '2: parserUp() false')
    scripts.malua = 'RUNNING'
    step()
    assert(Dps.smart.beat == 1, '2: the beat advances on the next step once malua runs: ' .. Dps.smart.beat)
    assert(SD.parserUp() == true, '2: parserUp() true with malua')
    step()
    assert(Dps.smart.beat == 2, '2: and keeps advancing: ' .. Dps.smart.beat)
    assert(Dps.smart.seq == 0, '2: no target, no pick: ' .. Dps.smart.seq)
end

-- ------------------------------------------------------------- 3: a live NPC target and the [DPS] INI give a pick in dps.smart
local P, O = 'Pyre of Bones', 'Bone Bolt'
do
    assert(Dps.smart.ranked == '|Pyre of Bones|Bone Bolt|', '3: ranked set from the INI: ' .. Dps.smart.ranked)
    State.myTargetId = 9
    step()
    local s = Dps.smart
    assert(s.seq > 0, '3: a pick was published: seq ' .. s.seq)
    assert(s.spell == P, '3: the DoT ranks first at full mana: ' .. tostring(s.spell))
    assert(s.targetId == 9, '3: on MyTargetID: ' .. tostring(s.targetId))
    assert(s.ranked:find('|' .. s.spell .. '|', 1, true), '3: the pick is in the ranked set')
    assert(SD.st.publishedBySeq[s.seq] and SD.st.publishedBySeq[s.seq].spell == P, '3: publishedBySeq remembers it')
end

-- ------------------------------------------------------------- 4: verdicts through onResult
local function ack(verdict)
    local s = Dps.smart
    s.result, s.ack = verdict, s.seq
    SD.onResult(s.seq, verdict)
end
local function noPForRat() return not (Dps.smart.spell == P and Dps.smart.targetId == 9 and Dps.smart.seq ~= Dps.smart.ack) end
local Resist
do
    Resist = package.loaded['necrobrain.resist']
    local st = SD.st
    Dps.cfg.DPSInterval = 7
    -- CAST_TAKEHOLD: that line is held on that mob for 5 min, never republished there
    ack('CAST_TAKEHOLD')
    local h = st.holds:find(P, 9, 'a rat', mq.now)
    assert(h and h.why == 'did not take hold' and h['until'] == mq.now + 300000, '4: TAKEHOLD holds the line on the mob 5 min')
    step()
    assert(Dps.smart.spell == O and Dps.smart.targetId == 9, '4: the next-best line after TAKEHOLD: ' .. tostring(Dps.smart.spell))
    -- SKIPPED: a back-off hold on that mob, longer each time back to back
    local t0 = mq.now
    ack('SKIPPED')
    assert(st.skippedStreak[O] and st.skippedStreak[O].n == 1 and st.skippedStreak[O].targetId == 9, '4: SKIPPED streak')
    h = st.holds:find(O, 9, 'a rat', mq.now)
    assert(h and h.why == 'macro skipped it' and h['until'] == t0 + 1500, '4: SKIPPED backs off 1.5 s')
    for _ = 1, 5 do step() assert(noPForRat(), '4: P is never republished for the rat') end
    assert(Dps.smart.spell ~= O or Dps.smart.seq == Dps.smart.ack, '4: O waits out its SKIPPED hold')
    for _ = 1, 3 do step() end   -- 1.6 s: the hold is over
    assert(Dps.smart.spell == O and Dps.smart.seq ~= Dps.smart.ack, '4: O again after the back-off')
    -- NOMATCH: the per-spell refusal cooldown
    ack('NOMATCH')
    assert(st.refused[O] == mq.now + 10000 and st.refused[O .. '#why'] == 'NOMATCH', '4: NOMATCH refuses the spell 10 s')
    for _ = 1, 51 do step() assert(noPForRat(), '4: P held through the NOMATCH wait') end
    assert(Dps.smart.spell == O and Dps.smart.seq ~= Dps.smart.ack, '4: O after the refusal: ' .. tostring(Dps.smart.spell))
    -- CAST_RESIST: the resist streak raises the refusal cooldown
    ack('CAST_RESIST')
    assert(st.resistStreak[O] and st.resistStreak[O].n == 1 and st.resistStreak[O].targetId == 9, '4: resist streak 1')
    assert(st.refused[O] == mq.now + Resist.refusalCooldown(1), '4: first resist cooldown')
    for _ = 1, 13 do step() assert(noPForRat(), '4: P held') end
    assert(Dps.smart.spell == O and Dps.smart.seq ~= Dps.smart.ack, '4: O after the resist cooldown')
    ack('CAST_RESIST')
    assert(st.resistStreak[O].n == 2 and st.refused[O] == mq.now + Resist.refusalCooldown(2), '4: resist streak 2 doubles the cooldown')
    for _ = 1, 26 do step() assert(noPForRat(), '4: P held') end
    assert(Dps.smart.spell == O and Dps.smart.seq ~= Dps.smart.ack, '4: O after the second resist cooldown')
    -- CAST_SUCCESS: mirrors the macro's timer (a nuke: DPSInterval from dps.cfg) and clears the streak
    ack('CAST_SUCCESS')
    assert(st.resistStreak[O] == nil, '4: success clears the resist streak')
    h = st.holds:find(O, 9, 'a rat', mq.now)
    assert(h and h.why == 'macro recast timer' and h['until'] == mq.now + 7000, '4: success mirrors DPSInterval (7 s) on the mob')
    assert(SD.st.publishedBySeq[Dps.smart.seq] == nil, '4: settled seqs are dropped')
    -- the macro's not-started verdicts hold every pick briefly (the port returns the macro's names)
    State.myTargetId = 10
    step()
    assert(Dps.smart.spell == P and Dps.smart.targetId == 10, '4: P on the bat (holds are per mob): ' .. tostring(Dps.smart.spell))
    ack('NoLOS')
    assert(st.castHoldUntil == mq.now + 2000 and st.castHoldWhy == 'NoLOS', '4: NoLOS holds all picks 2 s')
    step()
    assert(Dps.smart.seq == Dps.smart.ack, '4: nothing published during the hold')
    for _ = 1, 10 do step() end
    assert(Dps.smart.spell == P and Dps.smart.seq ~= Dps.smart.ack, '4: picks resume after the hold')
    -- a port-only CAST_SKIPPED reads as the macro's CAST_SUCCESS (it reported those as success)
    ack('CAST_SKIPPED')
    h = st.holds:find(P, 10, 'a bat', mq.now)
    assert(h and h.why == 'DoT running' and h['until'] == mq.now + 36000, '4: CAST_SKIPPED mirrors like a success')
end

-- ------------------------------------------------------------- 5: a decide that throws stays inside Tick and withholds the beat
do
    local Ranker = package.loaded['necrobrain.ranker']
    local Logger = package.loaded['necrobrain.logger']
    local realRank, realWrite = Ranker.rank, Logger.write
    local errLines = 0
    Logger.write = function(fmt, ...)
        if tostring(fmt):find('error', 1, true) then errLines = errLines + 1 end
        return realWrite(fmt, ...)
    end
    Ranker.rank = function() error('boom') end
    w.spawns[11] = { id = 11, name = 'a snake', type = 'NPC', dist = 25, hp = 85, level = 52 }
    State.myTargetId = 11
    local beat = Dps.smart.beat
    for _ = 1, 5 do
        local ok, err = pcall(step)
        assert(ok, '5: the error does not escape Tick: ' .. tostring(err))
    end
    assert(Dps.smart.beat == beat, '5: the beat is frozen while decide errors: ' .. beat .. ' -> ' .. Dps.smart.beat)
    assert(errLines == 1, '5: the error is logged once per 10 s, got ' .. errLines)
    assert(SD.st.lastErr ~= nil, '5: the error is remembered')
    Ranker.rank = realRank
    step()
    assert(Dps.smart.beat == beat + 1, '5: the beat resumes once a step succeeds')
    assert(SD.st.lastErr == nil, '5: cleared')
    Logger.write = realWrite
end

-- ------------------------------------------------------------- 6: DPSInterval / DPSCOn / conditions from dps.cfg and Config through core.cond
do
    local seen = {}
    local realOk = Cond.ok
    Cond.ok = function(c) seen[#seen + 1] = tostring(c) return realOk(c) end
    w.spawns[12] = { id = 12, name = 'a beetle', type = 'NPC', dist = 25, hp = 85, level = 52 }
    State.myTargetId = 12
    writeIni('mq.TLO.Me.PctMana() > 200')
    SD.Binds['/necrobrain'](SD, 'reload')
    Dps.cfg.DPSCOn = 1
    Config.conditionsOn = 1
    step()
    assert(Dps.smart.spell == O and Dps.smart.targetId == 12, '6: a false native DPSCond keeps P out of the pick: ' .. tostring(Dps.smart.spell))
    assert(tostring(SD.st.condSkipped[P]):find('INI condition false', 1, true), '6: and /why says so: ' .. tostring(SD.st.condSkipped[P]))
    local via = false
    for _, c in ipairs(seen) do if c == 'mq.TLO.Me.PctMana() > 200' then via = true end end
    assert(via, '6: the DPS condition went through core.cond')
    -- DPSCOn=0 (dps.cfg): the macro ignores DPSCond, so does the brain
    Dps.cfg.DPSCOn = 0
    step()
    assert(Dps.smart.spell == P and Dps.smart.targetId == 12, '6: DPSCOn=0 ignores the condition: ' .. tostring(Dps.smart.spell))
    -- ConditionsOn=0 (Config): ignored too
    Dps.cfg.DPSCOn = 1
    Config.conditionsOn = 0
    step()
    assert(Dps.smart.spell == P, '6: ConditionsOn=0 ignores the condition')
    Config.conditionsOn = 1
    step()
    assert(Dps.smart.spell == O, '6: back on: held out again')
    Cond.ok = realOk
    writeIni(nil)
    SD.Binds['/necrobrain'](SD, 'reload')
    -- DPSOn (dps.cfg) gates the |NN wait; DPSInterval was read by the success mirror in section 4
end

-- ------------------------------------------------------------- 7: the Cast tick hook
do
    SD:LoadSettings()
    assert(type(Cast.tickHooks.smartdps) == 'function', '7: tick hook registered by LoadSettings')
    local beat = Dps.smart.beat
    mq.now = mq.now + 200
    Cast.tickHooks.smartdps()
    assert(Dps.smart.beat == beat + 1, '7: the hook drives the step 200 ms later')
    Cast.tickHooks.smartdps()
    assert(Dps.smart.beat == beat + 1, '7: throttled: an immediate second call does not step: ' .. Dps.smart.beat)
    -- a catch-up after a long gap steps once, not twice back to back
    mq.now = mq.now + 1000
    Cast.tickHooks.smartdps()
    Cast.tickHooks.smartdps()
    assert(Dps.smart.beat == beat + 2, '7: one step after a gap, no double step: ' .. Dps.smart.beat)
    SD:Shutdown()
    assert(Cast.tickHooks.smartdps == nil, '7: removed by Shutdown')
    assert(unregistered.companion_events, '7: Shutdown unregisters the feed mailbox')
    assert(mq.events.nb_power_on == nil and mq.events.nb_power_off == nil, '7: and the Chaotic Power events')
    assert(SD.active ~= true, '7: inactive after Shutdown')
    SD.reset()
    SD:LoadSettings()
end

-- ------------------------------------------------------------- 8: dps.lua wiring
do
    for _, n in ipairs(registered) do assert(n ~= 'muleassist_smartdps', '8: dps.lua registers no muleassist_smartdps mailbox') end
    Dps.smart.seq, Dps.smart.ack, Dps.smart.beat, Dps.smart.beatLast = 0, 0, 0, 0
    Dps.cfg.SmartDPSOn, Dps.cfg.SmartDPSDebug, Dps.cfg.DPSCOn = 1, 0, 0
    State.myTargetId = 9
    w.spawns[9].hp = 85
    local results = {}
    local realOnResult = SD.onResult
    SD.onResult = function(seq, res) results[#results + 1] = { seq = seq, res = res } return realOnResult(seq, res) end
    local casts = {}
    local realCast = Cast.cast
    Cast.cast = function(name, id, from, opts)
        casts[#casts + 1] = { name = name, id = id, seq = Dps.smart.seq, smart = Dps.smart.spell, dontRecast = opts and opts.dontRecast }
        return 'CAST_SUCCESS'
    end
    mq.now = mq.now + 400
    T.xtargetReset()
    Dps:combatCast(9)
    Cast.cast = realCast
    SD.onResult = realOnResult
    assert(#casts >= 1, '8: dps cast the pick')
    local c = casts[1]
    assert(c.name == c.smart and c.id == 9 and c.dontRecast == true, '8: the cast is the SmartDPS pick: ' .. tostring(c.name))
    assert(#results >= 1 and results[1].seq == c.seq and results[1].res == 'CAST_SUCCESS',
        '8: the verdict reaches onResult with the pick seq: ' .. tostring(results[1] and results[1].seq) .. ' vs ' .. c.seq)
    -- the cast entry is held now (the success mirror ran inside the engine)
    assert(SD.st.holds:find(c.name, 9, 'a rat', mq.now), '8: the mirror ran')
    -- shadow mode: the ack comes back as 'shadow', which necrobrain ignores
    Dps.cfg.SmartDPSDebug = 1
    w.spawns[13] = { id = 13, name = 'a wasp', type = 'NPC', dist = 25, hp = 85, level = 52 }
    State.myTargetId = 13   -- a fresh mob: both lines are held on the rat now
    results = {}
    SD.onResult = function(seq, res) results[#results + 1] = { seq = seq, res = res } return realOnResult(seq, res) end
    for _ = 1, 30 do mq.now = mq.now + 200 SD:Tick({}) if Dps.smart.seq ~= Dps.smart.ack then break end end
    assert(Dps.smart.seq ~= Dps.smart.ack, '8: a shadow pick is outstanding')
    local seq = Dps.smart.seq
    Dps:smartHeartbeat()
    SD.onResult = realOnResult
    assert(#results == 1 and results[1].seq == seq and results[1].res == 'shadow', '8: shadow acks reach onResult')
    Dps.cfg.SmartDPSDebug = 0
    for _, n in ipairs(registered) do assert(n ~= 'muleassist_smartdps', '8: still no muleassist_smartdps mailbox') end
end

-- ------------------------------------------------------------- 8b: the verdict is acked against the pick that was cast
-- The engine steps from the Cast tick hook, so it can publish pick N+1 while dps.lua is still inside the cast of
-- pick N (the post-cast recovery wait, where Me.Casting is empty). The verdict belongs to N, as the macro's
-- SmartDPSSeqCast keeps it; N+1 stays outstanding.
do
    w.spawns[14] = { id = 14, name = 'a crab', type = 'NPC', dist = 25, hp = 85, level = 52 }
    State.myTargetId = 14
    Dps.cfg.SmartDPSOn, Dps.cfg.SmartDPSDebug, Dps.cfg.DPSCOn = 1, 0, 0
    for _ = 1, 30 do mq.now = mq.now + 200 SD:Tick({}) if Dps.smart.seq ~= Dps.smart.ack and Dps.smart.targetId == 14 then break end end
    assert(Dps.smart.spell == P and Dps.smart.targetId == 14 and Dps.smart.seq ~= Dps.smart.ack, '8b: P is the outstanding pick on the crab')
    local Ranker = package.loaded['necrobrain.ranker']
    local realRank = Ranker.rank
    local results, casts = {}, {}
    local realOnResult = SD.onResult
    SD.onResult = function(seq, res) results[#results + 1] = { seq = seq, res = res } return realOnResult(seq, res) end
    local realCast = Cast.cast
    Cast.cast = function(name, id, from, opts)
        casts[#casts + 1] = { name = name, seq = Dps.smart.seq }
        -- mid-cast (the post-cast wait): the ranking moves and the tick hook steps the engine 400 ms later
        Ranker.rank = function(u, ctx) local r = realRank(u, ctx) if #r > 1 then r[1], r[2] = r[2], r[1] end return r end
        mq.now = mq.now + 400
        Cast.tickHooks.smartdps()
        State.dpsPaused = true   -- end the pass after this entry: the newer pick must still be outstanding
        return 'CAST_SUCCESS'
    end
    mq.now = mq.now + 400
    T.xtargetReset()
    Dps:combatCast(14)
    Cast.cast = realCast
    SD.onResult = realOnResult
    Ranker.rank = realRank
    State.dpsPaused = false
    assert(#casts == 1 and casts[1].name == P, '8b: dps cast P: ' .. tostring(casts[1] and casts[1].name))
    local castSeq = casts[1].seq
    assert(#results == 1 and results[1].seq == castSeq and results[1].res == 'CAST_SUCCESS',
        '8b: the verdict is reported for the cast pick seq ' .. castSeq .. ', got ' .. tostring(results[1] and results[1].seq))
    assert(Dps.smart.ack == castSeq, '8b: dps.smart.ack is the cast seq: ' .. Dps.smart.ack)
    assert(Dps.smart.seq > castSeq and Dps.smart.spell == O, '8b: the newer pick (O) was published mid-cast')
    assert(Dps.smart.seq ~= Dps.smart.ack, '8b: and stays outstanding')
    local hP = SD.st.holds:find(P, 14, 'a crab', mq.now)
    local hO = SD.st.holds:find(O, 14, 'a crab', mq.now)
    assert(hP and hP.why == 'DoT running', '8b: the hold lands on the cast spell')
    assert(hO == nil, '8b: and not on the newer pick')
    -- the next pass casts the outstanding newer pick and acks it against its own seq
    local newSeq = Dps.smart.seq
    results, casts = {}, {}
    SD.onResult = function(seq, res) results[#results + 1] = { seq = seq, res = res } return realOnResult(seq, res) end
    Cast.cast = function(name) casts[#casts + 1] = { name = name, seq = Dps.smart.seq } return 'CAST_RESIST' end
    mq.now = mq.now + 50
    T.xtargetReset()
    Dps:combatCast(14)
    Cast.cast = realCast
    SD.onResult = realOnResult
    assert(casts[1] and casts[1].name == O and casts[1].seq == newSeq, '8b: the next pass casts O')
    assert(results[1] and results[1].seq == newSeq and results[1].res == 'CAST_RESIST', '8b: and acks O at its seq')
    assert(SD.st.resistStreak[O] and SD.st.resistStreak[O].targetId == 14, '8b: the resist lands on O')
end

-- ------------------------------------------------------------- 9: /necrobrain stop | start, why, diag, mob; SmartDPSOn off freezes
do
    local NB = SD.Binds['/necrobrain']
    step()
    local beat = Dps.smart.beat
    NB(SD, 'stop')
    for _ = 1, 3 do step() end
    assert(Dps.smart.beat == beat, '9: stop pauses the beat')
    assert(SD.active ~= true, '9: inactive while stopped')
    local seq = Dps.smart.seq
    for _ = 1, 3 do step() end
    assert(Dps.smart.seq == seq, '9: no publishing while stopped')
    NB(SD, 'start')
    step()
    assert(Dps.smart.beat == beat + 1, '9: start resumes')
    assert(SD.active == true, '9: active again')
    -- SmartDPSOn off after on: frozen, not torn down
    Dps.cfg.SmartDPSOn = 0
    beat = Dps.smart.beat
    for _ = 1, 3 do step() end
    assert(Dps.smart.beat == beat, '9: SmartDPSOn=0 freezes the beat')
    Dps.cfg.SmartDPSOn = 1
    step()
    assert(Dps.smart.beat == beat + 1, '9: and it resumes when turned back on')
    for _, verb in ipairs({ 'why', 'diag', 'mode', 'console', 'backfill', 'help' }) do
        local ok, err = pcall(NB, SD, verb)
        assert(ok, '9: /necrobrain ' .. verb .. ': ' .. tostring(err))
    end
    local ok, err = pcall(NB, SD, 'mode', 'burn')
    assert(ok and SD.st.lastMode == 'burn', '9: mode burn: ' .. tostring(err))
    NB(SD, 'mode', 'auto')
    mq.cmd('/target id 9')
    ok, err = pcall(SD.Binds['/nbmob'], SD)
    assert(ok, '9: /nbmob: ' .. tostring(err))
end

-- ------------------------------------------------------------- 10: a failed engine load is latched, cleaned up and retried every 30 s
do
    local Log = require('core.log')
    local loadErrs = 0
    local realErr = Log.error
    Log.error = function(fmt, ...) if tostring(fmt):find('failed to load', 1, true) then loadErrs = loadErrs + 1 end return realErr(fmt, ...) end
    local opens, closes = 0, 0
    package.loaded.lsqlite3 = { OPEN_READONLY = 1, open = function()
        opens = opens + 1
        return { nrows = function() return function() return nil end end, close = function() closes = closes + 1 end }
    end }
    SD:Shutdown()
    SD.reset()
    unregistered.companion_events = nil
    local realOpen = History.open
    History.open = function() error('snapshot boom') end   -- fails after the side effects (db, events, feed)
    Dps.cfg.SmartDPSOn = 1
    local beat = Dps.smart.beat
    local ok, err = pcall(step)
    assert(ok, '10: a failed load does not escape Tick: ' .. tostring(err))
    assert(SD.engine == nil and SD.active ~= true, '10: not running after a failed load')
    assert(opens == 1 and closes == 1, '10: the partial load closed its database handle: ' .. opens .. '/' .. closes)
    assert(mq.events.nb_power_on == nil and mq.events.nb_power_off == nil, '10: and dropped its events')
    assert(unregistered.companion_events, '10: and stopped the feed')
    assert(loadErrs == 1, '10: logged once: ' .. loadErrs)
    for _ = 1, 140 do step() end   -- 28 s: no retry yet
    assert(opens == 1, '10: no retry inside 30 s: ' .. opens)
    assert(Dps.smart.beat == beat, '10: no beat while not loaded')
    for _ = 1, 15 do step() end    -- past 30 s: one retry, which fails again quietly
    assert(opens == 2 and closes == 2, '10: retried once after 30 s, cleaned up again: ' .. opens .. '/' .. closes)
    assert(loadErrs == 1, '10: the repeat failure is not logged again: ' .. loadErrs)
    History.open = realOpen
    for _ = 1, 151 do step() if SD.engine then break end end
    assert(SD.engine == true and opens == 3 and closes == 2, '10: the next retry loads the engine: ' .. opens .. '/' .. closes)
    assert(mq.events.nb_power_on ~= nil, '10: its events registered once more')
    local b0 = Dps.smart.beat   -- the bridge counter restarted with SD.reset()
    step()
    assert(Dps.smart.beat == b0 + 1, '10: and the beat resumes')
    Log.error = realErr
    SD:Shutdown()
    assert(closes == 3, '10: Shutdown closes the database')
    package.loaded.lsqlite3 = nil
end

-- ------------------------------------------------------------- 11: an error out of the engine load never leaves busy stuck
do
    local Log = require('core.log')
    local realErr = Log.error
    SD:Shutdown()
    SD.reset()
    local realOpen = History.open
    History.open = function() error('snapshot boom') end
    Log.error = function() error('log boom') end   -- the failure path itself throws
    Dps.cfg.SmartDPSOn = 1
    local ok, err = pcall(step)
    assert(ok, '11: Tick does not throw out of a failed engine load: ' .. tostring(err))
    assert(SD.busy == false, '11: busy is cleared: ' .. tostring(SD.busy))
    assert(SD.active ~= true, '11: not active')
    Log.error = realErr
    History.open = realOpen
    for _ = 1, 151 do step() if SD.engine then break end end
    assert(SD.engine == true, '11: the engine loads on a later retry: SmartDPS was not disabled for the session')
    SD:Shutdown()
end

-- ------------------------------------------------------------- 12: no engine load while my name is empty
do
    local meNode = rawget(rawget(mq.TLO, '__children').Me, '__children')
    local bobName = meNode.CleanName
    SD:Shutdown()
    SD.reset()
    Dps.cfg.SmartDPSOn = 1
    meNode.CleanName = mq.node('')
    for _ = 1, 3 do step() end
    assert(SD.engine ~= true, '12: no engine while the name is empty')
    assert(SD.st.loadAt == nil, '12: and no load attempt recorded (the retry is not delayed): ' .. tostring(SD.st.loadAt))
    meNode.CleanName = bobName
    step()
    assert(SD.engine == true, '12: the engine loads on the next step once the name resolves')
    SD:Shutdown()
end

-- ------------------------------------------------------------- 12b: Boot loads the engine at startup
do
    SD:Shutdown()
    SD.reset()
    Dps.cfg.SmartDPSOn = 1
    SD:LoadSettings()
    SD:Boot()
    assert(SD.engine == true, '12b: Boot loads the engine on the main coroutine, before any main-loop pass')
    SD:Shutdown()
    SD.reset()
    Dps.cfg.SmartDPSOn = 0
    SD:Boot()
    assert(SD.engine ~= true, '12b: and not with SmartDPSOn=0')
    Dps.cfg.SmartDPSOn = 1
end

-- ------------------------------------------------------------- 13: nothing registers from inside a tick hook
-- Tick hooks run inside mq.delay conditions, which MQ evaluates on a throwaway coroutine: an mq.event /
-- actors.register made there keeps a dead lua_State and crashes the client when it fires (lua_rawgeti).
do
    SD:Shutdown()
    SD.reset()
    Dps.cfg.SmartDPSOn = 1
    SD:LoadSettings()
    local nReg = #registered
    mq.events.nb_power_on = nil
    mq.now = mq.now + 1000
    Cast.tickDelay(1)   -- the stub's mq.delay runs the condition once: the tick hooks run under Cast.inHook()
    assert(Cast.inHook() == false, '13: inHook is false again after the hooks')
    assert(SD.engine ~= true, '13: no engine load from inside a tick hook')
    assert(#registered == nReg, '13: no actors.register from inside a tick hook')
    assert(mq.events.nb_power_on == nil, '13: no mq.event from inside a tick hook')
    assert(SD.st.loadAt == nil, '13: the deferral is not a failed attempt (no retry delay)')
    step()   -- the next main-loop pass loads it
    assert(SD.engine == true, '13: the engine loads on the next main-loop Tick')
    assert(#registered == nReg + 1 and mq.events.nb_power_on ~= nil, '13: and registers there')
    SD:Shutdown()
end

os.remove(TMP .. "/" .. INI)
os.remove(TMP .. "/necrobrain_srv_Bob.log")
print('smartdps_test OK')
