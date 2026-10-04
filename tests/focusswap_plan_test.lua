-- Run: luajit tests/test_plan.lua   (from lua/muleassist)
package.path = './?.lua;./?/init.lua;' .. package.path
local pass, fail = 0, 0
local function check(name, cond, detail)
  if cond then pass = pass + 1 else fail = fail + 1; io.write('FAIL: ' .. name .. (detail ~= nil and (' -- ' .. tostring(detail)) or '') .. '\n') end
end
local function near(a, b) return type(a) == 'number' and math.abs(a - b) < 1e-9 end
local P = require('focusswap.plan')
local Fx = require('tests.focusswap.fixtures')

local POISON = 'Breeches of Whispered Death'
local FIRE = 'Breeches of Phenomenal Power'
local function pants(which)
  if which == 'poison' then return Fx.item(POISON, Fx.MURK_BLOOD, { 'legs' }, 'Murk Blood') end
  return Fx.item(FIRE, Fx.PYRILEN_FURY, { 'legs' }, 'Pyrilen Fury')
end
local spells = { Fx.POISON_DOT, Fx.FIRE_DOT }

local invA = { worn = { legs = pants('poison') }, bag = { pants('fire') } }
local a = P.build(invA, spells)
check('two entries', #a.entries == 2, #a.entries)
check('poison DoT wants the poison pants', a.entries[1].spell == 'Chaos Venom' and a.entries[1].item == POISON and a.entries[1].slot == 'legs')
check('fire DoT wants the fire pants', a.entries[2] and a.entries[2].item == FIRE)
check('gain is the full focus', a.entries[2] and near(a.entries[2].gain, 15.5), a.entries[2] and a.entries[2].gain)
check('map string', a.map == '|Chaos Venom>' .. POISON .. '>legs|Ignite Blood>' .. FIRE .. '>legs|', a.map)

local invB = { worn = { legs = pants('fire') }, bag = { pants('poison') } }
check('map is the same whichever pants are worn', P.build(invB, spells).map == a.map)

-- a fire cloak worn alongside already covers fire spells
local cloak = Fx.item('Putrid Cloak of the Hag', Fx.PYRILEN_FURY, { 'back' }, 'Pyrilen Fury')
local c = P.build({ worn = { legs = pants('poison'), back = cloak }, bag = { pants('fire') } }, spells)
check('fire cloak: only the poison entry', #c.entries == 1 and c.entries[1].spell == 'Chaos Venom', #c.entries)

-- a gain under MinGain publishes nothing
local weak = { { attrib = 124, base = 1, base2 = 4 }, { attrib = 135, base = 2 } }
local invD = { worn = { legs = pants('poison') }, bag = { Fx.item('Weak Fire Pants', weak, { 'legs' }) } }
local d = P.build(invD, spells)
check('a 2.5 gain is under MinGain 3: no fire entry', #d.entries == 1 and d.entries[1].spell == 'Chaos Venom', #d.entries)
check('MinGain 2 lets it in', #P.build(invD, spells, { minGain = 2 }).entries == 2)

-- two contested slots for one spell: the bigger gain wins
local bigFire = { { attrib = 124, base = 1, base2 = 60 }, { attrib = 135, base = 2 } }
local invE = { worn = { legs = pants('poison'), leftwrist = Fx.item('Plain Bracer', nil, { 'leftwrist' }) },
  bag = { pants('fire'), Fx.item('Fire Bracer', bigFire, { 'leftwrist' }) } }
local e = P.build(invE, { Fx.FIRE_DOT })
check('wrist gain 30.5 beats legs gain 15.5', #e.entries == 1 and e.entries[1].slot == 'leftwrist' and e.entries[1].item == 'Fire Bracer', e.entries[1] and e.entries[1].slot)

-- a blocked item drops out
local f = P.build(invA, spells, { blocked = { [FIRE] = true } })
check('blocked fire pants: legs no longer contested', #f.entries == 0 and f.map == '', #f.entries)

-- cut on whole entries
local t = P.build(invA, spells, { maxLen = 60 })
check('truncated flag', t.truncated == true)
check('only whole entries kept', t.map == '|Chaos Venom>' .. POISON .. '>legs|', t.map)

-- EQ applies only the best focus of each type
local twoPoison = { Fx.item('A', Fx.MURK_BLOOD, {}), Fx.item('B', { { attrib = 124, base = 10 }, { attrib = 135, base = 4 } }, {}) }
check('best of a type counts, not the sum', near(P.setScore(twoPoison, Fx.POISON_DOT), 15.5), P.setScore(twoPoison, Fx.POISON_DOT))
check('weights override', near(P.setScore(twoPoison, Fx.POISON_DOT, { [124] = 2 }), 31))

-- a duration focus pays only on a DoT
local dur = { Fx.item('Dur', { { attrib = 128, base = 20 } }, {}) }
check('duration focus counts on a DoT', near(P.setScore(dur, Fx.FIRE_DOT), 20))
check('duration focus is worth nothing on a nuke', P.setScore(dur, Fx.FIRE_NUKE) == 0)

check('nothing contested: empty map', P.build({ worn = { legs = pants('poison') }, bag = {} }, spells).map == '')

-- muleassist's LoadIni rewrites DPS entries to the spell's RankName, so the map is keyed on that
local rankedFire = Fx.spell({ name = 'Ignite Blood', id = 1002, resist = 'fire', key = 'Ignite Blood Rk. II' })
local rk = P.build(invA, { rankedFire })
check('map keys on the spell\'s key, not its name', rk.map == '|Ignite Blood Rk. II>' .. FIRE .. '>legs|', rk.map)

io.write(string.format('test_plan: %d passed, %d failed\n', pass, fail))
os.exit(fail == 0 and 0 or 1)
