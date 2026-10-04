-- Run: luajit tests/test_ttd.lua   (from F:\lua\necrobrain)
package.path = './necrobrain/?.lua;./?.lua;' .. package.path
require('tests.necrobrain_fakes')
local pass, fail = 0, 0
local function check(name, cond, detail)
  if cond then pass = pass + 1 else fail = fail + 1; io.write('FAIL: ' .. name .. (detail and (' -- ' .. tostring(detail)) or '') .. '\n') end
end
local T = require('ttd')

local s, src = T.estimate(7, 100, nil)
check('nothing known -> none', s == nil and src == 'none')
s, src = T.estimate(7, 80, { avgDur = 30 })
check('history seed', math.abs(s - 24) < 0.01 and src == 'history', s)

-- 2%/s decline: at 90% -> 45 s left
T.observe(7, 'a rat', 100, 0)
T.observe(7, 'a rat', 98, 1000)
T.observe(7, 'a rat', 96, 2000)
T.observe(7, 'a rat', 94, 3000)
s, src = T.estimate(7, 94, { avgDur = 30 })
check('thin measurement defers to the seed', src == 'history' and math.abs(s - 28.2) < 0.05, s)
s, src = T.estimate(7, 94, nil)
check('thin measurement used when there is no seed', src == 'measured' and math.abs(s - 47) < 0.5, s)
-- keep the same 2%/s decline going to 9 s of samples: now the measurement outranks the seed
for i = 4, 9 do T.observe(7, 'a rat', 94 - (i - 3) * 2, i * 1000) end
s, src = T.estimate(7, 82, { avgDur = 30 })
check('measured beats history once 9 s of samples exist (bounded to 1.5x seed remaining)', src == 'measured' and math.abs(s - 36.9) < 0.1, s)

-- window trims to 20 s
for i = 10, 30 do T.observe(7, 'a rat', 94 - (i - 3) * 2, i * 1000) end
s, src = T.estimate(7, 40, nil)
check('still measured after trim', src == 'measured' and math.abs(s - 20) < 0.5, s)

-- no decline for 9+ s -> notdying
T.reset(8)
-- a mob that has been hit (90%) and then sits flat for 10 s is not dying; a mob at 100% is
-- simply not engaged (covered below) and must never read as notdying
for i = 0, 10 do T.observe(8, 'a bat', 90, i * 1000) end
s, src = T.estimate(8, 90, { avgDur = 30 })
-- flat from first sight (walked in tagged, or parked): never engaged, so the seed stands (review: a
-- sub-100% plateau used to read 999 'notdying' and credit every DoT its full duration)
check('flat from first sight -> the seed, not notdying', src == 'history' and math.abs(s - 27) < 0.01, s)
s, src = T.estimate(8, 90, nil)
check('flat from first sight, no seed -> none', s == nil and src == 'none', src)

-- heal resets the window
T.reset(9)
T.observe(9, 'a cat', 50, 0); T.observe(9, 'a cat', 48, 1000)
T.observe(9, 'a cat', 90, 2000)  -- big heal
s, src = T.estimate(9, 90, { avgDur = 40 })
check('after heal falls back to history', src == 'history' and math.abs(s - 36) < 0.01, src)

-- invalid pct inputs never guess short
s, src = T.estimate(11, nil, { avgDur = 30 })
check('nil pct -> none', s == nil and src == 'none', src)
s, src = T.estimate(11, 'abc', nil)
check('non-numeric pct -> none', s == nil and src == 'none', src)

-- decelerating decline: full-window rate looks fast (1.55%/s -> ~44s at 69%),
-- but the last 10s flattened to 0.1%/s. The slower (recent) rate must win,
-- so the estimate goes long (measured, >400s) instead of reporting ~44s.
T.reset(12)
T.observe(12, 'a wolf', 100, 0)
T.observe(12, 'a wolf', 85, 5000)
T.observe(12, 'a wolf', 70, 10000)
for t = 11000, 20000, 1000 do T.observe(12, 'a wolf', 69, t) end
s, src = T.estimate(12, 69, nil)
check('decelerating decline biases long', src == 'measured' and s > 400, s)
s, src = T.estimate(12, 69, { avgDur = 30 })
check('...but a seed bounds it to 1.5x remaining (30 x 0.69 x 1.5 = 31.05)', src == 'measured' and math.abs(s - 31.05) < 0.05, s)

-- truly stalled: last 10s is dead flat (70 -> 70, 0% decline) -> notdying,
-- even though the full window (100 -> 70 over 10s) still shows real decline.
T.reset(13)
T.observe(13, 'a troll', 100, 0)
T.observe(13, 'a troll', 85, 5000)
T.observe(13, 'a troll', 70, 10000)
for t = 11000, 20000, 1000 do T.observe(13, 'a troll', 70, t) end
s, src = T.estimate(13, 70, { avgDur = 30 })
check('truly stalled -> notdying', s == 999 and src == 'notdying', s)

-- gradual heal: each step rises less than 10 from the *previous* sample, but
-- the min-based reset rule catches the cumulative drift early: at 60%
-- (min so far is 48, 60 > 48+10=58) the window resets, leaving only
-- {60@3000, 66@4000} — a 2-sample uphill "trend" that fails the decline
-- checks (decline is negative), so estimate() falls through to history.
-- (Reset actually lands on the 60% sample, one step before the 66% sample
-- used for the query, but the observable result — history-seeded, 26.4 — is
-- unaffected either way.)
T.reset(14)
T.observe(14, 'a ghoul', 50, 0)
T.observe(14, 'a ghoul', 48, 1000)
T.observe(14, 'a ghoul', 54, 2000)
T.observe(14, 'a ghoul', 60, 3000)
T.observe(14, 'a ghoul', 66, 4000)
s, src = T.estimate(14, 66, { avgDur = 40 })
check('gradual heal resets window, falls back to history', src == 'history' and math.abs(s - 26.4) < 0.01, s)

-- zero/invalid history avgDur must not be treated as "has history"
s, src = T.estimate(15, 80, { avgDur = 0 })
check('avgDur 0 -> none', s == nil and src == 'none', s)

-- reviewer scenario: full window shows zero net decline (50 -> 58 -> 50), but
-- the recent 10s slice contains a blip (58@10s -> 50@13s = 8 decline over 3s)
-- that would look like a fast, valid rate on its own. The recent window must
-- never be the sole source of a measured rate: full span is 13s (>= 9s) with
-- 0% net decline, so this is 'notdying', not a ~19s 'measured' estimate.
-- (engaged first: a rise before any drop only raises the leading plateau)
T.reset(16)
T.observe(16, 'x', 51, 0)
T.observe(16, 'x', 50, 1000)
T.observe(16, 'x', 58, 10000)
T.observe(16, 'x', 50, 13000)
s, src = T.estimate(16, 50, nil)
check('recent blip alone cannot measure short', (s == 999 and src == 'notdying') or (src == 'measured' and s > 300), s)
-- a mob regenerating on its walk-in (90 -> 91 -> 92) never starts the clock: the seed stands
T.reset(19)
for t = 0, 15000, 200 do T.observe(19, 'a regen', 90 + math.floor(t / 6000), t) end
s, src = T.estimate(19, 92, { avgDur = 30 })
check('regen walk-in: the seed, not notdying', src == 'history' and math.abs(s - 27.6) < 0.01, s)

-- same blip shape, but full span is only 5s (< 9s FLAT_MS threshold) so it
-- can't be declared notdying either; with no history it falls through to
-- 'none' rather than trusting the recent-only rate.
T.reset(17)
T.observe(17, 'x', 50, 0)
T.observe(17, 'x', 58, 3000)
T.observe(17, 'x', 50, 5000)
s, src = T.estimate(17, 50, nil)
check('recent blip, short full span, no history -> none', s == nil and src == 'none', s)

-- same as above but with history available: falls back to history instead
-- of the recent-only rate.
T.reset(18)
T.observe(18, 'x', 50, 0)
T.observe(18, 'x', 58, 3000)
T.observe(18, 'x', 50, 5000)
s, src = T.estimate(18, 50, { avgDur = 30 })
check('recent blip, short full span, falls back to history', src == 'history' and math.abs(s - 15) < 0.01, s)

-- full HP: an untouched mob is 'not engaged', never 'notdying' or 'measured'
T.reset(21)
for i = 0, 15 do T.observe(21, 'a dog', 100, i * 1000) end
s, src = T.estimate(21, 100, nil)
check('full hp, no history -> none', s == nil and src == 'none', src)
s, src = T.estimate(21, 100, { avgDur = 59 })
check('full hp, history -> history seed', src == 'history' and math.abs(s - 59) < 0.01, s)
-- and the idle samples must not dilute the first real rate once the pull starts
T.observe(21, 'a dog', 98, 16000); T.observe(21, 'a dog', 96, 17000); T.observe(21, 'a dog', 94, 18000); T.observe(21, 'a dog', 92, 19000)
s, src = T.estimate(21, 92, nil)
check('rate from engaged samples only (2%/s -> 46s)', src == 'measured' and math.abs(s - 46) < 0.5, s)

-- seed cap: 30 s scout at 60% -> remaining 18 s; a slow measured read (1%/2s -> 120 s) is capped to 27
-- (its first drop was at 65% 10 s ago: the seed gave it 19.5 s, so it has not been outlived yet)
T.reset(31)
for i = 0, 12 do T.observe(31, 'a scout', 66 - math.floor(i / 2), i * 1000) end
s, src = T.estimate(31, 60, { avgDur = 30 })
check('measured capped at 1.5x seed remaining', src == 'measured' and math.abs(s - 27) < 0.05, s)
-- same mob on a 14 s seed, 14 s after its first drop: due dead 9.1 s after it and still alive, so the
-- seed was wrong for it - the slow live read stands, no cap
for i = 13, 16 do T.observe(31, 'a scout', 66 - math.floor(i / 2), i * 1000) end
s, src = T.estimate(31, 58, { avgDur = 14 })
check('outlived seed: no cap on the live estimate', src == 'measured' and s > 60, s)
-- and the floor: a burst read (10%/s) on the same seed cannot go below 4.2
T.reset(32)
for i = 0, 9 do T.observe(32, 'a scout', 100 - i * 4, i * 1000) end
s, src = T.estimate(32, 64, { avgDur = 14 })
check('measured floored at 0.5x seed remaining', src == 'measured' and s >= 14 * 0.64 * 0.5 - 0.01, s)
-- mature recent window replaces a slow full window: 10 s flat (mezzed) then 2%/s for 10 s
T.reset(33)
for i = 0, 9 do T.observe(33, 'a bat', 90, i * 1000) end
for i = 10, 19 do T.observe(33, 'a bat', 90 - (i - 9) * 2, i * 1000) end
s, src = T.estimate(33, 70, nil)
check('mature recent window wins (70 / 2 = 35s, not 70/1.05)', src == 'measured' and math.abs(s - 35) < 0.6, s)

-- the lockout: a 5 s seed (one odd session window) on a mob that really lives ~99 s at 1%/s.
-- Thin samples defer to the seed at first; once it has outlived the seed the live rate takes over.
T.reset(41)
for i = 0, 4 do T.observe(41, 'a warrior', 99 - i, i * 1000) end
s, src = T.estimate(41, 95, { avgDur = 5 })
check('thin samples still defer to an unfalsified seed', src == 'history' and math.abs(s - 4.75) < 0.01, s)
for i = 5, 8 do T.observe(41, 'a warrior', 99 - i, i * 1000) end
s, src = T.estimate(41, 91, { avgDur = 5 })
check('outlived 5 s seed: live rate, not the seed', src == 'measured' and s > 60, s)
-- a walk-in at 99% never starts the clock, however long it lasts
T.reset(42)
for t = 0, 15000, 1000 do T.observe(42, 'a warrior', 99, t) end
s, src = T.estimate(42, 99, { avgDur = 5 })
check('a flat walk-in never counts as outliving the seed', src == 'history' and math.abs(s - 4.95) < 0.01, src)
-- ... and the clock starts at the first drop off it
T.observe(42, 'a warrior', 98, 16000)
for t = 17000, 24000, 1000 do T.observe(42, 'a warrior', 98 - (t - 16000) / 1000, t) end
s, src = T.estimate(42, 90, { avgDur = 5 })
check('clock from the first drop: outlived 8 s later (due at 6.9 s)', src == 'measured' and s > 30, s)
-- a gap in watching restarts the window and the clock
T.reset(45)
T.observe(45, 'a warrior', 96, 0); T.observe(45, 'a warrior', 95, 1000); T.observe(45, 'a warrior', 94, 2000)
T.observe(45, 'a warrior', 60, 32000)
s, src = T.estimate(45, 60, { avgDur = 20 })
check('back after 30 s away: the seed, not outlived', src == 'history' and math.abs(s - 12) < 0.01, src)
T.reset(43)
T.observe(43, 'a warrior', 99, 0); T.observe(43, 'a warrior', 99, 3000)
s, src = T.estimate(43, 99, { avgDur = 30 })
check('seed not yet outlived and no rate -> history', src == 'history' and math.abs(s - 29.7) < 0.01, s)
-- a heal reset restarts the engagement clock
T.reset(44)
T.observe(44, 'a warrior', 60, 0); T.observe(44, 'a warrior', 59, 1000); T.observe(44, 'a warrior', 58, 2000)
T.observe(44, 'a warrior', 80, 3000); T.observe(44, 'a warrior', 80, 4000)
s, src = T.estimate(44, 80, { avgDur = 1 })
check('heal reset restarts the clock (not outlived)', src == 'history', src)

-- seedFrom: one session window no longer replaces history
local seed = T.seedFrom({ 5 }, { avgDur = 25, maxHP = 9000, hpWeight = 4 })
check('one session window blends with history (5 + 2*25)/3', math.abs(seed.avgDur - 55 / 3) < 1e-9, seed.avgDur)
check('blend keeps history max HP', seed.maxHP == 9000 and seed.hpWeight == 4 and seed.source == 'session+history')
seed = T.seedFrom({ 20, 22, 24, 26, 28, 30, 20, 22, 24, 26 }, { avgDur = 60 })
check('ten session windows outweigh history', math.abs(seed.avgDur - (242 + 120) / 12) < 1e-9, seed.avgDur)
seed = T.seedFrom({ 25, 28 }, { avgDur = 4, fights = 1 })
check('history counts as no more windows than it holds (1)', math.abs(seed.avgDur - (53 + 4) / 3) < 1e-9, seed.avgDur)
check('blend is labelled', seed.source == 'session+history' and T.seedFrom({ 5 }, nil).source == 'session')
seed = T.seedFrom({ 5, 7 }, nil)
check('no history: session mean', seed.avgDur == 6 and seed.fights == 2)
local h = { avgDur = 40 }
check('no session windows: history unchanged', T.seedFrom({}, h) == h and T.seedFrom(nil, h) == h)

io.write(string.format('test_ttd: %d passed, %d failed\n', pass, fail))
os.exit(fail == 0 and 0 or 1)
