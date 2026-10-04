-- Run: luajit tests/test_holds.lua   (from F:\lua\necrobrain)
package.path = './necrobrain/?.lua;./?.lua;' .. package.path
require('tests.necrobrain_fakes')
local pass, fail = 0, 0
local function check(name, cond, detail)
  if cond then pass = pass + 1 else fail = fail + 1; io.write('FAIL: ' .. name .. (detail and (' -- ' .. tostring(detail)) or '') .. '\n') end
end
local Holds = require('holds')

-- ID-keyed record from a CAST_SUCCESS ack
local h = Holds.new()
h:set('Ashengate Pyre', 101, 'a stalking feran', 30000, { dot = true, why = 'DoT running' })
check('find by spawn ID', h:find('Ashengate Pyre', 101, 'a stalking feran', 1000) ~= nil)
check('a same-named second mob is not held', h:find('Ashengate Pyre', 102, 'a stalking feran', 1000) == nil)
check('another spell is not held', h:find('Venin', 101, 'a stalking feran', 1000) == nil)
check('expired record is gone', h:find('Ashengate Pyre', 101, 'a stalking feran', 30000) == nil)
check('expired record was dropped', next(h.bySpell['Ashengate Pyre']) == nil)

-- the same DoT on two mobs at once
h = Holds.new()
h:set('Ashengate Pyre', 101, 'a feran', 30000, { dot = true })
h:set('Ashengate Pyre', 102, 'a feran', 40000, { dot = true })
check('two mobs, two records', h:find('Ashengate Pyre', 101, 'a feran', 0)['until'] == 30000
  and h:find('Ashengate Pyre', 102, 'a feran', 0)['until'] == 40000)

-- a feed tick refines the per-tick amount; the chat line capitalizes the article
h = Holds.new()
h:set("Vakk`dra's Sickly Mists", 101, 'a feran', 42000, { dot = true })
local rec = h:tick("Vakk`dra's Sickly Mists", 'A feran', 1010, 6000)
check('tick matches the chat name case-insensitively', rec ~= nil and rec.perTick == 1010, rec and rec.perTick)
check('tick for an unheld spell is ignored', h:tick('Ashengate Pyre', 'A feran', 1434, 6000) == nil)
h:set("Vakk`dra's Sickly Mists", 101, 'a feran', 50000, { dot = true })
check('a refreshed record keeps the learned per-tick', h:find("Vakk`dra's Sickly Mists", 101, 'a feran', 0).perTick == 1010)

-- name-only records (feed, shadow mode): matched by lowercased name, superseded by an ID record
h = Holds.new()
h:set('Curse of Mortality', nil, 'A Feran', 30000, { dot = true, perTick = 1463 })
check('name-only record matches any spawn of that name', h:find('Curse of Mortality', 555, 'a feran', 0) ~= nil)
h:set('Curse of Mortality', 101, 'a feran', 31000, { dot = true })
check('an ID record replaces the name-only one', h:find('Curse of Mortality', 555, 'a feran', 0) == nil)
check('and keeps the per-tick the name-only one learned', h:find('Curse of Mortality', 101, 'a feran', 0).perTick == 1463)

-- running DoTs on one mob, for the DfB look-ahead
h = Holds.new()
h:set('Ashengate Pyre', 101, 'a feran', 30000, { dot = true, perTick = 1434 })
h:set("Vakk`dra's Sickly Mists", 101, 'a feran', 42000, { dot = true })
h:set('Venin', 101, 'a feran', 10000, { dot = false, why = 'macro recast timer' })
h:set('Curse of Mortality', 102, 'a feran', 30000, { dot = true })
local run = h:running(101, 'a feran', 6000)
check('running lists only DoTs on this mob', #run == 2, #run)
check('running carries time left', run[1].spell == 'Ashengate Pyre' and math.abs(run[1].leftSec - 24) < 1e-9, run[1] and run[1].leftSec)
check('running keeps an unseen per-tick as nil', run[2].perTick == nil)

-- prune: expiry and dead spawns
h:prune(6000, function(id) return id ~= 102 end)
check('prune drops a dead spawn', h:find('Curse of Mortality', 102, 'a feran', 6000) == nil)
check('prune keeps a live one', h:find('Ashengate Pyre', 101, 'a feran', 6000) ~= nil)
h:prune(50000)
check('prune drops everything expired', next(h.bySpell) == nil)
h:set('Venin', 101, 'a feran', 10000)
h:set('Venin', 103, 'a feran', 10000)
local t = h:targets(); table.sort(t)
check('targets lists every held spawn once', #t == 2 and t[1] == 101 and t[2] == 103, #t)

-- learned stacking (review item 5): only my own DoTs, only after two agreeing "did not take hold"
local blockers = {}
check('no candidates: nothing learned', Holds.learnBlock(blockers, 'Dread Pyre', {}) == nil and blockers['Dread Pyre'] == nil)
local got, confirmed = Holds.learnBlock(blockers, 'Dread Pyre', { 'Ashengate Pyre' })
check('first observation is recorded, not yet confirmed', got and got[1] == 'Ashengate Pyre' and not confirmed)
h = Holds.new()
h:set('Ashengate Pyre', 101, 'a feran', 30000, { dot = true })
check('an unconfirmed pair blocks nothing', h:blockedBy(blockers, 'Dread Pyre', 101, 'a feran', 1000) == nil)
got, confirmed = Holds.learnBlock(blockers, 'Dread Pyre', { 'Ashengate Pyre' })
check('second agreeing observation confirms', confirmed == true)
check('blocked while my blocker runs on that spawn', h:blockedBy(blockers, 'Dread Pyre', 101, 'a feran', 1000) == 'Ashengate Pyre')
check('not blocked on another spawn of the same name', h:blockedBy(blockers, 'Dread Pyre', 102, 'a feran', 1000) == nil)
check('not blocked once my blocker expires', h:blockedBy(blockers, 'Dread Pyre', 101, 'a feran', 30000) == nil)
check('unrelated spell never blocked', h:blockedBy(blockers, 'Venin', 101, 'a feran', 1000) == nil)
-- a name-only record (feed, shadow mode) never proves a block on any spawn
h2 = Holds.new()
h2:set('Ashengate Pyre', nil, 'a feran', 30000, { dot = true })
check('a name-only blocker blocks nothing', h2:blockedBy(blockers, 'Dread Pyre', 101, 'a feran', 1000) == nil)
-- a takehold lock (not a DoT) never blocks
h:set('Curse of Mortality', 101, 'a feran', 30000, { dot = false, why = 'did not take hold' })
local cb = { X = { set = { ['Curse of Mortality'] = true }, n = 2 } }
check('a non-DoT record (a takehold lock) never blocks', h:blockedBy(cb, 'X', 101, 'a feran', 1000) == nil)
-- narrowing: two candidates, then one of them
blockers = {}
Holds.learnBlock(blockers, 'Dread Pyre', { 'Ashengate Pyre', 'Pyre of Mori' })
got, confirmed = Holds.learnBlock(blockers, 'Dread Pyre', { 'Ashengate Pyre' })
check('narrowed to what was running both times, and confirmed', #got == 1 and got[1] == 'Ashengate Pyre' and confirmed)
got, confirmed = Holds.learnBlock(blockers, 'Dread Pyre', { 'Pyre of Mori' })
check('no overlap: start over from the new evidence, unconfirmed', #got == 1 and got[1] == 'Pyre of Mori' and not confirmed)
check('a spell never blocks itself', Holds.learnBlock(blockers, 'Ashengate Pyre', { 'Ashengate Pyre' }) == nil)
-- unlearning: the spell landed while its supposed blocker ran
blockers = { ['Corath Venom'] = { set = { ["Vakk`dra's Sickly Mists"] = true }, n = 2 } }
check('landing under the blocker unlearns it', Holds.unlearnBlock(blockers, 'Corath Venom', { "Vakk`dra's Sickly Mists" }) and blockers['Corath Venom'] == nil)
-- a |once DoT: locked 5 min, but on the mob (and blocking) only for its duration
h = Holds.new()
h:set('Ashengate Pyre', 101, 'a feran', 300000, { dot = true, dotUntil = 30000 })
blockers = { ['Dread Pyre'] = { set = { ['Ashengate Pyre'] = true }, n = 2 } }
check('|once DoT: still locked after it ended', h:find('Ashengate Pyre', 101, 'a feran', 40000) ~= nil)
check('|once DoT: no longer running or blocking after it ended', #h:running(101, 'a feran', 40000) == 0
  and h:blockedBy(blockers, 'Dread Pyre', 101, 'a feran', 40000) == nil)
check('|once DoT: running and blocking while it ticks', #h:running(101, 'a feran', 10000) == 1
  and h:blockedBy(blockers, 'Dread Pyre', 101, 'a feran', 10000) == 'Ashengate Pyre')

io.write(string.format('test_holds: %d passed, %d failed\n', pass, fail))
os.exit(fail == 0 and 0 or 1)
