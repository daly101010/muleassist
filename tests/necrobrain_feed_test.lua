-- Run: luajit tests/test_feed.lua   (from F:\necrobrain)
package.path = './necrobrain/?.lua;./?.lua;' .. package.path
local F = require('tests.necrobrain_fakes')
local pass, fail = 0, 0
local function check(name, cond, detail)
  if cond then pass = pass + 1 else fail = fail + 1; io.write('FAIL: ' .. name .. (detail and (' -- ' .. tostring(detail)) or '') .. '\n') end
end
local Feed = require('feed')
local got = {}
Feed.on(function(ev) got[#got + 1] = ev end)
Feed.start('Calbuss')

local function evt(t) t.id = 'evt'; t.sender = t.sender or 'Calbuss'; F.deliver('companion_events', t) end

-- own cast -> tick within grace = landed
F.now = 1000
evt({ source = 'Calbuss', target = 'a rat', ability = 'Venin', kind = 'cast', amount = 0, outcome = 'cast' })
check('cast event', got[1] and got[1].type == 'cast' and got[1].spell == 'Venin' and got[1].target == 'a rat')
F.now = 2500
evt({ source = 'Calbuss', target = 'a rat', ability = 'Venin', kind = 'dot', amount = 1200, outcome = 'hit' })
check('landed with amount', got[3] and got[3].type == 'landed' and got[3].amount == 1200, got[3] and got[3].type)
check('damage event too', got[2] and got[2].type == 'damage' and got[2].mine == true)

-- own cast -> resist
F.now = 5000
evt({ source = 'Calbuss', target = 'a rat', ability = 'Dread Pyre', kind = 'cast', amount = 0, outcome = 'cast' })
evt({ source = 'Calbuss', target = 'a rat', ability = 'Dread Pyre', kind = 'nuke', amount = 0, outcome = 'resist' })
check('resisted', got[#got].type == 'resisted' and got[#got].spell == 'Dread Pyre')

-- own cast with no confirmation -> now emits its own 'expired' event (never a
-- landed(0)); GRACE_MS is 10000 (companion emits 'cast' on "You begin
-- casting", so the confirming tick/resist arrives one full cast-time later -
-- 3-6s for necro spells - and the old 2500ms grace expired almost every
-- pending cast before its outcome). The tick must land more than 10000ms
-- after the cast to trigger the sweep.
F.now = 9000
evt({ source = 'Calbuss', target = 'a rat', ability = 'Shield of Darkness', kind = 'cast', amount = 0, outcome = 'cast' })
F.now = 19500; Feed.tick()
check('expired event (not landed)', got[#got].type == 'expired' and got[#got].spell == 'Shield of Darkness', got[#got] and got[#got].type)

-- other people's events: damage only, never cast/landed
local n = #got
evt({ sender = 'Beyonce', source = 'Beyonce', target = 'a rat', ability = 'Venin', kind = 'dot', amount = 900, outcome = 'hit' })
check('others damage passes', got[#got].type == 'damage' and got[#got].mine == false)
evt({ sender = 'Beyonce', source = 'Beyonce', target = 'a rat', ability = 'Venin', kind = 'cast', amount = 0, outcome = 'cast' })
check('others cast ignored', #got == n + 1)

-- pets and incoming are not damage-to-mob signals for us
evt({ source = 'Daly`s pet', target = 'a rat', ability = 'hits', kind = 'melee', amount = 50, outcome = 'hit', isPet = true })
check('pet damage still counts toward the mob', got[#got].type == 'damage' and got[#got].amount == 50)

-- diag counts: casts = Venin + Dread Pyre + Shield of Darkness = 3; landed =
-- Venin only (1) since an expiry no longer inflates diag.landed; resisted =
-- Dread Pyre (1); expired = Shield of Darkness (1). (Before this fix wave,
-- expirePending also bumped diag.landed, so this used to read landed == 2.)
local d = Feed.diag()
check('diag counts', d.casts == 3 and d.landed == 1 and d.resisted == 1 and d.expired == 1, string.format('%d %d %d %d', d.casts, d.landed, d.resisted, d.expired))

-- a tick landing 5000ms after its cast is well inside the widened 10s grace
-- and must be treated as that cast's confirmation.
F.now = 20000
evt({ source = 'Calbuss', target = 'a rat', ability = 'Scent of Terris', kind = 'cast', amount = 0, outcome = 'cast' })
F.now = 25000
evt({ source = 'Calbuss', target = 'a rat', ability = 'Scent of Terris', kind = 'dot', amount = 800, outcome = 'hit' })
check('tick 5s after cast confirms under the 10s grace', got[#got].type == 'landed' and got[#got].amount == 800 and got[#got].spell == 'Scent of Terris', got[#got] and got[#got].type)

-- correlation by spell+target: two pending casts of the same spell on two
-- different targets must resolve independently, newest-target-match first.
F.now = 30000
evt({ source = 'Calbuss', target = 'a rat', ability = 'Ignite Bones', kind = 'cast', amount = 0, outcome = 'cast' })
F.now = 30300
evt({ source = 'Calbuss', target = 'a bat', ability = 'Ignite Bones', kind = 'cast', amount = 0, outcome = 'cast' })
F.now = 30500
evt({ source = 'Calbuss', target = 'a bat', ability = 'Ignite Bones', kind = 'dot', amount = 500, outcome = 'hit' })
check('landed resolves the matching target (a bat)', got[#got].type == 'landed' and got[#got].target == 'a bat' and got[#got].amount == 500, got[#got] and got[#got].target)

-- the tick line capitalizes the article ('A bat has taken ...') while the cast carries CleanName
F.now = 31000
evt({ source = 'Calbuss', target = 'a wolf', ability = 'Ignite Bones', kind = 'cast', amount = 0, outcome = 'cast' })
F.now = 31200
evt({ source = 'Calbuss', target = 'a bat', ability = 'Ignite Bones', kind = 'cast', amount = 0, outcome = 'cast' })
F.now = 31500
evt({ source = 'Calbuss', target = 'A wolf', ability = 'Ignite Bones', kind = 'dot', amount = 400, outcome = 'hit' })
check('target match ignores case (A wolf claims a wolf, not the newer bat)', got[#got].type == 'landed' and got[#got].amount == 400
  and tostring(got[#got].target):lower() == 'a wolf', got[#got] and got[#got].target)
evt({ source = 'Calbuss', target = 'A bat', ability = 'Ignite Bones', kind = 'dot', amount = 450, outcome = 'hit' })
check('and the bat cast is still there to claim', got[#got].type == 'landed' and got[#got].amount == 450, got[#got] and got[#got].type)

-- the untouched pending entry (a rat) must still be sitting there; expire it
-- to prove it was not the one consumed above (now past the 10s grace)
F.now = 41000
Feed.tick()
check('unclaimed pending (a rat) still expires on its own', got[#got].type == 'expired' and got[#got].target == 'a rat', got[#got] and got[#got].target)

-- a tick of my DoT on one mob never answers my cast on another: the cast on 'a bear' stays pending
-- and expires on its own
F.now = 60000
evt({ source = 'Calbuss', target = 'a bear', ability = 'Ignite Bones', kind = 'cast', amount = 0, outcome = 'cast' })
F.now = 60500
local before = #got
evt({ source = 'Calbuss', target = 'A lynx', ability = 'Ignite Bones', kind = 'dot', amount = 300, outcome = 'hit' })
local claimedOther = false
for i = before + 1, #got do if got[i].type == 'landed' then claimedOther = true end end
check('another mob\'s tick does not claim my pending cast', not claimedOther)
F.now = 71000
Feed.tick()
check('... which then expires on its own', got[#got].type == 'expired' and got[#got].target == 'a bear', got[#got] and got[#got].target)
-- a cast whose target companion could not read ('') is still claimed by spell alone
F.now = 72000
evt({ source = 'Calbuss', target = '', ability = 'Ignite Bones', kind = 'cast', amount = 0, outcome = 'cast' })
F.now = 72500
evt({ source = 'Calbuss', target = 'A lynx', ability = 'Ignite Bones', kind = 'dot', amount = 310, outcome = 'hit' })
check('a target-less cast is claimed by spell', got[#got].type == 'landed' and got[#got].amount == 310, got[#got] and got[#got].type)


-- a tick arriving 11s after the only pending cast of that spell (past the 10s
-- grace) must not be treated as its confirmation: the cast expires on its own
-- (an 'expired' event) and the tick's hit is only reported as damage
F.now = 45000
evt({ source = 'Calbuss', target = 'a rat', ability = 'Leech Touch', kind = 'cast', amount = 0, outcome = 'cast' })
F.now = 56000
local nStale = #got
evt({ source = 'Calbuss', target = 'a rat', ability = 'Leech Touch', kind = 'dot', amount = 700, outcome = 'hit' })
check('stale-tick damage still recorded', got[nStale + 1].type == 'damage' and got[nStale + 1].amount == 700)
check('stale cast expires instead of being confirmed', got[nStale + 2].type == 'expired' and got[nStale + 2].spell == 'Leech Touch')
check('no bogus landed confirmation was emitted', #got == nStale + 2)

-- malformed / non-table payloads increment diag.dropped
local droppedBefore = Feed.diag().dropped
F.deliver('companion_events', { id = 'nope' })
F.deliver('companion_events', 'not-a-table-payload')
check('malformed table and non-table payload both increment dropped', Feed.diag().dropped == droppedBefore + 2, Feed.diag().dropped)

-- a message() that errors when called also counts as dropped
local subscriberFn = F.subscribers['companion_events']
local droppedBefore2 = Feed.diag().dropped
subscriberFn(function() error('boom') end)
check('pcall(message) failure increments dropped', Feed.diag().dropped == droppedBefore2 + 1, Feed.diag().dropped)

-- myPet hits count as mine for damage/HP-tracking, but never correlate as a
-- landed confirmation (pets do not cast the character's pending spells)
local nPet = #got
evt({ source = 'Daly`s pet', target = 'a rat', ability = 'hits', kind = 'melee', amount = 75, outcome = 'hit', myPet = true })
check('myPet hit is damage with mine == true', got[#got].type == 'damage' and got[#got].mine == true and got[#got].amount == 75)
check('myPet hit creates no landed event', #got == nPet + 1)

-- resists carry claimed: only the one that matches my pending cast counts toward per-mob resist
-- memory; a repeat (another box's companion rebroadcasting the same line) is unclaimed
F.now = 900000
evt({ source = 'Calbuss', target = 'Overlord Mata Muram', ability = 'Ashengate Pyre', kind = 'cast', amount = 0, outcome = 'cast' })
F.now = 903000
evt({ source = 'Calbuss', target = 'Overlord Mata Muram', ability = 'Ashengate Pyre', kind = 'nuke', amount = 0, outcome = 'resist' })
check('resist matching a pending cast is claimed', got[#got].type == 'resisted' and got[#got].claimed == true and got[#got].target == 'Overlord Mata Muram', got[#got].claimed)
evt({ source = 'Calbuss', target = 'Overlord Mata Muram', ability = 'Ashengate Pyre', kind = 'nuke', amount = 0, outcome = 'resist' })
check('repeat resist with no pending cast is unclaimed', got[#got].type == 'resisted' and got[#got].claimed == false, got[#got].claimed)

-- a ranked spell: companion cuts the cast line at the first period ('Curse of Mortality Rk') while the
-- resist line keeps the whole name; the resist still answers that cast
F.now = 910000
evt({ source = 'Calbuss', target = 'a lich', ability = 'Curse of Mortality Rk', kind = 'cast', amount = 0, outcome = 'cast' })
F.now = 913000
evt({ source = 'Calbuss', target = 'a lich', ability = 'Curse of Mortality Rk. II', kind = 'nuke', amount = 0, outcome = 'resist' })
check('ranked resist claims its cut cast name', got[#got].type == 'resisted' and got[#got].claimed == true, got[#got].claimed)
check('baseSpell strips a whole or a cut rank suffix only', Feed.baseSpell('Curse of Mortality Rk. II') == 'Curse of Mortality'
  and Feed.baseSpell('Curse of Mortality Rk') == 'Curse of Mortality' and Feed.baseSpell('Venin') == 'Venin'
  and Feed.baseSpell('Dark Rkoth') == 'Dark Rkoth', Feed.baseSpell('Curse of Mortality Rk'))

-- stop() must silence further delivery entirely
Feed.stop()
local nAfterStop = #got
evt({ source = 'Calbuss', target = 'a rat', ability = 'Venin', kind = 'cast', amount = 0, outcome = 'cast' })
check('stop() then deliver of an own cast produces no new event', #got == nAfterStop)

io.write(string.format('test_feed: %d passed, %d failed\n', pass, fail))
os.exit(fail == 0 and 0 or 1)
