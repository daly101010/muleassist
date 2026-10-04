-- Run: luajit tests/test_history.lua   (from F:\lua\necrobrain)
package.path = './necrobrain/?.lua;./?.lua;' .. package.path
local F = require('tests.necrobrain_fakes')
local pass, fail = 0, 0
local function check(name, cond, detail)
  if cond then pass = pass + 1 else fail = fail + 1; io.write('FAIL: ' .. name .. (detail and (' -- ' .. tostring(detail)) or '') .. '\n') end
end
local H = require('history')

-- ---------------------------------------------------------------- fixture
-- Fights: three boxes share the db; own walkers see only Calbuss's fights, the pool sees the zone's.
local fights = {
  { id = 1, zone = 'Dranik', char = 'Calbuss', mob = 'a drachnid champion', maxHp = 40000, weight = 100, ended = 100 },
  { id = 2, zone = 'Dranik', char = 'Calbuss', mob = 'a drachnid champion', maxHp = 42000, weight = 200, ended = 200 },
  { id = 3, zone = 'Dranik', char = 'Daly',    mob = 'a drachnid champion', maxHp = 45000, weight = 300, ended = 250 },
  { id = 4, zone = 'Dranik', char = 'Calbuss', mob = 'a drachnid inquisitor', maxHp = nil, weight = 0, ended = 300 },
  { id = 5, zone = 'Other Zone', char = 'Calbuss', mob = 'a bat', maxHp = 1000, weight = 10, ended = 400 },
}
local charRows = { { character = 'Calbuss' }, { character = 'Daly' }, { character = 'Beyonce' } }

-- Event fixture (companion's 12s-lull "fight" chains many mobs into one row; CASTER windows are
-- reconstructed from raw cast/hit/kill rows). Ordered as WINDOW_BATCH_SQL returns them: by
-- ended_at, fight_id, LOWER(target), t.
--   fight 1: Daly's pull hits bracket Calbuss's own cast at t=12 (gaps all <= 8s); the kill lands
--     at t=31 -> window = 31-12 = 19 (start = own cast, end = slain line).
--   fight 2: 'a bat': only Daly hits, no own cast/hit and no kill -> no caster window.
--     'a drachnid champion' segment 1: no own cast row; Calbuss's own dot hit at t=8 is the start
--       fallback (8 - 3s typical cast time = 5); hits continue to t=20; kill at t=22 -> 17.
--     a 28s gap (22 -> 50, > 8s) splits the next segment, logged under the sentence-capitalized
--       'A drachnid champion': own cast at t=50, kill at t=58 -> 8. Case folds both into one mob.
--     'a drachnid inquisitor': single Daly hit -> skipped. 'Daly' -> a session character, excluded.
--     'Kontik' -> no space in the name (pet/player), excluded.
-- Expected champion windows in order: {19, 17, 8} -> fights=3, avgDur=(19+17+8)/3, lastDur=8.
local eventRows = {
  { fight_id = 1, target = 'a drachnid champion', t = 0,  kind = 'melee', source = 'Daly',    ended_at = 100 },
  { fight_id = 1, target = 'a drachnid champion', t = 6,  kind = 'melee', source = 'Daly',    ended_at = 100 },
  { fight_id = 1, target = 'a drachnid champion', t = 12, kind = 'cast',  source = 'Calbuss', ended_at = 100 },
  { fight_id = 1, target = 'a drachnid champion', t = 18, kind = 'melee', source = 'Daly',    ended_at = 100 },
  { fight_id = 1, target = 'a drachnid champion', t = 24, kind = 'melee', source = 'Daly',    ended_at = 100 },
  { fight_id = 1, target = 'a drachnid champion', t = 30, kind = 'melee', source = 'Daly',    ended_at = 100 },
  { fight_id = 1, target = 'a drachnid champion', t = 31, kind = 'kill',  source = 'Daly',    ended_at = 100 },
  { fight_id = 2, target = 'a bat', t = 0, kind = 'melee', source = 'Daly', ended_at = 200 },
  { fight_id = 2, target = 'a bat', t = 5, kind = 'melee', source = 'Daly', ended_at = 200 },
  { fight_id = 2, target = 'a drachnid champion', t = 0,  kind = 'melee', source = 'Daly',    ended_at = 200 },
  { fight_id = 2, target = 'a drachnid champion', t = 8,  kind = 'dot',   source = 'Calbuss', ended_at = 200 },
  { fight_id = 2, target = 'a drachnid champion', t = 14, kind = 'melee', source = 'Daly',    ended_at = 200 },
  { fight_id = 2, target = 'a drachnid champion', t = 20, kind = 'melee', source = 'Daly',    ended_at = 200 },
  { fight_id = 2, target = 'a drachnid champion', t = 22, kind = 'kill',  source = 'Daly',    ended_at = 200 },
  { fight_id = 2, target = 'A drachnid champion', t = 50, kind = 'cast',  source = 'Calbuss', ended_at = 200 },
  { fight_id = 2, target = 'A drachnid champion', t = 58, kind = 'kill',  source = 'Daly',    ended_at = 200 },
  { fight_id = 2, target = 'a drachnid inquisitor', t = 7, kind = 'melee', source = 'Daly', ended_at = 200 },
  { fight_id = 2, target = 'Daly',   t = 3, kind = 'melee', source = 'a drachnid champion', ended_at = 200 },
  { fight_id = 2, target = 'Kontik', t = 4, kind = 'melee', source = 'a drachnid champion', ended_at = 200 },
  { fight_id = 6, target = 'a bat', t = 2, kind = 'cast', source = 'Calbuss', ended_at = 500 },
  { fight_id = 6, target = 'a bat', t = 9, kind = 'kill', source = 'Daly', ended_at = 500 },
}

local MISTS = "Vakk`dra's Sickly Mists"
-- fight_ability rows: (fight, source, ability, kind, hits, total, resists, is_pet, over_total)
local abilityRows = {
  { 1, 'Calbuss', MISTS, 'dot', 1000, 1000000, 10, 0, 0 },
  { 2, 'Calbuss', MISTS, 'dot', 2136, 2924553, 26, 0, 0 },
  { 1, 'Calbuss', 'Dread Pyre', 'nuke', 1080, 1356686, 9, 0, 0 },
  { 1, 'Calbuss', 'Drain Life', 'nuke', 100, 250000, 2, 0, 0 },
  { 2, 'Calbuss', 'Drain Life', 'heal', 100, 200000, 0, 0, 100000 },   -- raw heal = 300000
  { 1, 'Calbuss', 'Touch of Iglum', 'heal', 2, 900, 0, 0, 100 },
  { 2, 'Calbuss', 'Touch of Iglum', 'heal', 2, 500, 0, 0, 500 },       -- 4 hits, raw 2000
  { 2, 'Calbuss', 'Touch of Iglum', 'heal', 9, 999, 0, 1, 0 },         -- pet: excluded
  { 2, 'Calbuss', 'Old Merged Tap', 'nuke', 4, 4000, 0, 0, 1200 },     -- pre-split merged row: excluded
  { 1, 'Daly', 'Slash', 'melee', 50, 50000, 0, 0, 0 },                 -- another source: excluded by SQL
  { 21, 'Calbuss', MISTS, 'dot', 64, 100000, 4, 0, 0 },                -- fight 21 appears later (forward)
}
-- fight_cast rows: (fight, source, spell, casts)
local castRows = {
  { 1, 'Calbuss', MISTS, 500 }, { 2, 'Calbuss', MISTS, 492 },
  { 1, 'Calbuss', 'Dread Pyre', 526 }, { 1, 'Calbuss', 'Drain Life', 110 },
  { 2, 'Calbuss', 'Cast Only Spell', 5 },
  { 21, 'Calbuss', MISTS, 8 },
}
-- resist events per fight (already aggregated per mob/ability the way RESIST_BATCH_SQL does)
local resistRows = {
  { 1, 'overlord mata muram', MISTS, 2, 1 },
  { 3, 'overlord mata muram', MISTS, 3, 2 },   -- Daly's box logged its own casts: pooled
  { 5, 'a bat', 'Dread Pyre', 1, 0 },
}

local calls, slow = {}, {}
local function bump(k) calls[k] = (calls[k] or 0) + 1 end
local function parseIds(sql)
  local set, list = {}, sql:match('IN %(([%d, ]+)%)')
  for id in (list or ''):gmatch('%d+') do set[tonumber(id)] = true end
  return set
end
local db = { nrows = function(_, sql)
  local rows, mark = {}, nil
  if sql:find('DISTINCT character', 1, true) then
    mark, rows = 'chars', charRows
  elseif sql:find('SELECT f.id AS id', 1, true) then
    local who = sql:match("s%.character = '([^']+)'")
    local zn = sql:match("f%.zone = '([^']+)'")
    local op, bound, dir, lim = sql:match('f%.id%s*([<>]=?)%s*(%d+)%s*ORDER BY f%.id (%u+) LIMIT (%d+)')
    bound, lim = tonumber(bound), tonumber(lim)
    mark = 'ids:' .. (who or '*') .. ':' .. (zn or '*')
    local list = {}
    for _, f in ipairs(fights) do
      if (not who or f.char == who) and (not zn or f.zone == zn)
        and ((op == '<' and f.id < bound) or (op == '>' and f.id > bound) or (op == '>=' and f.id >= bound)) then
        list[#list + 1] = f.id
      end
    end
    table.sort(list, function(a, b) if dir == 'DESC' then return a > b end return a < b end)
    for i = 1, math.min(lim, #list) do rows[#rows + 1] = { id = list[i] } end
  elseif sql:find('FROM fight_ability a', 1, true) then
    mark = 'ability'
    local ids, src = parseIds(sql), sql:match("a%.source = '([^']+)'")
    for _, r in ipairs(abilityRows) do
      if ids[r[1]] and r[2] == src then
        rows[#rows + 1] = { ability = r[3], kind = r[4], hits = r[5], total = r[6], resists = r[7], is_pet = r[8], over_total = r[9] }
      end
    end
  elseif sql:find('FROM fight_cast c', 1, true) then
    mark = 'cast'
    local ids, src = parseIds(sql), sql:match("c%.source = '([^']+)'")
    for _, r in ipairs(castRows) do
      if ids[r[1]] and r[2] == src then rows[#rows + 1] = { ability = r[3], casts = r[4] } end
    end
  elseif sql:find('CROSS JOIN event e ON e.fight_id = f.id', 1, true) then
    mark = 'window'
    local ids = parseIds(sql)
    for _, r in ipairs(eventRows) do if ids[r.fight_id] then rows[#rows + 1] = r end end
  elseif sql:find('primary_target', 1, true) then
    mark = 'hp'
    local ids = parseIds(sql)
    for _, f in ipairs(fights) do
      if ids[f.id] and f.mob then rows[#rows + 1] = { mob = f.mob, max_hp = f.maxHp, hp_weight = f.weight } end
    end
  elseif sql:find("e.outcome = 'resist'", 1, true) then
    mark = 'resist'
    local ids = parseIds(sql)
    for _, r in ipairs(resistRows) do
      if ids[r[1]] then rows[#rows + 1] = { mob = r[2], ability = r[3], casts = r[4], resists = r[5] } end
    end
  else
    error('unexpected sql: ' .. sql)
  end
  bump(mark)
  if slow[mark] then F.now = F.now + slow[mark] end
  local i = 0
  return function() i = i + 1; return rows[i] end
end }

-- in-memory snapshot store (deep copies, like a pickle round trip)
local store, saves = {}, 0
local function copy(t)
  if type(t) ~= 'table' then return t end
  local o = {}
  for k, v in pairs(t) do o[k] = copy(v) end
  return o
end
H.store = { load = function(path) return copy(store[path]) end, save = function(path, t) store[path] = copy(t); saves = saves + 1 end }

local function status(name)
  for _, w in ipairs(H.status().walkers) do if w.name == name then return w end end
end
local function stepAll(zone, maxSteps)
  for _ = 1, maxSteps or 60 do
    F.now = F.now + 200
    H.step(zone, F.now)
  end
end
local function allDone()
  local s = H.status()
  return s.walkers[1].done and s.walkers[2].done and s.walkers[3].done
end

-- ---------------------------------------------------------------- first session
H.attach(db)
F.now = 100000
check('open without a snapshot reports so', H.open('lethar', 'Calbuss', 'Dranik') == false)
check('open reads the character list only', calls.chars == 1 and calls.ability == nil and calls.window == nil and calls.hp == nil)
check('no data before the first step', H.mob('Dranik', 'a drachnid champion') == nil and H.spell('Calbuss', MISTS) == nil)
check('quote escaping', H._q("Vakk`dra's") == "'Vakk`dra''s'")

stepAll('Dranik')
check('all walkers finish the small history', allDone(), (function()
  local p = {}
  for _, w in ipairs(H.status().walkers) do p[#p + 1] = w.name .. '=' .. tostring(w.loaded) .. '/' .. tostring(w.done) end
  return table.concat(p, ' ')
end)())
check('windows walked Calbuss\'s three Dranik fights, pool the zone\'s four, spells all four of hers',
  status('windows').loaded == 3 and status('pool').loaded == 4 and status('spells').loaded == 4,
  string.format('windows=%s pool=%s spells=%s', tostring(status('windows').loaded), tostring(status('pool').loaded), tostring(status('spells').loaded)))
check('own walkers bind the character, the windows walker the zone too, the pool only the zone',
  calls['ids:Calbuss:*'] and calls['ids:Calbuss:Dranik'] and calls['ids:*:Dranik'] and not calls['ids:*:*'])

local m = H.mob('Dranik', 'a drachnid champion')
local expectedAvg = (19 + 17 + 8) / 3
local expectedHp = (40000 * 100 + 42000 * 200 + 45000 * 300) / 600
check('mob: caster windows from own fights, max HP pooled across boxes',
  m and m.fights == 3 and m.avgDur and math.abs(m.avgDur - expectedAvg) < 1e-9 and m.lastDur == 8
    and m.maxHP and math.abs(m.maxHP - expectedHp) < 1e-6 and m.hpWeight == 600,
  m and string.format('fights=%s avgDur=%s lastDur=%s maxHP=%s weight=%s', tostring(m.fights), tostring(m.avgDur), tostring(m.lastDur), tostring(m.maxHP), tostring(m.hpWeight)))
check('mob lookup case-insensitive', (H.mob('Dranik', 'A Drachnid Champion') or {}).fights == 3)
local inq = H.mob('Dranik', 'a drachnid inquisitor')
check('mob without windows or HP samples still present', inq and inq.fights == 0 and inq.maxHP == nil and inq.hpWeight == 0, inq)
check('other zone\'s mob nil', H.mob('Dranik', 'a bat') == nil)
check('unknown zone nil', H.mob('Other Zone', 'a bat') == nil)

local s = H.spell('Calbuss', MISTS)
check('spell avg hit and resist rate sum the per-fight rows', s and math.abs(s.avgHit - 1251.5) < 1 and math.abs(s.resistRate - 36 / 992) < 1e-6 and s.casts == 992,
  s and string.format('avgHit=%s rate=%s casts=%s', tostring(s.avgHit), tostring(s.resistRate), tostring(s.casts)))
check('damage spell without heal rows has no avgHeal', s and s.avgHeal == nil)
local iglum = H.spell('Calbuss', 'Touch of Iglum')
check('heal-only spell: avgHeal from effective+overheal, pet row excluded, no damage stats',
  iglum and iglum.avgHeal and math.abs(iglum.avgHeal - 500) < 1e-9 and iglum.avgHit == nil and iglum.resistRate == nil, iglum and tostring(iglum.avgHeal))
local pyre = H.spell('Calbuss', 'Dread Pyre')
check('zero heal hits -> no avgHeal, damage stats kept', pyre and pyre.avgHeal == nil and pyre.avgHit ~= nil)
local tap = H.spell('Calbuss', 'Drain Life')
check('lifetap merges damage and heal stats',
  tap and tap.avgHit and tap.avgHeal and tap.resistRate and math.abs(tap.avgHit - 2500) < 1e-9
    and math.abs(tap.avgHeal - 3000) < 1e-9 and math.abs(tap.resistRate - 2 / 110) < 1e-9,
  tap and string.format('avgHit=%s avgHeal=%s rate=%s', tostring(tap.avgHit), tostring(tap.avgHeal), tostring(tap.resistRate)))
check('merged pre-split tap row excluded', H.spell('Calbuss', 'Old Merged Tap') == nil)
check('a cast-only line carries no stats', H.spell('Calbuss', 'Cast Only Spell') == nil)
check('another character\'s spell nil', H.spell('Daly', 'Slash') == nil and H.spell('Beyonce', MISTS) == nil)

local mr = H.mobResist('Dranik', 'Overlord Mata Muram')
check('pooled resists sum every box\'s fights in the zone', mr and mr[MISTS] and mr[MISTS].casts == 5 and mr[MISTS].resists == 3,
  mr and mr[MISTS] and (mr[MISTS].casts .. '/' .. mr[MISTS].resists))
check('pooled resists are zone-bound', H.mobResist('Other Zone', 'a bat') == nil)
check('nothing saved yet while under the save cadence', saves == 0)

-- ---------------------------------------------------------------- budget
H.setZone('Other Zone')
check('zone change flushes the snapshot', saves == 1)
check('the new zone starts with fresh walkers', status('windows').loaded == 0 and status('pool').loaded == 0 and status('spells').done == true)
slow.window = 60
stepAll('Other Zone', 6)
local w = status('windows')
check('a slow windows step pauses that walker with its batch kept', w.paused and w.paused:find('not cached', 1, true) and w.loaded == 1 and w.spentMs == 60,
  string.format('paused=%s loaded=%s spent=%s', tostring(w.paused), tostring(w.loaded), tostring(w.spentMs)))
check('the pool walker is unaffected', status('pool').done == true and status('pool').loaded == 1 and status('pool').paused == nil)
check('paused walker still serves what it read', (H.mob('Other Zone', 'a bat') or {}).maxHP == 1000)
slow.window = nil
local before = calls['ids:Calbuss:Other Zone']
fights[#fights + 1] = { id = 6, zone = 'Other Zone', char = 'Calbuss', mob = 'a bat', maxHp = 1200, weight = 10, ended = 500 }
F.now = F.now + H.FORWARD_MS
stepAll('Other Zone', 3)
check('a paused walker does not catch up at the normal forward cadence', calls['ids:Calbuss:Other Zone'] == before and status('windows').loaded == 1)
F.now = F.now + H.RETRY_MS
stepAll('Other Zone', 3)
check('after RETRY_MS the paused walker folds the new fight', status('windows').loaded == 2 and (H.mob('Other Zone', 'a bat') or {}).fights == 1,
  string.format('loaded=%s fights=%s', tostring(status('windows').loaded), tostring((H.mob('Other Zone', 'a bat') or {}).fights)))
check('the pool caught fight 6 at the normal cadence', status('pool').loaded == 2)

-- cumulative budget: steps under SLOW_MS still add up
H.setZone('Dranik')
H.BUDGET_MS = 100
local saved = H.WINDOWS.cap
H.WINDOWS.cap = 100
for i = 10, 20 do fights[#fights + 1] = { id = i, zone = 'Budget Zone', char = 'Calbuss', mob = 'a rat', maxHp = nil, weight = 0, ended = 1000 + i } end
slow.window = 30
H.setZone('Budget Zone')
stepAll('Budget Zone', 30)
w = status('windows')
check('the per-session budget pauses a walker whose steps add up', w.paused and w.paused:find('budget', 1, true) and w.loaded == 4 and w.spentMs == 120,
  string.format('paused=%s loaded=%s spent=%s', tostring(w.paused), tostring(w.loaded), tostring(w.spentMs)))
slow.window = nil
H.BUDGET_MS = 500

-- forced backfill ignores the pause and the budget, then saves
slow.window = 80
local savesBefore = saves
H.force(50)
check('force is reported in status', H.status().forceLeft == 50)
stepAll('Budget Zone', 5)
w = status('windows')
check('forced steps read the rest of the zone regardless of speed', w.done == true and w.loaded == 11, string.format('done=%s loaded=%s', tostring(w.done), tostring(w.loaded)))
check('forced backfill ends with a save', H.status().forceLeft == 0 and saves == savesBefore + 1)
slow.window = nil
H.WINDOWS.cap = saved

-- ---------------------------------------------------------------- second session (snapshot)
H.setZone('Dranik')
H.close()
local callsBefore = copy(calls)
F.now = 900000
check('open restores the snapshot', H.open('lethar', 'Calbuss', 'Dranik') == true)
m = H.mob('Dranik', 'a drachnid champion')
check('restored mob history is available at once, without fight queries',
  m and m.fights == 3 and math.abs(m.maxHP - expectedHp) < 1e-6 and calls.window == callsBefore.window and calls.hp == callsBefore.hp)
s = H.spell('Calbuss', MISTS)
check('restored spell stats are available at once', s and s.casts == 992 and calls.ability == callsBefore.ability)
check('restored walkers are done', status('windows').done and status('pool').done and status('spells').done)
-- the global spells walker lagged the fixture's later fights (6, 10-20): done walkers keep looking
-- forward at the forward cadence until they have caught up
for _ = 1, 6 do F.now = F.now + H.FORWARD_MS; stepAll('Dranik', 3) end
check('restored walkers catch up on fights saved since the snapshot', status('spells').loaded == 16
  and status('windows').loaded == 3 and status('pool').loaded == 4,
  string.format('spells=%s windows=%s pool=%s', tostring(status('spells').loaded), tostring(status('windows').loaded), tostring(status('pool').loaded)))

-- forward: a fight saved during the session is folded in at the forward cadence
fights[#fights + 1] = { id = 21, zone = 'Dranik', char = 'Calbuss', mob = 'a drachnid champion', maxHp = 50000, weight = 100, ended = 2000 }
F.now = F.now + H.FORWARD_MS
stepAll('Dranik', 3)
s = H.spell('Calbuss', MISTS)
check('new own fight folded into spell stats', s and s.casts == 1000 and s.hits == 3200 and s.resists == 40,
  s and string.format('casts=%s hits=%s resists=%s', tostring(s.casts), tostring(s.hits), tostring(s.resists)))
m = H.mob('Dranik', 'a drachnid champion')
check('new fight folded into the pool\'s max HP', m and m.hpWeight == 700, m and tostring(m.hpWeight))

-- zone switching keeps every zone's data in the snapshot
H.setZone('Other Zone')
check('old zone is not served while another is selected', H.mob('Dranik', 'a drachnid champion') == nil)
check('the other zone comes back from the snapshot', (H.mob('Other Zone', 'a bat') or {}).fights == 1)
H.setZone('Dranik')
check('switching back needs no re-walk', (H.mob('Dranik', 'a drachnid champion') or {}).fights == 3 and status('windows').done == true)

-- ---------------------------------------------------------------- caps and failures
store = {}
H.WINDOWS.cap = 2
H.POOL.cap = 4
H.open('lethar', 'Calbuss', 'Dranik')
stepAll('Dranik')
check('caps bound the backward walk', status('windows').loaded == 2 and status('windows').done and status('pool').loaded == 4 and status('pool').done,
  string.format('windows=%s pool=%s', tostring(status('windows').loaded), tostring(status('pool').loaded)))
H.WINDOWS.cap = 40
H.POOL.cap = 200

H.attach({ nrows = function() error('simulated query failure') end })
store = {}
local okOpen = pcall(H.open, 'lethar', 'Calbuss', 'Dranik')
local okStep = okOpen and pcall(stepAll, 'Dranik', 5)
check('query failures neither throw nor leave stale data', okOpen and okStep and H.mob('Dranik', 'a drachnid champion') == nil and H.spell('Calbuss', MISTS) == nil)

-- segmentation unit: the classic windows
H.attach(db)
local wins = H._segmentWindows(eventRows, 'Calbuss', { calbuss = true, daly = true })
local durs = {}
for _, x in ipairs(wins) do if x.mob == 'a drachnid champion' then durs[#durs + 1] = x.dur end end
check('segmentation yields {19, 17, 8} for the champion', #durs == 3 and durs[1] == 19 and durs[2] == 17 and durs[3] == 8, table.concat(durs, ','))

-- a ranked spell pools under its base name: cast rows read 'Curse of Mortality Rk' (companion's capture
-- stops at the first period), resist rows 'Curse of Mortality Rk. II'
fights[#fights + 1] = { id = 7, zone = 'Ranked', char = 'Calbuss', mob = 'a lich', maxHp = 5000, weight = 10, ended = 700 }
resistRows[#resistRows + 1] = { 7, 'a lich', 'Curse of Mortality Rk', 3, 0 }
resistRows[#resistRows + 1] = { 7, 'a lich', 'Curse of Mortality Rk. II', 0, 2 }
H.attach(db)
H.open('lethar', 'Ranker', 'Ranked')
stepAll('Ranked', 10)
local lich = H.mobResist('Ranked', 'a lich')
local com = lich and lich['Curse of Mortality']
check('rank suffixes pool under the base spell name', com and com.casts == 3 and com.resists == 2 and lich['Curse of Mortality Rk'] == nil,
  com and (com.casts .. '/' .. com.resists) or 'no record')

-- a snapshot saved with raw-name resist keys is folded under the base name on open
lich['Curse of Mortality'] = nil
lich['Curse of Mortality Rk'] = { casts = 3, resists = 0 }
lich['Curse of Mortality Rk. II'] = { casts = 0, resists = 2 }
H.close()
local RANKER = 'F:/Config/necrobrain_lethar_Ranker.lua'
check('a saved snapshot is marked folded', store[RANKER] and store[RANKER].resistFolded == true)
store[RANKER].resistFolded = nil   -- as an older build saved it
check('reopen restores the snapshot', H.open('lethar', 'Ranker', 'Ranked') == true)
local lich2 = H.mobResist('Ranked', 'a lich') or {}
local com2 = lich2['Curse of Mortality']
check('raw-name resist keys are migrated on open', com2 and com2.casts == 3 and com2.resists == 2 and lich2['Curse of Mortality Rk. II'] == nil,
  com2 and (com2.casts .. '/' .. com2.resists) or 'no record')

-- the fold runs once per snapshot: a marked snapshot skips it, an unmarked one folds and is marked on save,
-- and both paths answer the same
H.close()
check('the folded snapshot is marked on save', store[RANKER].resistFolded == true)
local foldCalls = 0
local realFold = H.foldResist
H.foldResist = function(t) foldCalls = foldCalls + 1; return realFold(t) end
H.open('lethar', 'Ranker', 'Ranked')
check('a marked snapshot skips the fold', foldCalls == 0, foldCalls)
local lich3 = H.mobResist('Ranked', 'a lich') or {}
check('a marked snapshot answers as before', lich3['Curse of Mortality'] and lich3['Curse of Mortality'].casts == 3
  and lich3['Curse of Mortality'].resists == 2)
H.close()
-- an unmarked snapshot (an older build's) with raw keys: folds exactly once, then is marked
store[RANKER].resistFolded = nil
store[RANKER].zones.Ranked.pool.resist['a lich'] = { ['Curse of Mortality Rk'] = { casts = 3, resists = 0 },
  ['Curse of Mortality Rk. II'] = { casts = 0, resists = 2 }, Bonebreaker = { casts = '4', resists = 1 } }
H.open('lethar', 'Ranker', 'Ranked')
check('an unmarked snapshot folds once', foldCalls == 1, foldCalls)
local unmarked = H.mobResist('Ranked', 'a lich') or {}
H.close()
check('the unmarked snapshot is marked on the next save', store[RANKER].resistFolded == true)
H.open('lethar', 'Ranker', 'Ranked')
check('and the next open skips the fold', foldCalls == 1, foldCalls)
local marked = H.mobResist('Ranked', 'a lich') or {}
local function same(a, b)
  for k, v in pairs(a) do if not (b[k] and b[k].casts == v.casts and b[k].resists == v.resists) then return false end end
  for k in pairs(b) do if not a[k] then return false end end
  return true
end
check('folded and marked paths give identical records', same(unmarked, marked) and unmarked['Curse of Mortality']
  and unmarked['Curse of Mortality'].casts == 3 and unmarked['Curse of Mortality'].resists == 2
  and unmarked.Bonebreaker.casts == 4 and unmarked['Curse of Mortality Rk'] == nil)
H.close()
H.foldResist = realFold
-- foldResist leaves a mob with no ranked key as it is and merges only mobs that have one
local unranked = { Bonebreaker = { casts = 4, resists = 1 }, ['Curse of Mortality'] = { casts = 2, resists = 0 } }
local ranked = { ['Splurt Rk. II'] = { casts = 1, resists = 1 }, Splurt = { casts = 2, resists = 0 } }
local foldSnap = { zones = { Z = { pool = { resist = { ['a rat'] = unranked, ['a bat'] = ranked } } } } }
H.foldResist(foldSnap)
local zr = foldSnap.zones.Z.pool.resist
check('fold keeps an unranked mob untouched', zr['a rat'] == unranked and zr['a rat'].Bonebreaker.casts == 4)
check('fold merges a ranked mob', zr['a bat'] ~= ranked and zr['a bat'].Splurt.casts == 3 and zr['a bat'].Splurt.resists == 1
  and zr['a bat']['Splurt Rk. II'] == nil)
H.foldResist({})   -- no zones: nothing to do, no error
-- an old snapshot that had to be folded is dirty from the start (its mark reaches disk at the next flush,
-- even without M.close); a marked one is not
store = { ['F:/Config/necrobrain_lethar_Dirty.lua'] = { v = H.SNAPSHOT_VERSION, chars = {},
  spells = { st = { loaded = 0 }, stats = {} }, zones = {} } }
H.open('lethar', 'Dirty', 'Ranked')
check('an unmarked snapshot opens dirty', H.status().dirty == true)
H.close()
H.open('lethar', 'Dirty', 'Ranked')
check('a marked snapshot opens clean', H.status().dirty == false)
H.close()
-- a brand-new snapshot is born folded (the pool walker keys by base name)
store = {}
H.open('lethar', 'Fresh', 'Ranked')
H.close()
check('a new snapshot is saved marked', store['F:/Config/necrobrain_lethar_Fresh.lua'].resistFolded == true)
-- baseSpell: the fast path returns the name unchanged; ranked names still lose the suffix
check('baseSpell fast path', H._baseSpell('Bonebreaker') == 'Bonebreaker' and H._baseSpell(nil) == ''
  and H._baseSpell('Curse of Mortality Rk. II') == 'Curse of Mortality' and H._baseSpell('Curse of Mortality Rk') == 'Curse of Mortality'
  and H._baseSpell('Rkxyz Bolt') == 'Rkxyz Bolt')

-- a failed query is not an empty history: no done latch, the batch is retried after RETRY_MS
local flaky = false
local flakyDb = { nrows = function(_, sql)
  if flaky then error('database is locked') end
  return db.nrows(db, sql)
end }
H.attach(flakyDb)
local dranikCount, dranikNewest = 0, 0
for _, f in ipairs(fights) do if f.zone == 'Dranik' then dranikCount = dranikCount + 1; if f.id > dranikNewest then dranikNewest = f.id end end end
H.open('lethar', 'Flaky', 'Dranik')
flaky = true
F.now = F.now + 1000
for _ = 1, 3 do H.step('Dranik', F.now) end
local p = status('pool')
check('a failed first batch does not latch done', p.done == false and p.newest == nil and p.loaded == 0,
  string.format('done=%s newest=%s loaded=%s', tostring(p.done), tostring(p.newest), tostring(p.loaded)))
flaky = false
F.now = F.now + 1000
local queried = false
for _ = 1, 3 do if H.step('Dranik', F.now) then queried = true end end
check('the first-batch retry waits for RETRY_MS', not queried and status('pool').loaded == 0)
F.now = F.now + H.RETRY_MS
for _ = 1, 3 do H.step('Dranik', F.now) end
p = status('pool')
check('the retried first batch loads the newest fights', p.newest == dranikNewest and p.loaded == H.POOL.batch,
  string.format('newest=%s loaded=%s', tostring(p.newest), tostring(p.loaded)))
flaky = true
F.now = F.now + 1000
for _ = 1, 3 do H.step('Dranik', F.now) end
p = status('pool')
check('a failed backfill batch does not latch done', p.done == false and p.loaded == H.POOL.batch,
  string.format('done=%s loaded=%s', tostring(p.done), tostring(p.loaded)))
flaky = false
F.now = F.now + 1000
queried = false
for _ = 1, 3 do if H.step('Dranik', F.now) then queried = true end end
check('the backfill retry waits for RETRY_MS', not queried and status('pool').loaded == H.POOL.batch)
F.now = F.now + H.RETRY_MS
stepAll('Dranik', 12)
p = status('pool')
check('the backfill resumes after the retry', p.loaded == dranikCount, string.format('loaded=%s done=%s', tostring(p.loaded), tostring(p.done)))

-- a failed batch query (the id sequence answered, the batch did not) leaves the cursor alone
local batchFails = false
local batchDb = { nrows = function(_, sql)
  if batchFails and sql:find('primary_target', 1, true) then error('database is locked') end
  return db.nrows(db, sql)
end }
H.attach(batchDb)
store = {}
H.open('lethar', 'BatchFail', 'Dranik')
batchFails = true
F.now = F.now + 1000
for _ = 1, 3 do H.step('Dranik', F.now) end
p = status('pool')
check('a failed batch query folds nothing and moves no cursor', p.loaded == 0 and p.newest == nil and p.done == false,
  string.format('loaded=%s newest=%s done=%s', tostring(p.loaded), tostring(p.newest), tostring(p.done)))
check('... and leaves no half-folded data', H.mob('Dranik', 'a drachnid champion') == nil or (H.mob('Dranik', 'a drachnid champion').hpWeight or 0) == 0)
batchFails = false
F.now = F.now + H.RETRY_MS + 1000
stepAll('Dranik', 20)
p = status('pool')
check('the failed batch is read again after the retry', p.loaded == dranikCount and p.done == true,
  string.format('loaded=%s done=%s', tostring(p.loaded), tostring(p.done)))

-- no database at all: nothing is latched 'done', and a later session with the database reads everything
H.attach(nil)
store = {}
H.open('lethar', 'NoDb', 'Dranik')
stepAll('Dranik', 10)
p = status('pool')
check('no database: walkers are not latched done', p.done == false and p.newest == nil and status('spells').done == false,
  string.format('pool done=%s newest=%s', tostring(p.done), tostring(p.newest)))
H.close()
H.attach(db)
H.open('lethar', 'NoDb', 'Dranik')
stepAll('Dranik', 20)
check('the next session with the database reads the zone', status('pool').loaded == dranikCount, status('pool').loaded)

-- a snapshot an older build latched 'done' with nothing read is started over on open
local latched = function() return { newest = 0, oldest = 0, done = true, loaded = 0 } end
store = { ['F:/Config/necrobrain_lethar_Latched.lua'] = { v = H.SNAPSHOT_VERSION, chars = {},
  spells = { st = latched(), stats = {} },
  zones = { Dranik = { windows = { st = latched(), byMob = {} }, pool = { st = latched(), hp = {}, resist = {} } } } } }
H.attach(db)
check('the latched snapshot restores', H.open('lethar', 'Latched', 'Dranik') == true)
stepAll('Dranik', 20)
check('a latched-empty walker is started over', status('pool').loaded == dranikCount, status('pool').loaded)

-- an older build latched a partly walked cursor 'done' on a failed query: cleared on open, the walk
-- goes on past its oldest and latches again only on a real empty answer
H.attach(db)
store = {}
H.open('lethar', 'Partial', 'Dranik')
stepAll('Dranik', 20)
local full = status('pool').loaded
local snapZ = store['F:/Config/necrobrain_lethar_Partial.lua']
H.close()
snapZ = store['F:/Config/necrobrain_lethar_Partial.lua']
local pst = snapZ.zones.Dranik.pool.st
check('this build marks its latches', pst.done == true and pst.doneOk == true)
-- rewind the pool to its newest fight only, latched the old way
local keep = pst.newest
snapZ.zones.Dranik.pool = { st = { newest = keep, oldest = keep, done = true, loaded = 1 }, hp = {}, resist = {} }
H.open('lethar', 'Partial', 'Dranik')
stepAll('Dranik', 20)
check('a legacy partial latch walks on past its oldest', status('pool').loaded == full and status('pool').done == true,
  string.format('loaded=%s of %s', tostring(status('pool').loaded), tostring(full)))
H.close()

-- a forced run stops on the first failed query instead of spinning through its steps
local failCalls = 0
H.attach({ nrows = function() failCalls = failCalls + 1; error('database is locked') end })
store = {}
H.open('lethar', 'ForceFail', 'Dranik')
failCalls = 0
H.force(400)
H.step('Dranik', F.now + 200)
check('forced run stops after one failed query', failCalls == 1 and H.status().forceLeft == 0, failCalls)
H.close()

-- no database at load: the opener is retried by /necrobrain backfill and on the minute
local opens, openOk = 0, false
H.attach(nil, function() opens = opens + 1; return openOk and db or nil end)
store = {}
H.open('lethar', 'LateDb', 'Dranik')
H.force(50)
check('backfill without a database does not start', H.status().forceLeft == 0 and opens == 1)
openOk = true
H.force(50)
stepAll('Dranik', 5)
check('backfill opens the database once it is there and reads', opens == 2 and H.handle() == db and status('pool').loaded == dranikCount,
  string.format('opens=%d loaded=%s', opens, tostring(status('pool').loaded)))
H.close()
opens, openOk = 0, false
H.attach(nil)
store = {}
H.open('lethar', 'LateDb2', 'Dranik')
stepAll('Dranik', 3)
check('a failed reopen is not retried inside the minute', opens <= 1, opens)
openOk = true
F.now = F.now + H.RETRY_MS + 1
stepAll('Dranik', 20)
check('the minute retry opens the database and the walkers read', H.handle() == db and status('pool').loaded == dranikCount,
  string.format('opens=%d loaded=%s', opens, tostring(status('pool').loaded)))
H.close()
H.attach(db, false)

io.write(string.format('test_history: %d passed, %d failed\n', pass, fail))
os.exit(fail == 0 and 0 or 1)
