-- Run: luajit tests/test_resist.lua   (from F:\lua\necrobrain)
package.path = './necrobrain/?.lua;./?.lua;' .. package.path
local pass, fail = 0, 0
local function check(name, cond, detail)
  if cond then pass = pass + 1 else fail = fail + 1; io.write('FAIL: ' .. name .. (detail and (' -- ' .. tostring(detail)) or '') .. '\n') end
end
local R = require('resist')
local MMM = 'Overlord Mata Muram'

-- no data at all: the ranker keeps its default land chance
local mem = R.new()
check('no data -> nil', mem:rate(MMM, 'disease', 0) == nil)
check('unresistable never has a rate', mem:rate(MMM, 'unresistable', 0, 50, 50) == nil)

-- live resists: two is still a coin flip, three straight is avoided (ranker AVOID_RESIST 0.50)
mem:record(MMM, 'disease', true, 1000)
mem:record(MMM, 'disease', true, 6000)
local r2 = mem:rate(MMM, 'disease', 6000)
check('two resists stay under 0.5', r2 and r2 < 0.5, r2)
mem:record(MMM, 'disease', true, 11000)
local r3 = mem:rate(MMM, 'disease', 11000)
check('three straight resists reach 0.5', r3 and r3 >= 0.5, r3)

-- elements and mobs are independent; mob names fold case (DoT ticks capitalize "A ...")
check('other element untouched', mem:rate(MMM, 'fire', 11000) == nil)
check('other mob untouched', mem:rate('Warden Hanvar', 'disease', 11000) == nil)
check('mob name case-insensitive', mem:rate('overlord mata muram', 'disease', 11000) == r3)

-- a land pulls the rate back down
mem:record(MMM, 'disease', false, 12000)
local r4 = mem:rate(MMM, 'disease', 12000)
check('a landed cast lowers the rate', r4 and r4 < r3, r4)

-- live samples age out of the window (a debuff / resist buff can change the picture)
local aged = mem:rate(MMM, 'disease', 12000 + R.WINDOW_MS + 1)
check('samples older than the window drop out', aged == nil, aged)

-- only the most recent MAX_SAMPLES outcomes count
local capped = R.new()
for i = 1, R.MAX_SAMPLES do capped:record('a rat', 'fire', true, i) end
for i = 1, R.MAX_SAMPLES do capped:record('a rat', 'fire', false, 100 + i) end
local rc = capped:rate('a rat', 'fire', 200)
check('old outcomes beyond MAX_SAMPLES are forgotten', rc and rc < 0.1, rc)

-- history seeds the rate before the first cast of this fight
local hist = R.new()
local hHigh = hist:rate(MMM, 'fire', 0, 50, 60)
check('history of heavy resists avoids from the first cast', hHigh and hHigh >= 0.5, hHigh)
local hLow = hist:rate(MMM, 'fire', 0, 0, 60)
check('history of clean lands reads low', hLow and hLow < 0.1, hLow)
check('history with zero casts is no data', hist:rate(MMM, 'fire', 0, 0, 0) == nil)

-- live lands outweigh a bad history within a handful of casts
for i = 1, 5 do hist:record(MMM, 'fire', false, i * 1000) end
local hRecover = hist:rate(MMM, 'fire', 5000, 60, 60)
check('five live lands override a 100% resist history', hRecover and hRecover < 0.5, hRecover)

-- nil / empty names never crash and never record
local safe = R.new()
safe:record(nil, 'fire', true, 0)
safe:record('', 'fire', true, 0)
safe:record('a rat', nil, true, 0)
check('nil mob/type ignored', safe:rate('a rat', 'fire', 0) == nil)

-- escalating refusal cooldown for back-to-back resists of one spell on one mob
check('cooldown streak 1', R.refusalCooldown(1) == R.BASE_CD_MS, R.refusalCooldown(1))
check('cooldown streak 2 doubles', R.refusalCooldown(2) == R.BASE_CD_MS * 2, R.refusalCooldown(2))
check('cooldown streak 3 doubles again', R.refusalCooldown(3) == R.BASE_CD_MS * 4, R.refusalCooldown(3))
check('cooldown capped', R.refusalCooldown(10) == R.MAX_CD_MS, R.refusalCooldown(10))
check('cooldown with no streak is the base', R.refusalCooldown(nil) == R.BASE_CD_MS and R.refusalCooldown(0) == R.BASE_CD_MS)

io.write(string.format('test_resist: %d passed, %d failed\n', pass, fail))
os.exit(fail == 0 and 0 or 1)
