-- modules/healagent.lua: the per-box publisher for the raid heal gap ledger (modules/healbrain on the MA's
-- box). With [Heals] HealBrainOn it ships, every 250 ms, what this box knows - its own HP, mana, cast in
-- flight and counters, its group's HP and positions, the raid roster when it is the MA, its heal/cure lines
-- and their readiness (1 Hz) and the bot's own decisions (/whynot, withheld group heals, unready cures,
-- interrupts) - to the brain over actors. Passive: it never casts and never changes bot state.
-- A port of sidekick-next ma_healagent.lua (origin/feat/heal-ledger @ 6a94070): the snapshot and event
-- logic is kept; every macro-variable read is replaced by bot state, the loop by Tick, and the ImGui window,
-- /healagent bind and startup wait / exit logic are gone.
-- Spec: muleassist/docs/superpowers/specs/2026-10-03-luaport-healledger-design.md
local mq = require('mq')
local T = require('core.tlo')
local Config = require('core.config')
local Spell = require('core.spell')
local Lines = require('core.lines')
local Log = require('core.log')
local State = require('core.state')
local Stats = require('core.stats')

local M = { name = 'healagent' }

M.Settings = {
    scalars = {
        { section = 'Heals', key = 'HealBrainOn', type = 'int', default = 0 },
    },
}

M.SCRIPT = 'muleassist'
M.BRAIN_ADDR = { mailbox = 'heal_brain', script = M.SCRIPT }
M.AGENT_MAILBOX = 'heal_agent'
M.LOOP_MS, M.LINES_MS, M.RAID_CACHE_MS = 250, 1000, 10000

-- ---------------------------------------------------------------- helpers
local num, str, bool = T.num, T.str, T.bool

local function split(s, sep)
    local out = {}
    for piece in string.gmatch(s or '', '([^' .. sep .. ']+)') do out[#out + 1] = piece end
    return out
end

local function trim(s) return (tostring(s or ''):gsub('^%s+', ''):gsub('%s+$', '')) end

local function myName() return T.myName() end

local function groupKey(me)
    local rg = num(function() return mq.TLO.Raid.Member(me).Group() end, 0)
    if rg > 0 then return 'raid:' .. rg end
    local leader = str(function() return mq.TLO.Group.Leader.CleanName() end)
    if leader ~= '' then return 'grp:' .. leader end
    return 'grp:' .. me
end

local function amMainAssist()
    return tostring(State.mainAssist or ''):lower() == myName():lower()
end

-- ---------------------------------------------------------------- spell facts
-- the agent's kind ('direct'|'hot'|'group'|'other') is core/spell's cat; range / cast time / mana as before
local function spellFacts(name)
    local f = Spell.facts(name)
    return { range = f.range or 0, aerange = f.aerange or 0, castMs = f.castMs or 0, mana = f.mana or 0,
        kind = f.cat or 'other', spellKind = f.kind }
end

local function isReady(name, f)
    return Spell.ready(name, f and f.spellKind)
end

-- the bot's heal and cure lines with readiness; refreshed at 1 Hz
function M:buildLines()
    local mana = num(function() return mq.TLO.Me.CurrentMana() end)
    local out = { direct = {}, group = {}, cures = {} }
    local kinds = {}
    local Heals = require('modules.heals')
    for _, l in ipairs(Heals.single or {}) do
        local name, pct = trim(l.name), tonumber(l.pct) or 0
        local tag = trim(l.args and l.args[3] or ''):lower()
        if name ~= '' and pct > 0 and not Lines.has(l, 'tap') and not Lines.has(l, 'mob') then
            local f = spellFacts(name)
            if f.kind == 'direct' or f.kind == 'hot' then
                kinds[name] = f.kind
                out.direct[#out.direct + 1] = { name = name, pct = pct, range = f.range > 0 and f.range or 100,
                    castMs = f.castMs, ready = isReady(name, f), mana = f.mana <= mana, tag = tag, hot = f.kind == 'hot' }
            end
        end
    end
    for _, l in ipairs(Heals.group or {}) do
        local name, pct = trim(l.name), tonumber(l.pct) or 0
        if name ~= '' and pct > 0 then
            local f = spellFacts(name)
            kinds[name] = 'group'
            out.group[#out.group + 1] = { name = name, pct = pct, range = f.aerange > 0 and f.aerange or 100,
                ready = isReady(name, f), mana = f.mana <= mana }
        end
    end
    for _, c in ipairs(require('modules.cures').lines or {}) do
        local name = trim(c.name)
        if name ~= '' then
            local types = {}
            if not c.any then for ty, on in pairs(c.types or {}) do if on then types[ty] = true end end end
            local f = spellFacts(name)
            kinds[name] = 'cure'
            out.cures[#out.cures + 1] = { name = name, types = types, range = f.range > 0 and f.range or 100, ready = isReady(name, f) }
        end
    end
    self.lineKinds = kinds
    return out
end

-- ---------------------------------------------------------------- /healreport counters (1 Hz)
local STAT_INTS = { 'single', 'tank', 'groupT', 'self', 'pet', 'oog', 'tap', 'mob', 'intHeal', 'intTap', 'intMob',
    'intNPC', 'dpsCut', 'fail', 'group', 'groupRange', 'smart', 'smartFail', 'cure', 'cureGroup', 'cureHeld',
    'cureUnready', 'skip', 'lowPct', 'tankLow', 'fights' }
M.STAT_INTS = STAT_INTS

local function nonEmpty(v) if v == nil or v == '' then return nil end return v end

function M:buildStats()
    local hs = Stats.hs
    local st = {}
    for _, key in ipairs(STAT_INTS) do st[key] = tonumber(hs[key]) or 0 end
    st.failLast = nonEmpty(hs.failLast)
    st.lowName = nonEmpty(hs.lowName)
    st.line = (State.healStats ~= nil and State.healStats ~= '') and State.healStats or Stats.build(myName())
    st.sinceSec = math.max(0, Stats.elapsed())
    return st
end

-- ---------------------------------------------------------------- counters
local function myCounters()
    local c = {
        p = num(function() return mq.TLO.Me.CountersPoison() end, -1),
        d = num(function() return mq.TLO.Me.CountersDisease() end, -1),
        c = num(function() return mq.TLO.Me.CountersCurse() end, -1),
        co = num(function() return mq.TLO.Me.CountersCorruption() end, -1),
    }
    if c.p >= 0 and c.d >= 0 and c.c >= 0 and c.co >= 0 then return c end
    -- fall back to the bot's own line: N|poisonID|diseaseID|curseID|corruptionID (0 = clean)
    local md = split(State.myDebuffs or '0', '|')
    return { p = (tonumber(md[2]) or 0) > 0 and 1 or 0, d = (tonumber(md[3]) or 0) > 0 and 1 or 0,
             c = (tonumber(md[4]) or 0) > 0 and 1 or 0, co = (tonumber(md[5]) or 0) > 0 and 1 or 0 }
end

-- ---------------------------------------------------------------- cast in flight
function M:casting(nowMs, myId)
    local castSeen = self.castSeen
    local spell = str(function() return mq.TLO.Me.Casting() end)
    if spell == '' then castSeen.spell = nil self.castCtx = nil return nil end
    if castSeen.spell ~= spell then
        castSeen.spell = spell
        castSeen.startedAt = nowMs
        castSeen.targetId = num(function() return mq.TLO.Target.ID() end)
        castSeen.targetName = str(function() return mq.TLO.Target.CleanName() end)
        castSeen.fromCtx = false
    end
    -- the cast engine's own name and target id (its interrupt hook ctx) beat the Target TLO when they match
    local ctx = self.castCtx
    if ctx and not castSeen.fromCtx and ctx.targetId > 0 and ctx.name:lower() == spell:lower() then
        castSeen.targetId = ctx.targetId
        local sp = T.spawn(ctx.targetId)
        castSeen.targetName = sp and str(function() return sp.CleanName() end) or castSeen.targetName
        castSeen.fromCtx = true
    end
    local left = num(function() return mq.TLO.Me.CastTimeLeft() end)
    local kind = self.lineKinds[spell]
    if not kind then kind = spellFacts(spell).kind end
    local tid = castSeen.targetId
    if kind == 'group' then tid = myId end
    return { spell = spell, targetId = tid, targetName = castSeen.targetName, landsAt = nowMs + left, startedAt = castSeen.startedAt, kind = kind }
end

-- ---------------------------------------------------------------- targets
-- class / knownId: the raid roster passes its cached class and the spawn id it already read
local function spawnRecord(sp, name, group, isPet, class, knownId)
    local id = knownId
    if not id then
        if not sp or not sp() then return nil end
        id = num(function() return sp.ID() end)
    end
    if id <= 0 then return nil end
    local hp = num(function() return sp.PctHPs() end)
    -- a dead member's spawn stays type PC at 0 HP (the corpse is another spawn): Dead() or 0 HP
    return id, {
        name = name or str(function() return sp.CleanName() end),
        hp = hp,
        x = num(function() return sp.X() end), y = num(function() return sp.Y() end), z = num(function() return sp.Z() end),
        dead = bool(function() return sp.Dead() end) or hp <= 0,
        class = class or str(function() return sp.Class.ShortName() end),
        group = group, pet = isPet == true,
    }
end

--- The MA's raid roster: each member's name / group / class is cached (re-read when Raid.Members() changes,
--- when a slot's spawn id changes - a reordered roster, a zone-in - and every RAID_CACHE_MS); HP, position
--- and death are read every pass for the members in zone.
function M:raidTargets(out, myId, nowMs)
    local c = self.raidCache
    local rn = num(function() return mq.TLO.Raid.Members() end)
    if rn ~= c.n or nowMs >= c.refreshAt then
        c.n, c.refreshAt, c.members = rn, nowMs + self.RAID_CACHE_MS, {}
    end
    for i = 1, rn do
        local rm = mq.TLO.Raid.Member(i)
        -- only raiders with a spawn in this zone: no position means the brain cannot judge range
        local rid = num(function() return rm.Spawn.ID() end)
        if rid > 0 and rid ~= myId and not out[tostring(rid)] then
            local e = c.members[i]
            if not e or e.id ~= rid then
                e = { id = rid, name = str(function() return rm.Name() end), group = num(function() return rm.Group() end),
                    class = str(function() return rm.Spawn.Class.ShortName() end) }
                c.members[i] = e
            end
            local id, rec = spawnRecord(rm.Spawn, e.name, 'raid:' .. e.group, false, e.class, rid)
            if id then out[tostring(id)] = rec end
        end
    end
end

function M:buildTargets(gkey, withRaid, myId, nowMs)
    local out = {}
    local n = num(function() return mq.TLO.Group.Members() end)
    for i = 1, n do
        local m = mq.TLO.Group.Member(i)
        -- keyed by tostring(id): a sparse integer-keyed table is not a safe actors payload
        local id, rec = spawnRecord(m, nil, gkey, false)
        if id and id ~= myId then out[tostring(id)] = rec end
        local pid, prec = spawnRecord(m and m.Pet, nil, gkey, true)
        if pid then out[tostring(pid)] = prec end
    end
    if withRaid then self:raidTargets(out, myId, nowMs) end
    return out
end

-- ---------------------------------------------------------------- bot decisions -> events
local INT_REASONS = {
    intHeal = 'target past the heal line', intTap = 'tap at full HP',
    intMob = 'nuke-heal with the tank recovered', intNPC = 'heal on an NPC',
}
local INT_KEYS = { 'intHeal', 'intTap', 'intMob', 'intNPC' }

local function whynotTarget(text)
    -- "[HH:MM:SS] Where: What -> Who: Why (xN)"; the bot's cast engine logs Who as a spawn id
    local who = text and text:match('%->%s*([^:]+):') or nil
    if not who then return nil, nil end
    who = trim(who)
    local asId = tonumber(who)
    if asId then
        local name = str(function() return mq.TLO.Spawn(asId).CleanName() end)
        return asId, name ~= '' and name or who
    end
    local id = num(function() return mq.TLO.Spawn('=' .. who).ID() end)
    return id, who
end

function M:collectEvents(nowMs, cast)
    local hs, hsNow = self.seen, Stats.hs
    local events = {}
    if cast then self.lastCast = { spell = cast.spell, targetId = cast.targetId, targetName = cast.targetName } end
    local lastCast = self.lastCast
    -- the bot's own interrupt counters (/healreport): each increment is one interrupt of the last cast
    for _, key in ipairs(INT_KEYS) do
        local n = tonumber(hsNow[key]) or 0
        if hs.seeded and n > hs[key] then
            events[#events + 1] = { kind = 'interrupt', spell = lastCast.spell, targetId = lastCast.targetId,
                targetName = lastCast.targetName, reason = INT_REASONS[key], ts = nowMs }
        end
        hs[key] = n
    end
    local gr = tonumber(hsNow.groupRange) or 0
    if hs.seeded and gr > hs.groupRange then
        events[#events + 1] = { kind = 'withheld', spell = 'group heal', targetId = 0, reason = 'withheld: 2+ hurt in the zone but nobody in the heal\'s range', ts = nowMs }
    end
    hs.groupRange = gr
    local cu = tonumber(hsNow.cureUnready) or 0
    if cu > hs.cureUnready and hs.seeded then
        events[#events + 1] = { kind = 'withheld', spell = nonEmpty(hsNow.cureUnreadyLast) or 'cure', targetId = 0, reason = 'cure not ready (not memmed in combat, or on reuse)', ts = nowMs }
    end
    hs.cureUnready = cu
    local w = Log.whynot
    local idx = tonumber(w.idx) or 0
    local text = idx > 0 and w.ring[idx] or nil
    if text and text ~= hs.whynotText and hs.seeded then
        -- "[HH:MM:SS] Where: What -> Who: Why (xN)": strip the stamp, the spell sits between the first ':' and '->'
        local tid, who = whynotTarget(text)
        local body = text:gsub('^%[[^%]]*%]%s*', '')
        local spell = body:match('^[^:]+:%s*(.-)%s*%->')
        events[#events + 1] = { kind = 'withheld', spell = (spell and spell ~= '') and spell or nil,
            targetId = tid or 0, targetName = who, reason = body, ts = nowMs }
    end
    hs.whynotText = text
    hs.seeded = true
    return events, text
end

-- ---------------------------------------------------------------- the snapshot
--- One snapshot in the ledger's schema (healledger/ledger.lua header). full = the 1 Hz parts too: lines,
--- stats, the macro block and, when this box is the MA, the raid roster.
function M:snapshot(nowMs, full)
    local me = myName()
    local myId = T.myId()
    local gkey = groupKey(me)
    if full then
        self.lines = self:buildLines()
        self.stats = self:buildStats()
    end
    local isMA = amMainAssist()
    local cast = self:casting(nowMs, myId)
    local events, whynot = self:collectEvents(nowMs, cast)
    local targets = self:buildTargets(gkey, isMA and full, myId, nowMs)
    self.seq = self.seq + 1
    local Heals = require('modules.heals')
    return {
        v = 1, from = me, id = myId, ts = nowMs, seq = self.seq,
        zone = str(function() return mq.TLO.Zone.ShortName() end),
        me = {
            hp = num(function() return mq.TLO.Me.PctHPs() end), mana = num(function() return mq.TLO.Me.PctMana() end),
            dead = bool(function() return mq.TLO.Me.Dead() end) or num(function() return mq.TLO.Me.PctHPs() end) <= 0,
            stunned = bool(function() return mq.TLO.Me.Stunned() end), feigned = bool(function() return mq.TLO.Me.Feigning() end),
            x = num(function() return mq.TLO.Me.X() end), y = num(function() return mq.TLO.Me.Y() end), z = num(function() return mq.TLO.Me.Z() end),
            class = str(function() return mq.TLO.Me.Class.ShortName() end), group = gkey,
            inCombat = T.inCombat(),
            casting = cast, counters = myCounters(),
        },
        lines = full and self.lines or nil,
        stats = full and self.stats or nil,
        targets = targets,
        macro = full and {
            healLine = tonumber(State.singleHealPoint) or 0, tankLine = tonumber(State.singleHealPointMA) or 0,
            healTank = nonEmpty(State.healTank), healTankId = tonumber(State.healTankId) or 0,
            healsOn = State.healsOn and 1 or 0, curesOn = State.curesOn and 1 or 0, whynotLast = whynot,
            healPets = (Heals.cfg and Heals.cfg.HealGroupPetsOn or 0) ~= 0,
            isMA = isMA, combat = State.combatStart == true,
        } or nil,
        events = events,
    }
end

-- ---------------------------------------------------------------- actors
function M:register()
    if self.dropbox or self.registerFailed then return self.dropbox end
    -- never register from a tick hook: the callback would keep a dead coroutine (core/cast.lua Cast.inHook)
    if not require('core.cast').canRegister() then return nil end
    local ok, actors = pcall(require, 'actors')
    if not ok or not actors then
        self.registerFailed = true
        Log.warn('HealAgent: actors unavailable - no snapshots sent')
        return nil
    end
    local okReg, box = pcall(actors.register, M.AGENT_MAILBOX, function(message)
        -- non-yieldable: copy scalars only
        local okm, c = pcall(function() return message() end)
        if okm and type(c) == 'table' and c.kind == 'brain' then
            M.brain.name = tostring(c.from or '?')
            M.brain.seenAt = mq.gettime()
        end
    end)
    if okReg then self.dropbox = box
    else
        self.registerFailed = true
        Log.warn('HealAgent: actors.register failed: %s', tostring(box))
    end
    return self.dropbox
end

--- Status for the brain's report: snapshots sent / failed, the last brain heard and when.
function M:status()
    return { sent = self.sent, sendFails = self.sendFails, brain = self.brain.name, seenAt = self.brain.seenAt }
end

-- ---------------------------------------------------------------- module hooks
function M.reset()
    if M.dropbox then pcall(function() M.dropbox:unregister() end) end
    M.dropbox, M.registerFailed = nil, false
    M.brain = { name = nil, seenAt = 0 }
    M.sent, M.sendFails = 0, 0
    M.seq = 0
    M.nextTick, M.nextFull = 0, 0
    M.lines, M.stats = nil, nil
    M.lineKinds = {}
    M.castSeen = { spell = nil, startedAt = 0, targetId = 0, targetName = nil, fromCtx = false }
    M.castCtx, M.hookErr = nil, nil
    M.raidCache = { n = -1, refreshAt = 0, members = {} }
    M.lastCast = { spell = nil, targetId = 0, targetName = nil }
    M.seen = { intHeal = 0, intTap = 0, intMob = 0, intNPC = 0, groupRange = 0, cureUnready = 0, whynotText = nil, seeded = false }
end
M.reset()

function M:LoadSettings()
    self.cfg = Config.load(self.Settings)
    State.healBrainOn = (self.cfg.HealBrainOn or 0) ~= 0
    -- Cast.wait blocks the main loop for the whole cast and runs the interrupt hooks every 100 ms: sample
    -- from there too, so this box stays fresh (and shows its cast in flight) while it casts
    local Cast = require('core.cast')
    Cast.addInterruptHook('healagent', function(ctx) M:onCastTick(ctx) return nil end)
    -- and from the cast engine's other blocking waits (cooldowns, memorising); Tick's own 250 ms throttle is
    -- shared with the main loop and the interrupt hook, so nothing is sent twice in one window
    Cast.addTickHook('healagent', function() M:onCastTick(nil) end)
end

--- The cast engine's interrupt hook: remember what it is casting on whom, then Tick (self-throttled to
--- 250 ms, never yields). Never returns a reason and never raises, so it cannot stop or break a cast.
function M:onCastTick(ctx)
    local ok, err = pcall(function()
        if not State.healBrainOn then return end
        if type(ctx) == 'table' and type(ctx.name) == 'string' and ctx.name ~= '' then
            local new = { name = ctx.name, targetId = tonumber(ctx.targetId) or 0, timeLeftMs = tonumber(ctx.timeLeftMs) }
            local prev = self.castCtx
            -- a new cast: another spell or target, or a fresh (longer) cast bar. Back-to-back casts of one spell
            -- never show the main loop an empty Me.Casting, so castSeen is restarted here.
            if not prev or prev.name ~= new.name or prev.targetId ~= new.targetId
                or (new.timeLeftMs and prev.timeLeftMs and new.timeLeftMs > prev.timeLeftMs) then
                self.castSeen.spell, self.castSeen.fromCtx = nil, false
            end
            self.castCtx = new
        end
        self:Tick()
    end)
    if not ok and tostring(err) ~= self.hookErr then
        self.hookErr = tostring(err)
        pcall(Log.error, 'HealAgent: cast-time sample failed: %s', self.hookErr)
    end
end

function M:Tick()
    if not State.healBrainOn then
        -- re-seed on the way back on: counter deltas and /whynot entries from the off time are not news
        self.seen.seeded = false
        return
    end
    local now = mq.gettime()
    if now < self.nextTick then return end
    -- on a 250 ms grid: the main loop's 100 ms passes must not stretch it to 300
    self.nextTick = self.nextTick + self.LOOP_MS
    if self.nextTick <= now then self.nextTick = now + self.LOOP_MS end
    local box = self:register()
    if not box then return end
    local full = now >= self.nextFull
    if full then self.nextFull = now + self.LINES_MS end
    local snap = self:snapshot(now, full)
    local ok, res = pcall(function() return box:send(M.BRAIN_ADDR, snap) end)
    if ok and not (type(res) == 'number' and res < 0) then self.sent = self.sent + 1 else self.sendFails = self.sendFails + 1 end
end

function M:Shutdown()
    if self.dropbox then pcall(function() self.dropbox:unregister() end) end
    self.dropbox = nil
    local Cast = package.loaded['core.cast']
    if Cast and Cast.interruptHooks then Cast.interruptHooks.healagent = nil end
    if Cast and Cast.removeTickHook then Cast.removeTickHook('healagent') end
end

M.Binds = {
    ['/healbrainon'] = function(self, arg)
        local a = tostring(arg or ''):lower()
        local v
        if a == 'on' or a == '1' then v = 1
        elseif a == 'off' or a == '0' then v = 0
        else v = State.healBrainOn and 0 or 1 end
        self.cfg = self.cfg or {}
        self.cfg.HealBrainOn = v
        if v ~= 0 and not State.healBrainOn then self.seen.seeded = false end
        State.healBrainOn = v ~= 0
        Config.set('Heals', 'HealBrainOn', v)
        Log.info('HealBrainOn %d', v)
    end,
}

return M
