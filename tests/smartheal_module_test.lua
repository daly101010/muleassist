-- lua tests/smartheal_module_test.lua   (from lua/muleassist)
-- modules/smartheal.lua with a fake engine: init one phase per pass, the pick reaches heals, the seq / beat /
-- fallback rules of the old bridge, the HoT veto, a confirmed HoT is registered, telemetry, healer-only.
package.path = './?.lua;./?/init.lua;' .. package.path
local Stub = require('tests.stub_mq')
local mq = Stub.new({})
local World = require('tests.world')
local Ini = require('core.ini')
local Config = require('core.config')
local Timers = require('core.timers')
local State = require('core.state')
local T = require('core.tlo')

local Log = require('core.log')
local errLogs = 0
do local realErr = Log.error Log.error = function(...) errLogs = errLogs + 1 return realErr(...) end end
local infoLogs = {}
do local realInfo = Log.info Log.info = function(fmt, ...) infoLogs[#infoLogs + 1] = tostring(fmt) return realInfo(fmt, ...) end end
local flogs = {}
local function flogCount(pat) local n = 0 for _, l in ipairs(flogs) do if l:find(pat, 1, true) then n = n + 1 end end return n end
local sent = {}
package.loaded.actors = { register = function(name, fn)
    return { send = function(_, addr, payload) sent[#sent + 1] = { addr = addr, payload = payload } end, unregister = function() end }
end }

local fake = {
    TOTAL_INIT_PHASES = 3, phases = {}, sensorTicks = 0, registered = {}, merges = 0,
    nextAction = nil, nextReason = 'no_heal_needed', directAction = nil, shutdownCalled = false,
    Config = { spells = { single = { 'Remedy' } }, hotMaxDeficitPct = 35, hotEnabled = true,
        logCategories = { hotCoverage = true }, emergencyPct = 50, minHealPct = 10, broadcastEnabled = true },
    TargetMonitor = { targets = {} },
    Logger = { info = function(cat, fmt, ...) flogs[#flogs + 1] = cat .. ': ' .. string.format(fmt, ...) end },
}
function fake.initPhased(p) fake.phases[#fake.phases + 1] = p end
function fake.isInitialized() return #fake.phases >= fake.TOTAL_INIT_PHASES end
function fake.tickSensors(o) fake.sensorTicks = fake.sensorTicks + 1 fake.sensorOpts = o end
function fake.buildHealAction(o)
    fake.lastOpts = o
    if fake.Config.hotEnabled == false then return fake.directAction, 'priority_targets' end
    return fake.nextAction, fake.nextReason
end
function fake.prepareHealCast(a) return { spellName = a.spellName, isHoT = a.isHoT } end
function fake.registerHealCast(i) fake.registered[#fake.registered + 1] = i end
function fake.shutdown() fake.shutdownCalled = true fake.shutdownEmergency, fake.shutdownBroadcast = fake.Config.emergencyPct, fake.Config.broadcastEnabled end
fake.Config.mergeFromSpellBar = function() fake.merges = fake.merges + 1 fake.mergeEmergency = fake.Config.emergencyPct return 0, {} end
function fake.TargetMonitor.getTarget(id) return fake.TargetMonitor.targets[id] end
function fake.TargetMonitor.getAllTargets() return fake.TargetMonitor.targets end
function fake.TargetMonitor.updateActorTargets(feed) fake.feed = feed end
package.loaded['smartheal'] = fake

local data = { ['MuleAssist_srv_Bob.ini'] = {
    General = { MainAssist = 'Tank' },
    Heals = { HealsOn = '1', HealsSize = '1', Heals1 = 'Remedy|60', SmartHealsOn = '1', SmartHealFloorPct = '20',
        SmartHealEmergencyPct = '40', HealGroupPetsOn = '1', XTarHeal = '0' },
} }
Ini.use(Ini.tableBackend(data))
Config.iniFile = 'MuleAssist_srv_Bob.ini'
Config.condFile = Config.iniFile
Config.rankFn = function(n) return n end
Config.zoneId = function() return 100 end
Timers.setClock(function() return mq.now end)
local w = World.build(mq, {
    dannet = true, me = { class = 'CLR', curMana = 2000 }, groupN = 1, gems = { [1] = 'Remedy' },
    spells = { ['Remedy'] = { tt = 'Single', range = 100, dur = 0, castMs = 2000, mana = 100, heal = 50 } },
    group = { [0] = { id = 1, name = 'Bob', class = 'CLR' }, [1] = { id = 7, name = 'Tank', class = 'WAR' } },
})
w.spawns[7] = { id = 7, name = 'Tank', type = 'PC', dist = 20, hp = 90 }

local Heals = require('modules.heals')
Heals:LoadSettings({})
local SH = require('modules.smartheal')
local function pass(ms) mq.now = mq.now + (ms or 200) T.xtargetReset() SH:Tick({}) end

State.healsOn, State.smartHealsOn, State.mainAssistId, State.singleHealPoint = true, true, 7, 70
State.role = 'assist'

-- 1: init one phase per pass, fallback meanwhile
SH.reset()
pass() pass() pass()
assert(#fake.phases == 3 and Heals.smart.fallback == 1, 'phased init, fallback while starting: ' .. #fake.phases)
assert(fake.Config.broadcastEnabled == false and fake.Config.logCategories.hotCoverage == false, 'bridge overrides applied')

-- 2: a pick reaches heals (seq 1), with the bot's settings applied
fake.nextAction = { spellName = 'Remedy', targetId = 7, targetName = 'Tank', tier = 'single', isHoT = false, reason = 'priority_targets' }
pass()
local s = Heals.smart
assert(s.spell == 'Remedy' and s.targetId == 7 and s.tier == 'single' and s.seq == 1 and s.fallback == 0, 'pick published')
assert(fake.sensorOpts and fake.sensorOpts.readOnly == true, 'read-only sensors')
assert(fake.lastOpts.ignoreSpellEngine == true and fake.lastOpts.skipIfCasting == false and fake.lastOpts.pcHealPct == 70, 'selection opts')
assert(fake.Config.minHealPct == 20 and fake.Config.nonSquishyMinHealPct == 20 and fake.Config.lowPressureMinDeficitPct == 20, 'heal floor')
assert(fake.Config.emergencyPct == 40 and fake.Config.healPetsEnabled == true, 'emergency pct, pets')
local decisions = 0
for _, m in ipairs(sent) do if m.payload.kind == 'decision' then decisions = decisions + 1 assert(m.addr.mailbox == 'companion_smartheal' and m.addr.character == 'Bob') end end
assert(flogCount('bridge: PUBLISH seq=1 Remedy on Tank [single] priority_targets') == 1, 'PUBLISH line in the engine log: ' .. table.concat(flogs, ' | '))
assert(decisions == 3, 'decision telemetry to companion, maui, medley: ' .. decisions)

-- 3: same pick, not consumed -> no republish; beat keeps advancing
local beat = s.beat
pass()
assert(s.seq == 1 and s.beat > beat, 'same pick not republished, beat advances')

-- 3b: external targets are fed: an out-of-group MA (tank) and the XTarTanks slot (Heals.xtarOverride, dps)
w.spawns[8] = { id = 8, name = 'Ext', type = 'PC', dist = 20, hp = 80 }
w.spawns[9] = { id = 9, name = 'Fan', type = 'PC', dist = 20, hp = 70 }
w.xtargets = { 9 }
Heals.xtarOverride = '1'
State.mainAssistId = 8
fake.feed = nil
pass()
local byId = {}
for _, f in ipairs(fake.feed or {}) do byId[f.id] = f end
assert(byId[8] and byId[8].role == 'tank' and byId[8].hp == 80, 'out-of-group MA fed as tank')
assert(byId[9] and byId[9].role == 'dps' and byId[9].hp == 70, 'XTarTanks slot (xtarOverride) fed as dps')
assert(not byId[7], 'a group member is not fed')
w.xtargets, Heals.xtarOverride, State.mainAssistId = {}, nil, 7

-- 4: consumed (ack) -> the still-wanted pick republishes at seq 2
SH.onResult(1, 'CAST_SUCCESS')
Heals.smart.ack = 1
pass()
assert(s.seq == 2, 'republished after the ack: ' .. s.seq)

-- 5: a confirmed HoT success is registered with the engine; a failed one is not
fake.nextAction = { spellName = 'Elixir', targetId = 7, targetName = 'Tank', tier = 'single', isHoT = true }
fake.TargetMonitor.targets[7] = { pctHP = 90 }
pass()
local hotSeq = s.seq
SH.onResult(hotSeq, 'CAST_SUCCESS')
assert(flogCount('bridge: ACK seq=' .. hotSeq .. ' result=CAST_SUCCESS (Elixir on Tank)') == 1, 'ACK line: ' .. table.concat(flogs, ' | '))
assert(#fake.registered == 1 and fake.registered[1].confirmedLanded == true and fake.registered[1].spellName == 'Elixir', 'HoT registered')
SH.onResult(hotSeq, 'CAST_SUCCESS')
assert(#fake.registered == 1, 'a result is applied once')
-- a non-success result for a new HoT pick is not registered; a throwing engine does not raise out of onResult
Heals.smart.ack = hotSeq
pass()
local seq2 = s.seq
assert(seq2 == hotSeq + 1, 'HoT republished after its ack')
SH.onResult(seq2, 'CAST_FIZZLE')
assert(#fake.registered == 1, 'a failed HoT is not registered')
Heals.smart.ack = seq2
pass()
local seq3 = s.seq
local realPrep = fake.prepareHealCast
fake.prepareHealCast = function() error('prep boom') end
local errsBefore = errLogs
assert(pcall(SH.onResult, seq3, 'CAST_SUCCESS'), 'onResult is error-isolated')
fake.prepareHealCast = realPrep
assert(errLogs == errsBefore + 1, 'onResult error logged once')

-- 6: HoT veto below 100 - hotMaxDeficitPct swaps in a direct heal
fake.TargetMonitor.targets[7] = { pctHP = 50 }
fake.directAction = { spellName = 'Remedy', targetId = 7, targetName = 'Tank', tier = 'single', isHoT = false }
Heals.smart.ack = s.seq
pass()
assert(s.spell == 'Remedy' and fake.Config.hotEnabled == true, 'vetoed to a direct heal, hotEnabled restored')
local vetoes = 0
for _, m in ipairs(sent) do if m.payload.kind == 'veto' then vetoes = vetoes + 1 end end
assert(vetoes >= 3, 'veto telemetry')
assert(flogCount('bridge: HoT veto: Elixir on Tank') >= 1, 'veto in the engine log')

-- 7: unserviceable -> fallback 1; intentional HoT wait (no_heal_needed with a heal memorized) -> fallback 0
fake.nextAction, fake.nextReason = nil, 'unserviceable'
pass()
assert(s.fallback == 1, 'unserviceable falls back')
assert(s.spell == '' and s.targetId == 0 and s.tier == 'none', 'the withdrawn pick is published empty')
assert(flogCount('bridge: WITHDRAW seq=' .. s.seq) == 1, 'WITHDRAW line')
fake.nextReason = 'no_heal_needed'
pass()
assert(s.fallback == 0, 'HoT wait keeps smart heals')

-- 8: no configured heal memorized -> fallback 1 and the beat stops
w.gems = {}
mq.now = mq.now + 2000
pass()
local b2 = s.beat
pass()
assert(s.fallback == 1 and s.beat == b2, 'nothing memorized: fallback, no beat')
w.gems = { [1] = 'Remedy' }
mq.now = mq.now + 2000

-- 9: gem rescan every 10 s, saving the profile's values (not the overrides)
local before = fake.merges
mq.now = mq.now + 10000
pass()
assert(fake.merges == before + 1 and fake.mergeEmergency == 50 and fake.Config.emergencyPct == 40, 'rescan with overrides swapped out')

-- 9b: a small floor keeps the engine's secondary floors at their minimums
Heals.cfg.SmartHealFloorPct = 12
pass()
assert(fake.Config.minHealPct == 12 and fake.Config.nonSquishyMinHealPct == 15 and fake.Config.lowPressureMinDeficitPct == 20, 'floor 12: 12 / 15 / 20')

-- 10: BuffMode / HealsOn off -> fallback, no sensor tick
local ticks = fake.sensorTicks
State.buffMode = true
pass()
assert(s.fallback == 1 and fake.sensorTicks == ticks, 'inactive under BuffMode')
State.buffMode = false
State.healsOn = false
pass()
assert(s.fallback == 1 and fake.sensorTicks == ticks, 'inactive with HealsOn off')
State.healsOn = true

-- 11: non-healer classes never start the engine
SH.reset()
fake.phases = {}
local realClass = T.myClass
T.myClass = function() return 'WAR' end   -- the test world's class is fixed at build
pass()
T.myClass = realClass
assert(#fake.phases == 0, 'a warrior never starts the engine')

-- 12: Shutdown stops the engine and unevents every engine event
fake.Config.emergencyPct, fake.Config.broadcastEnabled = 50, true   -- the profile's values, as the engine loaded them
SH.reset()
pass() pass() pass() pass()
assert(fake.Config.emergencyPct == 40 and fake.Config.broadcastEnabled == false, 'overrides applied before shutdown')
mq.events = {}
for _, n in ipairs(SH.EVENT_NAMES) do mq.events[n] = { pattern = 'x' } end
SH:Shutdown()
local left = 0
for _ in pairs(mq.events) do left = left + 1 end
assert(fake.shutdownCalled and left == 0, 'shutdown + unevent')
assert(fake.shutdownEmergency == 50 and fake.shutdownBroadcast == true, 'the engine saves the profile values, not the overrides')

-- 12b: never started: Shutdown does nothing; onResult before ready is a no-op
SH.reset()
fake.shutdownCalled = false
SH:Shutdown()
assert(not fake.shutdownCalled, 'Shutdown without a started engine does nothing')
assert(pcall(SH.onResult, 1, 'CAST_SUCCESS') and SH.lastAck == 0, 'onResult before ready is a no-op')

-- 14: a failed init phase is retried (not skipped); not ready until every phase succeeded; fallback throughout
SH.reset()
fake.phases = {}
local failOnce = true
local realInit, realIsInit = fake.initPhased, fake.isInitialized
fake.initPhased = function(p) fake.phases[#fake.phases + 1] = p if p == 2 and failOnce then failOnce = false error('phase boom') end end
Heals.smartSet({ fallback = 0 })
pass() assert(Heals.smart.fallback == 1, 'phase 1 ok, fallback')
Heals.smartSet({ fallback = 0 })
pass() assert(Heals.smart.fallback == 1 and not SH.ready, 'a failing phase falls back')
pass() assert(not SH.ready, 'phase 2 retried, phase 3 pending')
assert(#fake.phases == 3 and fake.phases[2] == 2 and fake.phases[3] == 2, 'phase 2 attempted twice')
pass() assert(SH.ready and Heals.smart.fallback == 1 and fake.phases[4] == 3, 'ready after the last phase')
-- ... and isInitialized false after the last phase keeps it unready until the engine reports ready
SH.reset()
fake.phases = {}
fake.initPhased = function(p) fake.phases[#fake.phases + 1] = p end
local engineUp = false
fake.isInitialized = function() return engineUp end
pass() pass() pass() pass()
assert(not SH.ready and Heals.smart.fallback == 1, 'not ready while the engine is not initialized')
engineUp = true
pass() pass()
assert(SH.ready, 'ready once the engine reports initialized')
fake.initPhased, fake.isInitialized = realInit, realIsInit

-- 15: a step error -> fallback 1, one Log.error per 30 s
SH.reset()
fake.phases = {}
pass() pass() pass() pass()
local realTick = fake.tickSensors
fake.tickSensors = function() error('sensor boom') end
errLogs = 0
Heals.smartSet({ fallback = 0 })
pass() pass() pass()
assert(Heals.smart.fallback == 1 and errLogs == 1, 'step error: fallback, one log in 30 s: ' .. errLogs)
mq.now = mq.now + 30000
pass()
assert(errLogs == 2, 'logged again after 30 s')
fake.tickSensors = realTick
pass()
assert(Heals.smart.fallback == 0, 'recovers')

-- 16: no configured heal spells: one chat warning when the engine becomes ready
fake.Config.HasConfiguredSpells = function() return false end
infoLogs = {}
SH.reset()
fake.phases = {}
pass() pass() pass() pass() pass()
local warned = 0
for _, l in ipairs(infoLogs) do if l:find('no heal spells assigned yet', 1, true) then warned = warned + 1 end end
assert(warned == 1, 'warned once: ' .. warned)
fake.Config.HasConfiguredSpells = function() return true end
infoLogs = {}
SH.reset()
fake.phases = {}
pass() pass() pass()
for _, l in ipairs(infoLogs) do assert(not l:find('no heal spells assigned yet', 1, true), 'no warning with spells') end
fake.Config.HasConfiguredSpells = nil

-- 13: EVENT_NAMES matches the engine source, and none collides with the bot's events
local function slurp(p) local f = io.open(p, 'rb') if not f then return '' end local d = f:read('a') f:close() return d end
local engineNames, listed = {}, {}
for _, f in ipairs({ 'spell_events', 'damage_parser', 'damage_attribution', 'mob_assessor' }) do
    for n in slurp('smartheal/' .. f .. '.lua'):gmatch("mq%.event%(%s*'([%w_]+)'") do engineNames[n] = true end
end
for _, n in ipairs(SH.EVENT_NAMES) do listed[n] = true end
for n in pairs(engineNames) do assert(listed[n], 'EVENT_NAMES misses ' .. n) end
local p = io.popen('dir /b /s modules\\*.lua core\\*.lua 2>nul') or io.popen('ls modules/*.lua core/*.lua')
for path in p:lines() do
    for n in slurp(path):gmatch("mq%.event%(%s*'([%w_]+)'") do assert(not listed[n], 'event name collision: ' .. n) end
end
p:close()

print('smartheal_module_test OK')
