-- necrobrain/holds.lua — which DPS lines the macro will refuse on which mob right now. Pure (no mq).
--
-- After a CAST_SUCCESS the macro locks that line on that target (muleassist.mac CombatCast,
-- DPSTimer<i>_<target>): a DoT for its full duration, anything else for DPSInterval, and a TAKEHOLD
-- for 5 minutes. Its skip test is "timer running", so a pick for a locked line comes back SKIPPED
-- and the rest of that pass is idle. The brain mirrors those locks here, keyed by spell and spawn ID,
-- so it never offers a line the macro will refuse. The same records tell the ranker which DoTs are
-- ticking on the mob (Demand for Blood's synergy and the running-DoT screen).
--
-- A record made from a macro verdict carries the spawn ID. A record made from the feed alone (shadow
-- mode, or a DoT the macro cast while the bridge was stale) only knows the mob's name from the chat
-- line, so it matches by lowercased name.
local M = {}
-- a learned stacking pair only blocks after this many consistent "did not take hold" observations, so
-- one misread verdict (the macro maps "too powerful" to TAKEHOLD too) cannot bench a DoT all session
M.BLOCK_CONFIRM = 2

local Holds = {}
Holds.__index = Holds

function M.new() return setmetatable({ bySpell = {} }, Holds) end

local function lower(s) return tostring(s or ''):lower() end

local function keyOf(targetId, name)
    local id = tonumber(targetId)
    if id and id > 0 then return id end
    return 'n:' .. lower(name)
end

local function matches(rec, targetId, name)
    local id = tonumber(targetId)
    if rec.targetId then return id ~= nil and rec.targetId == id end
    return rec.name == lower(name)
end

-- A record lives until both its lock (until: the macro will refuse the line) and its DoT (dotUntil: my
-- DoT is on the mob) are over; a |once DoT locks 5 min but ticks only for its duration.
local function alive(rec, now)
    return math.max(rec['until'], rec.dotUntil or 0) > now
end

-- opts: { dot = bool, why = string, perTick = number, dotUntil = ms (defaults to untilMs for a DoT) }
function Holds:set(spell, targetId, name, untilMs, opts)
    opts = opts or {}
    local list = self.bySpell[spell] or {}
    self.bySpell[spell] = list
    local id = tonumber(targetId)
    local isDot = opts.dot == true
    local rec = {
        targetId = (id and id > 0) and id or nil, name = lower(name), ['until'] = untilMs,
        dot = isDot, dotUntil = isDot and (opts.dotUntil or untilMs) or nil,
        why = opts.why or 'macro timer', perTick = opts.perTick,
    }
    -- an ID-keyed record supersedes a name-only one for the same mob (and keeps what it learned)
    local old = list[keyOf(targetId, name)]
    if rec.targetId and rec.name ~= '' then
        old = old or list['n:' .. rec.name]
        list['n:' .. rec.name] = nil
    end
    if old and not rec.perTick then rec.perTick = old.perTick end
    list[keyOf(targetId, name)] = rec
    return rec
end

-- The macro's live lock for this spell on this mob, or nil (dead records are dropped on the way).
function Holds:find(spell, targetId, name, now)
    local list = self.bySpell[spell]
    if not list then return nil end
    for k, rec in pairs(list) do
        if not alive(rec, now) then
            list[k] = nil
        elseif rec['until'] > now and matches(rec, targetId, name) then
            return rec
        end
    end
    return nil
end

-- A DoT tick from the feed: refine the per-tick amount of this spell's record on the mob named in
-- the chat line. Returns the record it updated, or nil when none matches.
function Holds:tick(spell, name, amount, now)
    local list = self.bySpell[spell]
    if not list then return nil end
    local want = lower(name)
    for k, rec in pairs(list) do
        if not alive(rec, now) then
            list[k] = nil
        elseif rec.dot and rec.dotUntil > now and rec.name == want then
            rec.perTick = tonumber(amount) or rec.perTick
            return rec
        end
    end
    return nil
end

-- DoTs ticking on this mob: { { spell, perTick, leftSec }, ... }. perTick may be nil (not seen yet).
function Holds:running(targetId, name, now)
    local out = {}
    for spell, list in pairs(self.bySpell) do
        for k, rec in pairs(list) do
            if not alive(rec, now) then
                list[k] = nil
            elseif rec.dot and rec.dotUntil > now and matches(rec, targetId, name) then
                out[#out + 1] = { spell = spell, perTick = rec.perTick, leftSec = (rec.dotUntil - now) / 1000 }
            end
        end
    end
    table.sort(out, function(a, b) return a.spell < b.spell end)
    return out
end

-- Drop expired records and ID-keyed records whose spawn is gone (spawn IDs are reused).
-- spawnAlive(id) -> bool; omitted = keep every live ID.
function Holds:prune(now, spawnAlive)
    for spell, list in pairs(self.bySpell) do
        local any = false
        for k, rec in pairs(list) do
            if not alive(rec, now) or (rec.targetId and spawnAlive and not spawnAlive(rec.targetId)) then
                list[k] = nil
            else
                any = true
            end
        end
        if not any then self.bySpell[spell] = nil end
    end
end

-- Stacking learned from my own verdicts. The macro answered "did not take hold" for spell on a mob
-- where these DoTs of mine (candidates, already narrowed by the caller to same-line shapes) were
-- running: one of them blocks it (Dread Pyre under my Ashengate Pyre). Each observation narrows the set
-- to what was running every time; it blocks only once BLOCK_CONFIRM observations agree. Only my own holds
-- ever count, so another necro's copy of a DoT on the same mob blocks nothing.
-- blockers: { [spell] = { set = { [blockerSpell] = true }, n = observations } }.
-- Returns the blocker list now held for spell and whether it is confirmed, or nil when nothing was learned.
function M.learnBlock(blockers, spell, candidates)
    local seen = {}
    for _, other in ipairs(candidates or {}) do
        if other ~= spell then seen[other] = true end
    end
    if next(seen) == nil then return nil end
    local prev, n = blockers[spell], 1
    if prev then
        local both = {}
        for other in pairs(prev.set) do if seen[other] then both[other] = true end end
        -- nothing in common: the old guess was wrong, start over from the new evidence
        if next(both) ~= nil then seen, n = both, prev.n + 1 end
    end
    blockers[spell] = { set = seen, n = n }
    local out = {}
    for other in pairs(seen) do out[#out + 1] = other end
    table.sort(out)
    return out, n >= M.BLOCK_CONFIRM
end

-- spell landed while these DoTs of mine were running on that mob: none of them blocks it
function M.unlearnBlock(blockers, spell, runningSpells)
    local b = blockers[spell]
    if not b then return false end
    local changed = false
    for _, other in ipairs(runningSpells or {}) do
        if b.set[other] then b.set[other] = nil; changed = true end
    end
    if next(b.set) == nil then blockers[spell] = nil end
    return changed
end

-- The confirmed blocker set for spell, or nil.
function M.confirmedBlockers(blockers, spell)
    local b = blockers and blockers[spell]
    if b and b.n >= M.BLOCK_CONFIRM then return b.set end
    return nil
end

-- The DoT of mine running on this very spawn (never a name-only record) that blocks spell, or nil.
function Holds:blockedBy(blockers, spell, targetId, name, now)
    local set = M.confirmedBlockers(blockers, spell)
    local id = tonumber(targetId)
    if not set or not id then return nil end
    for other in pairs(set) do
        local list = self.bySpell[other]
        for _, rec in pairs(list or {}) do
            if rec.dot and rec.targetId == id and rec.dotUntil > now then return other, rec end
        end
    end
    return nil
end

-- Target IDs with at least one record (for the caller's liveness check).
function Holds:targets()
    local out, seen = {}, {}
    for _, list in pairs(self.bySpell) do
        for _, rec in pairs(list) do
            if rec.targetId and not seen[rec.targetId] then
                seen[rec.targetId] = true
                out[#out + 1] = rec.targetId
            end
        end
    end
    return out
end

return M
