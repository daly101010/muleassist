-- Run: luajit tests/test_ranker.lua   (from F:\necrobrain)
package.path = './necrobrain/?.lua;./?.lua;' .. package.path
require('tests.necrobrain_fakes')
local pass, fail = 0, 0
local function check(name, cond, detail)
  if cond then pass = pass + 1 else fail = fail + 1; io.write('FAIL: ' .. name .. (detail and (' -- ' .. tostring(detail)) or '') .. '\n') end
end
local R = require('ranker')

local vakk  = { index = 2, spell = "Vakk`dra's Sickly Mists", mana = 866, castSec = 3, recastSec = 1.5, durSec = 42, isDot = true, base = 1010, resistType = 'poison' }
local ashen = { index = 3, spell = 'Ashengate Pyre', mana = 1629, castSec = 3, recastSec = 1.5, durSec = 30, isDot = true, base = 1434, resistType = 'fire' }
local dfb   = { index = 4, spell = 'Demand for Blood', mana = 673, castSec = 6, recastSec = 1.5, durSec = 0, isDot = false, base = 2214, resistType = 'poison', synergy = 'power' }
local undead= { index = 5, spell = 'Annihilate Undead', mana = 368, castSec = 5, recastSec = 1.5, durSec = 0, isDot = false, base = 2012, resistType = 'magic', undeadOnly = true }
local venin = { index = 9, spell = 'Venin', mana = 660, castSec = 6, recastSec = 1.5, durSec = 0, isDot = false, base = 2279, resistType = 'poison' }
local sev   = { index = 8, spell = "Severan's Rot", mana = 947, castSec = 3, recastSec = 1.5, durSec = 72, isDot = true, base = 734, resistType = 'disease' }
local entries = { vakk, ashen, dfb, undead, venin, sev }

local function ctx(o)
  local c = { ttdSecs = 30, mode = 'eff', powerUp = false, targetUndead = false, remainingHP = nil,
    spellStats = function() return nil end, mobResist = function() return nil end, runningDotDpsPerTick = 0 }
  for k, v in pairs(o or {}) do c[k] = v end
  return c
end

local r = R.rank(entries, ctx())
local order = {}; for i, x in ipairs(r) do order[i] = x.entry.spell end
check('undead-only excluded on non-undead', not table.concat(order, ','):find('Annihilate'))
check('vakk first on 30s trash', order[1] == "Vakk`dra's Sickly Mists", table.concat(order, ','))
check('severan below venin on 30s', (function() local sv, vn; for i, s in ipairs(order) do if s == "Severan's Rot" then sv = i end; if s == 'Venin' then vn = i end end; return sv and vn and sv > vn end)(), table.concat(order, ','))

r = R.rank(entries, ctx({ targetUndead = true }))
check('undead nuke leads on undead', r[1].entry.spell == 'Annihilate Undead', r[1].entry.spell)

r = R.rank(entries, ctx({ powerUp = true }))
order = {}; for i, x in ipairs(r) do order[i] = x.entry.spell end
check('dfb excluded while Power up', not table.concat(order, ','):find('Demand'))

r = R.rank(entries, ctx({ ttdSecs = 90, runningDotDpsPerTick = 4000 }))
check('dfb leads with a dot stack and Power down', r[1].entry.spell == 'Demand for Blood', r[1].entry.spell)

r = R.rank(entries, ctx({ ttdSecs = 4 }))
check('nothing fits in 4 s', #r == 0, #r)

r = R.rank(entries, ctx({ mobResist = function(t) if t == 'poison' then return 0.6 end end }))
order = {}; for i, x in ipairs(r) do order[i] = x.entry.spell end
check('poison avoided at 60% resist', not table.concat(order, ','):find('Vakk') and not table.concat(order, ','):find('Venin'), table.concat(order, ','))

r = R.rank({ vakk, venin }, ctx({ ttdSecs = 15 }))
check('short ttd prefers the nuke', r[1].entry.spell == 'Venin', r[1].entry.spell)

r = R.rank({ vakk, ashen }, ctx({ ttdSecs = 90, mode = 'burn' }))
check('burn mode prefers the bigger tick', r[1].entry.spell == 'Ashengate Pyre', r[1].entry.spell)

-- one-tick DoTs are never offered: at 12 s Vakk`dra's would land one tick; with the nukes
-- unavailable the answer must be 'nothing', not a 1.3 dmg/mana DoT
r = R.rank({ vakk, ashen }, ctx({ ttdSecs = 12 }))
check('one-tick DoT excluded at 12 s', #r == 0, #r)
check('reason names the tick floor', tostring(R.excluded()["Vakk`dra's Sickly Mists"]):find('only 1 tick', 1, true) ~= nil, R.excluded()["Vakk`dra's Sickly Mists"])
r = R.rank({ vakk }, ctx({ ttdSecs = 16 }))
check('two ticks at 16 s is allowed', #r == 1, #r)

check('explain is a string', type(R.explain(r[1])) == 'string' and #R.explain(r[1]) > 10)

-- Test (a): _lastExcluded must reset on each rank() call
r = R.rank({ undead }, ctx({ targetUndead = false }))
check('undead excluded on non-undead target has reason', type(R.excluded()['Annihilate Undead']) == 'string')
r = R.rank({ undead }, ctx({ targetUndead = true }))  -- no clearExcluded() call
check('_lastExcluded reset on next rank() call', R.excluded()['Annihilate Undead'] == nil)

-- Test (b): synergy ticks must be floored; with ttdSecs=50, DfB synergy should be:
-- horizon = min(60, max(0, 50-6)) = 44s, ticks = floor(44/6) = 7
-- expected = 2214*0.85 + 0.25 chance * 0.85 land * 0.42 uplift * 1000*7 = 1881.9 + 624.75 = 2506.65
r = R.rank({ dfb }, ctx({ ttdSecs = 50, runningDotDpsPerTick = 1000, powerUp = false }))
check('synergy ticks floored correctly', r[1] and math.abs(r[1].expected - 2506.65) < 0.01,
  r[1] and ('expected=' .. r[1].expected) or 'no result')

-- Named: TTD / overkill holds are dropped and scoring goes to burn (damage per caster second).
r = R.rank(entries, ctx({ ttdSecs = 2, remainingHP = 500 }))
check('2s ttd on trash excludes everything', #r == 0, #r)
r = R.rank(entries, ctx({ ttdSecs = 2, remainingHP = 500, named = true }))
check('named ignores ttd and overkill', #r == 5, #r)
check('named scores by caster time (burn)', r[1] and r[1].score > 100, r[1] and r[1].score)
check('named does not mutate caller ctx', (function() local c = ctx({ ttdSecs = 2, named = true }); R.rank(entries, c); return c.ttdSecs == 2 and c.mode == 'eff' end)())
r = R.rank(entries, ctx({ ttdSecs = 2, remainingHP = 500, named = true, powerUp = true }))
check('named still respects Chaotic Power up', #r == 4, #r)

-- Chaotic Power carried onto the next mob: DoT ticks that land while the buff is still up
-- run ~+42% (observed +38..47%). Tick k lands at castSec + 6k; only ticks inside
-- powerLeftSec get the uplift. 30 s ttd -> Vakk`dra 4 ticks of 858.5 (1010 x 0.85).
r = R.rank({ vakk }, ctx({ ttdSecs = 30, powerUp = true, powerLeftSec = 40 }))
check('all 4 ticks boosted under fresh Power', r[1] and math.abs(r[1].expected - 858.5 * 4 * 1.42) < 0.01, r[1] and r[1].expected)
r = R.rank({ vakk }, ctx({ ttdSecs = 30, powerUp = true, powerLeftSec = 16 }))
check('only ticks inside the window boosted (9 s, 15 s yes; 21 s, 27 s no)', r[1] and math.abs(r[1].expected - 858.5 * (2 * 1.42 + 2)) < 0.01, r[1] and r[1].expected)
check('reason shows ticks under Power', r[1] and tostring(r[1].reason):find('2 under Power', 1, true) ~= nil, r[1] and r[1].reason)
r = R.rank({ vakk }, ctx({ ttdSecs = 30, powerUp = true }))
check('powerUp without powerLeftSec = no uplift (legacy ctx)', r[1] and math.abs(r[1].expected - 858.5 * 4) < 0.01, r[1] and r[1].expected)
r = R.rank({ vakk }, ctx({ ttdSecs = 30, powerUp = false, powerLeftSec = 40 }))
check('powerLeftSec ignored when Power is down', r[1] and math.abs(r[1].expected - 858.5 * 4) < 0.01, r[1] and r[1].expected)
r = R.rank({ venin }, ctx({ ttdSecs = 30, powerUp = true, powerLeftSec = 40 }))
check('nukes untouched by Power', r[1] and math.abs(r[1].expected - 2279 * 0.85) < 0.01, r[1] and r[1].expected)
-- With real stats Vakk`dra averages ~1341/tick vs Venin ~2731: at 20 s (2 ticks) Venin wins cold,
-- Vakk`dra wins with Power fresh.
local stats = { ["Vakk`dra's Sickly Mists"] = { avgHit = 1341 }, Venin = { avgHit = 2731 } }
r = R.rank({ vakk, venin }, ctx({ ttdSecs = 20, spellStats = function(s) return stats[s] end }))
check('20 s cold: Venin over 2-tick Vakk`dra', r[1].entry.spell == 'Venin', r[1].entry.spell)
r = R.rank({ vakk, venin }, ctx({ ttdSecs = 20, powerUp = true, powerLeftSec = 50, spellStats = function(s) return stats[s] end }))
check('20 s under fresh Power: Vakk`dra over Venin', r[1].entry.spell == "Vakk`dra's Sickly Mists", r[1].entry.spell)

-- Life Burn: named-only AA valued at 75% of CURRENT HP, unresistable (land 1.0), free.
local lifeburn = { index = 12, spell = 'Life Burn', mana = 0, castSec = 0.1, recastSec = 1.5, durSec = 0, isDot = false,
  base = nil, hpFraction = 0.75, resistType = 'unresistable', isAA = true, reuseSec = 6840, namedOnly = true }
r = R.rank({ lifeburn, venin }, ctx({ ttdSecs = 30, currentHP = 10000 }))
check('named-only AA excluded on trash', #r == 1 and r[1].entry.spell == 'Venin', r[1] and r[1].entry.spell)
check('reason says named only', tostring(R.excluded()['Life Burn']):find('named', 1, true) ~= nil, R.excluded()['Life Burn'])
r = R.rank({ lifeburn, venin, ashen }, ctx({ named = true, currentHP = 10000 }))
check('AA leads on a named', r[1].entry.spell == 'Life Burn', r[1].entry.spell)
check('expected = 0.75 x current HP, land 1.0', math.abs(r[1].expected - 7500) < 0.01, r[1].expected)
r = R.rank({ lifeburn }, ctx({ named = true, currentHP = 4000, spellStats = function(s) if s == 'Life Burn' then return { avgHit = 9000 } end end }))
check('hp fraction ignores history avgHit', math.abs(r[1].expected - 3000) < 0.01, r[1].expected)
r = R.rank({ lifeburn }, ctx({ named = true }))
check('no HP reading = excluded', #r == 0 and tostring(R.excluded()['Life Burn']):find('HP', 1, true) ~= nil, R.excluded()['Life Burn'])
r = R.rank({ lifeburn }, ctx({ named = true, currentHP = 10000, powerUp = true, powerLeftSec = 50 }))
check('Power uplift does not touch a nuke AA', math.abs(r[1].expected - 7500) < 0.01, r[1].expected)

-- Self-heal value (lifetaps): min(avgHeal * units * land, missingHP) * healWeight(pctHPs).
local spear = { index = 1, spell = 'Spear of Muram', mana = 500, castSec = 0.5, recastSec = 1.5, durSec = 0, isDot = false, base = 1000, resistType = 'disease' }
local iglum = { index = 2, spell = 'Touch of Iglum', mana = 500, castSec = 3, recastSec = 1.5, durSec = 0, isDot = false, base = 1000, resistType = 'disease' }
local bond  = { index = 3, spell = 'Bond of Inruku', mana = 500, castSec = 3, recastSec = 1.5, durSec = 42, isDot = true, base = 200, resistType = 'disease' }
local shdStats = { ['Touch of Iglum'] = { avgHeal = 1000 }, ['Bond of Inruku'] = { avgHeal = 200 } }
local function shd(o)
  local c = ctx({ spellStats = function(s) return shdStats[s] end })
  for k, v in pairs(o or {}) do c[k] = v end
  return c
end
local function row(list, spell) for _, x in ipairs(list) do if x.entry.spell == spell then return x end end end

check('healWeight 0 at 100%', R.healWeight(100) == 0, R.healWeight(100))
check('healWeight 0 at 90%', R.healWeight(90) == 0, R.healWeight(90))
check('healWeight 0.5 at 70%', math.abs(R.healWeight(70) - 0.5) < 1e-9, R.healWeight(70))
check('healWeight 1 at 50%', R.healWeight(50) == 1, R.healWeight(50))
check('healWeight capped at 1', R.healWeight(10) == 1, R.healWeight(10))
check('healWeight 0 without a reading', R.healWeight(nil) == 0, R.healWeight(nil))

r = R.rank({ spear, iglum }, shd({ pctHPs = 100, missingHP = 0 }))
check('full HP: tap scored as damage only', row(r, 'Touch of Iglum') and math.abs(row(r, 'Touch of Iglum').expected - 850) < 0.01, row(r, 'Touch of Iglum') and row(r, 'Touch of Iglum').expected)
check('full HP: equal damage/mana ties keep INI order', r[1].entry.spell == 'Spear of Muram', r[1].entry.spell)

r = R.rank({ spear, iglum }, shd({ pctHPs = 50, missingHP = 5000 }))
check('hurt: tap outranks equal nuke', r[1].entry.spell == 'Touch of Iglum', r[1].entry.spell)
check('hurt: tap expected = damage + full heal', math.abs(r[1].expected - 1700) < 0.01, r[1].expected)
check('reason shows the heal', tostring(r[1].reason):find(' heal 850', 1, true) ~= nil, r[1].reason)

r = R.rank({ iglum }, shd({ pctHPs = 50, missingHP = 300 }))
check('heal capped at missing HP', math.abs(r[1].expected - 1150) < 0.01, r[1].expected)

r = R.rank({ iglum }, shd({ pctHPs = 70, missingHP = 5000 }))
check('half weight at 70%', math.abs(r[1].expected - 1275) < 0.01, r[1].expected)

r = R.rank({ bond }, shd({ pctHPs = 50, missingHP = 5000 }))
check('DoT tap: heal scales with ticks (4 at 30 s)', math.abs(r[1].expected - 1360) < 0.01, r[1].expected)
r = R.rank({ bond }, shd({ ttdSecs = 16, pctHPs = 50, missingHP = 5000 }))
check('DoT tap: 2 ticks at 16 s', math.abs(r[1].expected - 680) < 0.01, r[1].expected)

r = R.rank({ iglum }, shd({ pctHPs = 50, missingHP = 5000, mobResist = function() return 0.4 end }))
check('land chance applies to the heal', math.abs(r[1].expected - 1200) < 0.01, r[1].expected)

r = R.rank({ iglum }, ctx({ pctHPs = 50, missingHP = 5000 }))
check('no avgHeal: damage only', math.abs(r[1].expected - 850) < 0.01, r[1].expected)

r = R.rank({ iglum }, shd({ pctHPs = 50, missingHP = 5000, remainingHP = 600 }))
check('remaining-HP cap judged on damage only: 600 + full heal 850', r[1] and math.abs(r[1].expected - 1450) < 0.01, r[1] and r[1].expected)
check('reason says capped', r[1] and tostring(r[1].reason):find('capped at 600 hp left', 1, true) ~= nil, r[1] and r[1].reason)

r = R.rank({ iglum }, shd({ pctHPs = 50, missingHP = 5000, named = true }))
check('named keeps the heal value', r[1] and math.abs(r[1].expected - 1700) < 0.01, r[1] and r[1].expected)

-- every candidate resist-avoided (a boss that eats the whole list): still cast, ranked by land
-- chance, instead of going idle for the fight
local mists = { index = 1, spell = "Vakk`dra's Sickly Mists", mana = 866, castSec = 3, recastSec = 1.5, durSec = 42, isDot = true, base = 1010, resistType = 'disease' }
local pyre  = { index = 2, spell = 'Ashengate Pyre', mana = 1629, castSec = 3, recastSec = 1.5, durSec = 30, isDot = true, base = 1434, resistType = 'fire' }
local rates = { disease = 0.9, fire = 0.6 }
-- the boss case: a named that eats the whole list
r = R.rank({ mists, pyre }, ctx({ ttdSecs = 90, named = true, mobResist = function(t) return rates[t] end }))
check('all resist-avoided falls back to ranking', #r == 2, #r)
check('fallback prefers the element that lands more', r[1] and r[1].entry.spell == 'Ashengate Pyre', r[1] and r[1].entry.spell)
check('fallback land is the observed chance', r[1] and math.abs(r[1].land - 0.4) < 1e-9, r[1] and r[1].land)
check('fallback clears the resist exclusion reasons', R.excluded()['Ashengate Pyre'] == nil, R.excluded()['Ashengate Pyre'])

-- one element still lands: the resisted one stays avoided (no fallback)
r = R.rank({ mists, pyre }, ctx({ ttdSecs = 90, mobResist = function(t) if t == 'disease' then return 0.9 end end }))
check('a landing element keeps the resisted one out', #r == 1 and r[1].entry.spell == 'Ashengate Pyre', #r)
check('resisted element keeps its reason', tostring(R.excluded()["Vakk`dra's Sickly Mists"]):find('disease resisted 90%', 1, true) ~= nil, R.excluded()["Vakk`dra's Sickly Mists"])

-- fallback never revives entries excluded for other reasons
r = R.rank({ mists, undead }, ctx({ ttdSecs = 90, named = true, mobResist = function(t) if t == 'disease' then return 0.9 end end }))
check('fallback keeps non-resist exclusions', #r == 1 and r[1].entry.spell == "Vakk`dra's Sickly Mists", #r)
check('non-resist reason survives fallback', R.excluded()['Annihilate Undead'] == 'target not undead', R.excluded()['Annihilate Undead'])

-- The fallback is for a mob that resists the WHOLE list. When the list still has an element that
-- lands (Curse of Mortality, magic) but that entry is held upstream (DoT still running, INI
-- condition, cooldown), hold instead of feeding resisted spells (Oshiruk 2026-09-14: 42 of 47
-- offline picks resisted while Curse's DoT ran).
r = R.rank({ mists, pyre }, ctx({ ttdSecs = 90, listResistTypes = { 'disease', 'fire', 'magic' },
  mobResist = function(t) return rates[t] end }))
check('hold while a listed element still lands', #r == 0, #r)
check('held entries keep their resist reasons', tostring(R.excluded()["Vakk`dra's Sickly Mists"]):find('disease resisted', 1, true) ~= nil,
  R.excluded()["Vakk`dra's Sickly Mists"])

r = R.rank({ mists, pyre }, ctx({ ttdSecs = 90, named = true, listResistTypes = { 'disease', 'fire' },
  mobResist = function(t) return rates[t] end }))
check('fallback when every listed element is resisted', #r == 2 and r[1].entry.spell == 'Ashengate Pyre', #r)
-- on trash the fallback only feeds what still lands 30% of the time
r = R.rank({ mists, pyre }, ctx({ ttdSecs = 90, listResistTypes = { 'disease', 'fire' },
  mobResist = function(t) return rates[t] end }))
check('trash fallback: only the 60%-resisted element', #r == 1 and r[1].entry == pyre, #r)
check('trash fallback: the 90% one says why', tostring(R.excluded()["Vakk`dra's Sickly Mists"]):find('on trash the fallback needs', 1, true) ~= nil,
  R.excluded()["Vakk`dra's Sickly Mists"])
check('a fallback pick is marked', r[1].fallback == true and tostring(r[1].reason):find('whole list resisted', 1, true) ~= nil)

r = R.rank({ mists, pyre }, ctx({ ttdSecs = 90, listResistTypes = { 'disease', 'fire', 'unresistable' },
  mobResist = function(t) return rates[t] end }))
check('an unresistable list entry blocks the fallback', #r == 0, #r)

r = R.rank({ mists, pyre }, ctx({ ttdSecs = 90, listResistTypes = { 'disease', 'fire', 'cold' },
  mobResist = function(t) return rates[t] end }))
check('an element with no resist data blocks the fallback', #r == 0, #r)

-- ---------------------------------------------------------------- Demand for Blood look-ahead
local function find(res, spell) for _, x in ipairs(res) do if x.entry.spell == spell then return x end end end
-- ttd 60, nothing running: DfB prices the DoTs it would be cast ahead of.
-- horizon min(60, 54) = 54; Ashengate (1218.9/tick) 5 ticks = 6094.5, then Vakk`dra (858.5) from offset 4.5:
-- floor((54 - 4.5 - 3)/6) = 7 ticks = 6009.5; synergy = 0.25*0.85*0.42*12104 = 1080.28
r = R.rank({ dfb, vakk, ashen }, ctx({ ttdSecs = 60, runningDots = {} }))
local d = find(r, 'Demand for Blood')
check('DfB look-ahead values the DoTs about to be cast', d and math.abs(d.synergy - 1080.2835) < 0.01, d and d.synergy)
check('DfB opens ahead of Ashengate', (function()
  local di, ai; for i, x in ipairs(r) do if x.entry == dfb then di = i end; if x.entry == ashen then ai = i end end
  return di and ai and di < ai end)(), (function() local o = {}; for i, x in ipairs(r) do o[i] = x.entry.spell end; return table.concat(o, ',') end)())
check('DfB reason names the lottery', d and tostring(d.reason):find('power lottery', 1, true) ~= nil, d and d.reason)
-- running DoTs count only the ticks they have left after DfB lands: 20 s left - 6 s cast = 2 ticks
r = R.rank({ dfb }, ctx({ ttdSecs = 90, runningDots = { { spell = 'X', perTick = 1000, leftSec = 20 } } }))
check('running DoT: remaining ticks only', r[1] and math.abs(r[1].synergy - 178.5) < 0.01, r[1] and r[1].synergy)
-- a DoT on an element the mob resists is not something the necro will cast next
r = R.rank({ dfb, ashen }, ctx({ ttdSecs = 60, runningDots = {}, mobResist = function(t) if t == 'fire' then return 0.6 end end }))
check('resist-avoided DoT left out of the look-ahead', r[1] and r[1].entry == dfb and r[1].synergy == 0, r[1] and r[1].synergy)
-- no lottery while Power is already up (DfB is excluded then anyway)
r = R.rank({ dfb, vakk }, ctx({ ttdSecs = 60, runningDots = {}, powerUp = true, powerLeftSec = 40 }))
check('no DfB while Power is up', find(r, 'Demand for Blood') == nil)

-- ---------------------------------------------------------------- Chaotic Weakness
-- ttd 30: 4 ticks of Vakk`dra; the first lands at 3 + 6 = 9 s, inside a 12 s Weakness -> 3.75 units
r = R.rank({ vakk }, ctx({ ttdSecs = 30, weaknessUp = true, weaknessLeftSec = 12 }))
check('Weakness costs the ticks inside its window', r[1] and math.abs(r[1].expected - 858.5 * 3.75) < 0.01, r[1] and r[1].expected)
check('reason shows ticks under Weakness', r[1] and tostring(r[1].reason):find('1 under Weakness', 1, true) ~= nil, r[1] and r[1].reason)
r = R.rank({ vakk, venin }, ctx({ ttdSecs = 30 }))
check('cold: Vakk`dra over Venin', r[1].entry == vakk, r[1].entry.spell)
r = R.rank({ vakk, venin }, ctx({ ttdSecs = 30, weaknessUp = true, weaknessLeftSec = 12 }))
check('Weakness: the nuke goes ahead of a new DoT', r[1].entry == venin, r[1].entry.spell)
check('Weakness keeps the DoT ranked, only later', #r == 2 and r[2].entry == vakk, #r)
check('Weakness note on the held DoT', tostring(r[2].reason):find('nukes first', 1, true) ~= nil, r[2].reason)
r = R.rank({ vakk }, ctx({ ttdSecs = 30, weaknessUp = true, weaknessLeftSec = 12 }))
check('Weakness with no nuke castable still casts the DoT', #r == 1, #r)
r = R.rank({ vakk, venin }, ctx({ ttdSecs = 30, weaknessUp = true, weaknessLeftSec = 12, powerUp = true, powerLeftSec = 40 }))
check('Weakness wins over Power when both are up', r[1].entry == venin, r[1].entry.spell)

-- ---------------------------------------------------------------- Chaotic Power ordering
-- 20 s, real stats: Venin (3.52/mana) beats a 2-tick Vakk`dra (2.63) cold; with Power up the DoT goes
-- first even with no powerLeftSec to credit (the tier, not the uplift, decides)
r = R.rank({ vakk, venin }, ctx({ ttdSecs = 20, powerUp = true, spellStats = function(s) return stats[s] end }))
check('Power: DoT ahead of a better-scoring nuke', r[1].entry == vakk, r[1].entry.spell)
check('Power note on the held nuke', tostring(r[2].reason):find('DoTs first', 1, true) ~= nil, r[2].reason)
-- a lifetap that is healing a hurt caster is not pushed behind the DoTs
r = R.rank({ vakk, iglum }, ctx({ ttdSecs = 30, powerUp = true, pctHPs = 50, missingHP = 5000,
  spellStats = function(s) return shdStats[s] end }))
local tap = find(r, 'Touch of Iglum')
check('Power: a healing tap keeps its place', tap and tap.tier == 0, tap and tap.tier)
r = R.rank({ vakk, iglum }, ctx({ ttdSecs = 30, powerUp = true, pctHPs = 100, missingHP = 0,
  spellStats = function(s) return shdStats[s] end }))
tap = find(r, 'Touch of Iglum')
check('Power: a tap at full HP is a nuke', tap and tap.tier == 1, tap and tap.tier)

-- ---------------------------------------------------------------- Gift of Mana
local function lv(e, level) local c = {}; for k, v in pairs(e) do c[k] = v end; c.level = level; return c end
local venin71, vakk74, ashen74 = lv(venin, 71), lv(vakk, 74), lv(ashen, 74)
r = R.rank({ venin71, vakk74, ashen74 }, ctx({ ttdSecs = 30 }))
check('no GoM: Vakk`dra leads', r[1].entry == vakk74, r[1].entry.spell)
r = R.rank({ venin71, vakk74, ashen74 }, ctx({ ttdSecs = 30, gom = { up = true } }))
check('GoM: the most expensive castable spell goes first', r[1].entry == ashen74, r[1].entry.spell)
check('GoM: then by mana', r[2].entry == vakk74 and r[3].entry == venin71, r[2].entry.spell)
check('GoM reason says what it saves', tostring(r[1].reason):find('Gift of Mana: saves 1629', 1, true) ~= nil, r[1].reason)
r = R.rank({ venin71, vakk74, ashen74 }, ctx({ ttdSecs = 30, gom = { up = true, levelCap = 72 } }))
check('GoM level cap: only spells at or under it are free', r[1].entry == venin71 and r[1].gom and not r[2].gom, r[1].entry.spell)
r = R.rank({ venin71, ashen74 }, ctx({ ttdSecs = 30, gom = { up = true }, mobResist = function(t) if t == 'fire' then return 0.6 end end }))
check('GoM is never spent on a resist-avoided spell', #r == 1 and r[1].entry == venin71, #r)
r = R.rank({ lifeburn, venin71 }, ctx({ named = true, currentHP = 10000, gom = { up = true } }))
check('GoM skips a free AA', r[1].entry == venin71 and not find(r, 'Life Burn').gom, r[1].entry.spell)
r = R.rank({ venin71, vakk74, ashen74 }, ctx({ ttdSecs = 30, gom = { up = true }, currentMana = 1000 }))
check('GoM: only spells the macro will attempt at current mana', r[1].entry == vakk74 and not find(r, 'Ashengate Pyre').gom, r[1].entry.spell)
r = R.rank({ venin71, ashen74 }, ctx({ ttdSecs = 30, gom = { up = true }, weaknessUp = true, weaknessLeftSec = 12 }))
check('GoM under Weakness: nukes first still', r[1].entry == venin71, r[1].entry.spell)
r = R.rank({ venin71, ashen74 }, ctx({ ttdSecs = 30, gom = { up = true }, powerUp = true, powerLeftSec = 40 }))
check('GoM under Power: the expensive DoT', r[1].entry == ashen74, r[1].entry.spell)

-- ---------------------------------------------------------------- remaining-HP cap (review item 7)
local drain = { index = 7, spell = 'Drain Life', mana = 667, castSec = 3.2, recastSec = 1.5, durSec = 0, isDot = false, base = 1505, resistType = 'magic' }
-- mob at 3% (1200 hp), HP flat so TTD reads 999: the nuke that finishes it is not excluded, and the
-- 42 s DoT is worth only the 1200 hp it can still do
r = R.rank({ vakk, drain, venin }, ctx({ ttdSecs = 999, remainingHP = 1200 }))
check('low HP: the finishing nuke is ranked', find(r, 'Venin') ~= nil, R.excluded()['Venin'])
check('low HP: nothing is worth more than the HP left', (function() for _, x in ipairs(r) do if x.expected > 1200.01 then return false end end return true end)())
check('low HP, efficiency: cheapest finisher first (Venin 660 mana)', r[1].entry == venin, r[1].entry.spell)
r = R.rank({ vakk, drain, venin }, ctx({ ttdSecs = 999, remainingHP = 1200, mode = 'burn' }))
check('low HP, burn: the fastest finisher first (Drain Life 4.7 s)', r[1].entry == drain, r[1].entry.spell)
check('low HP: a DoT is dropped when a nuke finishes the mob', find(r, "Vakk`dra's Sickly Mists") == nil
  and R.excluded()["Vakk`dra's Sickly Mists"] == 'a nuke finishes the mob sooner', R.excluded()["Vakk`dra's Sickly Mists"])
local mori = { index = 13, spell = 'Pyre of Mori', mana = 560, castSec = 3, recastSec = 1.5, durSec = 54, isDot = true, base = 419, resistType = 'fire' }
r = R.rank({ mori, venin }, ctx({ ttdSecs = 999, remainingHP = 1200, manaWeight = 0.5 }))
check('low HP, blended: a slow cheap DoT does not beat the finishing nuke', r[1].entry == venin, r[1].entry.spell)
r = R.rank({ vakk }, ctx({ ttdSecs = 30, remainingHP = 100000 }))
check('cap does not touch a healthy mob', r[1] and math.abs(r[1].expected - 858.5 * 4) < 0.01, r[1] and r[1].expected)
r = R.rank({ venin }, ctx({ ttdSecs = 2, remainingHP = 500 }))
check('TTD still excludes a nuke that cannot finish casting', #r == 0, #r)

-- ---------------------------------------------------------------- mana-aware scoring (review item 9)
check('manaWeight 0 at 80%+', R.manaWeight(80) == 0 and R.manaWeight(100) == 0)
check('manaWeight 1 at 35% and below', R.manaWeight(35) == 1 and R.manaWeight(5) == 1)
check('manaWeight halfway at 57.5%', math.abs(R.manaWeight(57.5) - 0.5) < 1e-9, R.manaWeight(57.5))
check('manaWeight nil without a reading', R.manaWeight(nil) == nil)
-- 24 s trash, full mana: efficiency ranks Vakk`dra first, burn-like ordering puts Ashengate first
r = R.rank({ vakk, ashen, venin }, ctx({ ttdSecs = 24 }))
check('efficiency: Vakk`dra first', r[1].entry == vakk, r[1].entry.spell)
r = R.rank({ vakk, ashen, venin }, ctx({ ttdSecs = 24, manaWeight = 0 }))
check('mana not binding: Ashengate first (most damage per caster second)', r[1].entry == ashen, r[1].entry.spell)
r = R.rank({ vakk, ashen, venin }, ctx({ ttdSecs = 24, manaWeight = 1 }))
check('manaWeight 1 orders like efficiency', r[1].entry == vakk, r[1].entry.spell)
r = R.rank({ vakk, ashen, venin }, ctx({ ttdSecs = 24, manaWeight = 1, mode = 'burn' }))
check('burn mode ignores manaWeight (1 would order like efficiency)', r[1].entry == ashen, r[1].entry.spell)

-- ---------------------------------------------------------------- remaining-HP cap, second pass
-- my running DoTs are subtracted: 3 ticks of 1000 left on a mob with 2500 hp -> nothing to add
r = R.rank({ vakk, venin }, ctx({ ttdSecs = 999, remainingHP = 2500, runningDots = { { spell = 'X', perTick = 1000, leftSec = 20 } } }))
check('my running DoTs already cover the HP left: no pick', #r == 0 and tostring(R.excluded()['Venin']):find('already cover', 1, true) ~= nil, R.excluded()['Venin'])
-- ... 2 ticks left of 1000 on 2500: 500 left for new casts
r = R.rank({ venin }, ctx({ ttdSecs = 999, remainingHP = 2500, runningDots = { { spell = 'X', perTick = 1000, leftSec = 13 } } }))
check('cap uses the HP left after my DoTs', r[1] and math.abs(r[1].expected - 500) < 0.01, r[1] and r[1].expected)
-- a capped DoT that would finish the mob in one tick is a nuke's job when a nuke can finish it...
r = R.rank({ vakk, venin }, ctx({ ttdSecs = 999, remainingHP = 500 }))
check('one-tick finisher DoT dropped when a nuke finishes the mob', #r == 1 and r[1].entry == venin
  and R.excluded()["Vakk`dra's Sickly Mists"] == 'a nuke finishes the mob sooner', R.excluded()["Vakk`dra's Sickly Mists"])
-- ... but with no nuke castable it is still offered: something has to finish the mob
r = R.rank({ vakk }, ctx({ ttdSecs = 999, remainingHP = 500 }))
check('one-tick finisher DoT kept when no nuke can finish', #r == 1 and r[1].oneTick == true, #r)
-- my running DoTs cover the HP: a healing lifetap is still worth its heal
r = R.rank({ iglum, venin }, ctx({ ttdSecs = 999, remainingHP = 2000, pctHPs = 40, missingHP = 6000,
  runningDots = { { spell = 'X', perTick = 1000, leftSec = 30 } }, spellStats = function(s) return shdStats[s] end }))
check('HP covered by my DoTs: only the healing tap is offered', #r == 1 and r[1].entry == iglum and r[1].heal > 0, #r)
-- the lottery cap counts my running DoTs' ticks as boostable, not as already spent
local dfbRun = find(R.rank({ dfb }, ctx({ ttdSecs = 999, remainingHP = 12000,
  runningDots = { { spell = 'A', perTick = 1500, leftSec = 18 }, { spell = 'B', perTick = 1000, leftSec = 24 } } })), 'Demand for Blood')
check('DfB lottery keeps the value of my running DoTs near the cap', dfbRun and dfbRun.synergy > 500, dfbRun and dfbRun.synergy)
-- with no nuke able to finish it, a capped DoT stays ranked and shows the ticks it needs
r = R.rank({ vakk }, ctx({ ttdSecs = 999, remainingHP = 2000 }))
check('capped DoT with no finishing nuke is kept', r[1] and r[1].capped and tostring(r[1].reason):find('3 of 7 ticks', 1, true) ~= nil, r[1] and r[1].reason)
-- dominance: two DoTs alike but for damage - the stronger never ranks below the weaker
local weak = { index = 20, spell = 'Weak DoT', mana = 866, castSec = 3, recastSec = 1.5, durSec = 42, isDot = true, base = 700, resistType = 'poison' }
for _, remHP in ipairs({ 3000, 4000, 5000, 6009, 8000 }) do
  for _, mw in ipairs({ 0, 0.5, 1 }) do
    r = R.rank({ weak, vakk }, ctx({ ttdSecs = 60, remainingHP = remHP, manaWeight = mw }))
    local sv, sw = find(r, "Vakk`dra's Sickly Mists"), find(r, 'Weak DoT')
    check(string.format('dominance at %d hp, weight %.1f', remHP, mw), sv and sw and sv.score >= sw.score - 1e-9,
      sv and sw and string.format('%.3f vs %.3f', sv.score, sw.score))
  end
end
-- the Power tier and Gift of Mana do not promote a capped finisher DoT
r = R.rank({ vakk, drain }, ctx({ ttdSecs = 999, remainingHP = 3000, powerUp = true, powerLeftSec = 40, mode = 'burn' }))
local cv = find(r, "Vakk`dra's Sickly Mists")
check('Power: a capped DoT gets no DoT-first tier', cv == nil or cv.tier == 1, cv and cv.tier)
r = R.rank({ lv(vakk, 74) }, ctx({ ttdSecs = 999, remainingHP = 2000, gom = { up = true } }))
check('GoM is not spent on a capped finisher DoT', r[1] and not r[1].gom, r[1] and tostring(r[1].gom))
-- fallback picks: no GoM, no Chaotic tier
r = R.rank({ lv(mists, 74), lv(pyre, 74), lv(venin, 71) }, ctx({ ttdSecs = 90, named = true, gom = { up = true }, powerUp = true, powerLeftSec = 40,
  listResistTypes = { 'disease', 'fire', 'poison' }, mobResist = function(t) return ({ disease = 0.9, fire = 0.95, poison = 0.55 })[t] end }))
check('fallback: no GoM and no Chaotic tier on fallback picks, order is by score', #r == 3 and (function()
  for i, x in ipairs(r) do
    if x.gom or x.tier ~= 0 or not x.fallback then return false end
    if i > 1 and r[i - 1].score < x.score then return false end
  end
  return true end)(), #r)
-- DfB's lottery on a nearly dead mob is bounded by the HP left after its own hit
r = R.rank({ dfb, vakk, ashen }, ctx({ ttdSecs = 999, remainingHP = 2500, runningDots = {} }))
local dd = find(r, 'Demand for Blood')
check('DfB lottery bounded by HP left', dd and dd.synergy <= 0.25 * 0.85 * 0.42 * (2500 - 1881.9) + 1e-6, dd and dd.synergy)
-- ... and skips a DoT its confirmed blocker would stop (Dread after Ashengate)
local dread = { index = 5, spell = 'Dread Pyre', mana = 1093, castSec = 3, recastSec = 1.5, durSec = 30, isDot = true, base = 956, resistType = 'fire' }
local blockFn = function(sp) if sp == 'Dread Pyre' then return { ['Ashengate Pyre'] = true } end end
local a1 = find(R.rank({ dfb, ashen, dread }, ctx({ ttdSecs = 90, runningDots = {} })), 'Demand for Blood').synergy
local a2 = find(R.rank({ dfb, ashen, dread }, ctx({ ttdSecs = 90, runningDots = {}, stackBlocked = blockFn })), 'Demand for Blood').synergy
check('DfB lottery drops Dread behind Ashengate', a2 < a1, string.format('%.1f vs %.1f', a2, a1))

io.write(string.format('test_ranker: %d passed, %d failed\n', pass, fail))
os.exit(fail == 0 and 0 or 1)
