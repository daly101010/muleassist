-- necrobrain/ranker.lua — pure scoring of the necro's DPS entries for ONE mob at
-- ONE moment. Efficiency mode: expected damage per mana inside the mob's remaining
-- life. Burn mode: expected damage per second of caster time. Pure (no mq).
local M = {}
M.DEFAULT_LAND = 0.85
M.AVOID_RESIST = 0.50
M.TICK_SEC = 6
-- Mana-aware scoring. In auto mode init passes ctx.manaWeight a (0..1) from the caster's mana and the
-- score is damage / (a x mana + (1 - a) x MANA_PER_SEC x seconds): a = 1 is damage per mana
-- (efficiency), a = 0 orders like burn (damage per caster second). MANA_PER_SEC, the necro's own mana
-- spend while chain-casting its list, puts both costs on one scale.
M.MANA_BURN_PCT = 80     -- at or above: mana is not binding, burn ordering
M.MANA_EFF_PCT = 35      -- at or below: every point of mana counts, efficiency ordering
M.MANA_PER_SEC = 150
-- On trash the whole-list resist fallback only feeds spells that still land 30% of the time; on a named
-- any land chance beats idling.
M.FALLBACK_TRASH_MAX_RATE = 0.70

function M.manaWeight(pctMana)
    local p = tonumber(pctMana)
    if not p then return nil end
    local w = (M.MANA_BURN_PCT - p) / (M.MANA_BURN_PCT - M.MANA_EFF_PCT)
    if w < 0 then return 0 end
    if w > 1 then return 1 end
    return w
end
-- A DoT that lands a single tick costs 900-1400 mana for less than a nuke does for 660; it is
-- never the right buy, and offering it lets the brain fill a 1.5 s nuke cooldown with it.
M.MIN_DOT_TICKS = 2
-- Demand for Blood's recourse: 25% Chaotic Power II (DoT damage +1..100% for 60 s), 1% Chaotic
-- Weakness (DoT damage -0..50% for 12 s); both are limited to detrimental spells up to L75 lasting
-- 24 s or more, so they touch DoTs only. tickUplift is the realized per-tick gain while Power is up
-- (observed +38..47%): it is credited to any DoT tick landing inside the remaining window (Power is a
-- self buff, so it carries to the next mob) and it prices a DfB cast's proc. The proc needs DfB to land.
M.POWER = { chance = 0.25, windowSec = 60, tickUplift = 0.42 }
M.WEAKNESS = { tickPenalty = 0.25 }

-- Lifetap self-heal value: weight 0 at or above HEAL_FULL_PCT caster HP, rising to 1 at
-- HEAL_MAX_PCT and below; the heal itself is capped at the HP actually missing.
M.HEAL_FULL_PCT = 90
M.HEAL_MAX_PCT = 50

function M.healWeight(pctHPs)
    local p = tonumber(pctHPs)
    if not p then return 0 end
    local w = (M.HEAL_FULL_PCT - p) / (M.HEAL_FULL_PCT - M.HEAL_MAX_PCT)
    if w < 0 then return 0 end
    if w > 1 then return 1 end
    return w
end

local function healValue(e, ctx, units, land)
    local stats = ctx.spellStats and ctx.spellStats(e.spell) or nil
    local avg = stats and tonumber(stats.avgHeal)
    local missing = tonumber(ctx.missingHP) or 0
    if not avg or avg <= 0 or missing <= 0 then return 0 end
    local w = M.healWeight(ctx.pctHPs)
    if w <= 0 then return 0 end
    return math.min(avg * units * land, missing) * w
end

local function expectedDamage(e, ctx, land)
    local stats = ctx.spellStats and ctx.spellStats(e.spell) or nil
    local perUnit = (stats and stats.avgHit and stats.avgHit > 0) and stats.avgHit or e.base
    -- health-transfer abilities (Life Burn) deal a fraction of the caster's CURRENT HP:
    -- history averages describe a different HP pool, so the live reading wins outright
    if e.hpFraction then perUnit = (tonumber(ctx.currentHP) or 0) * e.hpFraction end
    local ttd = ctx.ttdSecs
    if e.isDot then
        local avail = ttd and math.max(0, ttd - e.castSec) or e.durSec
        local ticks = math.min(math.floor(avail / M.TICK_SEC), math.floor(e.durSec / M.TICK_SEC))
        -- tick k lands at castSec + k*TICK_SEC; those inside the Chaotic Power window run hotter,
        -- those inside the Chaotic Weakness window run cooler
        local boosted, weakened = 0, 0
        local left = ctx.powerUp and tonumber(ctx.powerLeftSec) or 0
        local wleft = ctx.weaknessUp and tonumber(ctx.weaknessLeftSec) or 0
        for k = 1, ticks do
            local at = e.castSec + k * M.TICK_SEC
            if at <= left then boosted = boosted + 1 end
            if at <= wleft then weakened = weakened + 1 end
        end
        local units = ticks + boosted * M.POWER.tickUplift - weakened * M.WEAKNESS.tickPenalty
        return perUnit * land * units, ticks, boosted, weakened
    end
    return perUnit * land, 1, 0, 0
end

local function landFor(e, ctx)
    if e.resistType == 'unresistable' then return 1, nil end
    local rate = ctx.mobResist and ctx.mobResist(e.resistType) or nil
    return rate and (1 - rate) or M.DEFAULT_LAND, rate
end

local function perTickOf(d, ctx)
    local stats = ctx.spellStats and ctx.spellStats(d.spell) or nil
    return (stats and stats.avgHit and stats.avgHit > 0) and stats.avgHit or d.base or 0
end

-- Demand for Blood as a lottery ahead of a DoT cycle: if it lands, 25% chance that every DoT tick in
-- the next 60 s (or the mob's remaining life) runs hotter. Value = chance x land x uplift x the DoT
-- damage expected in that window: the ticks the DoTs already on the mob have left (ctx.runningDots),
-- plus the DoTs the necro would cast next (the usable, not-running DoTs in pool), best first, one
-- after another, each only while it still fits MIN_DOT_TICKS. A legacy ctx.runningDotDpsPerTick (no
-- runningDots) counts as running for the whole window.
local function synergyBonus(e, ctx, land, pool, sumCap)
    if e.synergy ~= 'power' or ctx.powerUp then return 0 end
    local horizon = M.POWER.windowSec
    if ctx.ttdSecs then horizon = math.min(horizon, math.max(0, ctx.ttdSecs - e.castSec)) end
    local maxTicks = math.floor(horizon / M.TICK_SEC)
    if maxTicks <= 0 then return 0 end
    local sum, running = 0, {}
    if ctx.runningDots then
        for _, d in ipairs(ctx.runningDots) do
            running[d.spell] = true
            local left = math.max(0, (tonumber(d.leftSec) or 0) - e.castSec)
            sum = sum + (tonumber(d.perTick) or 0) * math.min(maxTicks, math.floor(left / M.TICK_SEC))
        end
    else
        sum = (tonumber(ctx.runningDotDpsPerTick) or 0) * maxTicks
    end
    local upcoming = {}
    for _, d in ipairs(pool or {}) do
        -- a DoT a running DoT of mine would stop from taking hold (learned stacking) adds nothing
        local stopped = false
        local blockers = ctx.stackBlocked and ctx.stackBlocked(d.spell) or nil
        for b in pairs(blockers or {}) do if running[b] then stopped = true end end
        if d.isDot and d ~= e and not running[d.spell] and not stopped then
            local dland, rate = landFor(d, ctx)
            if not (rate and rate >= M.AVOID_RESIST) then
                upcoming[#upcoming + 1] = { d = d, per = perTickOf(d, ctx) * dland }
            end
        end
    end
    table.sort(upcoming, function(a, b)
        if a.per ~= b.per then return a.per > b.per end
        return (a.d.index or 0) < (b.d.index or 0)
    end)
    local offset, counted = 0, {}
    for _, u in ipairs(upcoming) do
        local d = u.d
        local fit = math.floor(math.max(0, horizon - offset - d.castSec) / M.TICK_SEC)
        local ticks = math.min(math.floor(d.durSec / M.TICK_SEC), fit)
        -- nor does one an earlier DoT of this cycle would stop (Dread Pyre after Ashengate Pyre)
        local stopped = false
        local blockers = ctx.stackBlocked and ctx.stackBlocked(d.spell) or nil
        for b in pairs(blockers or {}) do if counted[b] then stopped = true end end
        if ticks >= M.MIN_DOT_TICKS and not stopped then
            sum = sum + u.per * ticks
            offset = offset + d.castSec + (d.recastSec or 1.5)
            counted[d.spell] = true
        end
    end
    -- on a mob close to death the DoT damage the proc could boost is bounded by the HP it has left
    if sumCap then sum = math.min(sum, math.max(0, sumCap)) end
    return M.POWER.chance * land * M.POWER.tickUplift * sum
end

-- Score one entry at a land chance from rate (nil = default). Returns the ranked record, or nil
-- and the exclusion reason (tick floor, HP left). pool: the usable entries (DfB's look-ahead).
-- rem: the mob's HP left after my running DoTs finish their ticks (nil = unknown).
local function scoreEntry(e, ctx, rate, pool, rem, remRaw)
    local land = rate and (1 - rate) or M.DEFAULT_LAND
    if e.resistType == 'unresistable' then land = 1 end
    local exp, units, boosted, weakened = expectedDamage(e, ctx, land)
    if e.isDot and units < M.MIN_DOT_TICKS then
        return nil, string.format('only %d tick%s would land (need %d)', units, units == 1 and '' or 's', M.MIN_DOT_TICKS)
    end
    -- Damage past the mob's remaining HP is worth nothing, for a nuke and a DoT alike (a DoT was once
    -- credited 7 ticks on a mob with one tick of HP left while the nuke that would finish it was
    -- excluded as overkill). Every entry keeps the same time unit (caster seconds); a capped DoT that
    -- a nuke can beat to the kill is dropped in rank().
    local sec = e.castSec + (e.recastSec or 1.5)
    local capped, need = false, nil
    if rem then
        if rem <= 0 then
            -- my running DoTs already cover the HP it has left: only a lifetap's heal is still worth a cast
            exp, capped, need = 0, true, 0
        elseif exp > rem then
            if e.isDot and units > 0 then need = math.ceil(rem / (exp / units)) end
            exp, capped = rem, true
        end
    end
    -- the cap and the tick floor judge damage only; the self-heal value is added after them
    local heal = healValue(e, ctx, need and math.max(1, math.min(units, need)) or units, land)
    if rem and rem <= 0 and heal <= 0 then return nil, 'my running DoTs already cover the HP it has left' end
    -- the DoT damage the lottery can boost on this mob is bounded by the HP left after DfB's own hit
    -- (the raw HP: my running DoTs' ticks are part of what it boosts)
    local synergy = synergyBonus(e, ctx, land, pool, remRaw and (remRaw - exp) or nil)
    exp = exp + heal + synergy
    local score
    local a = tonumber(ctx.manaWeight)
    if ctx.mode == 'burn' then
        score = exp / sec
    elseif a then
        a = math.max(0, math.min(1, a))
        score = exp / math.max(1, a * (e.mana or 0) + (1 - a) * M.MANA_PER_SEC * sec)
    else
        score = exp / math.max(1, e.mana)
    end
    local tickNote = ''
    if boosted > 0 then tickNote = tickNote .. ' (' .. boosted .. ' under Power)' end
    if weakened > 0 then tickNote = tickNote .. ' (' .. weakened .. ' under Weakness)' end
    return { entry = e, score = score, expected = exp, land = land, heal = heal, synergy = synergy, capped = capped,
        oneTick = need ~= nil and need < M.MIN_DOT_TICKS,
        reason = string.format('%s: exp %.0f land %.2f %s%s%s -> %.2f', e.spell, exp, land,
            e.isDot and ((need and (need .. ' of ' .. units) or units) .. ' ticks' .. tickNote) or 'hit',
            heal > 0 and string.format(' heal %.0f', heal) or '',
            synergy > 0 and string.format(' power lottery %.0f', synergy) or '', score)
            .. (capped and string.format(' [capped at %.0f hp left]', rem) or '') }
end

-- Gift of Mana makes the next spell free: any spell with a mana cost at or under the proc's level cap.
-- muleassist's CastWhat still refuses a spell whose full cost exceeds current mana (it checks
-- Spell.Mana, not the proc), so with ctx.currentMana known only spells the necro could pay for count.
local function gomEligible(e, ctx)
    local g = ctx.gom
    if not (g and g.up) or e.isAA or (tonumber(e.mana) or 0) <= 0 then return false end
    local cm = tonumber(ctx.currentMana)
    if cm and e.mana > cm then return false end
    local cap = tonumber(g.levelCap)
    return not cap or (tonumber(e.level) or 0) <= cap
end
M.gomEligible = gomEligible

-- Ordering tier from the Chaotic procs (lower sorts first): under Chaotic Weakness direct damage goes
-- ahead of new DoT casts; under Chaotic Power DoTs go ahead of nukes, except a lifetap that is healing
-- a hurt caster. Weakness wins when both are up (12 s against 60 s). Returns the tier and a /why note.
local function chaosTier(r, ctx)
    -- a fallback pick (the mob resists the whole list) is ordered by score alone: land chance rules there
    if r.fallback then return 0, nil end
    if ctx.weaknessUp then
        if r.entry.isDot then return 1, 'Chaotic Weakness: nukes first' end
        return 0, nil
    end
    if ctx.powerUp then
        -- a capped DoT is a finisher, not a Power DoT: the boost has no HP left to work on
        if (r.entry.isDot and not r.capped) or (r.heal or 0) > 0 then return 0, nil end
        return 1, 'Chaotic Power: DoTs first'
    end
    return 0, nil
end

-- True when every resist type on the necro's whole DPS list (ctx.listResistTypes) is avoided on this
-- mob, i.e. nothing on the list lands - the only case where the fallback may feed resisted spells.
-- An unresistable line or an element with no resist evidence means something still lands: hold
-- until it is usable (its DoT runs out, its condition comes true) rather than cast into resists.
-- Callers that pass no list keep the old behavior (only the entries handed in count).
local function wholeListResisted(ctx)
    local types = ctx.listResistTypes
    if not types then return true end
    for _, t in ipairs(types) do
        if t == 'unresistable' then return false end
        local rate = ctx.mobResist and ctx.mobResist(t) or nil
        if not rate or rate < M.AVOID_RESIST then return false end
    end
    return true
end

function M.rank(entries, ctx)
    M._lastExcluded = {}
    -- Named: never hold back. Time-to-death and remaining-HP limits are trash-mob economics
    -- (and TTD on a named is a guess against a huge HP pool) - drop them and score by caster
    -- time (burn) so every DoT and nuke stays on the table.
    if ctx.named then
        local c = {}
        for k, v in pairs(ctx) do c[k] = v end
        c.ttdSecs, c.remainingHP, c.mode = nil, nil, 'burn'
        ctx = c
    end
    -- HP the mob has left once my running DoTs have ticked out (they need no new cast); nil = unknown
    local remRaw = tonumber(ctx.remainingHP)
    local rem = remRaw
    if rem then
        local pending = 0
        local ttdTicks = ctx.ttdSecs and math.floor(ctx.ttdSecs / M.TICK_SEC) or nil
        for _, d in ipairs(ctx.runningDots or {}) do
            local ticks = math.floor((tonumber(d.leftSec) or 0) / M.TICK_SEC)
            if ttdTicks then ticks = math.min(ticks, ttdTicks) end
            pending = pending + (tonumber(d.perTick) or 0) * ticks
        end
        rem = math.max(0, rem - pending)
    end
    local out = {}
    local resistHeld = {}   -- { e, rate } avoided only for resists: the fallback pool
    for _, e in ipairs(entries) do
        local reason
        if e.undeadOnly and not ctx.targetUndead then
            reason = 'target not undead'
        elseif e.namedOnly and not ctx.named then
            reason = string.format('named only (%.0f min reuse)', (e.reuseSec or 0) / 60)
        elseif e.hpFraction and (tonumber(ctx.currentHP) or 0) <= 0 then
            reason = 'no current HP reading'
        elseif e.synergy == 'power' and ctx.powerUp then
            reason = 'Chaotic Power already up'
        elseif ctx.ttdSecs and ctx.ttdSecs < e.castSec + 1 then
            reason = string.format('ttd %.0fs < cast %.0fs', ctx.ttdSecs, e.castSec)
        end
        local rate = ctx.mobResist and ctx.mobResist(e.resistType) or nil
        if not reason and rate and rate >= M.AVOID_RESIST then
            reason = string.format('%s resisted %.0f%%', e.resistType, rate * 100)
            resistHeld[#resistHeld + 1] = { e = e, rate = rate }
        end
        if not reason then
            local res, why = scoreEntry(e, ctx, rate, entries, rem, remRaw)
            if res then out[#out + 1] = res else reason = why end
        end
        if reason then
            -- excluded entries are not returned, but keep the reason for /necrobrain why
            M._lastExcluded = M._lastExcluded or {}
            M._lastExcluded[e.spell] = reason
        end
    end
    -- Everything castable is on an element this mob resists AND so is everything else on the list
    -- (a boss that eats the whole list): rank those at their observed land chance rather than leave
    -- the fight idle. If another listed element still lands, hold for it instead.
    if #out == 0 and wholeListResisted(ctx) then
        for _, h in ipairs(resistHeld) do
            if not ctx.named and h.rate > M.FALLBACK_TRASH_MAX_RATE then
                M._lastExcluded[h.e.spell] = string.format('%s resisted %.0f%% (on trash the fallback needs <= %.0f%%)',
                    h.e.resistType, h.rate * 100, M.FALLBACK_TRASH_MAX_RATE * 100)
            else
                local res, why = scoreEntry(h.e, ctx, h.rate, entries, rem, remRaw)
                if res then
                    res.fallback = true
                    res.reason = res.reason .. ' [whole list resisted]'
                    out[#out + 1] = res
                    M._lastExcluded[h.e.spell] = nil
                else
                    M._lastExcluded[h.e.spell] = why
                end
            end
        end
    end
    -- A nuke that finishes the mob beats a DoT that would take ticks to: drop the capped DoTs then. With no
    -- such nuke a capped DoT stays, even a one-tick finisher: something has to finish the mob.
    local nukeFinishes = false
    for _, r in ipairs(out) do if r.capped and not r.entry.isDot then nukeFinishes = true end end
    if nukeFinishes then
        local kept = {}
        for _, r in ipairs(out) do
            if r.capped and r.entry.isDot then
                M._lastExcluded[r.entry.spell] = 'a nuke finishes the mob sooner'
            else
                kept[#kept + 1] = r
            end
        end
        out = kept
    end
    -- Order: the Chaotic tier first; within it a live Gift of Mana goes to the most expensive eligible
    -- spell (every ranked entry already passed the refusal, resist and TTD screens); then score.
    for _, r in ipairs(out) do
        local note
        r.tier, note = chaosTier(r, ctx)
        -- Gift of Mana is not spent on a capped finisher or on a fallback pick at a poor land chance
        r.gom = gomEligible(r.entry, ctx) and not r.capped and not r.fallback
        if r.gom then r.reason = r.reason .. string.format(' [Gift of Mana: saves %d]', r.entry.mana) end
        if note then r.reason = r.reason .. ' [' .. note .. ']' end
    end
    table.sort(out, function(a, b)
        if a.tier ~= b.tier then return a.tier < b.tier end
        if a.gom ~= b.gom then return a.gom end
        if a.gom and a.entry.mana ~= b.entry.mana then return a.entry.mana > b.entry.mana end
        if a.score ~= b.score then return a.score > b.score end
        return a.entry.index < b.entry.index
    end)
    return out
end

function M.explain(result)
    if not result then return 'nothing castable' end
    return result.reason
end

function M.excluded() return M._lastExcluded or {} end
function M.clearExcluded() end -- no-op; _lastExcluded is reset at the start of M.rank()

return M
