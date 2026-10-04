-- core/cast.lua: CastWhat v2. One entry point for commands, skills, discs, items, AAs and book spells:
-- holds, resolve, memorise, target, the buff presence / stacking / level checks, cast, wait with the
-- interrupt hooks, result normalisation, retries and the MiscGem re-mem. Results keep the macro's
-- vocabulary (CAST_SUCCESS, CAST_INTERRUPTED, CAST_RESIST, CAST_FIZZLED, CAST_NOTREADY, CAST_OUTOFMANA,
-- CAST_OUTOFRANGE, CAST_CANNOTSEE, CAST_NOTARGET, CAST_COMPONENTS, CAST_RECOVER, CAST_NO_RESULT ...) plus the
-- named holds (Dead, Invis, Feign, Sitting, Midcombat, Chasing, Longmem, NoLOS) and CAST_SKIPPED for a buff
-- the target already has / that would not stack or land (the macro reported those as CAST_SUCCESS).
--
-- Senders (`from`): Buffs, OOGBuffs, BuffBeg, Pet, Cure, SingleHeal, GroupHeal, Heal, DPS, Mez, Pull, Med,
-- CheckEndurance, CheckAura, SummonStuff, Regenother, CastMount ... The rules that depend on the sender are
-- the macro's: buff senders yield to the chase, Heal senders may mem mid-combat, combat senders keep
-- TAKEHOLD/IMMUNE truthful, OOGBuffs/BuffBeg skip the already-present check differently.
local mq = require('mq')
local T = require('core.tlo')
local Spell = require('core.spell')
local Log = require('core.log')
local State = require('core.state')
local Timers = require('core.timers')
local Rules = require('core.buffrules')

local M = {}

M.result = 'CAST_NO_RESULT'
--- interrupt hooks: fn(ctx) -> reason string to stop the cast, or nil. ctx = { name, targetId, from, facts, timeLeftMs, kind }
M.interruptHooks = {}
function M.addInterruptHook(name, fn) M.interruptHooks[name] = fn end
--- tick hooks: fn() run from the cast's long blocking waits (the cast bar, the settle / cooldown / ready waits,
--- memorising, the misc gem waits) so modules ticked from the main loop keep running while a cast blocks it.
--- Return values are ignored and errors contained: a tick hook never interrupts a cast. Each fn throttles
--- itself and must not yield.
M.tickHooks = {}
function M.addTickHook(name, fn) M.tickHooks[name] = fn end
function M.removeTickHook(name) M.tickHooks[name] = nil end
--- True while tick hooks run. They mostly run inside an mq.delay condition, which MQ evaluates on a
--- throwaway coroutine (LuaCoroutine::CheckCondition). An mq.bind / mq.event / actors.register /
--- mq.imgui.init made there stores that coroutine's lua_State in its callback; once the coroutine is
--- collected, MQ calling the callback crashes the client (lua_rawgeti on a dead state). Hook code must
--- defer any registration while this is true and do it on the next main-loop pass.
local hookDepth = 0
function M.inHook() return hookDepth > 0 end
--- Binds and events run on throwaway coroutines too (LuaEvent.cpp), so the only safe place to register is
--- the script's main coroutine, which init.lua captures at load and which lives as long as the script.
--- Not captured (tests) = only the hook rule applies.
local mainCo, mainCaptured = nil, false
function M.captureMainCoroutine() mainCo, mainCaptured = coroutine.running(), true end
function M.canRegister()
    if hookDepth > 0 then return false end
    if mainCaptured and coroutine.running() ~= mainCo then return false end
    return true
end
local function runTickHooks()
    hookDepth = hookDepth + 1
    for _, fn in pairs(M.tickHooks) do pcall(fn) end
    hookDepth = hookDepth - 1
end
--- mq.delay(ms, cond) with the tick hooks run on every check; no cond = the full delay. Modules use
--- Cast.tickDelay for their own long waits (pull, rez, movement ...) so the heal ledger keeps ticking.
local function tickDelay(ms, cond)
    return mq.delay(ms, function()
        runTickHooks()
        if cond then return cond() end
        return false
    end)
end
M.tickDelay = tickDelay

--- Hooks other modules install (movement, ohshit, healer aggro). Each has a safe default.
M.hooks = {
    chaseLagging = function() return false end,     -- movement: the chase target is getting away
    moveForCast = function(targetId, range, why) return false end,   -- movement: walk into range / LoS
    ohShit = function(from) end,                    -- ohshit: the pre/post-cast emergency check
    feignHold = function() return false end,        -- healeraggro: feigning during the aggro-off hold
    doWeMove = function(reason) end,                -- movement: return to camp / follow the chase target
    combatReset = function(reason) end,             -- combat: CombatReset (attack off, target clear ...)
    preCast = function(name, id, from, facts) end,  -- focusswap: swap the spell's focus item in before the cast
}

-- settings ([General] unless noted), loaded by LoadSettings
M.cfg = { MiscGem = 8, MiscGemLW = 0, MiscGemRemem = 1, InvisCastHold = 1, CastRetries = 3, CastingInterruptOn = 0,
    GemStuckAbility = 'NULL', ActNatural = 1, InterruptHeals = 100, CastSettleMs = 150 }
M.Settings = {
    scalars = {
        { section = 'General', key = 'MiscGem', type = 'int', default = 8 },
        { section = 'General', key = 'MiscGemLW', type = 'int', default = 0 },
        { section = 'General', key = 'MiscGemRemem', type = 'int', default = 1 },
        { section = 'General', key = 'InvisCastHold', type = 'int', default = 1 },
        { section = 'General', key = 'CastRetries', type = 'int', default = 3 },
        { section = 'General', key = 'CastingInterruptOn', type = 'int', default = 0 },
        { section = 'General', key = 'GemStuckAbility', type = 'string', default = 'NULL', rank = false },
        { section = 'General', key = 'CastSettleMs', type = 'int', default = 150 },
        { section = 'Pull', key = 'ActNatural', type = 'int', default = 1 },
        { section = 'Heals', key = 'InterruptHeals', type = 'int', default = 100 },
    },
}
function M.LoadSettings()
    local Config = require('core.config')
    local c = Config.load(M.Settings)
    for k, v in pairs(c) do M.cfg[k] = v end
    M.captureMiscGems()
end
--- What sits in the misc gems now: put back after a one-off cast. Called at settings load and again
--- after a spell set loads ([SpellSet] LoadSpellSet, /memmyspells), never while a scratch spell is
--- waiting to be cast (that would record the scratch spell as the original).
function M.captureMiscGems()
    if M.reMemWaitShort or M.reMemWaitLong then return end
    M.reMemMiscGem = T.str(function() return mq.TLO.Me.Gem(M.cfg.MiscGem).Name() end)
    M.reMemMiscGemLW = (M.cfg.MiscGemLW or 0) > 0 and T.str(function() return mq.TLO.Me.Gem(M.cfg.MiscGemLW).Name() end) or ''
end
M.reMemMiscGem, M.reMemMiscGemLW = '', ''
M.reMemWaitShort, M.reMemWaitLong = nil, nil     -- the spells memmed over the misc gems, waiting to be cast
M.lastCastAt = 0                                   -- ms clock of the last successful cast (SitToMed)
M.castWhatFails = 0                                -- the recast count of the last cast (DPS resist timer)
M.castedOOGs = 0

-- ------------------------------------------------------------- sender classes
local function lower(s) return tostring(s or ''):lower() end
local function isBuffSender(from) local f = lower(from) return f:find('^buffs') or f:find('^oogbuffs') or f == 'buffbeg' or f:find('^pet') end
local function isHealSender(from) return lower(from):find('heal') ~= nil end
local COMBAT_SENDERS = { dps = true, debuffcast = true, combat = true, aggro = true, aoe = true, gom = true, ohshitstuff = true }
local function truthfulTakehold(from) return COMBAT_SENDERS[lower(from)] == true end
local function truthfulImmune(from) local f = lower(from) return COMBAT_SENDERS[f] == true or f == 'mez' end

-- ------------------------------------------------------------- cast result events
local resultEvents = {
    { 'ma_cast_fizzle', '#*#Your spell fizzles#*#', 'CAST_FIZZLED' },
    { 'ma_cast_fizzle2', 'Your #1# spell fizzles!', 'CAST_FIZZLED' },
    { 'ma_cast_interrupted', '#*#Your spell is interrupted#*#', 'CAST_INTERRUPTED' },
    { 'ma_cast_interrupted2', 'Your #1# spell is interrupted.', 'CAST_INTERRUPTED' },
    { 'ma_cast_interrupted3', '#*#Your casting has been interrupted#*#', 'CAST_INTERRUPTED' },
    { 'ma_cast_resist', '#*#resisted your #1#!', 'CAST_RESIST' },
    { 'ma_cast_resist2', '#*#Your target resisted the #1# spell#*#', 'CAST_RESIST' },
    { 'ma_cast_mezimmune', '#*#Your target cannot be mesmerized#*#', 'CAST_IMMUNE' },
    { 'ma_cast_distracted', '#*#You are too distracted to cast a spell now#*#', 'CAST_SUCCESS' },
    { 'ma_cast_nopet', '#*#You cannot cast this spell on your pet#*#', 'CAST_SUCCESS' },
    { 'ma_cast_takehold', '#*#Your spell did not take hold#*#', 'CAST_TAKEHOLD' },
    { 'ma_cast_takehold2', '#*#Your spell would not have taken hold#*#', 'CAST_TAKEHOLD' },
    { 'ma_cast_takehold3', '#*#Your spell is too powerful#*#', 'CAST_TAKEHOLD' },
    { 'ma_cast_immune', '#*#Your target has no mana to affect#*#', 'CAST_IMMUNE' },
    { 'ma_cast_immune2', '#*#Your target looks unaffected#*#', 'CAST_IMMUNE' },
    { 'ma_cast_immune3', '#*#Your target is immune to changes in its attack speed#*#', 'CAST_IMMUNE' },
    { 'ma_cast_immune4', '#*#Your target is immune to changes in its run speed#*#', 'CAST_IMMUNE' },
    { 'ma_cast_immune5', '#*#Your target cannot be given extra melee attacks#*#', 'CAST_IMMUNE' },
    { 'ma_cast_range', '#*#Your target is out of range, get closer#*#', 'CAST_OUTOFRANGE' },
    { 'ma_cast_los', '#*#You cannot see your target#*#', 'CAST_CANNOTSEE' },
    { 'ma_cast_notarget', '#*#You must first select a target for this spell#*#', 'CAST_NOTARGET' },
    { 'ma_cast_notarget2', '#*#This spell only works on#*#', 'CAST_NOTARGET' },
    { 'ma_cast_notarget3', '#*#You must first target a group member#*#', 'CAST_NOTARGET' },
    { 'ma_cast_mana', '#*#Insufficient Mana to cast this spell#*#', 'CAST_OUTOFMANA' },
    { 'ma_cast_stunned', '#*#You can\'t cast spells while stunned#*#', 'CAST_STUNNED' },
    { 'ma_cast_silenced', '#*#You *CANNOT* cast spells, you have been silenced#*#', 'CAST_SILENCED' },
    { 'ma_cast_standing', '#*#You must be standing to cast a spell#*#', 'CAST_STANDING' },
    { 'ma_cast_recover', '#*#You haven\'t recovered yet#*#', 'CAST_RECOVER' },
    { 'ma_cast_recover2', '#*#Spell recovery time not yet met#*#', 'CAST_RECOVER' },
    { 'ma_cast_notready', '#*#Spell recast time not yet met#*#', 'CAST_NOTREADY' },
    { 'ma_cast_components', '#*#You are missing some required components#*#', 'CAST_COMPONENTS' },
}

local eventsRegistered = false
function M.registerEvents()
    if eventsRegistered then return end
    for _, e in ipairs(resultEvents) do
        local res = e[3]
        mq.event(e[1], e[2], function() M.result = res end)
    end
    eventsRegistered = true
end
local function flushEvents()
    for _, e in ipairs(resultEvents) do pcall(mq.flushevents, e[1]) end
end

-- ------------------------------------------------------------- small helpers
local function casting() return T.num(function() return mq.TLO.Me.Casting.ID() end) > 0 end
local function inCombatState() return T.str(function() return mq.TLO.Me.CombatState() end) == 'COMBAT' end
local function targetId() return T.num(function() return mq.TLO.Target.ID() end) end

--- Wait for the current target's buff data (TargetBuffWait): 1 s in inspect range, 0.3 s beyond 200.
function M.targetBuffWait()
    if targetId() == 0 or T.bool(function() return mq.TLO.Target.BuffsPopulated() end) then return end
    local far = T.num(function() return mq.TLO.Target.Distance() end) > 200
    mq.delay(far and 300 or 1000, function() return T.bool(function() return mq.TLO.Target.BuffsPopulated() end) end)
end

--- Stand up for a cast; false when still not standing after a second (the macro's Sitting hold).
local function standGate()
    if T.bool(function() return mq.TLO.Me.Standing() end) then return true end
    mq.cmd('/stand')
    mq.delay(1000, function() return T.bool(function() return mq.TLO.Me.Standing() end) end)
    return T.bool(function() return mq.TLO.Me.Standing() end)
end

--- Moving at all: my own speed, or nav still carrying me.
local function moving()
    return T.bool(function() return mq.TLO.Me.Moving() end) or T.num(function() return mq.TLO.Navigation.Velocity() end) > 0
end
M.STILL_WAIT_MS = 1500   -- the longest a cast waits for me to stop
-- [General] CastSettleMs (default 150): after the last step, so the server has me stopped when the cast starts

--- Wait (up to STILL_WAIT_MS) until I stop, then CastSettleMs more; no wait when already still.
function M.waitStill()
    if not moving() then return end
    tickDelay(M.STILL_WAIT_MS, function() return not moving() end)
    local settle = math.max(0, math.min(tonumber(M.cfg.CastSettleMs) or 150, 2000))
    if settle > 0 then tickDelay(settle) end
end

--- Stop every mover for a cast with a cast time and wait until I stand still: a cast started on the move (or one
--- step after the pause, while the client still carries me) is interrupted. Stick, nav and AdvPath are paused and
--- come back with the returned resume(); a /moveto is turned off (it has no pause) and the next DoWeMove / pull
--- step reissues it. `still` false (an instant cast, a bard song) pauses without waiting, as before.
function M.holdStill(still)
    local pausedStick, pausedNav, pausedFollow = false, false, false
    if T.bool(function() return mq.TLO.Stick.Active() end) then mq.cmd('/stick pause') pausedStick = true end
    if T.bool(function() return mq.TLO.Navigation.Active() end) and not T.bool(function() return mq.TLO.Navigation.Paused() end) then mq.cmd('/nav pause') pausedNav = true end
    if T.bool(function() return mq.TLO.AdvPath.Following() end) and not T.bool(function() return mq.TLO.AdvPath.Paused() end) then mq.cmd('/squelch /afollow pause') pausedFollow = true end
    if still and T.bool(function() return mq.TLO.MoveTo.Moving() end) then mq.cmd('/squelch /moveto off') end
    if still then M.waitStill() end
    return function()
        if pausedStick then mq.cmd('/stick unpause') end
        if pausedNav and T.bool(function() return mq.TLO.Navigation.Paused() end) then mq.cmd('/nav pause') end
        if pausedFollow then mq.cmd('/squelch /afollow unpause') end
    end
end

--- Target `id` unless a self cast of a group SPA-0 spell (the melee target is kept then).
local function acquireTarget(id, facts)
    if id <= 0 then return true end
    if targetId() == id then return true end
    local tt = lower(facts and facts.targetType)
    if id == T.myId() and tt:find('group') and facts.hasSPA and facts.hasSPA(0) then return true end
    if not T.spawn(id) then return false end
    mq.cmdf('/squelch /target id %d', id)
    mq.delay(1000, function() return targetId() == id end)
    return targetId() == id
end

--- BuffOrChildPresent: the spell, or a SPA 374/340 child it triggers, is on the current target with > 180 s left.
function M.buffOrChildPresent(name)
    if T.num(function() return mq.TLO.Target.BuffDuration(name).TotalSeconds() end) > 180 then return true end
    local sp = mq.TLO.Spell(name)
    if T.bool(function() return sp.HasSPA(374)() end) or T.bool(function() return sp.HasSPA(340)() end) then
        for i = 1, 6 do
            local child = T.str(function() return sp.Trigger(i).Name() end)
            if child ~= '' and T.num(function() return mq.TLO.Target.BuffDuration(child).TotalSeconds() end) > 180 then return true end
        end
    end
    return false
end

--- WillItStick on a real recipient: PCs, mercenaries and PC-owned pets, never Self or Group v spells.
local function willStick(name, id, facts)
    local tt = lower(facts.targetType)
    if tt == 'self' or tt:find('group v') then return true end
    local sp = T.spawn(id)
    if not sp then return true end
    local ty = T.str(function() return sp.Type() end)
    local ownerPC = T.str(function() return sp.Master.Type() end) == 'PC'
    if ty ~= 'PC' and ty ~= 'Mercenary' and not ownerPC then return true end
    return Rules.willStick(T.num(function() return mq.TLO.Spell(name).Level() end), T.num(function() return sp.Level() end))
end

-- ------------------------------------------------------------- memorising (MemSpell)
--- Memorise `name` into gem `gem`; false when it did not land. Bails on hostiles unless a Heal sender or BuffMode.
function M.memSpell(name, gem, from)
    gem = tonumber(gem) or 0
    if not name or name == '' or gem == 0 then return false end
    if T.num(function() return mq.TLO.Me.Gem(name)() end) > 0 then return true end
    if T.num(function() return mq.TLO.Me.Book(name)() end) == 0 then
        Log.warn('Could Not find the spell %s in your spell book.', name)
        return false
    end
    local exempt = isHealSender(from) or State.buffMode
    mq.cmdf('/memspell %d "%s"', gem, name)
    tickDelay(30000, function()
        if not exempt and T.hostiles() > 0 then return true end
        return T.str(function() return mq.TLO.Me.Gem(gem).Name() end) == name
    end)
    if T.bool(function() return mq.TLO.Window('SpellBookWnd').Open() end) then mq.cmd('/windowstate SpellBookWnd close') end
    if inCombatState() then tickDelay(300) end
    return T.str(function() return mq.TLO.Me.Gem(gem).Name() end) == name
end

--- Put the misc gem's original spell back when a one-off spell was cast from it (MiscGemRemem).
function M.rememMiscGem(force)
    local c = M.cfg
    if (c.MiscGemRemem or 0) == 0 then return end
    if c.MiscGemRemem == 1 or c.MiscGemRemem == 2 then
        local cur = T.str(function() return mq.TLO.Me.Gem(c.MiscGem).Name() end)
        local holdActive = Timers.running('cast:miscgemhold') and cur == M.reMemWaitShort
        if M.reMemMiscGem ~= '' and cur ~= M.reMemMiscGem and (force or not holdActive) then
            if T.num(function() return mq.TLO.Me.Gem(M.reMemMiscGem)() end) == 0 then
                M.memSpell(M.reMemMiscGem, c.MiscGem, 'remem')
            end
            M.reMemWaitShort = nil
        end
    end
    if (c.MiscGemRemem == 1 or c.MiscGemRemem == 3) and (c.MiscGemLW or 0) > 0 and M.reMemMiscGemLW ~= '' then
        local cur = T.str(function() return mq.TLO.Me.Gem(c.MiscGemLW).Name() end)
        if cur ~= M.reMemMiscGemLW and (force or not M.reMemWaitLong) then
            M.memSpell(M.reMemMiscGemLW, c.MiscGemLW, 'remem')
            M.reMemWaitLong = nil
        end
    end
end

-- ------------------------------------------------------------- the wait
--- Wait for the cast in progress to finish, running the interrupt hooks every 100 ms. Returns the result.
function M.wait(name, id, from, facts, kind)
    local castMs = (facts and facts.castMs) or 0
    tickDelay(300, function() return casting() or M.result ~= 'CAST_NO_RESULT' end)
    if not casting() then
        if M.result ~= 'CAST_NO_RESULT' then return M.result end
        tickDelay(200)
        mq.doevents()
        if M.result ~= 'CAST_NO_RESULT' then return M.result end
    end
    if not casting() then
        -- no cast bar and no chat result: for a cast-time spell, item or AA that is still ready, nothing was
        -- cast (an unknown or unusable name, a silent refusal). Callers must not arm timers on it.
        if castMs > 250 and not casting() then
            local ready = false
            if kind == 'spell' then ready = T.bool(function() return mq.TLO.Me.SpellReady(name)() end)
            elseif kind == 'item' then ready = T.bool(function() return mq.TLO.Me.ItemReady(name)() end)
            elseif kind == 'aa' then ready = T.bool(function() return mq.TLO.Me.AltAbilityReady(name)() end) end
            if ready then
                Log.whyNot('NotStarted', name, tostring(id), 'no cast bar and still ready')
                return 'CAST_NOT_STARTED'
            end
        end
        return 'CAST_SUCCESS'
    end
    local stuckAt = T.now() + 20000
    -- a hard end: the cast time plus the gem-stuck recovery window, so stuck gems never trap the loop
    local hardEnd = T.now() + castMs + 30000
    local buffCheck = isBuffSender(from) and (M.cfg.CastingInterruptOn or 0) ~= 0
    while casting() do
        mq.doevents()
        if M.result ~= 'CAST_NO_RESULT' and M.result ~= 'CAST_SUCCESS' then break end
        local left = T.num(function() return mq.TLO.Me.CastTimeLeft() end)
        -- the buff interrupt (KACheckBUFFS): target dead, gone or out of range
        if buffCheck and id > 0 and id ~= T.myId() then
            local sp = T.spawn(id)
            local range = facts.range > 0 and facts.range or facts.aerange
            if not sp or T.num(function() return sp.PctHPs() end) < 1 or T.str(function() return sp.Type() end) == 'Corpse' then
                Log.whyNot('Interrupt', name, tostring(id), 'buff target dead or gone')
                mq.cmd('/stopcast') mq.delay(100) flushEvents()
                M.result = 'CAST_INTERRUPTED_BY_ME'
                return M.result
            elseif range > 0 and T.num(function() return sp.Distance() end) > range then
                Log.whyNot('Interrupt', name, T.str(function() return sp.CleanName() end), 'buff target out of range')
                mq.cmd('/stopcast') mq.delay(100) flushEvents()
                M.result = 'CAST_INTERRUPTED_BY_ME'
                return M.result
            end
        end
        for _, fn in pairs(M.interruptHooks) do
            local reason = fn({ name = name, targetId = id, from = from, facts = facts, timeLeftMs = left, kind = kind })
            if reason then
                Log.whyNot('Interrupt', name, tostring(id), reason)
                Log.info('Interrupting %s - %s', name, reason)
                mq.cmd('/stopcast') mq.delay(200) flushEvents()
                M.result = 'CAST_INTERRUPTED_BY_ME'
                return M.result
            end
        end
        if T.now() > stuckAt then
            -- the gems are stuck (an EQ bug): a cast-time AA unsticks them
            Log.warn('OUR GEMS ARE STUCK!')
            local ab = M.cfg.GemStuckAbility
            if ab and ab ~= '' and ab ~= 'NULL' and T.bool(function() return mq.TLO.Me.AltAbilityReady(ab)() end) then
                mq.cmdf('/alt act %d', T.num(function() return mq.TLO.Me.AltAbility(ab).ID() end))
                tickDelay(5000, function() return not T.bool(function() return mq.TLO.Me.SpellInCooldown() end) end)
                mq.cmd('/stopcast')
            end
            stuckAt = T.now() + 2000
        end
        if T.now() > hardEnd then
            Log.warn('Cast of %s did not end in %d s - stopping it.', name, math.floor((castMs + 30000) / 1000))
            mq.cmd('/stopcast') mq.delay(200) flushEvents()
            M.result = 'CAST_INTERRUPTED'
            return M.result
        end
        runTickHooks()   -- after the interrupt hooks, which may hand modules the cast's context first
        mq.delay(100)
    end
    tickDelay(150)
    mq.doevents()
    if M.result == 'CAST_NO_RESULT' then M.result = 'CAST_SUCCESS' end
    -- let the global cooldown pass (heal senders check once and move on)
    if not isHealSender(from) then
        tickDelay(2000, function()
            if isBuffSender(from) and M.hooks.chaseLagging() then return true end
            return not T.bool(function() return mq.TLO.Me.SpellInCooldown() end)
        end)
    end
    mq.doevents()
    return M.result
end

-- ------------------------------------------------------------- the cast
--- cast(name, targetId, from, opts) -> result string.
--- opts.kind forces 'spell'|'aa'|'item'|'disc'|'command'|'skill'; opts.tag sets State.castTag ('Heal'|'Tap'|'Mob');
--- opts.noWait returns right after the cast command; opts.dontRecast disables the fizzle/resist retry;
--- opts.nomem keeps the misc gem as it is after the cast; opts.item lets a BuffBeg cast click an item;
--- opts.skipOhShit skips the emergency pre/post-check.
function M.cast(name, id, from, opts)
    opts = opts or {}
    from = from or 'Unknown'
    local res = M.castInner(name, tonumber(id) or 0, from, opts)
    if res ~= 'CAST_SUCCESS' and res ~= 'CAST_SKIPPED' and res ~= 'CAST_STARTED' and res ~= '' then
        local who = 'none'
        local sp = T.spawn(id)
        if sp then who = T.str(function() return sp.CleanName() end) end
        Log.whyNot(from, name, who, res)
    end
    return res
end

local function resolveKind(name, opts)
    if opts.kind then return opts.kind end
    if lower(name):find('^command:') then return 'command' end
    local n = name:gsub('^[Ii]tem:', '')
    if T.num(function() return mq.TLO.FindItem('=' .. n).ID() end) > 0 and T.num(function() return mq.TLO.FindItem('=' .. n).Clicky.Spell.ID() end) > 0 then return 'item' end
    if T.bool(function() return mq.TLO.Me.AbilityReady(n)() end) or T.num(function() return mq.TLO.Me.SkillCap(n)() end) > 0 then return 'skill' end
    return Spell.kind(n)
end

function M.castInner(name, id, from, opts)
    M.castWhatFails = 0
    if not name or name == '' or name == 'NULL' then return 'CAST_NO_RESULT' end
    name = name:gsub('^[Ii]tem:', '')
    local kind = resolveKind(name, opts)
    if not kind then return 'CAST_UNKNOWN' end
    local facts = Spell.facts(name)
    State.castTag = opts.tag or 'Heal'

    -- holds
    if not opts.skipOhShit and lower(from) ~= 'ohshitstuff' then M.hooks.ohShit(from) end
    if T.bool(function() return mq.TLO.Me.Hovering() end) then return 'Dead' end
    local tsp = id > 0 and T.spawn(id) or nil
    local ttype = tsp and T.str(function() return tsp.Type() end) or ''
    local hold = M.cfg.InvisCastHold or 0
    if hold > 0 and T.bool(function() return mq.TLO.Me.Invis() end) and T.aggroTargetId() == 0 and T.myClass() ~= 'ROG'
        and lower(from) ~= 'ohshitstuff' and ttype ~= 'Corpse' and (hold >= 2 or ttype ~= 'NPC') then
        if Timers.expired('cast:invisecho') then
            Timers.set('cast:invisecho', 20000)
            Log.pm('cast: holding %s (%s) on %s - I am invis and nothing hates me (InvisCastHold %d)', name, from, tsp and T.str(function() return tsp.CleanName() end) or 'me', hold)
        end
        return 'Invis'
    end
    local role = lower(State.role)
    if (role == 'tank' or role == 'pullertank' or role == 'hunter') and (facts.hasSPA and facts.hasSPA(74) or lower(name) == 'feign death') then return 'Feign' end
    if M.hooks.feignHold() then return 'Feigned' end

    flushEvents()
    M.result = 'CAST_NO_RESULT'

    -- command:
    if kind == 'command' then
        if not standGate() then return 'Sitting' end
        mq.cmdf('/docommand /%s', (name:gsub('^[Cc]ommand:', ''):gsub('^/', '')))
        mq.delay(200)
        M.lastCastAt = T.now()
        return 'CAST_SUCCESS'
    end
    -- a skill (/doability)
    if kind == 'skill' then
        if not T.bool(function() return mq.TLO.Me.AbilityReady(name)() end) then return 'CAST_NOTREADY' end
        if not standGate() then return 'Sitting' end
        mq.cmdf('/doability "%s"', name)
        mq.delay(500, function() return not T.bool(function() return mq.TLO.Me.AbilityReady(name)() end) end)
        M.lastCastAt = T.now()
        return 'CAST_SUCCESS'
    end
    -- a combat ability / disc
    if kind == 'disc' then
        if not T.bool(function() return mq.TLO.Me.CombatAbilityReady(name)() end) then return 'CAST_NOTREADY' end
        local sp = mq.TLO.Spell(name)
        if T.num(function() return sp.EnduranceCost() end) > T.num(function() return mq.TLO.Me.CurrentEndurance() end) then return 'CAST_OUTOFMANA' end
        local reagent = T.num(function() return sp.ReagentID(1)() end)
        if reagent > 0 and T.num(function() return mq.TLO.FindItemCount(reagent)() end) < T.num(function() return sp.ReagentCount(1)() end) then return 'NoReagent' end
        local isDisc = T.bool(function() return sp.IsSkill() end) and T.num(function() return sp.Duration() end) > 0 and not T.bool(function() return sp.StacksWithDiscs() end)
        if isDisc and T.num(function() return mq.TLO.Me.ActiveDisc.ID() end) > 0 then return 'CAST_NO_RESULT' end
        if not acquireTarget(id, facts) then return 'CAST_NOTARGET' end
        if not standGate() then return 'Sitting' end
        local resume = facts.castMs > 0 and M.holdStill(true) or function() end
        mq.cmdf('/disc %s', name)
        mq.delay(200, function() return not T.bool(function() return mq.TLO.Me.CombatAbilityReady(name)() end) end)
        local res = 'CAST_SUCCESS'
        if facts.castMs > 0 then res = M.normalise(M.wait(name, id, from, facts, kind), from) end
        resume()
        if res == 'CAST_SUCCESS' then M.lastCastAt = T.now() end
        return res
    end
    -- an item clicky
    if kind == 'item' then
        if lower(from) == 'buffbeg' and not opts.item then return 'CAST_NO_RESULT' end
        if not T.bool(function() return mq.TLO.Me.ItemReady(name)() end) then return 'CAST_NOTREADY' end
        if not acquireTarget(id, facts) then return 'CAST_NOTARGET' end
        if not standGate() then return 'Sitting' end
        if lower(from):find('^oogbuffs') then M.castedOOGs = M.castedOOGs + 1 end
        local clickSec = T.num(function() return mq.TLO.FindItem('=' .. name).CastTime() end)
        local resume = M.holdStill(clickSec > 0 or facts.castMs > 0)
        mq.cmdf('/useitem "%s"', name)
        if opts.noWait then resume() return 'CAST_STARTED' end
        local res = M.wait(name, id, from, facts, kind)
        resume()
        res = M.normalise(res, from)
        if res == 'CAST_SUCCESS' then M.lastCastAt = T.now() end
        return res
    end
    -- an AA
    if kind == 'aa' then
        if not T.bool(function() return mq.TLO.Me.AltAbilityReady(name)() end) then return 'CAST_NOTREADY' end
        local aa = mq.TLO.Me.AltAbility(name)
        local reagent = T.num(function() return aa.Spell.ReagentID(1)() end)
        if reagent > 0 and T.num(function() return mq.TLO.FindItemCount(reagent)() end) < T.num(function() return aa.Spell.ReagentCount(1)() end) then return 'NoReagent' end
        if not acquireTarget(id, facts) then return 'CAST_NOTARGET' end
        if not standGate() then return 'Sitting' end
        if lower(from):find('^oogbuffs') then M.castedOOGs = M.castedOOGs + 1 end
        local resume = M.holdStill(facts.castMs > 0)
        mq.cmdf('/alt act %d', T.num(function() return aa.ID() end))
        if opts.noWait then resume() return 'CAST_STARTED' end
        local res = M.wait(name, id, from, facts, kind)
        resume()
        mq.delay(200, function() return not T.bool(function() return mq.TLO.Me.AltAbilityReady(name)() end) end)
        if res == 'CAST_SUCCESS' and T.bool(function() return mq.TLO.Me.AltAbilityReady(name)() end) then res = 'CAST_RECOVER' end
        res = M.normalise(res, from)
        if res == 'CAST_SUCCESS' then M.lastCastAt = T.now() end
        return res
    end

    -- ------------------------------------------------- a book spell
    if not Spell.haveMana(name) then return 'CAST_OUTOFMANA' end
    if not acquireTarget(id, facts) then
        if id > 0 and lower(facts.targetType) ~= 'self' then return 'CAST_NOTARGET' end
    end
    -- the buff block: a beneficial duration spell on a target that already has it / cannot take it is skipped
    local tt = lower(facts.targetType)
    if facts.beneficial and facts.durationSec > 0 and id > 0 then
        M.targetBuffWait()
        if (M.cfg.ActNatural or 0) ~= 0 then tickDelay(1500) end
        if not T.bool(function() return mq.TLO.Spell(name).StacksSpawn(id)() end) then return M.skipped(name, id, from, 'does not stack') end
        local f = lower(from)
        if f ~= 'buffbeg' and f ~= 'ohshitstuff' and targetId() == id and M.buffOrChildPresent(name) then return M.skipped(name, id, from, 'already has it') end
        if not willStick(name, id, facts) then return M.skipped(name, id, from, 'too low level for it') end
    end
    -- reagents
    local sp = mq.TLO.Spell(name)
    local reagent = T.num(function() return sp.ReagentID(1)() end)
    if reagent > 0 and T.num(function() return mq.TLO.FindItemCount(reagent)() end) < T.num(function() return sp.ReagentCount(1)() end) then return 'CAST_COMPONENTS' end
    -- memorise when needed
    if not Spell.memmed(name) then
        local amAttackingMA = State.attacking and lower(State.mainAssist) == lower(T.myName())
        if amAttackingMA or (State.healsOn and T.aggroTargetId() > 0 and not isHealSender(from) and not State.buffMode) then
            Log.info("I can't memorize %s right now", name)
            return 'Midcombat'
        end
        if isBuffSender(from) and M.hooks.chaseLagging() then return 'Chasing' end
        local c = M.cfg
        local recast = T.num(function() return sp.RecastTime.TotalSeconds() end)
        if (c.MiscGemRemem or 0) ~= 0 and (c.MiscGemLW or 0) > 0 and recast > 30 and not M.reMemWaitLong then
            M.reMemWaitLong = name
            M.memSpell(name, c.MiscGemLW, from)
            return 'CAST_NO_RESULT'
        end
        -- MiscGem is held for a spell memmed earlier that has not cast yet (its long refresh): memming over it
        -- would leave neither castable - two 36 s pet buffs swapped in the gem every check and never landed.
        -- Wait for it to cast (or its hold to run out); a heal still takes the gem.
        local held = M.reMemWaitShort
        if held and held ~= name and not isHealSender(from) and Timers.running('cast:miscgemhold')
            and T.str(function() return mq.TLO.Me.Gem(c.MiscGem).Name() end) == held then
            if Timers.expired('cast:gembusyecho') then
                Timers.set('cast:gembusyecho', 10000)
                Log.pm('cast: %s waits - MiscGem %d is held for %s until it casts', name, c.MiscGem or 0, held)
            end
            return 'Longmem'
        end
        M.reMemWaitShort = name
        if isHealSender(from) then
            require('core.comms').say('r', "I don't have my heal spell %s ready! You should save it. Trying to mem...hold on!~", name)
        end
        if not M.memSpell(name, c.MiscGem, from) then return 'Longmem' end
        -- keep it in the misc gem until it casts (DMF <-> Sedulous Subversion mem loop, 2026-09-25)
        Timers.set('cast:miscgemhold', (recast < 90 and (recast + 30) or 120) * 1000)
        tickDelay(1500, function() return T.num(function() return mq.TLO.Me.GemTimer(name)() end) > 0 end)
        local gemLeft = T.num(function() return mq.TLO.Me.GemTimer(name)() end)
        if gemLeft > 200 and inCombatState() then return 'Longmem' end
        tickDelay(5000, function()
            if isBuffSender(from) and M.hooks.chaseLagging() then return true end
            return T.bool(function() return mq.TLO.Me.SpellReady(name)() end)
        end)
        if not T.bool(function() return mq.TLO.Me.SpellReady(name)() end) then return 'Longmem' end
    end
    return M.castSpell(name, id, from, facts, opts)
end

--- A skipped buff: not an error, not logged in /whynot, reported as CAST_SKIPPED.
function M.skipped(name, id, from, why)
    Log.debug('skip %s on %d (%s): %s', name, id, from, why)
    return 'CAST_SKIPPED'
end

--- The spell cast itself (Sub Cast + WaitCast + the post-cast handling).
function M.castSpell(name, id, from, facts, opts)
    local sp = mq.TLO.Spell(name)
    if isBuffSender(from) and M.hooks.chaseLagging() then return 'Chasing' end
    -- a detrimental on an NPC needs line of sight and range: let the movement module try once
    local tsp = id > 0 and T.spawn(id) or nil
    if tsp and not facts.beneficial and T.str(function() return tsp.Type() end) == 'NPC' then
        local los = T.bool(function() return tsp.LineOfSight() end)
        local dist = T.num(function() return tsp.Distance3D() end)
        if not los or (facts.range > 0 and dist > facts.range) then
            M.hooks.moveForCast(id, facts.range, from .. '/' .. name)
            if not T.bool(function() return tsp.LineOfSight() end) then return 'NoLOS' end
        end
    end
    -- stop for the cast (a bard song or an instant spell goes off on the move)
    local still = facts.castMs > 0 and T.myClass() ~= 'BRD'
    local resume = M.holdStill(still)
    if not standGate() then resume() return 'Sitting' end
    if lower(from):find('^oogbuffs') then
        M.castedOOGs = M.castedOOGs + 1
        Log.info('OOG buff %s on %s (#%d)', name, tsp and T.str(function() return tsp.CleanName() end) or '?', M.castedOOGs)
    end
    pcall(M.hooks.preCast, name, id, from, facts)  -- a focus swap never blocks the cast
    local tries = 0
    local res
    local again = true
    while again do
        again = false
        -- never /cast an unready spell: WaitCast would stamp it a success
        tickDelay(2000, function()
            if isBuffSender(from) and M.hooks.chaseLagging() then return true end
            return T.bool(function() return mq.TLO.Me.SpellReady(name)() end)
        end)
        if not T.bool(function() return mq.TLO.Me.SpellReady(name)() end) then
            res = 'CAST_NOTREADY'
        else
            if still and tries > 0 then M.waitStill() end   -- the recast after a move into range / line of sight
            flushEvents()
            M.result = 'CAST_NO_RESULT'
            mq.cmdf('/cast "%s"', name)
            tickDelay(200)
            -- re-issue until the cast bar shows the spell or the gem goes on cooldown (casts over 250 ms only)
            local reissue = 0
            while facts.castMs > 250 and not casting() and T.bool(function() return mq.TLO.Me.SpellReady(name)() end) and M.result == 'CAST_NO_RESULT' and reissue < 5 do
                reissue = reissue + 1
                mq.cmdf('/cast "%s"', name)
                tickDelay(200)
            end
            if opts.noWait then resume() return 'CAST_STARTED' end
            res = M.wait(name, id, from, facts, 'spell')
            -- one move for range / line of sight, then a recast
            if (res == 'CAST_OUTOFRANGE' or res == 'CAST_CANNOTSEE') and tries == 0 and tsp then
                tries = tries + 1
                if M.hooks.moveForCast(id, facts.range, from .. '/' .. name) then again = true end
            end
            -- fizzle / resist retry
            if not again and (res == 'CAST_FIZZLED' or res == 'CAST_RESIST') and not opts.dontRecast and M.castWhatFails < (M.cfg.CastRetries or 3) then
                M.castWhatFails = M.castWhatFails + 1
                if Spell.haveMana(name) and not T.bool(function() return mq.TLO.Me.Hovering() end) then
                    Log.info('spell %s - trying %s again', res, name)
                    tickDelay(2000, function() return T.num(function() return mq.TLO.Me.GemTimer(name)() end) == 0 end)
                    again = true
                end
            end
        end
    end
    resume()
    res = M.normalise(res, from)
    if res == 'CAST_SUCCESS' then
        M.lastCastAt = T.now()
        -- the misc gem: put the original back after the one-off spell cast from it
        if name == M.reMemWaitShort then
            Timers.clear('cast:miscgemhold')
            if not opts.nomem and not isHealSender(from) and not State.combatStart and T.num(function() return mq.TLO.Me.Buff('Resurrection Sickness').ID() end) == 0 then
                M.rememMiscGem(true)
            end
            M.reMemWaitShort = nil
        elseif name == M.reMemWaitLong then
            if not opts.nomem then M.rememMiscGem(true) end
            M.reMemWaitLong = nil
        end
    end
    return res
end

--- The macro's result normalisation: TAKEHOLD / IMMUNE are truthful only for combat senders; an unknown
--- value is a success.
local KNOWN = { CAST_CANCELLED = 1, CAST_FIZZLED = 1, CAST_RESIST = 1, CAST_INTERRUPTED = 1, CAST_TAKEHOLD = 1, CAST_IMMUNE = 1,
    CAST_NOTREADY = 1, CAST_RECOVER = 1, CAST_OUTOFRANGE = 1, CAST_CANNOTSEE = 1, CAST_NOTARGET = 1, CAST_OUTOFMANA = 1,
    CAST_STUNNED = 1, CAST_SILENCED = 1, CAST_STANDING = 1, CAST_COMPONENTS = 1, CAST_INTERRUPTED_BY_ME = 1, CAST_SKIPPED = 1,
    CAST_NOT_STARTED = 1 }
function M.normalise(res, from)
    if res == 'CAST_TAKEHOLD' and not truthfulTakehold(from) then return 'CAST_SUCCESS' end
    if res == 'CAST_IMMUNE' and not truthfulImmune(from) then return 'CAST_SUCCESS' end
    if not KNOWN[res] then return 'CAST_SUCCESS' end
    return res
end

return M
