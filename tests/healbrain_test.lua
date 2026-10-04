-- lua tests/healbrain_test.lua   (from lua/muleassist)
-- modules/healbrain.lua: snapshots in -> ledger rows -> JSONL; fights; heartbeat; second brain; commands.
package.path = './?.lua;./?/init.lua;' .. package.path
local Stub = require('tests.stub_mq')
local mq = Stub.new({})
local World = require('tests.world')
local Timers = require('core.timers')
local State = require('core.state')

local sent, handlers = {}, {}
package.loaded.actors = { register = function(name, fn)
    handlers[name] = fn
    return { name = name, unregister = function() handlers[name] = nil end,
        send = function(_, addr, payload) sent[#sent + 1] = { addr = addr, payload = payload } end }
end }
-- the window registration (mq.imgui.init) is counted: it must happen once, however often the brain re-activates
local windowInits = {}
mq.imgui = { init = function(name) windowInits[#windowInits + 1] = name end }

local WIN = package.config:sub(1, 1) == '\\'
local tmp = ((os.getenv('TEMP') or '/tmp'):gsub('\\', '/')) .. '/ma_healbrain_' .. os.time() .. '_' .. math.random(1000, 9999)
os.execute(WIN and ('mkdir "' .. tmp:gsub('/', '\\') .. '" 2>nul') or ('mkdir -p "' .. tmp .. '"'))
Timers.setClock(function() return mq.now end)
World.build(mq, { me = { class = 'CLR' } })
mq.configDir = tmp
State.mainAssist, State.healBrainOn, State.combatStart = 'Bob', true, false

local B = require('modules.healbrain')
B.reset()
local function deliver(payload) B.receive(function() return payload end) end
local function at(ms) mq.now = mq.now + (ms or 250) B:Tick({}) end
local function slurp(p) local f = io.open(p, 'rb') if not f then return '' end local d = f:read('a') f:close() return d end
local JSONL = tmp .. '/MuleAssist/HealingLogs/heal-ledger-' .. os.date('%Y-%m-%d') .. '.jsonl'

-- the ledger test's fixtures: an idle cleric with Remedy ready, a rogue under the line in range
local function healer(ts)
    return { v = 1, from = 'Cleric1', id = 111, ts = ts, seq = 1, zone = 'z',
        me = { hp = 100, mana = 80, dead = false, stunned = false, feigned = false, x = 0, y = 0, z = 0, class = 'CLR', group = 'g1', inCombat = true },
        lines = { direct = { { name = 'Remedy', pct = 85, range = 100, castMs = 1000, ready = true, mana = true } }, group = {}, cures = {} },
        targets = { [222] = { name = 'Rogue', hp = 50, x = 10, y = 0, z = 0, dead = false, class = 'ROG', group = 'g1', pet = false } },
        macro = { healLine = 85, tankLine = 40, healTank = 'Tank', healTankId = 999, healsOn = 1, curesOn = 0 },
        events = {} }
end

-- 1: nothing happens unless HealBrainOn and MA
State.mainAssist = 'Tank'
at()
assert(#sent == 0 and handlers.heal_brain == nil, 'not the MA: idle')
State.mainAssist = 'Bob'
at()
assert(handlers.heal_brain ~= nil, 'mailbox registered on the MA')

-- 2: an unhealed gap opens and is written as a JSONL gap record
for _ = 1, 10 do deliver(healer(mq.now)) at(250) end
local unhealed = false
for _, r in ipairs(B.ledger.rows) do if r.kind == 'unhealed' then unhealed = true end end
assert(unhealed, 'unhealed row opened')
local log = slurp(JSONL)
assert(log:find('"type":"gap"', 1, true) and log:find('unhealed', 1, true), 'gap row in the JSONL: ' .. JSONL)

-- 3: fight start / end records
State.combatStart = true
at()
State.combatStart = false
at()
log = slurp(JSONL)
assert(log:find('"type":"fight_start"', 1, true) and log:find('"type":"fight_end"', 1, true), 'fight records')

-- 4: heartbeat to agents and other brains, script muleassist
sent = {}
at(1000)
local toAgent, toBrain = false, false
for _, m in ipairs(sent) do
    if m.payload.kind == 'brain' and m.addr.script == 'muleassist' then
        if m.addr.mailbox == 'heal_agent' then toAgent = true end
        if m.addr.mailbox == 'heal_brain' then toBrain = true end
    end
end
assert(toAgent and toBrain, 'heartbeat sent')

-- 5: another brain heard
deliver({ kind = 'brain', from = 'Other', ts = mq.now })
at()
assert(B.otherBrains.Other, 'second brain noticed')
at(6000)
assert(not B.otherBrains.Other, 'other brain expires after 5 s')

-- 6: commands
B.Binds['/healbrain'](B, 'set', 'unhealedMs', '500')
assert(B.ledger.opts.unhealedMs == 500, 'set')
B.Binds['/healbrain'](B, 'reset')
assert(#B.ledger.rows == 0, 'reset')
B.Binds['/healbrain'](B, 'pause')
local paused = healer(mq.now)
paused.from = 'PausedBox'
deliver(paused)
at()
assert(B.ledger.boxes.PausedBox == nil, 'paused: nothing ingested')
B.Binds['/healbrain'](B, 'pause', 'off')
assert(pcall(B.Binds['/healbrain'], B, 'report'), 'report runs')

-- 6b: Cast.wait blocks the main loop, so the brain also ticks from the cast engine's tick hook (every blocking
-- wait), on the main loop's 250 ms cadence: a hook call inside the window does not tick again
local Cast = require('core.cast')
B:LoadSettings({})
local hook = Cast.tickHooks.healbrain
assert(type(hook) == 'function', 'tick hook installed')
at(250)
local tickedAt = B.UI.lastTickAt
local early = healer(mq.now)
early.from = 'EarlyBox'
deliver(early)
mq.now = mq.now + 100
hook()
assert(B.UI.lastTickAt == tickedAt and B.ledger.boxes.EarlyBox == nil, 'a hook call 100 ms after a main-loop tick does not tick')
mq.now = mq.now + 150
assert(hook() == nil, 'the hook returns nothing')
assert(B.UI.lastTickAt == mq.now and B.ledger.boxes.EarlyBox ~= nil, 'a snapshot delivered mid-cast is ingested through the hook')
local realTick = B.Tick
B.Tick = function() error('boom') end
local okHook, res = pcall(hook)
B.Tick = realTick
assert(okHook and res == nil, 'the hook swallows a Tick error')

-- 6b2: cadence - driven every 100 ms (the main loop), the brain ticks every 250 ms on average, not every 300
local ticks, last = 0, B.UI.lastTickAt
for _ = 1, 40 do
    at(100)
    if B.UI.lastTickAt ~= last then ticks, last = ticks + 1, B.UI.lastTickAt end
end
assert(ticks >= 15 and ticks <= 17, '4 s at 100 ms passes: ~16 ticks, got ' .. ticks)
sent = {}
for _ = 1, 40 do at(100) end
local beats = 0
for _, m in ipairs(sent) do if m.addr.mailbox == 'heal_agent' then beats = beats + 1 end end
assert(beats == 4, '4 s: 4 heartbeats, got ' .. beats)

-- 6b3: an unknown own name (Me not loaded) skips the tick and does not go idle
World.set(mq, 'Me.CleanName', '')
at(250)
assert(handlers.heal_brain ~= nil and B.active, 'empty name: still active')
local skipped = B.UI.lastTickAt
at(250)
assert(B.UI.lastTickAt == skipped, 'empty name: no tick')
World.set(mq, 'Me.CleanName', 'Bob')
at(250)
assert(B.UI.lastTickAt == mq.now, 'name back: ticking')

-- 6c: idle when HealBrainOn goes off or this box stops being the MA; re-activates later; the window once
assert(#windowInits == 1 and windowInits[1] == 'RaidHealLedger', 'window registered on the first active tick')
assert(B.UI.show == true, 'the window opens on the first activation')
State.healBrainOn = false
at()
assert(handlers.heal_brain == nil, 'HealBrainOn off: mailbox unregistered')
sent = {}
at(1000) at(1000)
assert(#sent == 0, 'HealBrainOn off: no heartbeats')
local idle = healer(mq.now)
idle.from = 'IdleBox'
deliver(idle)
State.healBrainOn = true
at()
assert(handlers.heal_brain ~= nil, 'HealBrainOn back on: mailbox registered again')
assert(B.ledger.boxes.IdleBox == nil, 'a snapshot queued while idle is not ingested after re-activation')
assert(B.UI.show == true, 'shown before going idle: shown again')
B.Binds['/healbrain'](B, 'hide')
State.mainAssist = 'Tank'
at()
assert(handlers.heal_brain == nil, 'no longer the MA: mailbox unregistered')
State.mainAssist = 'bob'
at()
assert(handlers.heal_brain ~= nil, 'MA again (case-insensitive): active')
assert(B.UI.show == false, '/healbrain hide is respected on re-activation')
assert(#windowInits == 1, 'window registered once across re-activations')
local printed = {}
local realPrint = print
print = function(...) printed[#printed + 1] = table.concat({ ... }, ' ') end
B.Binds['/healbrain'](B, 'stop')
print = realPrint
local reported = false
for _, line in ipairs(printed) do if line:find('Heal ledger:', 1, true) then reported = true end end
assert(reported, '/healbrain stop prints the night report')
at()
assert(handlers.heal_brain == nil, '/healbrain stop: idle')
B.Binds['/healbrain'](B, 'start')
at()
assert(handlers.heal_brain ~= nil, '/healbrain start: active again')
B.Binds['/healbrain'](B, 'stop')
at()
State.healBrainOn = false
at()
State.healBrainOn = true
at()
assert(handlers.heal_brain ~= nil and not B.stopped, 'HealBrainOn off -> on clears /healbrain stop')

-- 6e: the brain makes the directory (not store.lua's mkdir); a failure stops writes until the retry time
local Paths = require('smartheal.util.paths')
local realEnsure, ensures = Paths.ensureDir, 0
Paths.ensureDir = function(p) ensures = ensures + 1 return false, 'directory_unavailable:' .. p end
local Store = require('healledger.store')
local realWrite, writes = Store.write, 0
Store.write = function(...) writes = writes + 1 return realWrite(...) end
mq.configDir = tmp .. '/nodir'
B.store, B.storeErr, B.storeRetryAt = nil, nil, 0
assert(B:write({ type = 'note' }) == false and ensures == 1 and writes == 0, 'no directory: nothing written')
assert(B.storeErr, 'the failure is kept for the window')
B:write({ type = 'note' }) at() at()
assert(ensures == 1 and writes == 0, 'no retry before STORE_RETRY_MS')
State.healBrainOn = false at() State.healBrainOn = true at()
assert(ensures == 1, 're-activation honours the retry time')
mq.now = mq.now + B.STORE_RETRY_MS
B:write({ type = 'note' })
assert(ensures == 2 and writes == 0, 'retried after STORE_RETRY_MS')
mq.configDir = tmp
Paths.ensureDir = realEnsure
B.store = nil
mq.now = mq.now + B.STORE_RETRY_MS
assert(B:write({ type = 'note' }) == true and writes == 1 and B.storeErr == nil, 'writes again once the directory is there')
-- a day rollover with the directory gone: the brain's probe catches it before store.lua would mkdir
Paths.ensureDir = function(p) ensures = ensures + 1 return false, 'directory_unavailable:' .. p end
ensures, writes = 0, 0
B.store.dir = tmp .. '/gone/HealingLogs'
B.store.dateFn = function() return '2099-01-01' end
assert(B:write({ type = 'note' }) == false and ensures == 1 and writes == 0, 'rollover into a missing directory: store.lua never asked')
Paths.ensureDir = realEnsure

-- 6f: a Store.write failure (the file cannot open: a directory sits at its path) also throttles retries
local bad = tmp .. '/badfile'
local badFile = bad .. '/MuleAssist/HealingLogs/heal-ledger-' .. os.date('%Y-%m-%d') .. '.jsonl'
os.execute(WIN and ('mkdir "' .. badFile:gsub('/', '\\') .. '" 2>nul') or ('mkdir -p "' .. badFile .. '"'))
mq.configDir = bad
B.store, B.storeErr, B.storeRetryAt = nil, nil, 0
writes = 0
assert(B:write({ type = 'note' }) == false and writes == 1 and B.store.failed, 'file open failed: store.failed set')
assert(B.storeErr, 'the brain keeps the failure')
B:write({ type = 'note' }) B:write({ type = 'note' })
assert(writes == 1, 'no Store.write before STORE_RETRY_MS')
mq.now = mq.now + B.STORE_RETRY_MS
B:write({ type = 'note' })
assert(writes == 2, 'one retry after STORE_RETRY_MS')
Store.write = realWrite
mq.configDir = tmp
B.store, B.storeErr, B.storeRetryAt = nil, nil, 0

-- 6h: /healbrain start says what happened; report carries this box's agent status; hide clears the re-show;
-- with HealBrainOn off the tick never reads the own name (a TLO read per pass on every box)
local function capture(fn)
    local out, realP = {}, print
    print = function(...) out[#out + 1] = table.concat({ ... }, ' ') end
    local ok, err = pcall(fn)
    print = realP
    assert(ok, err)
    return table.concat(out, '\n')
end
at()
assert(B.active, '6h starts active')
local txt = capture(function() B.Binds['/healbrain'](B, 'start') end)
assert(txt:find('running', 1, true), '/healbrain start while active says so: ' .. txt)
B.Binds['/healbrain'](B, 'stop')
State.mainAssist = 'Tank'
txt = capture(function() B.Binds['/healbrain'](B, 'start') end)
assert(txt:find('idle', 1, true) and txt:find('MA', 1, true), '/healbrain start, not the MA: still idle, says why: ' .. txt)
State.mainAssist = 'Bob'
at()
State.healBrainOn = false
at()
B.Binds['/healbrain'](B, 'stop')
txt = capture(function() B.Binds['/healbrain'](B, 'start') end)
assert(txt:find('idle', 1, true) and txt:find('HealBrainOn', 1, true), '/healbrain start, HealBrainOn off: says why: ' .. txt)
local T = require('core.tlo')
local realName, nameReads = T.myName, 0
T.myName = function() nameReads = nameReads + 1 return realName() end
at() at()
T.myName = realName
assert(nameReads == 0, 'HealBrainOn off and idle: no own-name read, got ' .. nameReads)
State.healBrainOn = true
at()
assert(B.active and B.UI.show == false, 'hidden earlier: stays hidden')
B.Binds['/healbrain'](B, 'show')
State.healBrainOn = false
at()
assert(B.showAfterIdle == true and B.UI.show == false, 'shown on going idle: remembered')
B.Binds['/healbrain'](B, 'hide')
State.healBrainOn = true
at()
assert(B.active and B.UI.show == false, '/healbrain hide while idle: not re-shown on re-activation')
local A = require('modules.healagent')
A.sent, A.sendFails, A.brain = 12, 1, { name = 'Bob', seenAt = mq.now - 2000 }
txt = capture(function() B.Binds['/healbrain'](B, 'report') end)
assert(txt:find('12 sent', 1, true) and txt:find('brain heard: Bob', 1, true), 'report: agent status line: ' .. txt)
A.brain = { name = nil, seenAt = 0 }
txt = capture(function() B.Binds['/healbrain'](B, 'report') end)
assert(txt:find('brain heard: never', 1, true), 'report: no brain heard yet: ' .. txt)

-- 6d: Shutdown unregisters the mailbox and removes the hook
B:Shutdown()
assert(handlers.heal_brain == nil and Cast.tickHooks.healbrain == nil, 'Shutdown: mailbox and hook gone')

-- 6g: /healbrain show on a box that was never active registers the window (a fresh module instance)
package.loaded['modules.healbrain'] = nil
local B2 = require('modules.healbrain')
State.healBrainOn = false
B2.Binds['/healbrain'](B2, 'show')
assert(#windowInits == 2 and B2.UI.show == true and not B2.active, 'show while idle: window registered and shown')
B2.Binds['/healbrain'](B2, 'show')
assert(#windowInits == 2, 'still once')
package.loaded['modules.healbrain'] = B
State.healBrainOn = true

-- 7: the queue is capped at 2000
B.reset()
for i = 1, 2005 do deliver(healer(mq.now)) end
assert((#B.queue - (B.qHead or 1) + 1) <= 2000 and B.qDropped >= 5, 'queue cap')

-- 8: no actors.register / mq.imgui.init from inside a tick hook (an mq.delay condition: a dead coroutine)
do
    local Cst = require('core.cast')
    if B.dropbox then pcall(function() B.dropbox:unregister() end) end
    B.dropbox = nil
    local got = 'unset'
    Cst.addTickHook('test_hb_register', function() got = B:register() end)
    Cst.tickDelay(1)
    Cst.removeTickHook('test_hb_register')
    assert(got == nil and handlers.heal_brain == nil, '8: the brain does not register its mailbox from a tick hook')
    assert(B:register() ~= nil and handlers.heal_brain ~= nil, '8: and does from the main loop')
end

-- 9: /healbrain show from a bind (a throwaway coroutine) does not mq.imgui.init there; the next Tick does
do
    local Cst = require('core.cast')
    local inits = 0
    mq.imgui = mq.imgui or {}
    local realInit = mq.imgui.init
    mq.imgui.init = function() inits = inits + 1 end
    Cst.captureMainCoroutine()
    local fresh = package.loaded['modules.healbrain'] and dofile('modules/healbrain.lua')   -- windowRegistered starts false
    fresh.reset()
    coroutine.wrap(function() fresh.Binds['/healbrain'](fresh, 'show') end)()
    assert(inits == 0 and fresh.windowWanted, '9: no window registration from the bind coroutine')
    pcall(fresh.Tick, fresh, {})
    assert(inits == 1, '9: the next Tick registers the window: ' .. inits)
    mq.imgui.init = realInit
end

print('healbrain_test OK')
