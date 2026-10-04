-- luajit tests/cast_test.lua   (from lua/muleassist)
package.path = './?.lua;./?/init.lua;' .. package.path
local Stub = require('tests.stub_mq')
local mq = Stub.new({})
local World = require('tests.world')
local Cast = require('core.cast')
local Log = require('core.log')
local Spell = require('core.spell')
local State = require('core.state')
local Timers = require('core.timers')

-- normalisation
do
    assert(Cast.normalise('CAST_TAKEHOLD', 'Buffs') == 'CAST_SUCCESS' and Cast.normalise('CAST_TAKEHOLD', 'DPS') == 'CAST_TAKEHOLD', 'takehold truthful for combat senders')
    assert(Cast.normalise('CAST_IMMUNE', 'Mez') == 'CAST_IMMUNE' and Cast.normalise('CAST_IMMUNE', 'Cure') == 'CAST_SUCCESS', 'immune truthful for mez')
    assert(Cast.normalise('Whatever', 'Buffs') == 'CAST_SUCCESS' and Cast.normalise('CAST_RESIST', 'Buffs') == 'CAST_RESIST', 'unknown = success')
end

-- a self buff casts; an unknown name does not; a skipped buff is not an error
do
    local w = World.build(mq, { spells = { ['Talisman of the Tribunal'] = { tt = 'Group v2', dur = 2400, stacks = true, spa = { [0] = true } } } })
    w.spawns[1] = { id = 1, name = 'Bob', type = 'PC', dist = 0 }
    Spell.clearCache()
    mq.cmds = {}
    local res = Cast.cast('Talisman of the Tribunal', 1, 'Buffs')
    assert(res == 'CAST_SUCCESS', 'self buff: ' .. res)
    assert(World.count(mq, '^/cast "Talisman of the Tribunal"') == 1, 'one /cast issued')
    assert(World.count(mq, '/target id') == 0, 'a group spell on myself keeps the current target')
    assert(Cast.lastCastAt >= 0, 'last cast stamped')
    assert(Cast.cast('Nope', 1, 'Buffs') == 'CAST_UNKNOWN', 'unknown name')
    local list = Log.whyNotList()
    assert(list[1]:find('Nope') and list[1]:find('CAST_UNKNOWN'), 'unknown recorded in /whynot: ' .. tostring(list[1]))
    -- the target already has it: skipped, no cast, not in /whynot
    w.spawns[7] = { id = 7, name = 'Al', type = 'PC', dist = 10, level = 60 }
    w.spells['Shield of Thorns'] = { tt = 'Single', dur = 600, stacks = true, stacksOn = { [7] = false } }
    Spell.clearCache()
    mq.cmds = {}
    local n = #Log.whyNotList()
    res = Cast.cast('Shield of Thorns', 7, 'Buffs')
    assert(res == 'CAST_SKIPPED', 'no stack -> skipped: ' .. res)
    assert(World.count(mq, '^/cast') == 0 and #Log.whyNotList() == n, 'skipped: no cast, no whynot')
    -- too low for the spell: skipped by the level floors
    w.spawns[8] = { id = 8, name = 'Cy', type = 'PC', dist = 10, level = 30 }
    w.spells['Shield of Thorns'].stacksOn = {}
    w.spells['Shield of Thorns'].level = 70
    Spell.clearCache()
    res = Cast.cast('Shield of Thorns', 8, 'Buffs')
    assert(res == 'CAST_SKIPPED', 'level floor -> skipped: ' .. res)
    -- a 60 with a 70 spell: fine (floor 61 for 66-95 -> 60 is too low!) use a 65
    w.spawns[8].level = 65
    World.set(mq, 'Target.ID', 0)
    mq.cmds = {}
    res = Cast.cast('Shield of Thorns', 8, 'Buffs')
    assert(res == 'CAST_SUCCESS' and World.count(mq, '/target id 8') == 1, 'targets the recipient and casts: ' .. res)
end

-- the invis hold and its exemptions
do
    local w = World.build(mq, { spells = { ['Remedy'] = { tt = 'Single', dur = 0, st = 'Beneficial' } } })
    w.spawns[7] = { id = 7, name = 'Al', type = 'PC', dist = 10 }
    w.spawns[9] = { id = 9, name = 'a rat', type = 'NPC', dist = 10 }
    Spell.clearCache()
    World.set(mq, 'Me.Invis', true)
    Cast.cfg.InvisCastHold = 1
    assert(Cast.cast('Remedy', 7, 'Heal') == 'Invis', 'invis holds a cast on a PC')
    mq.cmds = {}
    assert(Cast.cast('Remedy', 9, 'DPS') == 'CAST_SUCCESS', 'mode 1 still casts at an NPC')
    Cast.cfg.InvisCastHold = 2
    assert(Cast.cast('Remedy', 9, 'DPS') == 'Invis', 'mode 2 holds everything')
    Cast.cfg.InvisCastHold = 0
    World.set(mq, 'Me.Invis', false)
end

-- memorising into the misc gem and putting the original back
do
    local w = World.build(mq, { spells = { ['Dawnlight'] = { tt = 'Single', dur = 1200, recast = 10 }, ['Remedy'] = {} }, gems = { [8] = 'Remedy' } })
    w.spawns[7] = { id = 7, name = 'Al', type = 'PC', dist = 10, level = 60 }
    Spell.clearCache()
    Cast.cfg.MiscGem, Cast.cfg.MiscGemRemem, Cast.cfg.MiscGemLW = 8, 1, 0
    Cast.reMemMiscGem = 'Remedy'
    mq.cmds = {}
    local res = Cast.cast('Dawnlight', 7, 'Buffs')
    assert(res == 'CAST_SUCCESS', 'cast after memming: ' .. res)
    assert(World.count(mq, '^/memspell 8 "Dawnlight"') == 1, 'memmed into the misc gem')
    assert(World.count(mq, '^/memspell 8 "Remedy"') == 1, 'the original went back')
    assert(w.gems[8] == 'Remedy', 'misc gem holds the original again')
    -- a -nomem sender (buff pass) leaves the fresh spell in the gem
    w.spawns[8] = { id = 8, name = 'Cy', type = 'PC', dist = 10, level = 60 }
    mq.cmds = {}
    res = Cast.cast('Dawnlight', 8, 'Buffs', { nomem = true })
    assert(World.count(mq, '^/memspell 8 "Remedy"') == 0 and w.gems[8] == 'Dawnlight', 'nomem keeps it')
end

-- a misc gem held for a spell still refreshing is not memmed over: two long-recast pet buffs no longer thrash
do
    local w = World.build(mq, { spells = {
        ['Pet Buff A'] = { tt = 'Single', dur = 3600, recast = 36, ready = false },
        ['Pet Buff B'] = { tt = 'Single', dur = 3600, recast = 36 },
        ['Remedy'] = { tt = 'Single', dur = 0 },
    }, gems = { [8] = 'Remedy' } })
    w.spawns[7] = { id = 7, name = 'Al', type = 'PC', dist = 10, level = 60 }
    Spell.clearCache()
    Cast.cfg.MiscGem, Cast.cfg.MiscGemRemem, Cast.cfg.MiscGemLW = 8, 1, 0
    Cast.reMemMiscGem, Cast.reMemWaitShort, Cast.reMemWaitLong = 'Remedy', nil, nil
    Timers.clear('cast:miscgemhold')
    -- A goes into the gem but is still refreshing: it waits there, held
    mq.cmds = {}
    local res = Cast.cast('Pet Buff A', 7, 'Pet', { nomem = true })
    assert(res == 'Longmem' and w.gems[8] == 'Pet Buff A' and Timers.running('cast:miscgemhold'), 'A memmed and held: ' .. res)
    -- B must not take the gem from A
    mq.cmds = {}
    res = Cast.cast('Pet Buff B', 7, 'Pet', { nomem = true })
    assert(res == 'Longmem' and World.count(mq, '^/memspell') == 0 and w.gems[8] == 'Pet Buff A', 'B waits, A keeps the gem: ' .. table.concat(mq.cmds, ';'))
    -- a heal still takes it
    mq.cmds = {}
    w.gems[8] = 'Pet Buff A'
    res = Cast.cast('Remedy', 7, 'SingleHeal')
    assert(World.count(mq, '^/memspell 8 "Remedy"') == 1, 'a heal overrides the hold: ' .. table.concat(mq.cmds, ';'))
    -- A refreshes and casts from the gem; then B gets it
    w.gems[8] = 'Pet Buff A'
    Cast.reMemWaitShort = 'Pet Buff A'
    Timers.set('cast:miscgemhold', 66000)
    w.spells['Pet Buff A'].ready = true
    mq.cmds = {}
    res = Cast.cast('Pet Buff A', 7, 'Pet', { nomem = true })
    assert(res == 'CAST_SUCCESS' and World.count(mq, '^/memspell') == 0, 'A casts from the gem it kept: ' .. res)
    assert(not Timers.running('cast:miscgemhold'), 'the hold ends with the cast')
    mq.cmds = {}
    res = Cast.cast('Pet Buff B', 7, 'Pet', { nomem = true })
    assert(World.count(mq, '^/memspell 8 "Pet Buff B"') == 1 and res == 'CAST_SUCCESS', 'then B takes the gem: ' .. res)
    Cast.reMemWaitShort = nil
end

-- interrupt hooks stop a cast in progress
do
    local w = World.build(mq, { spells = { ['Remedy'] = { tt = 'Single', dur = 0 } } })
    w.spawns[7] = { id = 7, name = 'Al', type = 'PC', dist = 10 }
    Spell.clearCache()
    World.set(mq, 'Me.Casting.ID', 5)
    Cast.addInterruptHook('test', function(ctx) if ctx.from == 'SingleHeal' then return 'target healed' end end)
    mq.cmds = {}
    local res = Cast.cast('Remedy', 7, 'SingleHeal')
    assert(res == 'CAST_INTERRUPTED_BY_ME' and World.count(mq, '^/stopcast') == 1, 'hook stops the cast: ' .. res)
    Cast.interruptHooks.test = nil
    World.set(mq, 'Me.Casting.ID', 0)
end

-- a cast-time spell that never reaches the cast bar is not a success; a cast bar that never ends is cut
do
    local w = World.build(mq, { spells = {
        ['Silent Nuke'] = { st = 'Detrimental', tt = 'Single', range = 200, dur = 0, castMs = 3000, mana = 10, noCast = true },
        ['Stuck Nuke'] = { st = 'Detrimental', tt = 'Single', range = 200, dur = 0, castMs = 3000, mana = 10, stuck = true },
    }, gems = { [1] = 'Silent Nuke', [2] = 'Stuck Nuke' } })
    w.spawns[9] = { id = 9, name = 'a rat', type = 'NPC', dist = 20, hp = 100 }
    Spell.clearCache()
    Timers.setClock(function() return mq.now end)
    local res = Cast.cast('Silent Nuke', 9, 'DPS')
    assert(res == 'CAST_NOT_STARTED', 'no cast bar, still ready: ' .. res)
    mq.cmds = {}
    local t0 = mq.now
    res = Cast.cast('Stuck Nuke', 9, 'DPS')
    assert(res == 'CAST_INTERRUPTED', 'the stuck cast bar is cut: ' .. res)
    assert(World.count(mq, '^/stopcast') >= 1 and mq.now - t0 < 60000, 'within the deadline: ' .. (mq.now - t0))
    w.castEndsAt = -1
    -- a cast bar that shows up late (inside the second look) is waited out with the interrupt hooks running
    w.spells['Late Nuke'] = { st = 'Detrimental', tt = 'Single', range = 200, dur = 0, castMs = 3000, mana = 10, lateMs = 400 }
    w.gems[3] = 'Late Nuke'
    Spell.clearCache()
    local calls = 0
    Cast.addInterruptHook('probe', function() calls = calls + 1 return nil end)
    local start = mq.now
    res = Cast.cast('Late Nuke', 9, 'DPS')
    Cast.interruptHooks.probe = nil
    assert(res == 'CAST_SUCCESS' and calls > 0, 'late start: hooks ran (' .. calls .. ')')
    assert(mq.now - start >= 3400, 'returned only after the cast bar ended: ' .. (mq.now - start))
    w.castStartsAt = 0
end

-- the scratch-gem originals are re-captured after a spell set loads, never mid-swap
do
    local w = World.build(mq, { spells = { ['Old Spell'] = {}, ['New Spell'] = {} }, gems = { [8] = 'Old Spell' } })
    Cast.cfg.MiscGem, Cast.cfg.MiscGemLW = 8, 0
    Cast.reMemWaitShort, Cast.reMemWaitLong = nil, nil
    Cast.captureMiscGems()
    assert(Cast.reMemMiscGem == 'Old Spell', 'captured: ' .. tostring(Cast.reMemMiscGem))
    w.gems[8] = 'New Spell'
    Cast.reMemWaitShort = 'Scratch'
    Cast.captureMiscGems()
    assert(Cast.reMemMiscGem == 'Old Spell', 'mid-swap: not re-captured')
    Cast.reMemWaitShort = nil
    Cast.captureMiscGems()
    assert(Cast.reMemMiscGem == 'New Spell', 'after the set loads: the new spell: ' .. tostring(Cast.reMemMiscGem))
end

-- the preCast hook runs once per gem cast, before the first /cast
do
    local w = World.build(mq, { spells = { ['Remedy'] = { tt = 'Single', dur = 0, st = 'Beneficial' } } })
    w.spawns[9] = { id = 9, name = 'a rat', type = 'NPC', dist = 10 }
    Spell.clearCache()
    Cast.cfg.InvisCastHold = 0
    local calls, cmdsAtCall = {}, nil
    local saved = Cast.hooks.preCast
    Cast.hooks.preCast = function(name, id, from, facts)
        calls[#calls + 1] = { name = name, from = from }
        cmdsAtCall = #mq.cmds
    end
    mq.cmds = {}
    local res = Cast.cast('Remedy', 9, 'DPS')
    Cast.hooks.preCast = saved
    assert(res == 'CAST_SUCCESS', 'cast ran: ' .. tostring(res))
    assert(#calls == 1 and calls[1].name == 'Remedy' and calls[1].from == 'DPS', 'preCast once: ' .. #calls)
    for i = 1, cmdsAtCall do assert(not mq.cmds[i]:find('^/cast'), 'preCast before /cast: ' .. mq.cmds[i]) end
end

-- tick hooks run in every blocking wait (cast bar, post-cast cooldown, memSpell, the misc gem waits), never
-- interrupt, and a throwing hook does not break the cast
do
    local w = World.build(mq, { spells = {
        ['Slow Nuke'] = { st = 'Detrimental', tt = 'Single', range = 200, dur = 0, castMs = 1000, mana = 10 },
        ['Dawnlight'] = { tt = 'Single', dur = 1200, recast = 10 }, ['Remedy'] = {},
    }, gems = { [1] = 'Slow Nuke', [8] = 'Remedy' } })
    w.spawns[9] = { id = 9, name = 'a rat', type = 'NPC', dist = 20, hp = 100 }
    w.spawns[7] = { id = 7, name = 'Al', type = 'PC', dist = 10, level = 60 }
    Spell.clearCache()
    Timers.setClock(function() return mq.now end)
    Cast.cfg.InvisCastHold, Cast.cfg.MiscGem, Cast.cfg.MiscGemRemem, Cast.cfg.MiscGemLW = 0, 8, 1, 0
    Cast.reMemMiscGem, Cast.reMemWaitShort, Cast.reMemWaitLong = 'Remedy', nil, nil
    local lastDelay = nil
    mq.onDelay = function(ms) lastDelay = ms end
    local calls = {}
    Cast.addTickHook('probe', function()
        calls[#calls + 1] = { delay = lastDelay, cast = World.count(mq, '^/cast "'), mem = World.count(mq, '^/memspell') }
        return 'stop it'   -- a tick hook's return value is ignored
    end)
    Cast.addTickHook('broken', function() error('boom') end)
    local function seen(pred) for _, c in ipairs(calls) do if pred(c) then return true end end return false end
    mq.cmds = {}
    local res = Cast.cast('Slow Nuke', 9, 'DPS')
    assert(res == 'CAST_SUCCESS' and World.count(mq, '^/stopcast') == 0, 'tick hooks never interrupt, a throwing one is contained: ' .. tostring(res))
    assert(seen(function(c) return c.cast > 0 and c.delay == 100 end), 'ticked in the cast-bar loop')
    assert(seen(function(c) return c.cast > 0 and c.delay == 2000 end), 'ticked in the post-cast cooldown wait')
    assert(seen(function(c) return c.cast > 0 and c.delay == 150 end), 'ticked in the post-cast settle delay')
    calls, mq.cmds = {}, {}
    res = Cast.cast('Dawnlight', 7, 'Buffs')
    assert(res == 'CAST_SUCCESS', 'cast after memming: ' .. tostring(res))
    assert(seen(function(c) return c.delay == 30000 end), 'ticked in the memSpell wait')
    assert(seen(function(c) return c.mem > 0 and c.cast == 0 and c.delay == 5000 end), 'ticked in the misc gem ready wait')
    Cast.removeTickHook('probe')
    Cast.removeTickHook('broken')
    assert(next(Cast.tickHooks) == nil, 'removeTickHook')
    Cast.addTickHook('kept', function() end)
    Cast.LoadSettings()
    assert(Cast.tickHooks.kept, 'Cast.LoadSettings keeps the tick hooks')
    Cast.removeTickHook('kept')
    -- Cast.tickDelay: the module-facing wrapper hands back mq.delay's result and keeps the exit condition
    local realDelay, gotMs, gotCond = mq.delay, nil, nil
    mq.delay = function(ms, cond) gotMs, gotCond = ms, cond return 'delay-result' end
    local hooked = 0
    Cast.addTickHook('count', function() hooked = hooked + 1 end)
    assert(Cast.tickDelay(7000, function() return true end) == 'delay-result' and gotMs == 7000, 'tickDelay passes ms and the result')
    assert(gotCond() == true and hooked == 1, 'its predicate runs the hooks, then the exit condition')
    Cast.tickDelay(3000)
    assert(gotCond() == false and hooked == 2, 'no condition: the full delay')
    Cast.removeTickHook('count')
    mq.delay = realDelay
    mq.onDelay = nil
end

-- a cast while moving: movement is paused and the cast waits until I have stopped (and a settle) before /cast
do
    local w = World.build(mq, { spells = {
        ['Remedy'] = { tt = 'Single', dur = 0, castMs = 2500 },
    }, gems = { [1] = 'Remedy' } })
    w.spawns[7] = { id = 7, name = 'Al', type = 'PC', dist = 10 }
    Spell.clearCache()
    -- on nav and moving; the client keeps carrying me one delay step after the pause
    local function startMoving()
        World.set(mq, 'Navigation.Active', true)
        World.set(mq, 'Navigation.Velocity', 10)
        World.set(mq, 'Me.Moving', true)
    end
    local pausedAt, movingAtCast
    local realCmd, realCmdf = mq.cmd, mq.cmdf
    local function movingNow()
        return rawget(mq.TLO.Me, '__children').Moving.__value or (rawget(mq.TLO.Navigation, '__children').Velocity.__value or 0) > 0
    end
    local function watch(s)
        if s == '/nav pause' then pausedAt = mq.now end
        if s:find('^/cast ') and movingAtCast == nil then movingAtCast = movingNow() end
    end
    mq.cmd = function(s) watch(s) realCmd(s) end
    mq.cmdf = function(fmt, ...) watch(string.format(fmt, ...)) realCmdf(fmt, ...) end
    -- as in MQ: a delay whose condition already holds returns at once (the stub always spends the full time)
    local realDelay = mq.delay
    mq.delay = function(ms, fn)
        if fn and fn() then return end
        return realDelay(ms, fn)
    end
    mq.onDelay = function()
        if pausedAt and mq.now > pausedAt then
            World.set(mq, 'Me.Moving', false)
            World.set(mq, 'Navigation.Velocity', 0)
        end
    end

    startMoving()
    pausedAt, movingAtCast = nil, nil
    mq.cmds = {}
    local t0 = mq.now
    Cast.cast('Remedy', 7, 'SingleHeal')
    assert(pausedAt, 'nav paused for the cast')
    assert(movingAtCast == false, 'the /cast waits until I stop moving')
    assert(mq.now - t0 >= Cast.cfg.CastSettleMs, 'and a settle after the stop')

    -- [General] CastSettleMs sets the settle: a long one shows in the elapsed time
    Cast.cfg.CastSettleMs = 900
    startMoving()
    pausedAt, movingAtCast = nil, nil
    local t3 = mq.now
    local resumeS = Cast.holdStill(true)
    assert(mq.now - t3 >= 900 and not movingNow(), 'CastSettleMs 900 waited after the stop')
    resumeS()
    -- 0 turns the settle off: only the wait for the stop
    Cast.cfg.CastSettleMs = 0
    startMoving()
    pausedAt = nil
    local t4 = mq.now
    Cast.holdStill(true)()
    local stopOnly = mq.now - t4
    Cast.cfg.CastSettleMs = 150
    startMoving()
    pausedAt = nil
    local t5 = mq.now
    Cast.holdStill(true)()
    assert(mq.now - t5 - stopOnly >= 150, 'CastSettleMs 0 skips the settle')

    -- an instant cast (or a bard song) pauses but does not wait for the stop
    startMoving()
    pausedAt = nil
    local t1 = mq.now
    local resume = Cast.holdStill(false)
    assert(pausedAt and mq.now == t1 and movingNow(), 'holdStill(false): paused, no wait')
    resume()

    -- a /moveto (no pause) is turned off for a cast-time spell
    World.set(mq, 'Navigation.Active', false)
    World.set(mq, 'Navigation.Velocity', 0)
    World.set(mq, 'Me.Moving', false)
    World.set(mq, 'MoveTo.Moving', true)
    mq.cmds = {}
    Cast.cast('Remedy', 7, 'SingleHeal')
    assert(World.count(mq, '/moveto off') == 1, '/moveto stopped for the cast')
    World.set(mq, 'MoveTo.Moving', false)

    -- standing still: no extra delay
    local t2 = mq.now
    Cast.waitStill()
    assert(mq.now == t2, 'waitStill does not wait when I am not moving')

    mq.cmd, mq.cmdf, mq.onDelay, mq.delay = realCmd, realCmdf, nil, realDelay
end

-- canRegister: only on the captured main coroutine and never inside the tick hooks
do
    assert(Cast.canRegister() == true, 'nothing captured (tests): registering is allowed outside hooks')
    Cast.captureMainCoroutine()
    assert(Cast.canRegister() == true, 'the main coroutine may register')
    local inCo = coroutine.wrap(function() return Cast.canRegister() end)()
    assert(inCo == false, 'another coroutine (a bind / event / mq.delay condition) may not')
    local inHook
    Cast.addTickHook('test_canreg', function() inHook = Cast.canRegister() end)
    Cast.tickDelay(1)
    Cast.removeTickHook('test_canreg')
    assert(inHook == false, 'inside the tick hooks it may not')
end

print('cast_test OK')
