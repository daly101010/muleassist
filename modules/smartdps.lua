-- modules/smartdps.lua: SmartDPS, the necrobrain picker, in-process. A port of necrobrain/init.lua @ afdb330
-- (F:/lua/necrobrain) into a bot module; spec
-- muleassist/docs/superpowers/specs/2026-10-03-luaport-necrobrain-design.md. necrobrain's own modules are
-- forked unchanged into necrobrain/ and required only as necrobrain.<name>.
--
-- The 200 ms step is the body of necrobrain's main loop, in source order. What changed from init.lua:
--   * no macro guards (the start wait, macro-gone exit, SmartDPSOn exit) and no loop of its own: the step
--     runs from Tick, from dps.lua's per-entry pass and from the Cast tick hook, all on one 200 ms throttle;
--   * macro reads come from the bot: dps.cfg (SmartDPSOn, SmartDPSDebug, DPSOn, DPSInterval, DPSCOn),
--     State.myTargetId, Config.iniFile, Config.conditionsOn; conditions go through core.cond;
--   * picks go to dps.lua through Dps.smartSet instead of /varset, and dps.lua reports each verdict through
--     M.onResult instead of SmartDPSAck / SmartDPSResult;
--   * the beat advances only while the parse service runs (companion, maui or malua) and the step did not
--     error; an error (decide included) withholds it, so dps.lua's fresh timer lapses and it walks its list;
--   * SmartDPSOn=0 or /necrobrain stop freezes the engine (no publishing, no beat) instead of exiting it.
-- Settings: none of its own. The engine (necrobrain.*) loads on the first active Tick. The Blade of Vesagran
-- rotation (necrobrain.vesagran: Calbuss / Beyonce, with Parsaxx's medley) is not part of the engine: it ticks on
-- every Tick pass whatever SmartDPSOn, /necrobrain stop or the 200 ms throttle say, and loads on the first one.
local mq = require('mq')
local Config = require('core.config')
local State = require('core.state')
local Cast = require('core.cast')
local Cond = require('core.cond')
local Log = require('core.log')

local M = { name = 'smartdps' }

M.vesagranOn = false
M.LOOP_MS = 200
M.PARSER_CHECK_MS = 5000
M.ERROR_LOG_MS = 10000
M.LOAD_RETRY_MS = 30000   -- a failed engine load is tried again at most this often
M.PARSER_SCRIPTS = { 'companion', 'maui', 'malua' }   -- MALua hosts companion's parse service

local SESSION_WINDOW_MIN_S, SESSION_WINDOW_MAX, SESSION_WINDOW_EXPIRE_MS = 2, 10, 600000
local PREFIX = 'SmartDPS'
local TAKEHOLD_MS = 300000   -- muleassist.mac locks a line 5 min on a mob after "did not take hold"
-- macro verdicts for a cast that never started (range, LoS, mana, stun, silence, target,
-- standing): not the spell's fault, so no per-spell cooldown - instead hold ALL picks briefly
-- and let the macro's combat loop fix position / med before the next attempt
local NOT_STARTED_HOLD_MS = {
    CAST_OUTOFRANGE = 2000, CAST_CANNOTSEE = 2000, CAST_NOTARGET = 1500, CAST_STUNNED = 2000,
    CAST_SILENCED = 2000, CAST_STANDING = 1500, CAST_OUTOFMANA = 5000,
    -- CastWhat's early returns when it will not cast at all: dead, invis with nothing on the hate list,
    -- no line of sight after its move, cannot stand, feigned (healer aggro)
    Dead = 5000, Invis = 3000, NoLOS = 2000, Sitting = 2000, Feigned = 3000,
}
-- per-spell cooldown by verdict when the spell itself was the problem
local VERDICT_CD_MS = {
    SKIPPED = 1500,          -- macro's own screens (HP threshold, recast timer, gem refresh)
    NOMATCH = 10000,         -- name not in the macro's list
    CAST_NOTREADY = 1500, CAST_RECOVER = 1500,
    CAST_IMMUNE = 120000,    -- this mob shrugs it off; per-mob memory is a Phase 2 item
    -- CAST_TAKEHOLD is not a per-spell cooldown: it is a 5 min hold on that mob (holds.lua)
}
local SKIPPED_MAX_CD_MS = 12000
local RANKED_MAX = 2000
-- core/cast.lua keeps the macro's verdict names (Dead, Invis, NoLOS, Sitting, Feigned, CAST_*), so the
-- table above applies as written. The one port-only verdict with a macro meaning: CAST_SKIPPED (a
-- beneficial duration spell the target already has / cannot take), which CastWhat reported as
-- CAST_SUCCESS. Anything else the port adds (CAST_NOT_STARTED, Longmem, NoReagent ...) falls in the
-- "other" bucket (2.5 s), as an unnamed macro verdict did.
local VERDICT_ALIAS = { CAST_SKIPPED = 'CAST_SUCCESS' }

local function Dps() return require('modules.dps') end
local function cfg() return Dps().cfg or {} end
local function cfgInt(key) return tonumber(cfg()[key]) or 0 end
-- the macro's flag lookup: an undeclared (nil) flag counts as on
local function flagOn(v)
    if v == nil then return true end
    return (tonumber(v) or 0) ~= 0
end
local function scriptRunning(name)
    local s = mq.TLO.Lua and mq.TLO.Lua.Script(name)
    return s and s.Status and s.Status() == 'RUNNING'
end

-- engine modules (loaded on the first active Tick)
local Bridge, Feed, History, TTD, Ranker, DpsList, Resist, Holds, Procs, Logger
local hookedFeed = nil   -- the Feed instance our listener is on (Feed.on has no removal)

local function log(fmt, ...)
    if not Logger then Logger = require('necrobrain.logger') end
    return Logger.write(fmt, ...)
end

local st   -- session state; M.reset() replaces it

function M.reset()
    if M.engine and Feed then pcall(Feed.stop) end
    st = {
        nextStep = 0, lastErr = nil, lastErrLog = nil,
        loadAt = nil, loadErrLogged = false,   -- the last engine load attempt; its failure is logged once
        me = '', cls = '', bridge = nil,
        powerUp = false, powerUntil = 0,
        -- auto: score blends damage per mana (low mana) into damage per caster second (high mana); eff / burn
        -- pin one end. A named is always burn.
        lastRank = {}, lastMode = 'auto',
        entries = {},
        -- the macro's per-line lock on each mob (DoT running, recast timer, did-not-take-hold): holds.lua
        holds = nil, lastHoldPrune = 0,
        -- spell -> { set = { [my DoT that blocks it] = true }, n = observations }, learned from "did not take
        -- hold" verdicts (holds.lua); it blocks once n >= Holds.BLOCK_CONFIRM. A property of the spells, so it
        -- outlives zoning.
        stackBlockers = {},
        -- Gift of Mana / Chaotic Power / Chaotic Weakness, read from the song and buff windows each decision
        fx = { gom = { up = false }, power = { up = false }, weakness = { up = false }, ok = true },
        memCache = nil, memAt = -1e9, notMemLogged = {},
        lastZone = '', lastMobId = 0,
        lastPubKey = nil, lastPubAt = 0,
        -- live mode feedback: what the macro did with each published seq, and spells it refused
        publishedBySeq = {}, lastAckSeen = 0, refused = {},
        castHoldUntil = 0, castHoldWhy = nil,
        -- back-to-back SKIPPED on one spell and target: the macro holds that line for longer than we know
        skippedStreak = {},   -- spell -> { targetId, n }
        lastNoPickLog = 0,
        -- in-session per-spawn-ID caster-window tracking: measures the necromancer's own
        -- casting window on a specific mob instance (first CAST_SUCCESS on its ID -> that
        -- ID dead/gone), independent of chat-derived history (which can't disambiguate
        -- same-named mobs and includes pull time).
        idFirstCast = {},    -- mobId -> { at = ms, name = lowercased CleanName, pct0 = HP% at that first pick }
        sessionWindows = {}, -- lowercased mob name -> list of window seconds (newest last, max 10)
        tracked = {},        -- mobId -> { name, lastSeen }
        parserUp = nil, lastParserCheck = 0,
        -- per-mob element resist memory behind ctx.mobResist (live feed outcomes + my history on the
        -- mob), and back-to-back CAST_RESIST verdicts per spell on one target (escalating refusal)
        resistMem = nil,
        resistStreak = {},   -- spell -> { targetId, n }
        condSkipped = {},
    }
    M.st = st
    M.engine, M.active, M.paused, M.busy = nil, false, false, false
end
M.reset()

-- ---------------------------------------------------------------- parser
--- The parse service is up: companion, maui or malua RUNNING. An up answer is kept 5 s as in the source;
--- a down one is asked again every step, so the beat starts on the step after the service does.
function M.parserUp()
    local now = mq.gettime()
    if not st.parserUp or (now - st.lastParserCheck) > M.PARSER_CHECK_MS then
        st.lastParserCheck = now
        local up = false
        for _, n in ipairs(M.PARSER_SCRIPTS) do if scriptRunning(n) then up = true break end end
        if up ~= st.parserUp then
            local first = st.parserUp == nil
            st.parserUp = up
            if M.engine then
                if up then log('parser up - learning')
                elseif first then log('companion/maui/malua is not running - no parser to learn from. Idling until it appears.')
                else log('no companion/maui/malua - idling, no picks') end
            end
        end
    end
    return st.parserUp == true
end

-- ---------------------------------------------------------------- feed -> my running DoTs
-- list entry resist type for a logged spell name (logs carry the rank suffix, the INI may not)
local function resistTypeOf(spell)
    local want = Feed.baseSpell(spell)
    for _, e in ipairs(st.entries) do
        if Feed.baseSpell(e.spell) == want then return e.resistType end
    end
    return nil
end

local function onFeed(ev)
    if not st.holds then return end
    local baseSpell = Feed.baseSpell
    -- one outcome per cast: a landed first tick/hit or a resist that answered my pending cast
    if ev.type == 'landed' or (ev.type == 'resisted' and ev.claimed) then
        local rt = resistTypeOf(ev.spell)
        if rt then st.resistMem:record(ev.target, rt, ev.type == 'resisted', ev.at) end
    end
    if ev.type == 'landed' and ev.amount > 0 then
        for _, e in ipairs(st.entries) do
            if e.isDot and baseSpell(e.spell) == baseSpell(ev.spell) then
                -- refine the per-tick of the hold the macro's verdict made; with none (shadow mode, or a
                -- DoT the macro cast while the bridge was stale) hold it by name from this first tick
                if not st.holds:tick(e.spell, ev.target, ev.amount, ev.at) then
                    st.holds:set(e.spell, nil, ev.target, ev.at + e.durSec * 1000,
                        { dot = true, why = 'DoT running', perTick = ev.amount })
                end
            end
        end
    end
end

local function entryFor(spell)
    for _, e in ipairs(st.entries) do
        if e.spell == spell then return e end
    end
    return nil
end

-- Mirror the timer the macro sets on a line for a mob after a CAST_SUCCESS (CombatCast): 5 min for
-- |once, the DoT's duration for a spell DoT (|spam aside), DPSInterval for everything else - so the next
-- pick is never one it will SKIP. Also anchors the session caster window on the mob's first cast.
local function mirrorSuccess(rec, now)
    local e = entryFor(rec.spell)
    if e and rec.targetId and rec.targetId > 0 then
        local secs
        if e.tag == 'once' then secs = 300
        elseif e.isDot and not e.isAA and e.tag ~= 'spam' then secs = e.durSec
        else secs = cfgInt('DPSInterval') end
        if secs > 0 then
            st.holds:set(e.spell, rec.targetId, rec.name, now + secs * 1000, {
                dot = e.isDot, why = e.isDot and 'DoT running' or 'macro recast timer',
                dotUntil = e.isDot and (now + e.durSec * 1000) or nil,
            })
        end
    end
    local targetId = rec.targetId
    if targetId and targetId > 0 and st.idFirstCast and not st.idFirstCast[targetId] then
        -- only a live mob starts a window: an ack that lands after the killing blow would otherwise
        -- open a second, bogus window on the corpse for a kill that was already banked
        local tsp = mq.TLO.Spawn(targetId)
        local live = tsp and tsp() and tsp.Type() == 'NPC' and (tonumber(tsp.PctHPs()) or 0) > 0
        local tname = live and tsp.CleanName()
        if tname then
            st.idFirstCast[targetId] = { at = rec.at, name = tostring(tname):lower(), pct0 = rec.pct }
        end
    end
end

-- DoTs ticking on this mob for Demand for Blood's look-ahead, with a per-tick amount for each (the
-- feed's tick, else history's average, else the tooltip base).
local function runningDotsFor(now, mobId, mobName)
    local out = st.holds:running(mobId, mobName, now)
    for _, d in ipairs(out) do
        -- history's average first: the feed's number is a single first tick, and one crit on it would
        -- make the pending damage (and the "my DoTs already cover it" hold) far too big
        local hs = History.spell(st.me, d.spell)
        local e = entryFor(d.spell)
        d.perTick = (hs and hs.avgHit) or d.perTick or (e and e.base) or 0
    end
    return out
end

-- Proc state for the ranking context. Chaotic Power falls back to the chat-line timer only when the
-- TLO read failed; a found effect with no readable duration counts as freshly up.
local function applyProcs(ctx, now)
    local fx = st.fx
    local p = fx.power
    if p.up then
        ctx.powerUp = true
        ctx.powerLeftSec = p.leftSec or (st.powerUntil > now and (st.powerUntil - now) / 1000) or Ranker.POWER.windowSec
    elseif not fx.ok and st.powerUp and now < st.powerUntil then
        ctx.powerUp, ctx.powerLeftSec = true, (st.powerUntil - now) / 1000
    else
        ctx.powerUp, ctx.powerLeftSec = false, 0
    end
    ctx.weaknessUp = fx.weakness.up == true
    ctx.weaknessLeftSec = fx.weakness.up and (fx.weakness.leftSec or 12) or 0
    ctx.gom = fx.gom.up and { up = true, levelCap = fx.gom.levelCap } or nil
    return ctx
end

local function procSummary()
    local fx = st.fx
    local parts = {}
    if fx.gom.up then
        parts[#parts + 1] = string.format('%s%s %.0fs', fx.gom.name or 'Gift of Mana',
            fx.gom.levelCap and string.format(' (cap L%d)', fx.gom.levelCap) or '', fx.gom.leftSec or 0)
    end
    if fx.power.up then parts[#parts + 1] = string.format('Chaotic Power %.0fs', fx.power.leftSec or 0) end
    if fx.weakness.up then parts[#parts + 1] = string.format('Chaotic Weakness %.0fs', fx.weakness.leftSec or 0) end
    if not fx.ok then parts[#parts + 1] = 'proc read failed' end
    return #parts > 0 and table.concat(parts, ', ') or 'no procs'
end

-- Which spell lines are memorized, re-read at most once a second. An unreadable gem list (zoning,
-- a spell set loading) screens nothing rather than holding every line.
local function memorizedNow(now)
    if not st.memCache or (now - st.memAt) >= 1000 then
        local m, known = Procs.memorized(st.entries)
        st.memCache, st.memAt = known and m or {}, now
        for spell, mem in pairs(st.memCache) do
            if mem == false and not st.notMemLogged[spell] then
                st.notMemLogged[spell] = true
                log('\ay%s is not memorized\ax - skipped until it is (the macro never re-mems a DPS line)', spell)
            elseif mem then
                st.notMemLogged[spell] = nil
            end
        end
    end
    return st.memCache
end

-- INI conditions: the macro skips an entry whose DPSCond evaluates false, so the brain must
-- rank only entries the macro would consider: the bot's own evaluator (core.cond: ${...} through
-- mq.parse, anything else native Lua). Skipped ones show in /why.
local function condTrue(cond)
    cond = tostring(cond or 'TRUE')
    local c = cond:upper()
    if c == '' or c == 'TRUE' or c == '1' then return true end
    local ok, r = pcall(Cond.ok, cond)
    return ok and r == true
end
local function castingName()
    local ok, c = pcall(function() return mq.TLO.Me.Casting() end)
    return ok and c and tostring(c) or nil
end

-- Returns the usable entries and a set of their spell names.
local function usableEntries(pct, mobName, mobId)
    local out, usable = {}, {}
    st.condSkipped = {}
    local condSkipped = st.condSkipped
    local now0 = mq.gettime()
    local mem = memorizedNow(now0)
    -- the spell in flight: its lock only starts when the macro acks the cast, and a pick for it
    -- published meanwhile (the ranking moved and came back) would be SKIPPED
    local casting = castingName()
    -- my DoTs on their way onto this mob: the one being cast, and the newest pick the macro has not
    -- acked yet (CastWhat's post-cast processing leaves a gap where Me.Casting is already empty) -
    -- a learned stacking block must hold for them before their own hold exists
    local inflight = {}
    if casting then
        for _, x in ipairs(st.entries) do
            if casting == x.spell or casting == x.rankName then inflight[x.spell] = true end
        end
    end
    local newest = st.publishedBySeq[st.bridge.seq]
    if newest and st.bridge.seq > st.lastAckSeen and newest.targetId == mobId then inflight[newest.spell] = true end
    -- CastWhat only casts a spell whose full cost is <= current mana (Gift of Mana or not; bards are
    -- exempt, as in CastWhat); a pick it cannot afford comes back CAST_NO_RESULT. Mana is paid when a
    -- cast completes, so the spell in flight is already spent unless Gift of Mana covers it.
    -- the macro only reads DPSCond while ConditionsOn and DPSCOn are both on
    local condsOn = flagOn(Config.conditionsOn) and flagOn(cfg().DPSCOn)
    local gomSpent = false
    local curMana = nil
    if st.cls ~= 'BRD' then
        local okM, m = pcall(function() return tonumber(mq.TLO.Me.CurrentMana()) end)
        curMana = okM and m or nil
        if curMana and casting then
            local okS, cm = pcall(function() return tonumber(mq.TLO.Spell(casting).Mana()) end)
            local okL, lvl = pcall(function() return tonumber(mq.TLO.Spell(casting).Level()) end)
            local covered = st.fx.gom.up and (not st.fx.gom.levelCap or (okL and lvl and lvl <= st.fx.gom.levelCap))
            if covered then gomSpent = true end   -- the spell in flight is using the proc up
            if okS and cm and not covered then curMana = curMana - cm end
        end
    end
    for _, e in ipairs(st.entries) do
        local until_ = st.refused[e.spell]
        local hold = st.holds:find(e.spell, mobId, mobName, now0)
        if pct and e.maxPct and pct > e.maxPct and cfgInt('DPSOn') == 1 then
            condSkipped[e.spell] = string.format('mob at %d%%, entry waits for <= %d%%', pct, e.maxPct)
        elseif casting and (casting == e.spell or casting == e.rankName) then
            condSkipped[e.spell] = 'being cast now'
        elseif hold then
            condSkipped[e.spell] = string.format('%s (%.0fs left)', hold.why, (hold['until'] - now0) / 1000)
        elseif mem[e.spell] == false then
            condSkipped[e.spell] = 'not memorized'
        elseif st.holds:blockedBy(st.stackBlockers, e.spell, mobId, mobName, now0) then
            -- one of MY DoTs on this mob blocked it before (another necro's copy never counts)
            condSkipped[e.spell] = string.format('would not take hold under my %s',
                tostring((st.holds:blockedBy(st.stackBlockers, e.spell, mobId, mobName, now0))))
        elseif (function()
                for b in pairs(Holds.confirmedBlockers(st.stackBlockers, e.spell) or {}) do
                    if inflight[b] then return true end
                end
                return false
            end)() then
            condSkipped[e.spell] = 'would not take hold under my DoT being cast now'
        elseif curMana and not e.isAA and (tonumber(e.mana) or 0) > curMana then
            condSkipped[e.spell] = string.format('needs %d mana, have %d', e.mana, curMana)
        elseif until_ and until_ > now0 then
            condSkipped[e.spell] = string.format('macro refused (%s) for %.0fs more', tostring(st.refused[e.spell .. '#why'] or '?'), (until_ - mq.gettime()) / 1000)
        elseif e.isAA and mq.TLO.Me.AltAbilityReady(e.spell)() ~= true then
            -- a 2 h AA picked while on cooldown would eat a refusal hold every few seconds
            condSkipped[e.spell] = 'AA not ready'
        elseif not condsOn or condTrue(e.cond) then
            out[#out + 1] = e
            usable[e.spell] = true
        else condSkipped[e.spell] = 'INI condition false: ' .. tostring(e.cond) end
    end
    return out, usable, gomSpent
end

-- ---------------------------------------------------------------- DPS list
-- Tell dps.lua which lines the brain ranks: its live gate holds only those, every other
-- line (self discs, swarm pets, |util) keeps the macro's own rules.
local function publishRanked()
    local names = {}
    for i, e in ipairs(st.entries) do names[i] = e.spell end
    local set, truncated = Bridge.rankedSet(names, RANKED_MAX)
    if truncated then log('\arranked set over %d chars - later lines follow the legacy DPS rules', RANKED_MAX) end
    if #names == 0 then log('no damage entries - no picks') end
    Dps().smartSet({ ranked = set })
end

local function loadEntries()
    local ini = Config.iniFile
    if not ini or ini == '' then return end
    -- the macro stored the name quoted ("MuleAssist_<server>_<char>.ini"); strip any quotes
    ini = tostring(ini):gsub('^%s*"', ''):gsub('"%s*$', '')
    local list, err, skipped = DpsList.load(mq.configDir .. '/' .. ini)
    if err then log('\ar%s', err) return end
    st.entries = list
    st.memCache = nil
    log('DPS list: %d damage entries from %s', #st.entries, ini)
    if skipped and #skipped > 0 then log('skipped: %s', table.concat(skipped, ', ')) end
    publishRanked()
end

-- The TTD seed for a mob name: this session's caster windows (per spawn ID, banked as full-HP
-- equivalents) blended with history's average, which counts as at most two windows (ttd.lua seedFrom).
local function seedFor(name, hrec)
    return TTD.seedFrom(st.sessionWindows[tostring(name or ''):lower()], hrec)
end

-- ctx.mobResist for one mob: resist memory for the element, seeded with every box's history on
-- that mob for the same spells (casts/resists summed over my list entries of that element).
local function mobResistFor(name, now)
    local hist = History.mobResist(mq.TLO.Zone.ShortName() or '', name)
    return function(rtype)
        local hr, hc = 0, 0
        if hist and rtype then
            for _, e in ipairs(st.entries) do
                local rec = e.resistType == rtype and hist[Feed.baseSpell(e.spell)] or nil
                if rec then hr, hc = hr + rec.resists, hc + rec.casts end
            end
        end
        return st.resistMem:rate(name, rtype, now, hr, hc)
    end
end

-- The whole-list resist fallback gate counts only lines that could land on this mob (dpslist.lua).
local function listResistTypesFor(targetUndead, named, mem, usable, ttdSecs)
    return DpsList.resistTypes(st.entries, {
        targetUndead = targetUndead, named = named, mem = mem, usable = usable, ttdSecs = ttdSecs,
        aaReady = function(spell) return mq.TLO.Me.AltAbilityReady(spell)() == true end,
    })
end

-- ---------------------------------------------------------------- decision
-- A live NPC spawn for id, or nil.
local function liveNpc(id)
    if not id or id <= 0 then return nil end
    local s = mq.TLO.Spawn(id)
    if s and s() and s.Type() == 'NPC' and (tonumber(s.PctHPs()) or 0) > 0 then return s end
    return nil
end

local function decide(now)
    -- The bot's kill target (the macro's MyTargetID). CombatCast returns before its live gate when it is
    -- not a live spawn, so a pick for anything else would be held at the gate.
    local mobId = tonumber(State.myTargetId) or 0
    local sp = liveNpc(mobId)
    if not sp then return nil end
    local name = sp.CleanName() or ''
    local pct = tonumber(sp.PctHPs()) or 0
    st.lastMobId = mobId
    TTD.observe(mobId, name, pct, now)
    local hrec = History.mob(mq.TLO.Zone.ShortName() or '', name)
    local seed = seedFor(name, hrec)
    local seedSrc = (seed and tonumber(seed.avgDur)) and (seed.source or 'history') or 'none'
    local ttdSecs, src = TTD.estimate(mobId, pct, seed)
    local named = sp.Named() == true
    local mode = (st.lastMode == 'burn') and 'burn' or 'eff'
    -- A named is always a burn for the brain (the ranker also drops its TTD / remaining-HP limits);
    -- BurnAllNamed still only governs the macro's own burn abilities.
    if named then mode = 'burn' end
    local manaWeight = (st.lastMode == 'auto' and not named) and Ranker.manaWeight(tonumber(mq.TLO.Me.PctMana())) or nil
    st.fx = Procs.read()
    local usable, usableSet, gomSpent = usableEntries(pct, name, mobId)
    local ctx = {
        ttdSecs = ttdSecs, mode = mode, named = named, manaWeight = manaWeight,
        currentHP = tonumber(mq.TLO.Me.CurrentHPs()) or 0,
        currentMana = tonumber(mq.TLO.Me.CurrentMana()),
        missingHP = math.max(0, (tonumber(mq.TLO.Me.MaxHPs()) or 0) - (tonumber(mq.TLO.Me.CurrentHPs()) or 0)),
        pctHPs = tonumber(mq.TLO.Me.PctHPs()) or 100,
        targetUndead = tostring(sp.Body.Name() or '') == 'Undead',
        remainingHP = (hrec and hrec.maxHP) and hrec.maxHP * pct / 100 or nil,
        spellStats = function(s) return History.spell(st.me, s) end,
        mobResist = mobResistFor(name, now),
        listResistTypes = listResistTypesFor(tostring(sp.Body.Name() or '') == 'Undead', named, memorizedNow(now), usableSet,
            (not named) and ttdSecs or nil),
        runningDots = runningDotsFor(now, mobId, name),
        stackBlocked = function(spell) return Holds.confirmedBlockers(st.stackBlockers, spell) end,
    }
    applyProcs(ctx, now)
    if gomSpent then ctx.gom = nil end   -- the cast in flight is spending Gift of Mana
    local lastRank = Ranker.rank(usable, ctx)
    st.lastRank = lastRank
    lastRank._ttd, lastRank._src, lastRank._pct, lastRank._mob = ttdSecs, src, pct, name
    lastRank._seed = seedSrc
    -- the label says what ordered the list: auto (mana-weighted), eff or burn
    local label = (manaWeight ~= nil) and 'auto' or mode
    lastRank._mode, lastRank._mw = label, manaWeight
    local top = lastRank[1]
    if not top then return nil end
    return { spellName = top.entry.spell, targetId = mobId, mode = label }
end

-- ---------------------------------------------------------------- engine load
local function openHistoryDb()
    -- Same load path as companion/db.lua: try the plain require first, and if the
    -- module isn't preloaded yet, pull it via mq.PackageMan and retry. No history is read here:
    -- History.open restores the last snapshot and the step folds fights in one small,
    -- time-budgeted batch per tick (companion.db is 1.4 GB on a spinning disk - see history.lua).
    local okS, sqlite = pcall(require, 'lsqlite3')
    if not okS or not sqlite then
        local pmOk, PackageMan = pcall(require, 'mq.PackageMan')
        if pmOk and PackageMan then
            local okR, s = pcall(PackageMan.Require, 'lsqlite3')
            sqlite = okR and s or nil
            okS = sqlite ~= nil
        end
    end
    if okS and sqlite then
        local path = mq.configDir .. '/companion.db'
        -- the opener stays with History: a database missing at load (companion not run yet) is retried
        -- every minute and on /necrobrain backfill
        local function openDb() return sqlite.open(path, sqlite.OPEN_READONLY) end
        local h = openDb()
        History.attach(h, openDb)
        if h then log('history: %s', path)
        else log('\arcould not open %s read-only - no history for now (retried every minute).', path) end
    else
        log('\arlsqlite3 unavailable - no history.')
    end
end

local function loadEngine()
    Logger = require('necrobrain.logger')
    Bridge = require('necrobrain.bridge')
    Feed = require('necrobrain.feed')
    History = require('necrobrain.history')
    TTD = require('necrobrain.ttd')
    Ranker = require('necrobrain.ranker')
    DpsList = require('necrobrain.dpslist')
    Resist = require('necrobrain.resist')
    Holds = require('necrobrain.holds')
    Procs = require('necrobrain.procs')
    st.me = mq.TLO.Me.CleanName() or ''
    st.cls = mq.TLO.Me.Class.ShortName() or ''
    st.bridge = Bridge.newState()
    st.holds = Holds.new()
    st.resistMem = Resist.new()
    st.lastZone = mq.TLO.Zone.ShortName() or ''
    openHistoryDb()
    -- Chaotic Power window: the song/buff windows (procs.lua) are the source; this chat-line timer only
    -- stands in when the TLO read fails.
    mq.event('nb_power_on', 'Quivering power pulses through your hands.#*#', function()
        st.powerUp, st.powerUntil = true, mq.gettime() + 62000
    end)
    mq.event('nb_power_off', 'The power fades away.#*#', function() st.powerUp = false end)
    if hookedFeed ~= Feed then Feed.on(function(ev) onFeed(ev) end) hookedFeed = Feed end
    Feed.start(st.me)
    loadEntries()
    if History.open(mq.TLO.EverQuest.Server() or 'unknown', st.me, st.lastZone) then
        log('history: snapshot restored for %s', st.me)
    else
        log('history: no snapshot yet - learning from fights as they are saved (/necrobrain backfill to read older ones)')
    end
    log('ready in %s mode (%s). /nbmob on a target, /necrobrain why | diag', cfgInt('SmartDPSDebug') == 0 and 'LIVE' or 'SHADOW', st.cls)
    M.engine = true
    Log.info('SmartDPS engine ready (necrobrain in-process, log %s)', tostring(Logger.path()))
end

-- Undo what a failed loadEngine got to: the feed mailbox, the Chaotic Power events and the database handle
-- (History's opener is replaced, so a stale one does not reopen it behind our back).
local function unloadPartial()
    if Feed then pcall(Feed.stop) end
    pcall(mq.unevent, 'nb_power_on')
    pcall(mq.unevent, 'nb_power_off')
    if History and History.handle then
        local db = History.handle()
        if db then pcall(db.close, db) end
        pcall(History.attach, nil, function() return nil end)
    end
end

--- Load the engine once; a failure is cleaned up, logged once and retried every LOAD_RETRY_MS.
local function ensureEngine(now)
    if M.engine then return true end
    -- the load registers events and the feed mailbox: never from a tick hook (Cast.inHook), next main-loop pass
    if not Cast.canRegister() then return false end
    -- not in the world yet: loading now would start the feed and the log under an empty name. Retry next step.
    if tostring(mq.TLO.Me.CleanName() or '') == '' then return false end
    if st.loadAt and (now - st.loadAt) < M.LOAD_RETRY_MS then return false end
    st.loadAt = now   -- attempted, before any side effect
    local ok, err = pcall(loadEngine)
    if ok then return true end
    M.engine = nil
    unloadPartial()
    if not st.loadErrLogged then
        st.loadErrLogged = true
        Log.error('SmartDPS: necrobrain engine failed to load: %s - retrying every %d s', tostring(err), math.floor(M.LOAD_RETRY_MS / 1000))
        pcall(log, '\arengine failed to load: %s', tostring(err))
    end
    return false
end

-- ---------------------------------------------------------------- results (dps.lua -> onResult)
-- The macro's verdict on a pick: anything but a successful cast puts that spell on a short cooldown so
-- the next publish is the next-best entry.
local function consume(ack, res, now)
    st.lastAckSeen = ack
    local rec = st.publishedBySeq[ack]
    local live = cfgInt('SmartDPSDebug') == 0
    if rec then
        if res ~= 'SKIPPED' then st.skippedStreak[rec.spell] = nil end
        if res == 'CAST_SUCCESS' or res:sub(1, 12) == 'CAST_SUCCESS' then
            st.resistStreak[rec.spell] = nil
            -- it landed while these DoTs of mine ran on that mob: none of them blocks it
            local names = {}
            for _, d in ipairs(st.holds:running(rec.targetId, rec.name, now)) do names[#names + 1] = d.spell end
            Holds.unlearnBlock(st.stackBlockers, rec.spell, names)
            mirrorSuccess(rec, now)
        elseif res == 'CAST_TAKEHOLD' then
            -- learn which of MY DoTs running on this mob blocks it: only same-line shapes (same
            -- element and duration, like Dread Pyre and Ashengate Pyre) are candidates
            local e = entryFor(rec.spell)
            if e then
                local cands = {}
                for _, d in ipairs(st.holds:running(rec.targetId, rec.name, now)) do
                    local o = entryFor(d.spell)
                    if o and o.resistType == e.resistType and o.durSec == e.durSec then cands[#cands + 1] = d.spell end
                end
                local learned, confirmed = Holds.learnBlock(st.stackBlockers, rec.spell, cands)
                if learned and confirmed then log('%s does not take hold under my %s - skipped while that runs on a mob',
                    rec.spell, table.concat(learned, ' / ')) end
            end
            -- the macro locks this line on this mob for 5 min (a stronger line of the same stack runs)
            st.holds:set(rec.spell, rec.targetId, rec.name, now + TAKEHOLD_MS, { why = 'did not take hold' })
            if live then log('\arrefused\ax %s -> did not take hold (held on this mob %.0fs)', rec.spell, TAKEHOLD_MS / 1000) end
        elseif NOT_STARTED_HOLD_MS[res] then
            st.castHoldUntil, st.castHoldWhy = now + NOT_STARTED_HOLD_MS[res], res
            if live then log('\aymacro hold\ax %s: %s (all picks held %.1fs)', rec.spell, res, NOT_STARTED_HOLD_MS[res] / 1000) end
        elseif res == 'SKIPPED' then
            local okR, recovering = pcall(function() return mq.TLO.Me.SpellInCooldown() end)
            if okR and recovering == true then
                -- the global recovery right after a cast: not this line's fault, wait it out
                st.castHoldUntil, st.castHoldWhy = now + 600, 'global recovery'
            else
                -- the macro screened this line on this mob (its own timer, a condition, a gem
                -- refresh): hold it there, longer each time it happens again back to back
                local sk = st.skippedStreak[rec.spell]
                if not (sk and sk.targetId == rec.targetId) then sk = { targetId = rec.targetId, n = 0 } end
                sk.n = sk.n + 1
                st.skippedStreak[rec.spell] = sk
                local cd = math.min(SKIPPED_MAX_CD_MS, VERDICT_CD_MS.SKIPPED * 2 ^ (sk.n - 1))
                st.holds:set(rec.spell, rec.targetId, rec.name, now + cd, { why = 'macro skipped it' })
                if live then log('\arrefused\ax %s -> SKIPPED (held on this mob %.1fs)', rec.spell, cd / 1000) end
            end
        elseif res ~= 'shadow' and res ~= '' then
            local cd = VERDICT_CD_MS[res] or 2500   -- FIZZLED / Interrupted / unknown
            if res == 'CAST_RESIST' then
                -- the same spell resisted back to back on one target backs off harder each time
                local rs = st.resistStreak[rec.spell]
                if not (rs and rs.targetId == rec.targetId) then rs = { targetId = rec.targetId, n = 0 } end
                rs.n = rs.n + 1
                st.resistStreak[rec.spell] = rs
                cd = Resist.refusalCooldown(rs.n)
            end
            st.refused[rec.spell] = now + cd
            st.refused[rec.spell .. '#why'] = res
            if live then log('\arrefused\ax %s -> %s (cooldown %.1fs)', rec.spell, res, cd / 1000) end
        end
    end
    -- every seq up to the ack is settled (a superseded or retracted pick never gets its own ack)
    for seq in pairs(st.publishedBySeq) do
        if seq <= ack then st.publishedBySeq[seq] = nil end
    end
end

local function logError(err)
    local now = mq.gettime()
    if st.lastErrLog and (now - st.lastErrLog) < M.ERROR_LOG_MS then return end
    st.lastErrLog = now
    local ok = pcall(log, '\arSmartDPS error: %s', tostring(err))
    if not ok then Log.error('SmartDPS error: %s', tostring(err)) end
end

--- dps.lua's verdict on pick `seq`: CAST_* from the cast, SKIPPED, NOMATCH or shadow.
function M.onResult(seq, verdict)
    if not M.engine then return end
    seq = tonumber(seq) or 0
    if seq == st.lastAckSeen then return end
    local res = tostring(verdict or '')
    res = VERDICT_ALIAS[res] or res
    local ok, err = pcall(consume, seq, res, mq.gettime())
    if not ok then logError(err) end
end

-- ---------------------------------------------------------------- the step
-- necrobrain's main loop body. Returns the decide error, if any (the beat is withheld for it too).
local function step(now)
    local D = Dps()
    Feed.tick()

    local zone = mq.TLO.Zone.ShortName() or ''
    if zone ~= st.lastZone then
        st.lastZone = zone
        History.setZone(zone)
        st.holds = Holds.new()
        TTD.reset(st.lastMobId)
        st.idFirstCast = {}
        st.sessionWindows = {}
        st.tracked = {}
        st.resistMem = Resist.new()
        st.resistStreak = {}
        st.skippedStreak = {}
        log('zone -> %s', zone)
    end
    -- history: at most one small, time-budgeted batch of fights per tick (see history.lua)
    History.step(zone, now)

    if (now - st.lastHoldPrune) >= 1000 then
        st.lastHoldPrune = now
        st.holds:prune(now, function(id)
            local s = mq.TLO.Spawn(id)
            return s ~= nil and s() ~= nil and s.Type() ~= 'Corpse'
        end)
    end

    local parserUp = M.parserUp()
    -- (the heartbeat goes out after a clean step, from M:Tick; the macro's verdicts arrive through onResult)
    local casting = castingName()

    -- session caster-window tracking: for every id whose first cast landed this
    -- session, watch for it dying/despawning and bank the elapsed window; expire
    -- stale entries so a mob that wandered off (or the char zoned mid-fight) doesn't
    -- linger forever.
    for id, fc in pairs(st.idFirstCast) do
        local tsp = mq.TLO.Spawn(id)
        local gone = not tsp or not tsp()
        local isCorpse = (not gone) and tsp.Type() and tsp.Type() == 'Corpse'
        local zeroHp = (not gone) and (not isCorpse) and tonumber(tsp.PctHPs()) == 0
        if gone or isCorpse or zeroHp then
            -- the window runs from my first cast, when the mob was at pct0: bank it as the full-HP
            -- time it implies, which is what the seed is scaled by (seed * pct / 100)
            local raw = (now - fc.at) / 1000
            local pct0 = math.min(100, tonumber(fc.pct0) or 100)
            local window = raw * 100 / math.max(1, pct0)
            -- a first cast below 25% says too little about the whole fight to extrapolate from
            if raw >= SESSION_WINDOW_MIN_S and pct0 >= 25 then
                local list = st.sessionWindows[fc.name] or {}
                list[#list + 1] = window
                while #list > SESSION_WINDOW_MAX do table.remove(list, 1) end
                st.sessionWindows[fc.name] = list
                local sum = 0
                for _, wsec in ipairs(list) do sum = sum + wsec end
                log('window: %s %.1fs from %d%% (%.1fs at full HP; session avg %.1fs over %d)', fc.name, raw, pct0,
                    window, sum / #list, #list)
            end
            st.idFirstCast[id] = nil
            st.tracked[id] = nil
        elseif (now - fc.at) > SESSION_WINDOW_EXPIRE_MS then
            st.idFirstCast[id] = nil
            st.tracked[id] = nil
        else
            st.tracked[id] = { name = fc.name, lastSeen = now }
        end
    end

    local action, decideErr
    if parserUp then
        local ok
        ok, action = pcall(decide, now)
        if not ok then
            decideErr = action == nil and 'decide error' or action
            action = nil
        end
    end
    if action and now < st.castHoldUntil then action = nil end
    -- Bridge.next republishes an unchanged pick as soon as the macro acks it,
    -- and this step runs every 200ms - re-sending it every tick spams the
    -- bridge for no reason. Only call it when the pick actually
    -- changed, when it has been more than 3s since the last publish (so a
    -- still-outstanding pick keeps getting republished per Bridge.next's own
    -- ack semantics), or when action is nil (clears the bridge; live retracts an unconsumed pick).
    local key = Bridge.actionKey(action)
    local live = cfgInt('SmartDPSDebug') == 0
    local ackNow = tonumber(D.smart.ack) or 0
    local consumed = ackNow >= st.bridge.seq
    -- While dps.lua is casting one of my unacked picks, publish nothing: a new pick would be taken
    -- in the same pass right after the cast (inside the global recovery, so SKIPPED), and its ack
    -- would overwrite the cast's own verdict before we read it - the hold, the running DoT and the
    -- stacking lesson that verdict carries would be lost. The next pick goes out once it is acked.
    local castingPick = false
    if casting and D.smart.seq ~= D.smart.ack then
        for seq, r in pairs(st.publishedBySeq) do
            if seq > ackNow and (casting == r.spell or casting == (entryFor(r.spell) or {}).rankName) then castingPick = true end
        end
    end
    -- Nor while the global spell recovery after a cast runs: the SpellReady gate would skip
    -- any spell pick right away (SKIPPED), so the pick waits the second or so until it clears.
    local okR, recovering = pcall(function() return mq.TLO.Me.SpellInCooldown() end)
    local waitRecovery = consumed and okR and recovering == true and action ~= nil
        and not (entryFor(action.spellName) or {}).isAA
    if castingPick or waitRecovery then
        -- keep the outstanding pick as it is
    elseif key ~= st.lastPubKey or action == nil or (live and consumed) or (now - st.lastPubAt) >= 3000 then
        local batch = Bridge.next(st.bridge, action, ackNow, PREFIX, live)
        if batch then
            local f = {}
            for _, kv in ipairs(batch) do f[kv[1]:sub(#PREFIX + 1)] = kv[2] end
            D.smartSet({ spell = f.Spell, targetId = tonumber(f.TargetID) or 0, mode = f.Mode, seq = tonumber(f.Seq) })
            st.lastPubKey, st.lastPubAt = key, now
            if action then
                local lastRank = st.lastRank
                st.publishedBySeq[st.bridge.seq] = { spell = action.spellName, targetId = action.targetId, at = now,
                    name = lastRank._mob, pct = lastRank._pct }
                if live then log('pick #%d: %s [%s] ttd %s (%s)', st.bridge.seq, action.spellName, action.mode,
                    lastRank._ttd and string.format('%.0fs', lastRank._ttd) or 'n/a', tostring(lastRank._src)) end
            end
        end
        if action == nil then
            st.lastPubKey = nil
            -- explain an empty pick while a mob is actually up, at most once per 2 s
            local lastRank = st.lastRank
            if live and lastRank._mob and (tonumber(lastRank._pct) or 0) > 1 and (lastRank._ttd or 1) > 1 and (now - (st.lastNoPickLog or 0)) > 2000 then
                st.lastNoPickLog = now
                local why = {}
                for spn, r in pairs(st.condSkipped) do why[#why + 1] = spn .. ': ' .. r end
                for spn, r in pairs(Ranker.excluded()) do why[#why + 1] = spn .. ': ' .. r end
                if now < st.castHoldUntil then why[#why + 1] = string.format('macro hold %s (%.1fs left)', tostring(st.castHoldWhy), (st.castHoldUntil - now) / 1000) end
                log('no pick on %s (hp %s%%, ttd %s %s): %s', tostring(lastRank._mob), tostring(lastRank._pct),
                    lastRank._ttd and string.format('%.0fs', lastRank._ttd) or 'n/a', tostring(lastRank._src),
                    #why > 0 and table.concat(why, '; ') or 'no reasons recorded')
            end
        end
    end
    return decideErr
end

-- ---------------------------------------------------------------- Blade of Vesagran
-- necrobrain/vesagran.lua is the claim mutex for the Blade rotation; its own state machine times the clicks, so it
-- is ticked on every pass; only a participant (Calbuss, Beyonce) initialises it, so other boxes never log or bind.
local V, vesTried = nil, false
-- characters in vesagran's PRIORITY table that run the claim from somewhere else: parsaxx (a bard) runs
-- medley's copy on the same /ves* commands, so a second state machine here would fight it. Any BRD is skipped too.
local VES_SKIP = { parsaxx = true }

local function tickVesagran()
    -- init binds /vesclaim /vesping /vesdel: never from a tick hook (Cast.inHook), next main-loop pass
    if not vesTried and Cast.canRegister() then
        local name = ''
        pcall(function() name = tostring(mq.TLO.Me.CleanName() or '') end)
        if name == '' then return end   -- not in the world yet: try again next pass
        vesTried = true
        local ok, err = pcall(function()
            local mod = require('necrobrain.vesagran')
            -- a non-participant never calls init(): it would log (a file append) on every start of every box
            local lname = name:lower()
            if mod.PRIORITY[lname] == nil or VES_SKIP[lname] then return end
            if tostring(mq.TLO.Me.Class.ShortName() or '') == 'BRD' then return end
            V = mod
            V.init()
            M.vesagranOn = true
        end)
        if not ok then
            if V then pcall(V.shutdown) end   -- init got as far as binding
            V, M.vesagranOn = nil, false
            pcall(Log.error, 'SmartDPS: vesagran failed to start: %s', tostring(err))
        end
    end
    if V then pcall(V.tick) end
end

-- ---------------------------------------------------------------- module hooks
--- Startup (init.lua, after LoadSettings, on the main coroutine): start Vesagran and load the engine now,
--- rather than on the first main-loop pass, which comes after the startup casts and MALua's load.
function M:Boot()
    tickVesagran()
    if (tonumber(cfg().SmartDPSOn) or 0) > 0 and not M.paused and not M.engine then
        local ok, err = pcall(ensureEngine, mq.gettime())
        if not ok then pcall(logError, err) end
    end
end

--- The 200 ms step, from the main loop, dps.lua's per-entry pass and the Cast tick hook. Never throws.
function M:Tick()
    tickVesagran()
    if (tonumber(cfg().SmartDPSOn) or 0) <= 0 or M.paused then M.active = false return end
    if M.busy then return end
    local now = mq.gettime()
    if now < st.nextStep then return end
    st.nextStep = math.max(st.nextStep + M.LOOP_MS, now + M.LOOP_MS)
    M.busy = true
    local okE, up = pcall(ensureEngine, now)   -- an error here must not leave busy set for the session
    if not okE then
        M.busy, M.active = false, false
        pcall(logError, up)
        return
    end
    if not up then M.busy, M.active = false, false return end
    local ok, res = pcall(step, now)
    M.busy = false
    local err = res   -- the step's error, or the decide error it returned (nil when clean)
    if not ok and err == nil then err = 'step error' end
    if err ~= nil then
        st.lastErr = err
        logError(err)
    else
        st.lastErr = nil
        if st.parserUp then
            Bridge.heartbeat(st.bridge, PREFIX)
            Dps().smartSet({ beat = st.bridge.beat })
        end
    end
    M.active = M.engine == true
end

function M:LoadSettings()
    Cast.addTickHook('smartdps', function() M:Tick() end)
    if M.engine then
        local ok, err = pcall(loadEntries)
        if not ok then logError(err) end
    end
end

function M:Shutdown()
    Cast.removeTickHook('smartdps')
    M.active = false
    if V then pcall(V.shutdown) end
    V, vesTried, M.vesagranOn = nil, false, false
    if not M.engine then return end
    pcall(Feed.stop)
    pcall(History.close)   -- saves the snapshot
    pcall(mq.unevent, 'nb_power_on')
    pcall(mq.unevent, 'nb_power_off')
    local db = History.handle()
    if db then pcall(db.close, db) end
    M.engine = nil
end

-- ---------------------------------------------------------------- commands
local USAGE = 'commands: mob, why, diag, mode auto|eff|burn, backfill [steps], console on|off, reload, stop, start'

local function mobCard()
    -- Strategy card for the CURRENT TARGET, in or out of combat: what history knows
    -- about it and how the ranker would order the list at its current HP.
    local sp = mq.TLO.Target
    if not sp or not sp() or sp.Type() ~= 'NPC' then log('target an NPC first') return end
    local name, pct = sp.CleanName() or '', tonumber(sp.PctHPs()) or 100
    local zone = mq.TLO.Zone.ShortName() or ''
    local hrec = History.mob(zone, name)
    if hrec then
        log('%s (%s): %d fights, avg %.0fs, last %.0fs, max HP %s (weight %.0f)', name, zone, hrec.fights,
            hrec.avgDur or 0, hrec.lastDur or 0, hrec.maxHP and string.format('%.0f', hrec.maxHP) or 'unknown', hrec.hpWeight or 0)
    else
        log('%s (%s): no history yet', name, zone)
    end
    local sessList = st.sessionWindows[tostring(name):lower()]
    if sessList and #sessList > 0 then
        local sum = 0
        for _, wsec in ipairs(sessList) do sum = sum + wsec end
        local seed = seedFor(name, hrec)
        log('  this session: %d kills, avg %.1fs (100%%-equivalent), last %.1fs; seed used %.1fs (%s)', #sessList,
            sum / #sessList, sessList[#sessList], seed and seed.avgDur or 0, seed and seed.source or 'n/a')
    end
    local ttdSecs, src = TTD.estimate(tonumber(sp.ID()) or 0, pct, seedFor(name, hrec))
    local named = sp.Named() == true
    st.fx = Procs.read()
    log('  ttd at %d%%: %s (%s)  undead=%s  named=%s  procs: %s', pct,
        ttdSecs and string.format('%.0fs', ttdSecs) or 'n/a', src,
        tostring(tostring(sp.Body.Name() or '') == 'Undead'), tostring(named), procSummary())
    for _, e in ipairs(st.entries) do
        local hs = History.spell(st.me, e.spell)
        if hs and hs.casts and hs.casts > 0 then
            log('  %-28s %5d casts  resist %4.1f%%  avg %s', e.spell, hs.casts, (hs.resistRate or 0) * 100,
                hs.avgHit and string.format('%.0f', hs.avgHit) or '-')
        end
    end
    local mr, seenRt = mobResistFor(name, mq.gettime()), {}
    for _, e in ipairs(st.entries) do
        local rt = e.resistType
        if rt and not seenRt[rt] then
            seenRt[rt] = true
            local rate = mr(rt)
            if rate then log('  %s resist %.0f%%', rt, rate * 100) end
        end
    end
    -- a named ranks the way decide() ranks it: burn only, no TTD / remaining-HP limit, namedOnly AAs offered
    local pctMana = tonumber(mq.TLO.Me.PctMana())
    for _, mode in ipairs(named and { 'burn' } or { 'auto', 'eff', 'burn' }) do
        local nbUsable, nbSet, nbGomSpent = usableEntries(pct, name, tonumber(sp.ID()) or 0)
        local ctx = {
            ttdSecs = ttdSecs, mode = (mode == 'auto') and 'eff' or mode, named = named,
            manaWeight = (mode == 'auto') and Ranker.manaWeight(pctMana) or nil,
            currentHP = tonumber(mq.TLO.Me.CurrentHPs()) or 0,
            currentMana = tonumber(mq.TLO.Me.CurrentMana()),
            missingHP = math.max(0, (tonumber(mq.TLO.Me.MaxHPs()) or 0) - (tonumber(mq.TLO.Me.CurrentHPs()) or 0)),
            pctHPs = tonumber(mq.TLO.Me.PctHPs()) or 100,
            targetUndead = tostring(sp.Body.Name() or '') == 'Undead',
            remainingHP = (hrec and hrec.maxHP) and hrec.maxHP * pct / 100 or nil,
            spellStats = function(s) return History.spell(st.me, s) end,
            mobResist = mobResistFor(name, mq.gettime()),
            listResistTypes = listResistTypesFor(tostring(sp.Body.Name() or '') == 'Undead', named, memorizedNow(mq.gettime()), nbSet,
                (not named) and ttdSecs or nil),
            runningDots = runningDotsFor(mq.gettime(), tonumber(sp.ID()) or 0, name),
        }
        ctx.stackBlocked = function(spell) return Holds.confirmedBlockers(st.stackBlockers, spell) end
        applyProcs(ctx, mq.gettime())
        if nbGomSpent then ctx.gom = nil end
        local rk = Ranker.rank(nbUsable, ctx)
        local names = {}
        for i, r in ipairs(rk) do names[i] = r.entry.spell end
        log('  %s order: %s', mode == 'auto' and string.format('auto (mana %d%%)', pctMana or 0) or mode,
            #names > 0 and table.concat(names, ' > ') or 'nothing castable')
    end
end

local consoleOn = false   -- /necrobrain console on|off: engine log lines on the console between commands
local function necrobrainCmd(self, cmd, arg)
        cmd = tostring(cmd or ''):lower()
        if cmd == 'stop' then
            M.paused, M.active = true, false
            Log.info('SmartDPS: necrobrain paused for this session (no picks, no beat) - /necrobrain start resumes')
            return
        elseif cmd == 'start' then
            M.paused = false
            Log.info('SmartDPS: necrobrain resumed%s', (tonumber(cfg().SmartDPSOn) or 0) > 0 and '' or ' (SmartDPSOn is 0: it waits for it)')
            return
        elseif cmd == 'mode' then
            arg = tostring(arg or ''):lower()
            if arg == 'auto' or arg == 'eff' or arg == 'burn' then st.lastMode = arg; log('mode %s', arg)
            else log('usage: /necrobrain mode auto|eff|burn') end
            return
        end
        if not M.engine then
            Log.info('SmartDPS: necrobrain is not running (SmartDPSOn %d) - it starts with SmartDPSOn=1', cfgInt('SmartDPSOn'))
            return
        end
        if cmd == 'console' then
            arg = tostring(arg or ''):lower()
            if arg == 'on' or arg == 'off' then
                consoleOn = (arg == 'on')
                log('console logging %s; file: %s', arg, Logger.path())
            else
                log('usage: /necrobrain console on|off (file logging always enabled)')
            end
        elseif cmd == 'why' then
            local lastRank = st.lastRank
            log('mob %s hp %s%% ttd %s (%s) (seed: %s) | %s | mode %s%s', tostring(lastRank._mob), tostring(lastRank._pct),
                tostring(lastRank._ttd and string.format('%.0fs', lastRank._ttd) or 'n/a'), tostring(lastRank._src),
                tostring(lastRank._seed or 'n/a'), procSummary(), tostring(lastRank._mode or st.lastMode),
                lastRank._mw and string.format(' (mana weight %.2f: 0 orders like burn, 1 like eff)', lastRank._mw) or '')
            for i, r in ipairs(lastRank) do log('  %d. %s', i, Ranker.explain(r)) end
            for spell, why in pairs(Ranker.excluded()) do log('  - %s: %s', spell, why) end
            for spell, why in pairs(st.condSkipped) do log('  - %s: %s', spell, why) end
        elseif cmd == 'diag' then
            local d = Feed.diag()
            local nref = 0
            for k, v in pairs(st.refused) do if not k:find('#why', 1, true) and v > mq.gettime() then nref = nref + 1 end end
            log('mode=%s refused-now=%d parser=%s%s', cfgInt('SmartDPSDebug') == 0 and 'LIVE' or 'shadow', nref,
                st.parserUp and 'up' or 'down', M.paused and ' (paused)' or '')
            log('feed casts=%d landed=%d resisted=%d expired=%d damage=%d dropped=%d; entries=%d; seq=%d ack=%d',
                d.casts, d.landed, d.resisted, d.expired, d.damage, d.dropped, #st.entries, st.bridge.seq, tonumber(Dps().smart.ack) or 0)
            local hs = History.status()
            for _, wk in ipairs(hs.walkers) do
                log('history %s (%s): %d fights, ids %s-%s, %d ms this session%s%s', wk.name, tostring(hs.zone), wk.loaded,
                    tostring(wk.oldest), tostring(wk.newest), wk.spentMs or 0,
                    wk.done and ', all read' or (wk.paused and (', paused: ' .. wk.paused) or ', walking'),
                    hs.forceLeft > 0 and string.format(' (forced, %d steps left)', hs.forceLeft) or '')
            end
        elseif cmd == 'mob' then mobCard()
        elseif cmd == 'reload' then loadEntries()
        elseif cmd == 'backfill' then
            -- read older history without the per-tick time budget: stutters until it reports done
            History.force(tonumber(arg) or 400)
        else log(USAGE) end
end

M.Binds = {
    -- a typed command answers on the console as well as in the log file (the logger's console is opt-in)
    ['/necrobrain'] = function(self, cmd, arg)
        if not Logger then pcall(function() Logger = require('necrobrain.logger') end) end
        if Logger then pcall(Logger.setConsole, true) end
        local ok, err = pcall(necrobrainCmd, self, cmd, arg)
        if Logger then pcall(Logger.setConsole, consoleOn) end
        if not ok then Log.error('SmartDPS: /necrobrain %s failed: %s', tostring(cmd), tostring(err)) end
    end,
    -- Short bind for the strategy card: target a mob, type /nbmob.
    ['/nbmob'] = function(self) M.Binds['/necrobrain'](M, 'mob') end,
}

return M
