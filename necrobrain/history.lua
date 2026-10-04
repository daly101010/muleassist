-- necrobrain/history.lua — read-only view of companion.db, loaded incrementally.
--
-- companion.db is 1.4 GB on a spinning disk and every query here blocks the game thread; a page
-- the OS has not cached costs 10-80 ms. The one-shot refresh this module used to run at load
-- (per-spell lifetime stats, the zone's max-HP scan, the last 40 fights' events, a 2000-fight
-- resist pool) read 3-30k scattered pages - minutes when cold, which froze the necros at every
-- muleassist load and zone change (2026-09-16). So:
--   * three walkers pull history in small batches of fight ids, newest first, one query batch
--     per M.step call: `spells` (this character's fight_ability / fight_cast rows, every zone),
--     `windows` (events of this character's fights in the zone -> per-mob caster windows) and
--     `pool` (the zone's fights from every box -> per-mob max HP, per-mob/spell resists);
--   * each step's wall time is charged against the walker's budget; a slow step means the disk,
--     so the walker pauses for this session (its forward catch-up retries once a minute);
--   * everything folded so far is persisted per server+character (mq.pickle), so the next
--     session starts from the snapshot and only folds in fights saved since;
--   * M.force runs the walk without the budget on demand (/necrobrain backfill) for when a
--     stutter is acceptable, e.g. parked in the lobby.
-- mob()/spell()/mobResist() are table lookups; the 200 ms loop never touches SQL on its own.
local mq = require('mq')
local Logger = require('necrobrain.logger')
local M = {}
local db = nil
local opener = nil       -- fn() -> handle: reopens the database when the load-time open failed
local reopenAt = 0
local failures = 0       -- failed queries so far (a forced run stops on the first new one)

M.SLOW_MS = 50           -- a step over this read from disk: pause the walker this session
M.BUDGET_MS = 500        -- total step time a walker may charge per session
M.FORWARD_MS = 15000     -- how often a walker looks for fights saved since its newest
M.RETRY_MS = 60000       -- a paused walker's forward catch-up retries this often
M.SAVE_MS = 120000       -- snapshot flush cadence while dirty
M.FORCE_SLICE_MS = 150   -- forced backfill: step time per M.step call
-- per walker: fights per budgeted step, per forced step, and how many fights the backward walk
-- covers (spells: effectively all; windows: the last 40 fights in the zone, as before; pool: 200,
-- resist.lua weighs history at most 6 casts)
M.SPELLS  = { batch = 5, forceBatch = 20, cap = 50000 }
M.WINDOWS = { batch = 1, forceBatch = 5,  cap = 40 }
M.POOL    = { batch = 2, forceBatch = 10, cap = 200 }
M.WINDOWS_PER_MOB = 40   -- caster windows kept per mob (the newest)
M.SNAPSHOT_VERSION = 1

local function q(s) return "'" .. tostring(s):gsub("'", "''") .. "'" end
M._q = q
local function idList(ids) return table.concat(ids, ',') end

-- A name without its rank suffix (feed.lua's baseSpell): companion's cast rows read 'Foo Rk' (its
-- capture stops at the first period) while resist rows keep 'Foo Rk. II'.
-- Most names carry no rank at all; the plain find skips both patterns for them (this runs per resist
-- record when an old snapshot is folded, and per row of every pool batch).
local function baseSpell(s)
    s = tostring(s or '')
    if not s:find('Rk', 1, true) then return s end
    return (s:gsub('%s+Rk%.%s*%a+$', ''):gsub('%s+Rk$', ''))
end
M._baseSpell = baseSpell

function M.attach(handle, open)
    db = handle
    if open ~= nil then opener = open end
end

function M.handle() return db end

-- rows, ok: ok is false when the query failed or there is no database, so a walker can tell "try
-- again later" from a real empty answer. A missing handle used to read as an empty history and latched
-- every walker 'done' into the snapshot, so a later session with the database read nothing.
local function rows(sql)
    local out = {}
    if not db then return out, false end
    local ok, err = pcall(function()
        for r in db:nrows(sql) do out[#out + 1] = r end
    end)
    if not ok then
        failures = failures + 1
        Logger.write('\arhistory query failed: %s', tostring(err))
    end
    return out, ok
end

-- ---------------------------------------------------------------- SQL
-- Every character companion has ever logged a session for - used so incoming hits landed on
-- our own characters/pets don't masquerade as mob kills.
local CHARS_SQL = "SELECT DISTINCT character FROM session;"

-- Fight-id sequences the walkers move along (%s op, %d bound, %s dir, %d limit). Each is an
-- INTEGER PRIMARY KEY range scan in id order that stops at LIMIT, so a step only reads the
-- fight rows it passes (session is 700 rows, always cached).
local OWN_IDS_SQL = [[
SELECT f.id AS id FROM fight f JOIN session s ON s.id = f.session_id
WHERE s.character = %s AND f.id %s %d
ORDER BY f.id %s LIMIT %d;
]]
local OWN_ZONE_IDS_SQL = [[
SELECT f.id AS id FROM fight f JOIN session s ON s.id = f.session_id
WHERE s.character = %s AND f.zone = %s AND f.id %s %d
ORDER BY f.id %s LIMIT %d;
]]
local ZONE_IDS_SQL = [[
SELECT f.id AS id FROM fight f
WHERE f.zone = %s AND f.id %s %d
ORDER BY f.id %s LIMIT %d;
]]

-- spells: this character's rollup rows for a batch of its own fights (idx_ability_fight /
-- idx_cast_fight: the rows of one fight sit together). Damage stats come from rows that are
-- neither heals nor pre-split merged taps (over_total > 0), heals from kind='heal' rows.
-- The unary + on source keeps the planner off idx_ability_source / idx_cast_source: with no
-- sqlite_stat1 it prefers that equality and would walk every row the character ever logged
-- (26k scattered pages) on each step.
local SPELL_BATCH_SQL = [[
SELECT a.ability AS ability, a.kind AS kind, a.is_pet AS is_pet, a.over_total AS over_total,
       a.hits AS hits, a.total AS total, a.resists AS resists
FROM fight_ability a WHERE a.fight_id IN (%s) AND +a.source = %s;
]]
local CAST_BATCH_SQL = [[
SELECT c.spell AS ability, c.casts AS casts
FROM fight_cast c WHERE c.fight_id IN (%s) AND +c.source = %s;
]]

-- windows: landed damage (any source, so the tank's hits still mark a window's end), this
-- character's own cast attempts and any kill line for a batch of its own fights in the zone,
-- pre-ordered so one forward pass segments per-mob CASTER windows. Join order is forced
-- (CROSS JOIN keeps left-to-right): events are reached per fight through idx_event_fight.
local WINDOW_BATCH_SQL = [[
SELECT e.fight_id AS fight_id, e.target AS target, e.t AS t, e.kind AS kind, e.source AS source,
       f.ended_at AS ended_at
FROM fight f CROSS JOIN event e ON e.fight_id = f.id
WHERE f.id IN (%s)
  AND ((e.outcome = 'hit' AND e.amount > 0 AND e.kind IN ('dot','nuke','melee','ds'))
    OR (e.kind = 'cast' AND e.source = %s)
    OR (e.kind = 'kill'))
ORDER BY f.ended_at, e.fight_id, LOWER(e.target), e.t;
]]

-- pool: per-mob max-HP samples (a property of the mob, so every box's fight counts) and, keyed by
-- spell name less its rank suffix (baseSpell) so only same-spell data ever meets, cast attempts and resists per mob/ability
-- from every box. Each box also logs other players' casts, so a row only counts when its source
-- is the character whose session logged it. Events come through idx_event_kind_fight - cast/nuke
-- rows only, never the raid's melee spam.
local HP_BATCH_SQL = [[
SELECT LOWER(f.primary_target) AS mob, f.mob_max_hp AS max_hp, f.mob_hp_weight AS hp_weight
FROM fight f WHERE f.id IN (%s) AND f.primary_target IS NOT NULL;
]]
local RESIST_BATCH_SQL = [[
SELECT LOWER(e.target) AS mob, e.ability AS ability,
       SUM(CASE WHEN e.kind = 'cast' THEN 1 ELSE 0 END) AS casts,
       SUM(CASE WHEN e.outcome = 'resist' THEN 1 ELSE 0 END) AS resists
FROM fight f
JOIN session s ON s.id = f.session_id
CROSS JOIN event e ON e.kind IN ('cast', 'nuke') AND e.fight_id = f.id
WHERE f.id IN (%s)
  AND e.source = s.character AND (e.kind = 'cast' OR e.outcome = 'resist')
GROUP BY LOWER(e.target), e.ability;
]]

-- ---------------------------------------------------------------- caster windows
-- A chain-pull camp closes one `fight` row only after a 12s lull, so a single fight can span a
-- dozen mobs. Per-mob CASTER windows are reconstructed from raw `event` rows instead: a gap of
-- more than GAP_S seconds with no row (cast, hit, or kill) on a target ends its current window.
-- A window measures the caster's own casting room on that mob, not the whole kill: it starts at
-- the first own cast (or, lacking one, the first own dot/nuke hit minus a typical 3s cast time)
-- and ends at the slain line if one landed in the window, else the last landed hit. Anything
-- shorter than MIN_WINDOW_S is noise, not a real window.
local GAP_S = 8
local MIN_WINDOW_S = 2
local CAST_TIME_S = 3
local MAX_AVG_SAMPLES = 10

-- rows: WINDOW_BATCH_SQL output in its ORDER BY; returns { {fightId, mob, startT, dur}, ... }
local function segmentWindows(list, character, chars)
    local out = {}
    local curKey, curMob, curFight, curLast = nil, nil, nil, nil
    local curCastT, curHitT, curKillT, curLastHitT = nil, nil, nil, nil
    local function closeSegment()
        if not curKey then return end
        local startT = curCastT or (curHitT and (curHitT - CAST_TIME_S)) or nil
        local endT = curKillT or curLastHitT or nil
        if startT and endT then
            local dur = endT - startT
            if dur >= MIN_WINDOW_S then out[#out + 1] = { fightId = curFight, mob = curMob, startT = startT, dur = dur } end
        end
        curKey, curMob, curFight, curLast = nil, nil, nil, nil
        curCastT, curHitT, curKillT, curLastHitT = nil, nil, nil, nil
    end
    for _, r in ipairs(list) do
        local mob = tostring(r.target):lower()
        -- exclude our own characters (incoming hits) and pets/players (single-word names)
        if not chars[mob] and mob:find(' ', 1, true) then
            local key = tostring(r.fight_id) .. '|' .. mob
            local t = tonumber(r.t) or 0
            if not (curKey == key and (t - curLast) <= GAP_S) then
                closeSegment()
                curKey, curMob, curFight = key, mob, tonumber(r.fight_id) or 0
            end
            curLast = t
            local kind = r.kind
            if kind == 'cast' then
                if not curCastT then curCastT = t end
            elseif kind == 'kill' then
                curKillT = t
            else -- dot/nuke/melee/ds landed hit
                curLastHitT = t
                if not curHitT and (kind == 'dot' or kind == 'nuke') and r.source == character then
                    curHitT = t
                end
            end
        end
    end
    closeSegment()
    return out
end
M._segmentWindows = segmentWindows

-- ---------------------------------------------------------------- state
local snap = nil                     -- persisted: { v, chars, spells = {st, stats}, zones = { [zone] = { windows = {st, byMob}, pool = {st, hp, resist} } } }
local server, char, zone = nil, nil, nil
local walkers = {}                   -- spells, windows, pool (the current zone's)
local dirty, lastSave = false, 0
local forceLeft = 0
local rr = 0

local function newSt() return { newest = nil, oldest = nil, done = false, loaded = 0 } end

local function snapshotPath()
    return string.format('%s/necrobrain_%s_%s.lua', mq.configDir, tostring(server), tostring(char))
end

-- Pluggable so tests keep snapshots in memory. The default writes next to the old file and
-- renames, so a crash mid-write leaves the previous snapshot intact.
M.store = {
    load = function(path)
        local f = loadfile(path)
        if not f then return nil end
        local ok, t = pcall(f)
        return (ok and type(t) == 'table') and t or nil
    end,
    save = function(path, t)
        local tmp = path .. '.tmp'
        mq.pickle(tmp, t)
        os.remove(path)
        local ok, err = os.rename(tmp, path)
        if not ok then Logger.write('\arhistory snapshot rename failed: %s', tostring(err)) end
    end,
}

-- ---------------------------------------------------------------- walker
local Walker = {}
Walker.__index = Walker

-- spec: { name, batch, forceBatch, cap, ids(op, bound, dir, limit) -> sql, load(walker, ids) }
-- data: the persisted sub-table for this walker (data.st is its cursor)
local function newWalker(spec, data)
    return setmetatable({ spec = spec, data = data, st = data.st, paused = nil, spentMs = 0, lastForward = 0, retryAt = 0 }, Walker)
end

function Walker:ids(op, bound, dir, limit)
    local out = {}
    local rs, ok = rows(self.spec.ids(op, bound, dir, limit))
    for _, r in ipairs(rs) do
        local id = tonumber(r.id)
        if id then out[#out + 1] = id end
    end
    return out, ok
end

-- Fold one batch of fight ids in; returns its lowest and highest id, or nil when a query of the batch
-- failed. A failed batch is not folded at all (every load collects all its rows before it applies any),
-- so the cursor stays put and the same fights are read again on the retry.
function Walker:fold(ids)
    local lo, hi = ids[1], ids[1]
    for _, id in ipairs(ids) do
        if id < lo then lo = id end
        if id > hi then hi = id end
    end
    if not self.spec.load(self, ids) then return nil end
    self.st.loaded = self.st.loaded + #ids
    dirty = true
    return lo, hi
end

-- Charge one step's wall time. A slow step means the pages came from disk, not the OS cache; the
-- next batch would cost the same again, so the walker pauses with whatever it has (forward
-- catch-up still retries every RETRY_MS). Forced steps are never charged.
function Walker:charge(startedAt, forced)
    local dt = mq.gettime() - startedAt
    self.spentMs = self.spentMs + dt
    if forced or self.paused then return end
    if dt > M.SLOW_MS then
        self.paused = string.format('a step took %d ms (limit %d) - history not cached', dt, M.SLOW_MS)
    elseif self.spentMs > M.BUDGET_MS then
        self.paused = string.format('%d ms budget spent', M.BUDGET_MS)
    end
    if self.paused then
        self.retryAt = mq.gettime() + M.RETRY_MS
        Logger.write('\ayhistory: %s walk paused at %d fights - %s (/necrobrain backfill to finish it)',
            self.spec.name, self.st.loaded, self.paused)
    end
end

-- One bounded unit of work: the newest batch on a fresh cursor; then fights saved since the
-- newest every FORWARD_MS; otherwise one older batch until the history or the cap runs out.
-- Companion saves a fight and its events in one transaction, so ids only ever grow. Returns
-- true when it queried.
function Walker:step(now, forced)
    local st = self.st
    local batch = forced and self.spec.forceBatch or self.spec.batch
    if not st.newest then
        if not forced and now < self.retryAt then return false end
        local t0 = mq.gettime()
        local ids, ok = self:ids('>=', 0, 'DESC', batch)
        if not ok then
            -- a failed query (locked db, companion mid-write) is not an empty history: retry the batch later
            self.retryAt = now + M.RETRY_MS
        elseif #ids == 0 then
            st.newest, st.oldest, st.done, st.doneOk = 0, 0, true, true
            dirty = true
        else
            local lo, hi = self:fold(ids)
            if lo then st.oldest, st.newest = lo, hi else self.retryAt = now + M.RETRY_MS end
        end
        self.lastForward = now
        self:charge(t0, forced)
        return true
    end
    if (now - self.lastForward) >= M.FORWARD_MS and (not self.paused or now >= self.retryAt or forced) then
        self.lastForward = now
        local t0 = mq.gettime()
        local ids = self:ids('>', st.newest, 'ASC', batch)
        if #ids > 0 then
            local _, hi = self:fold(ids)
            if hi then st.newest = hi end   -- a failed batch is read again at the next forward step
        end
        if self.paused then self.retryAt = now + M.RETRY_MS end
        self:charge(t0, forced)
        return true
    end
    if st.done or (self.paused and not forced) then return false end
    if st.loaded >= self.spec.cap then
        st.done, st.doneOk = true, true
        dirty = true
        return false
    end
    if not forced and now < self.retryAt then return false end
    local t0 = mq.gettime()
    local ids, ok = self:ids('<', st.oldest, 'DESC', batch)
    if not ok then
        self.retryAt = now + M.RETRY_MS
    elseif #ids == 0 then
        st.done, st.doneOk = true, true
        dirty = true
    else
        local lo = self:fold(ids)
        if lo then st.oldest = lo else self.retryAt = now + M.RETRY_MS end
    end
    self:charge(t0, forced)
    return true
end

-- ---------------------------------------------------------------- walker specs
local function spellsSpec(character)
    return {
        name = 'spells', batch = M.SPELLS.batch, forceBatch = M.SPELLS.forceBatch, cap = M.SPELLS.cap,
        ids = function(op, bound, dir, limit) return string.format(OWN_IDS_SQL, q(character), op, bound, dir, limit) end,
        load = function(w, ids)
            local stats = w.data.stats
            local function rec(name)
                local r = stats[name]
                if not r then
                    r = { casts = 0, dmgRows = 0, hits = 0, total = 0, resists = 0, healHits = 0, healRaw = 0 }
                    stats[name] = r
                end
                return r
            end
            local abil, okA = rows(string.format(SPELL_BATCH_SQL, idList(ids), q(character)))
            local casts, okC = rows(string.format(CAST_BATCH_SQL, idList(ids), q(character)))
            -- all or nothing: casts without hits (or hits without casts) would skew resistRate for good
            if not (okA and okC) then return false end
            for _, r in ipairs(abil) do
                if r.ability and (tonumber(r.is_pet) or 0) == 0 then
                    if r.kind == 'heal' then
                        local s = rec(r.ability)
                        s.healHits = s.healHits + (tonumber(r.hits) or 0)
                        s.healRaw = s.healRaw + (tonumber(r.total) or 0) + (tonumber(r.over_total) or 0)
                    elseif (tonumber(r.over_total) or 0) == 0 then
                        local s = rec(r.ability)
                        s.dmgRows = s.dmgRows + 1
                        s.hits = s.hits + (tonumber(r.hits) or 0)
                        s.total = s.total + (tonumber(r.total) or 0)
                        s.resists = s.resists + (tonumber(r.resists) or 0)
                    end
                end
            end
            for _, r in ipairs(casts) do
                if r.ability then
                    local s = rec(r.ability)
                    s.casts = s.casts + (tonumber(r.casts) or 0)
                end
            end
            return true
        end,
    }
end

local function windowsSpec(character, zoneName)
    return {
        name = 'windows', batch = M.WINDOWS.batch, forceBatch = M.WINDOWS.forceBatch, cap = M.WINDOWS.cap,
        ids = function(op, bound, dir, limit)
            return string.format(OWN_ZONE_IDS_SQL, q(character), q(zoneName), op, bound, dir, limit)
        end,
        load = function(w, ids)
            local list, ok = rows(string.format(WINDOW_BATCH_SQL, idList(ids), q(character)))
            if not ok then return false end
            local byMob = w.data.byMob
            for _, win in ipairs(segmentWindows(list, character, snap.chars)) do
                local l = byMob[win.mob] or {}
                l[#l + 1] = { id = win.fightId, t = win.startT, dur = win.dur }
                byMob[win.mob] = l
            end
            -- chronological (fight id, then start time); keep the newest WINDOWS_PER_MOB
            for _, l in pairs(byMob) do
                table.sort(l, function(a, b)
                    if a.id ~= b.id then return a.id < b.id end
                    return a.t < b.t
                end)
                while #l > M.WINDOWS_PER_MOB do table.remove(l, 1) end
            end
            return true
        end,
    }
end

local function poolSpec(zoneName)
    return {
        name = 'pool', batch = M.POOL.batch, forceBatch = M.POOL.forceBatch, cap = M.POOL.cap,
        ids = function(op, bound, dir, limit) return string.format(ZONE_IDS_SQL, q(zoneName), op, bound, dir, limit) end,
        load = function(w, ids)
            local hp, resist = w.data.hp, w.data.resist
            local hpRows, okH = rows(string.format(HP_BATCH_SQL, idList(ids)))
            local rsRows, okR = rows(string.format(RESIST_BATCH_SQL, idList(ids)))
            if not (okH and okR) then return false end
            for _, r in ipairs(hpRows) do
                if r.mob then
                    local wgt = tonumber(r.hp_weight) or 0
                    local h = hp[r.mob] or { sum = 0, weight = 0 }
                    if wgt > 0 then
                        h.sum = h.sum + (tonumber(r.max_hp) or 0) * wgt
                        h.weight = h.weight + wgt
                    end
                    hp[r.mob] = h
                end
            end
            for _, r in ipairs(rsRows) do
                if r.mob and r.ability then
                    local byAbility = resist[r.mob] or {}
                    local ability = baseSpell(r.ability)
                    local rec = byAbility[ability] or { casts = 0, resists = 0 }
                    rec.casts = rec.casts + (tonumber(r.casts) or 0)
                    rec.resists = rec.resists + (tonumber(r.resists) or 0)
                    byAbility[ability] = rec
                    resist[r.mob] = byAbility
                end
            end
            return true
        end,
    }
end

-- ---------------------------------------------------------------- lifecycle
local function ensureZone(z)
    local zs = snap.zones[z]
    if not zs then
        zs = { windows = { st = newSt(), byMob = {} }, pool = { st = newSt(), hp = {}, resist = {} } }
        snap.zones[z] = zs
        dirty = true
    end
    return zs
end

function M.save()
    if not snap then return end
    local ok, err = pcall(M.store.save, snapshotPath(), snap)
    if not ok then Logger.write('\arhistory snapshot not saved: %s', tostring(err)) end
    dirty, lastSave = false, mq.gettime()
end

local function selectZone(zoneName)
    zone = zoneName
    local zs = ensureZone(zone)
    walkers.windows = newWalker(windowsSpec(char, zone), zs.windows)
    walkers.pool = newWalker(poolSpec(zone), zs.pool)
end

-- Select the zone: its walkers resume from the snapshot (or start fresh); the previous zone's
-- progress is flushed first.
function M.setZone(zoneName)
    zoneName = tostring(zoneName or '')
    if zoneName == zone and walkers.windows then return end
    if dirty then M.save() end
    selectZone(zoneName)
end

local function loadChars()
    for _, r in ipairs(rows(CHARS_SQL)) do snap.chars[tostring(r.character):lower()] = true end
end

-- No database at load (lsqlite3 or the file was not ready): try the opener again. Returns true
-- when a handle is attached.
function M.reopen()
    if db then return true end
    if not opener then return false end
    local ok, h = pcall(opener)
    if not (ok and h) then return false end
    db = h
    Logger.write('\aghistory: database opened')
    if snap then loadChars() end
    return true
end

-- Fold every zone's resist keys under baseSpell (merging 'Foo Rk. II' into 'Foo'). Idempotent; M.open
-- runs it only on a snapshot that does not carry resistFolded yet. A mob none of whose keys holds "Rk"
-- has nothing to merge, so its records are kept as they are (the pool walker only ever stores numbers)
-- and the one-time fold costs a find per key instead of a rebuild.
function M.foldResist(t)
    local find = string.find
    for _, zs in pairs(t.zones or {}) do
        local resist = zs.pool and zs.pool.resist
        if resist then
            for mob, byAbility in pairs(resist) do
                local ranked = false
                for ability in pairs(byAbility) do
                    if find(ability, 'Rk', 1, true) then ranked = true break end
                end
                local merged = ranked and {} or nil
                if merged then
                    for ability, rec in pairs(byAbility) do
                        local base = baseSpell(ability)
                        local m = merged[base] or { casts = 0, resists = 0 }
                        m.casts = m.casts + (tonumber(rec.casts) or 0)
                        m.resists = m.resists + (tonumber(rec.resists) or 0)
                        merged[base] = m
                    end
                    resist[mob] = merged
                end
            end
        end
    end
end

-- Load the character's snapshot (or start one) and the set of known characters, then select the
-- zone. No fight data is read here: M.step folds it in over the following ticks. Returns true
-- when a snapshot was restored.
function M.open(serverName, character, zoneName)
    server, char = tostring(serverName or 'unknown'), tostring(character or 'unknown')
    walkers, forceLeft, rr = {}, 0, 0
    local ok, loaded = pcall(M.store.load, snapshotPath())
    local restored = ok and type(loaded) == 'table' and loaded.v == M.SNAPSHOT_VERSION
    snap = restored and loaded or { v = M.SNAPSHOT_VERSION, chars = {}, spells = { st = newSt(), stats = {} }, zones = {} }
    snap.chars = snap.chars or {}
    -- resist keys were once the raw ability name ('Foo Rk. II' beside 'Foo Rk'): fold a restored
    -- snapshot's keys under the base spell name so baseSpell lookups see the whole count. The pool
    -- walker has keyed by base name since, so a folded snapshot stays folded: resistFolded marks it
    -- (set here, written by the next save) and the fold - a VM loop over every zone's records, most
    -- of a boot's instruction budget - runs once per snapshot instead of at every load. A snapshot that
    -- had to be folded counts as dirty, so the mark reaches disk at the next SAVE_MS flush even when the
    -- session folds no fights and ends without M.close (a /lua stop).
    local markNew = restored and not snap.resistFolded
    if not snap.resistFolded then M.foldResist(snap) end
    snap.resistFolded = true
    -- Older builds read a failed query or a missing database as "no more history" and latched 'done'
    -- (doneOk marks a latch this build made from a real answer). A cursor done at id 0 with nothing
    -- loaded starts over; any other old latch is cleared so the walker probes past its oldest once more
    -- (one id query, or none when it sits at its cap) and latches again only on a real empty answer.
    local function unlatch(data)
        local st = data and data.st
        if not (st and st.done) or st.doneOk then return end
        if (tonumber(st.newest) or 0) == 0 and (tonumber(st.loaded) or 0) == 0 then
            data.st = newSt()
        else
            st.done = false
        end
    end
    unlatch(snap.spells)
    for _, zs in pairs(snap.zones or {}) do unlatch(zs.windows); unlatch(zs.pool) end
    loadChars()
    walkers.spells = newWalker(spellsSpec(char), snap.spells)
    selectZone(tostring(zoneName or ''))
    dirty, lastSave = markNew, mq.gettime()   -- nothing folded yet (bar an old snapshot's mark); the first fold marks it dirty
    return restored
end

function M.close()
    if snap then M.save() end
end

-- Run the walkers without the budget for up to n steps (/necrobrain backfill).
function M.force(n)
    forceLeft = math.max(0, math.floor(tonumber(n) or 0))
    if forceLeft > 0 and not M.reopen() then
        forceLeft = 0
        Logger.write('\arhistory: no database - nothing to backfill')
        return
    end
    if forceLeft > 0 then
        Logger.write('\ayhistory: forced backfill of up to %d steps - expect a stutter until it reports done', forceLeft)
    end
end

local function walkerList() return { walkers.windows, walkers.pool, walkers.spells } end

-- One call per loop tick. Budget mode: one query batch across the walkers (round robin, each
-- walker's own forward catch-up first). Forced mode: as many steps as fit in FORCE_SLICE_MS.
-- Returns true when a query ran.
function M.step(zoneName, now)
    if not snap then return false end
    now = now or mq.gettime()
    if zoneName and zoneName ~= '' and zoneName ~= zone then M.setZone(zoneName) end
    if not db and opener and now >= reopenAt then
        reopenAt = now + M.RETRY_MS
        M.reopen()
    end
    local list = walkerList()
    if forceLeft > 0 then
        local sliceEnd = mq.gettime() + M.FORCE_SLICE_MS
        local ran, failed = false, false
        repeat
            local any = false
            for _, w in ipairs(list) do
                if forceLeft > 0 and not failed and not w.st.done then
                    local f0 = failures
                    if w:step(now, true) then
                        any, ran = true, true
                        forceLeft = forceLeft - 1
                    end
                    -- a failed query (locked db, companion mid-write) would fail again at once: stop
                    -- the run rather than spin through the rest of the steps on it
                    if failures > f0 then failed = true end
                end
            end
            if not any or failed then forceLeft = 0 end
        until forceLeft <= 0 or mq.gettime() >= sliceEnd
        if forceLeft <= 0 then
            local parts = {}
            for _, w in ipairs(list) do
                parts[#parts + 1] = string.format('%s %d fights%s', w.spec.name, w.st.loaded, w.st.done and ' (all)' or '')
            end
            if failed then
                Logger.write('\ayhistory: forced backfill stopped - a query failed; try again later (%s)', table.concat(parts, ', '))
            else
                Logger.write('\aghistory: forced backfill done - %s', table.concat(parts, ', '))
            end
            M.save()
        end
        return ran
    end
    for i = 1, #list do
        rr = rr % #list + 1
        if list[rr]:step(now, false) then return true end
    end
    if dirty and (now - lastSave) >= M.SAVE_MS then M.save() end
    return false
end

-- ---------------------------------------------------------------- lookups
-- { fights, avgDur, lastDur, maxHP, hpWeight } for a mob of the current zone, or nil.
function M.mob(zoneName, mobName)
    if not snap or zoneName ~= zone then return nil end
    local zs = snap.zones[zone]
    if not zs then return nil end
    local mob = tostring(mobName):lower()
    local list, h = zs.windows.byMob[mob], zs.pool.hp[mob]
    if not list and not h then return nil end
    local rec = { fights = list and #list or 0, hpWeight = h and h.weight or 0 }
    if h and h.weight > 0 then rec.maxHP = h.sum / h.weight end
    if list and #list > 0 then
        local n = #list
        local sum, cnt = 0, 0
        for i = math.max(1, n - MAX_AVG_SAMPLES + 1), n do sum = sum + list[i].dur; cnt = cnt + 1 end
        rec.avgDur = cnt > 0 and (sum / cnt) or nil
        rec.lastDur = list[n].dur
    end
    return rec
end

-- { casts, hits, total, avgHit, resists, resistRate, avgHeal } for one of this character's
-- spells, or nil. Damage fields only when a damage rollup row was ever seen (a cast-only line
-- carries no resist rate), avgHeal only with landed heals.
function M.spell(character, spellName)
    if not snap or character ~= char then return nil end
    local s = snap.spells.stats[spellName]
    if not s then return nil end
    local out, any = {}, false
    if (s.dmgRows or 0) > 0 then
        out.casts, out.hits, out.total, out.resists = s.casts, s.hits, s.total, s.resists
        out.avgHit = s.hits > 0 and s.total / s.hits or nil
        out.resistRate = s.casts > 0 and s.resists / s.casts or nil
        any = true
    end
    if (s.healHits or 0) > 0 then
        out.avgHeal = s.healRaw / s.healHits
        any = true
    end
    return any and out or nil
end

-- { [ability] = { casts, resists } } pooled across every box on the mob, or nil.
function M.mobResist(zoneName, mobName)
    if not snap or zoneName ~= zone then return nil end
    local zs = snap.zones[zone]
    return zs and zs.pool.resist[tostring(mobName):lower()] or nil
end

function M.status()
    local out = { zone = zone, character = char, dirty = dirty, forceLeft = forceLeft, walkers = {} }
    for _, w in ipairs(walkerList()) do
        if w then
            out.walkers[#out.walkers + 1] = {
                name = w.spec.name, loaded = w.st.loaded, newest = w.st.newest, oldest = w.st.oldest,
                done = w.st.done, paused = w.paused, spentMs = w.spentMs,
            }
        end
    end
    return out
end

return M
