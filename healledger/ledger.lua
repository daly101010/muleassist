-- utils/heal_ledger.lua
-- The raid heal gap ledger: a world model built from per-box snapshots (ma_healagent) and the
-- detectors that turn it into gap rows - the places the raid's healing logic should have acted and
-- did not, judged with the information that logic had. Pure Lua, no mq dependency, so it runs under
-- plain luajit (tests/heal_ledger_test.lua) and can replay a recorded night.
--
-- Design: F:\macros\muleassist\docs\superpowers\specs\2026-09-30-heal-coordinator-design.md
--
-- Snapshot (one per box, from ma_healagent):
--   { v=1, from='Cleric1', id=111, ts=<sender ms>, seq=n, zone='...',
--     me = { hp, mana, dead, stunned, feigned, x, y, z, class, group=<group key>, inCombat,
--            casting = { spell, targetId, landsAt, kind='direct'|'hot'|'group'|'cure'|'other' } | nil },
--     lines = { direct = { {name, pct, range, castMs, ready, mana} }, group = { {name, pct, range, ready, mana} },
--               cures = { {name, types = {poison=true,...} (empty = any), range, ready} } },
--     targets = { [id] = { name, hp, x, y, z, dead, class, group, pet, counters = {p,d,c,co} | nil } },
--     macro = { healLine, tankLine, healTank, healTankId, healsOn, curesOn },
--     stats = { line = <HealStats one-liner>, single, tank, groupT, self, pet, oog, tap, mob, intHeal, intTap, intMob,
--               intNPC, dpsCut, fail, failLast, group, groupRange, smart, smartFail, cure, cureGroup, cureHeld,
--               cureUnready, skip, lowPct, lowName, tankLow, fights, sinceSec }   (the macro's /healreport counters, 1Hz)
--     events = { {kind='interrupt'|'withheld'|'cast', spell, targetId, targetName, reason, ts} } }
--
-- Gap kinds: unhealed, late, duplicate, uncured, missed_group, interrupted_nothing, death, withheld.

local M = {}

M.KINDS = { 'unhealed', 'late', 'duplicate', 'uncured', 'missed_group', 'interrupted_nothing', 'death', 'withheld' }

M.DEFAULTS = {
    staleMs         = 1000,   -- a box snapshot older than this is not trusted
    unhealedMs      = 1500,   -- under the line with an idle candidate healer this long
    lateMs          = 2000,   -- a heal that starts this long after the line was crossed
    duplicateMs     = 1500,   -- two direct heals landing within this window on one target
    uncuredMs       = 4000,   -- counters up with an idle matching curer this long
    missedGroupMs   = 3000,   -- 3+ of a group under a ready group line this long
    groupMinCount   = 3,
    interruptGraceMs = 1000,  -- re-check the target this long after "past the line" interrupt
    deathWindowMs   = 6000,   -- HP history kept per target for the death row
    maxRows         = 1000,
    sampleMs        = 250,
}

local function now_or(nowMs) return tonumber(nowMs) or 0 end

local function dist3(a, b)
    if not a or not b or a.x == nil or b.x == nil then return nil end
    local dx, dy, dz = (a.x - b.x), (a.y - b.y), ((a.z or 0) - (b.z or 0))
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function shallowCopy(t)
    local o = {}
    for k, v in pairs(t or {}) do o[k] = v end
    return o
end

-- ------------------------------------------------------------------ construction

function M.newLedger(opts)
    local L = { opts = {} }
    for k, v in pairs(M.DEFAULTS) do L.opts[k] = v end
    for k, v in pairs(opts or {}) do L.opts[k] = v end
    L.boxes = {}        -- [from] = { snap, receivedAt, prevEvents }
    L.targets = {}      -- [id] = merged target record
    L.rows = {}         -- ring of gap rows, oldest first
    L.open = {}         -- [key] = row still open
    L.nextRowId = 1
    L.episodes = {}     -- [targetId] = { underSince, candidateSince, lateRowed, dupPairs = {} }
    L.cureEpisodes = {} -- [targetId] = { since }
    L.groupEpisodes = {}-- [healer] = { since }
    L.pendingInterrupts = {} -- { dueAt, box, spell, targetId, targetName }
    L.fight = nil       -- { n, startedAt, ticks, casting = {[box]=ticks}, idleReady = {[box]=ticks}, rows = {} }
    L.fights = {}       -- closed fight summaries
    L.fightCount = 0
    L.lastTick = 0
    return L
end

-- ------------------------------------------------------------------ ingest

--- Merge one box snapshot into the model. nowMs is the brain's clock at receipt.
function M.ingest(L, snap, nowMs)
    if type(snap) ~= 'table' or type(snap.from) ~= 'string' or snap.from == '' then return false end
    nowMs = now_or(nowMs)
    local box = L.boxes[snap.from]
    if not box then
        box = { events = {} }
        L.boxes[snap.from] = box
    end
    -- lines and macro settings are sent at 1Hz; a snapshot without them keeps the last ones
    if box.snap then
        if snap.lines == nil then snap.lines = box.snap.lines end
        if snap.macro == nil then snap.macro = box.snap.macro end
        if snap.stats == nil then snap.stats = box.snap.stats end
    end
    box.snap = snap
    box.receivedAt = nowMs
    -- a box reports itself as a target too, with its own counters
    local me = snap.me
    if me and snap.id and snap.id > 0 then
        local t = L.targets[snap.id] or { id = snap.id, hist = {} }
        t.name = snap.from
        t.hp = me.hp
        t.x, t.y, t.z = me.x, me.y, me.z
        t.dead = me.dead == true
        t.class = me.class or t.class
        t.group = me.group or t.group
        t.counters = me.counters
        t.countersKnown = true
        t.isBox = true
        t.ts = nowMs
        L.targets[snap.id] = t
    end
    for id, tr in pairs(snap.targets or {}) do
        id = tonumber(id)
        if id and id > 0 and id ~= snap.id then
            local t = L.targets[id] or { id = id, hist = {} }
            -- the freshest reporter wins; a box's own report (above) is authoritative for counters
            if not t.ts or t.ts <= nowMs then
                t.name = tr.name or t.name
                if tr.hp ~= nil then t.hp = tr.hp end
                if tr.x ~= nil then t.x, t.y, t.z = tr.x, tr.y, tr.z end
                if tr.dead ~= nil then t.dead = tr.dead == true end
                t.class = tr.class or t.class
                t.group = tr.group or t.group
                t.pet = tr.pet == true
                if not t.isBox then
                    t.counters = tr.counters
                    t.countersKnown = tr.counters ~= nil
                end
                t.ts = nowMs
            end
            L.targets[id] = t
        end
    end
    -- discrete events: queue for the tick
    for _, ev in ipairs(snap.events or {}) do
        box.events[#box.events + 1] = ev
    end
    return true
end

-- ------------------------------------------------------------------ helpers

local function fresh(L, box, nowMs)
    return box and box.snap and (nowMs - (box.receivedAt or 0)) <= L.opts.staleMs
end

local function boxPos(box)
    local me = box.snap.me
    if not me then return nil end
    return { x = me.x, y = me.y, z = me.z }
end

local function boxIdle(box)
    local me = box.snap.me or {}
    return not me.dead and not me.stunned and not me.feigned and me.casting == nil
end

-- the line a healer holds a target to: its tank line for its heal tank, else its heal line
local function lineFor(box, targetId)
    local m = box.snap.macro or {}
    if m.healTankId and m.healTankId == targetId and m.tankLine then return m.tankLine end
    return m.healLine or 0
end

-- a ready direct line on this box that fits a target at hp within range dist
local function fittingDirect(box, hp, dist)
    for _, ln in ipairs((box.snap.lines or {}).direct or {}) do
        -- unknown geometry (a target with no position) never fits: no row from a guess
        if ln.ready and ln.mana ~= false and (ln.pct or 0) >= hp and dist ~= nil and (ln.range or 0) >= dist then
            return ln
        end
    end
    return nil
end

local COUNTER_KEYS = { poison = 'p', disease = 'd', curse = 'c', corruption = 'co' }

local function counterTypes(counters)
    local out = {}
    if not counters then return out end
    for name, key in pairs(COUNTER_KEYS) do
        if (tonumber(counters[key]) or 0) > 0 then out[#out + 1] = name end
    end
    return out
end

local function fittingCure(box, types, dist)
    for _, cl in ipairs((box.snap.lines or {}).cures or {}) do
        if cl.ready and dist ~= nil and (cl.range or 0) >= dist then
            local any = true
            for _ in pairs(cl.types or {}) do any = false end
            if any then return cl end
            for _, ty in ipairs(types) do
                if cl.types[ty] then return cl end
            end
        end
    end
    return nil
end

-- who is casting a beneficial heal on this target right now (lands in the future)
local function coverage(L, targetId, nowMs)
    local out = {}
    for name, box in pairs(L.boxes) do
        if fresh(L, box, nowMs) then
            local c = box.snap.me and box.snap.me.casting
            if c and c.targetId == targetId and (c.kind == 'direct' or c.kind == 'hot') and (c.landsAt or 0) >= nowMs then
                out[#out + 1] = { box = name, spell = c.spell, landsAt = c.landsAt, startedAt = c.startedAt }
            end
        end
    end
    return out
end

local function candidateDesc(box, name, dist, line)
    local me = box.snap.me or {}
    local m = box.snap.macro or {}
    return {
        box = name,
        spell = line and line.name or nil,
        dist = dist and math.floor(dist + 0.5) or nil,
        mana = me.mana,
        casting = me.casting and (me.casting.spell .. ' on ' .. tostring(me.casting.targetName or me.casting.targetId)) or nil,
        whynot = m.whynotLast,
    }
end

local function pushRow(L, row)
    row.id = L.nextRowId
    L.nextRowId = L.nextRowId + 1
    row.fight = L.fight and L.fight.n or 0
    L.rows[#L.rows + 1] = row
    if #L.rows > L.opts.maxRows then table.remove(L.rows, 1) end
    if L.fight then L.fight.rows[#L.fight.rows + 1] = row.id end
    return row
end

local function openRow(L, key, row)
    L.open[key] = row
    return pushRow(L, row)
end

local function closeRow(L, key, nowMs)
    local row = L.open[key]
    if row then
        row.closedAt = nowMs
        row.durationMs = nowMs - row.openedAt
        L.open[key] = nil
    end
    return row
end

-- ------------------------------------------------------------------ detectors

local function healersFor(L, nowMs)
    local hs = {}
    for name, box in pairs(L.boxes) do
        if fresh(L, box, nowMs) and box.snap.lines and box.snap.macro and (box.snap.macro.healsOn or 0) > 0
            and box.snap.lines.direct and #box.snap.lines.direct > 0 then
            hs[#hs + 1] = { name = name, box = box }
        end
    end
    return hs
end

local function curersFor(L, nowMs)
    local cs = {}
    for name, box in pairs(L.boxes) do
        if fresh(L, box, nowMs) and box.snap.lines and box.snap.macro and (box.snap.macro.curesOn or 0) > 0
            and box.snap.lines.cures and #box.snap.lines.cures > 0 then
            cs[#cs + 1] = { name = name, box = box }
        end
    end
    return cs
end

local function detectUnhealedAndLate(L, nowMs, healers, opened)
    for id, t in pairs(L.targets) do
        local ep = L.episodes[id] or {}
        L.episodes[id] = ep
        local freshT = t.ts and (nowMs - t.ts) <= L.opts.staleMs
        if not freshT or t.dead or not t.hp or t.hp < 1 then
            ep.underSince, ep.candidateSince, ep.lateRowed = nil, nil, nil
            closeRow(L, 'unhealed:' .. id, nowMs)
        else
            -- under any fresh healer's line for this target? (a pet only counts for a healer that heals pets)
            local under, candidates = false, {}
            for _, h in ipairs(healers) do
                local line = lineFor(h.box, id)
                if t.pet and not ((h.box.snap.macro or {}).healPets) then line = -1 end
                if t.hp <= line then
                    under = true
                    local d = dist3(boxPos(h.box), t)
                    local ln = fittingDirect(h.box, t.hp, d)
                    if ln and boxIdle(h.box) then
                        candidates[#candidates + 1] = candidateDesc(h.box, h.name, d, ln)
                    end
                end
            end
            if not under then
                ep.underSince, ep.candidateSince, ep.lateRowed = nil, nil, nil
                closeRow(L, 'unhealed:' .. id, nowMs)
            else
                ep.underSince = ep.underSince or nowMs
                local cov = coverage(L, id, nowMs)
                if #candidates > 0 and #cov == 0 then
                    ep.candidateSince = ep.candidateSince or nowMs
                else
                    ep.candidateSince = nil
                    closeRow(L, 'unhealed:' .. id, nowMs)
                end
                if ep.candidateSince and (nowMs - ep.candidateSince) >= L.opts.unhealedMs and not L.open['unhealed:' .. id] then
                    opened[#opened + 1] = openRow(L, 'unhealed:' .. id, {
                        kind = 'unhealed', openedAt = ep.candidateSince, target = { id = id, name = t.name },
                        targetHp = t.hp, candidates = candidates,
                        detail = string.format('%s at %d%% under the line with %d idle healer(s) able to cast', tostring(t.name), t.hp, #candidates),
                    })
                end
                -- late: a heal starts on this target long after it crossed the line
                if #cov > 0 and not ep.lateRowed then
                    ep.lateRowed = true
                    local c = cov[1]
                    local startedAt = c.startedAt or nowMs
                    if (startedAt - ep.underSince) >= L.opts.lateMs then
                        opened[#opened + 1] = pushRow(L, {
                            kind = 'late', openedAt = ep.underSince, closedAt = startedAt, durationMs = startedAt - ep.underSince,
                            target = { id = id, name = t.name }, targetHp = t.hp, healer = c.box, spell = c.spell,
                            detail = string.format('%s cast %s on %s %.1fs after it crossed the line', c.box, tostring(c.spell), tostring(t.name), (startedAt - ep.underSince) / 1000),
                        })
                    end
                end
            end
        end
    end
end

local function detectDuplicates(L, nowMs, opened)
    -- two boxes with a direct/hot cast in flight on the same target
    local byTarget = {}
    for name, box in pairs(L.boxes) do
        if fresh(L, box, nowMs) then
            local c = box.snap.me and box.snap.me.casting
            if c and c.targetId and (c.kind == 'direct') and (c.landsAt or 0) >= nowMs then
                byTarget[c.targetId] = byTarget[c.targetId] or {}
                table.insert(byTarget[c.targetId], { box = name, spell = c.spell, landsAt = c.landsAt, startedAt = c.startedAt })
            end
        end
    end
    for id, casts in pairs(byTarget) do
        if #casts >= 2 then
            table.sort(casts, function(a, b) return (a.startedAt or 0) < (b.startedAt or 0) end)
            local ep = L.episodes[id] or {}
            L.episodes[id] = ep
            ep.dupPairs = ep.dupPairs or {}
            for i = 2, #casts do
                local a, b = casts[1], casts[i]
                if math.abs((a.landsAt or 0) - (b.landsAt or 0)) <= L.opts.duplicateMs then
                    local key = a.box .. '|' .. b.box .. '|' .. tostring(b.startedAt or 0)
                    if not ep.dupPairs[key] then
                        ep.dupPairs[key] = true
                        local t = L.targets[id] or {}
                        opened[#opened + 1] = pushRow(L, {
                            kind = 'duplicate', openedAt = b.startedAt or nowMs, closedAt = nowMs, durationMs = 0,
                            target = { id = id, name = t.name }, targetHp = t.hp,
                            healer = b.box, spell = b.spell, first = { box = a.box, spell = a.spell },
                            detail = string.format('%s cast %s on %s while %s already had %s landing', b.box, tostring(b.spell), tostring(t.name), a.box, tostring(a.spell)),
                        })
                    end
                end
            end
        end
    end
end

local function detectUncured(L, nowMs, curers, opened)
    for id, t in pairs(L.targets) do
        local freshT = t.ts and (nowMs - t.ts) <= L.opts.staleMs
        local types = (freshT and not t.dead and t.countersKnown) and counterTypes(t.counters) or {}
        if #types == 0 then
            L.cureEpisodes[id] = nil
            closeRow(L, 'uncured:' .. id, nowMs)
        else
            local candidates = {}
            for _, c in ipairs(curers) do
                local d = dist3(boxPos(c.box), t)
                local cl = fittingCure(c.box, types, d)
                if cl and boxIdle(c.box) then
                    candidates[#candidates + 1] = candidateDesc(c.box, c.name, d, cl)
                end
            end
            local ep = L.cureEpisodes[id]
            if #candidates == 0 then
                L.cureEpisodes[id] = nil
                closeRow(L, 'uncured:' .. id, nowMs)
            else
                if not ep then
                    ep = { since = nowMs }
                    L.cureEpisodes[id] = ep
                end
                if (nowMs - ep.since) >= L.opts.uncuredMs and not L.open['uncured:' .. id] then
                    opened[#opened + 1] = openRow(L, 'uncured:' .. id, {
                        kind = 'uncured', openedAt = ep.since, target = { id = id, name = t.name }, targetHp = t.hp,
                        types = types, candidates = candidates,
                        detail = string.format('%s has %s counters with %d idle curer(s) holding a matching cure', tostring(t.name), table.concat(types, '/'), #candidates),
                    })
                end
            end
        end
    end
end

local function groupHealInFlight(L, nowMs, groupKey)
    for _, box in pairs(L.boxes) do
        if fresh(L, box, nowMs) then
            local me = box.snap.me or {}
            local c = me.casting
            if c and c.kind == 'group' and me.group == groupKey and (c.landsAt or 0) >= nowMs then return true end
        end
    end
    return false
end

local function detectMissedGroup(L, nowMs, healers, opened)
    for _, h in ipairs(healers) do
        local me = h.box.snap.me or {}
        local groupKey = me.group
        local best = nil
        if groupKey then
            for _, gl in ipairs((h.box.snap.lines or {}).group or {}) do
                if gl.ready and gl.mana ~= false then
                    local n, names = 0, {}
                    local hp = boxPos(h.box)
                    for id, t in pairs(L.targets) do
                        if t.group == groupKey and not t.dead and not t.pet and t.hp and t.hp >= 1 and t.hp <= (gl.pct or 0)
                            and t.ts and (nowMs - t.ts) <= L.opts.staleMs then
                            local d = dist3(hp, t)
                            if d ~= nil and d <= (gl.range or 0) then
                                n = n + 1
                                names[#names + 1] = string.format('%s %d%%', tostring(t.name), t.hp)
                            end
                        end
                    end
                    if n >= L.opts.groupMinCount and (not best or n > best.n) then
                        best = { n = n, line = gl, names = names }
                    end
                end
            end
        end
        local key = 'missed_group:' .. h.name
        if best and not groupHealInFlight(L, nowMs, groupKey) and not (me.casting and me.casting.kind == 'group') then
            local ep = L.groupEpisodes[h.name]
            if not ep then
                ep = { since = nowMs }
                L.groupEpisodes[h.name] = ep
            end
            if (nowMs - ep.since) >= L.opts.missedGroupMs and not L.open[key] then
                opened[#opened + 1] = openRow(L, key, {
                    kind = 'missed_group', openedAt = ep.since, healer = h.name, spell = best.line.name,
                    count = best.n, members = best.names, casting = me.casting and me.casting.spell or nil,
                    whynot = (h.box.snap.macro or {}).whynotLast,
                    detail = string.format('%s: %d of its group under %s|%d in range (%s) and no group heal cast', h.name, best.n, tostring(best.line.name), best.line.pct or 0, table.concat(best.names, ', ')),
                })
            end
        else
            L.groupEpisodes[h.name] = nil
            closeRow(L, key, nowMs)
        end
    end
end

local function detectDeaths(L, nowMs, healers, opened)
    for id, t in pairs(L.targets) do
        if t.dead and not t.deathRowed then
            t.deathRowed = true
            if t.wasAlive then
                local candidates = {}
                for _, h in ipairs(healers) do
                    local d = dist3(boxPos(h.box), t)
                    local ln = fittingDirect(h.box, t.lastHp or 1, d)
                    local c = h.box.snap.me and h.box.snap.me.casting
                    if ln and boxIdle(h.box) or (ln and c and c.targetId ~= id) then
                        candidates[#candidates + 1] = candidateDesc(h.box, h.name, d, ln)
                    end
                end
                if #candidates > 0 then
                    local hist = {}
                    for _, s in ipairs(t.hist or {}) do hist[#hist + 1] = { s[1], s[2] } end
                    opened[#opened + 1] = pushRow(L, {
                        kind = 'death', openedAt = nowMs, closedAt = nowMs, durationMs = 0,
                        target = { id = id, name = t.name }, targetHp = t.lastHp, candidates = candidates, history = hist,
                        detail = string.format('%s died with %d healer(s) holding a ready heal and not casting on it', tostring(t.name), #candidates),
                    })
                end
            end
        elseif not t.dead then
            t.deathRowed = nil
            t.wasAlive = true
        end
    end
end

local function drainEvents(L, nowMs, opened)
    for name, box in pairs(L.boxes) do
        if #box.events > 0 then
            for _, ev in ipairs(box.events) do
                local tid = tonumber(ev.targetId) or 0
                local t = L.targets[tid]
                if ev.kind == 'interrupt' then
                    L.pendingInterrupts[#L.pendingInterrupts + 1] = {
                        dueAt = nowMs + L.opts.interruptGraceMs, box = name, spell = ev.spell, targetId = tid,
                        targetName = ev.targetName or (t and t.name), reason = ev.reason, hpAt = t and t.hp,
                    }
                elseif ev.kind == 'withheld' then
                    -- only a withheld cast for a target that was under the line is a gap
                    local under = false
                    if t and t.hp then
                        under = t.hp <= lineFor(box, tid)
                    end
                    if under or tid == 0 then
                        opened[#opened + 1] = pushRow(L, {
                            kind = 'withheld', openedAt = ev.ts or nowMs, closedAt = ev.ts or nowMs, durationMs = 0,
                            healer = name, spell = ev.spell, target = t and { id = tid, name = t.name } or nil, targetHp = t and t.hp,
                            reason = ev.reason,
                            detail = string.format('%s withheld %s%s: %s', name, tostring(ev.spell or 'a cast'),
                                t and (' on ' .. tostring(t.name) .. (t.hp and (' (' .. t.hp .. '%)') or '')) or '', tostring(ev.reason)),
                        })
                    end
                end
            end
            box.events = {}
        end
    end
    -- interrupts due for their re-check
    local keep = {}
    for _, p in ipairs(L.pendingInterrupts) do
        if nowMs >= p.dueAt then
            local t = L.targets[p.targetId]
            local box = L.boxes[p.box]
            if t and t.hp and not t.dead and box and box.snap and t.hp <= lineFor(box, p.targetId) then
                opened[#opened + 1] = pushRow(L, {
                    kind = 'interrupted_nothing', openedAt = p.dueAt - L.opts.interruptGraceMs, closedAt = nowMs, durationMs = L.opts.interruptGraceMs,
                    healer = p.box, spell = p.spell, target = { id = p.targetId, name = p.targetName }, targetHp = t.hp, reason = p.reason,
                    detail = string.format('%s interrupted %s on %s (%s) and the target was still at %d%% a second later', p.box, tostring(p.spell), tostring(p.targetName), tostring(p.reason), t.hp),
                })
            end
        else
            keep[#keep + 1] = p
        end
    end
    L.pendingInterrupts = keep
end

local function sampleHistory(L, nowMs)
    local keepN = math.floor(L.opts.deathWindowMs / L.opts.sampleMs) + 1
    -- forget spawns nobody has reported for a minute (resummoned pets, zoned members)
    for id, t in pairs(L.targets) do
        if t.ts and (nowMs - t.ts) > 60000 then
            L.targets[id] = nil
            L.episodes[id] = nil
            L.cureEpisodes[id] = nil
        end
    end
    for _, t in pairs(L.targets) do
        if t.hp then
            t.hist[#t.hist + 1] = { nowMs, t.hp }
            while #t.hist > keepN do table.remove(t.hist, 1) end
            if not t.dead then t.lastHp = t.hp end
        end
    end
end

local function accountFight(L, nowMs, healers)
    local f = L.fight
    if not f then return end
    f.ticks = f.ticks + 1
    for _, h in ipairs(healers) do
        local me = h.box.snap.me or {}
        f.casting[h.name] = (f.casting[h.name] or 0) + (me.casting and 1 or 0)
        f.ticksBy[h.name] = (f.ticksBy[h.name] or 0) + 1
        if not me.casting then
            local ready = false
            for _, ln in ipairs((h.box.snap.lines or {}).direct or {}) do if ln.ready then ready = true break end end
            -- idle with a ready heal while someone in the raid is under its line
            if ready then
                for id, t in pairs(L.targets) do
                    if t.hp and not t.dead and t.hp >= 1 and t.hp <= lineFor(h.box, id) then
                        f.idleReady[h.name] = (f.idleReady[h.name] or 0) + 1
                        break
                    end
                end
            end
        end
    end
end

--- Run the detectors. Returns the rows opened this tick (closed rows are updated in place).
function M.tick(L, nowMs)
    nowMs = now_or(nowMs)
    L.lastTick = nowMs
    local opened = {}
    local healers = healersFor(L, nowMs)
    local curers = curersFor(L, nowMs)
    sampleHistory(L, nowMs)
    detectDeaths(L, nowMs, healers, opened)
    detectUnhealedAndLate(L, nowMs, healers, opened)
    detectDuplicates(L, nowMs, opened)
    detectUncured(L, nowMs, curers, opened)
    detectMissedGroup(L, nowMs, healers, opened)
    drainEvents(L, nowMs, opened)
    accountFight(L, nowMs, healers)
    return opened
end

-- ------------------------------------------------------------------ fights

function M.fightStart(L, nowMs)
    nowMs = now_or(nowMs)
    if L.fight then M.fightEnd(L, nowMs) end
    L.fightCount = L.fightCount + 1
    L.fight = { n = L.fightCount, startedAt = nowMs, ticks = 0, casting = {}, ticksBy = {}, idleReady = {}, rows = {} }
    return L.fight
end

function M.fightEnd(L, nowMs)
    nowMs = now_or(nowMs)
    local f = L.fight
    if not f then return nil end
    L.fight = nil
    local summary = { n = f.n, startedAt = f.startedAt, endedAt = nowMs, durationMs = nowMs - f.startedAt,
        byKind = {}, byTarget = {}, healers = {}, rows = #f.rows }
    local rowById = {}
    for _, r in ipairs(L.rows) do rowById[r.id] = r end
    for _, id in ipairs(f.rows) do
        local r = rowById[id]
        if r then
            summary.byKind[r.kind] = (summary.byKind[r.kind] or 0) + 1
            local tn = r.target and r.target.name or r.healer or '?'
            summary.byTarget[tn] = (summary.byTarget[tn] or 0) + 1
        end
    end
    for name, ticks in pairs(f.ticksBy) do
        summary.healers[name] = {
            castingPct = ticks > 0 and math.floor(100 * (f.casting[name] or 0) / ticks + 0.5) or 0,
            idleReadyPct = ticks > 0 and math.floor(100 * (f.idleReady[name] or 0) / ticks + 0.5) or 0,
        }
    end
    L.fights[#L.fights + 1] = summary
    return summary
end

--- Night summary across every closed fight.
function M.nightSummary(L)
    local s = { fights = #L.fights, byKind = {}, byTarget = {}, rows = #L.rows }
    for _, f in ipairs(L.fights) do
        for k, n in pairs(f.byKind) do s.byKind[k] = (s.byKind[k] or 0) + n end
        for k, n in pairs(f.byTarget) do s.byTarget[k] = (s.byTarget[k] or 0) + n end
    end
    return s
end

function M.reset(L)
    local opts = L.opts
    local fresh = M.newLedger(opts)
    for k, v in pairs(fresh) do L[k] = v end
end

-- ------------------------------------------------------------------ formatting

-- local wall clock, as the file's fight records and the macro's /whynot stamps (mq.gettime() is epoch ms)
local function clock(ms)
    if not ms then return '--:--:--.---' end
    local s = math.floor(ms / 1000)
    local ok, hms = pcall(os.date, '%H:%M:%S', s)
    if not ok or type(hms) ~= 'string' then hms = string.format('%02d:%02d:%02d', math.floor(s / 3600) % 24, math.floor(s / 60) % 60, s % 60) end
    return string.format('%s.%03d', hms, ms % 1000)
end
M.clock = clock

--- One line per row, for the window and the chat.
function M.formatRow(row, clockFn)
    clockFn = clockFn or clock
    local parts = { clockFn(row.openedAt), string.upper(row.kind) }
    if row.durationMs and row.durationMs > 0 then parts[#parts + 1] = string.format('%.1fs', row.durationMs / 1000) end
    parts[#parts + 1] = row.detail or ''
    local line = table.concat(parts, '  ')
    if row.candidates and #row.candidates > 0 then
        local cs = {}
        for _, c in ipairs(row.candidates) do
            local bits = { c.box }
            if c.spell then bits[#bits + 1] = c.spell .. ' ready' end
            if c.dist then bits[#bits + 1] = c.dist .. 'u' end
            if c.casting then bits[#bits + 1] = 'casting ' .. c.casting end
            if c.whynot then bits[#bits + 1] = 'whynot: ' .. c.whynot end
            cs[#cs + 1] = table.concat(bits, ', ')
        end
        line = line .. '  candidates: ' .. table.concat(cs, ' | ')
    end
    return line
end

return M
