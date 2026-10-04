-- Run: luajit tests/test_limits.lua   (from lua/muleassist)
package.path = './?.lua;./?/init.lua;' .. package.path
local pass, fail = 0, 0
local function check(name, cond, detail)
  if cond then pass = pass + 1 else fail = fail + 1; io.write('FAIL: ' .. name .. (detail ~= nil and (' -- ' .. tostring(detail)) or '') .. '\n') end
end
local function near(a, b) return type(a) == 'number' and math.abs(a - b) < 1e-9 end
local L = require('focusswap.limits')
local Fx = require('tests.focusswap.fixtures')

local foci, unknown = L.fromEffects('Murk Blood', Fx.MURK_BLOOD)
check('Murk Blood is one damage focus', #foci == 1 and foci[1].spa == 124, #foci)
check('range roll kept as lo/hi', foci[1].lo == 1 and foci[1].hi == 30)
check('all its limits are known', unknown == nil and foci[1].unknown == nil)
local murk = foci[1]
local pyr = L.fromEffects('Pyrilen Fury', Fx.PYRILEN_FURY)[1]

check('poison DoT: Murk applies', L.applies(murk, Fx.POISON_DOT))
check('poison DoT: Pyrilen does not', not L.applies(pyr, Fx.POISON_DOT))
check('fire DoT: Pyrilen applies', L.applies(pyr, Fx.FIRE_DOT))
check('expected value of a 1-30 roll is 15.5', near(L.value(murk, Fx.POISON_DOT), 15.5), L.value(murk, Fx.POISON_DOT))

local lvl72 = Fx.spell({ level = 72 })
check('2 levels over a decaying cap still applies', L.applies(murk, lvl72))
check('decay 5%/level: 15.5 * 0.9', near(L.value(murk, lvl72), 13.95), L.value(murk, lvl72))
check('20 levels over decays to 0', near(L.value(murk, Fx.spell({ level = 90 })), 0))

local hard = L.fromEffects('Hard', { { attrib = 124, base = 10, base2 = 0 }, { attrib = 134, base = 70, base2 = 0 } })[1]
check('fixed value focus', near(L.value(hard, Fx.POISON_DOT), 10))
check('hard cap: level 71 excluded', not L.applies(hard, Fx.spell({ level = 71 })))
check('hard cap: level 70 included', L.applies(hard, Fx.spell({ level = 70 })))

check('detrimental-only focus skips a beneficial spell', not L.applies(murk, Fx.spell({ beneficial = true })))
check('HP-effect limit skips a spell with no HP slot', not L.applies(murk, Fx.spell({ spas = { [11] = true } })))

local procsOnly = L.fromEffects('P', { { attrib = 124, base = 5 }, { attrib = 311, base = 1 } })[1]
check('procs-only focus never applies to a gem cast', not L.applies(procsOnly, Fx.POISON_DOT))

local minDur = L.fromEffects('D', { { attrib = 124, base = 5 }, { attrib = 140, base = 1 } })[1]
check('min duration: DoT in', L.applies(minDur, Fx.FIRE_DOT))
check('min duration: nuke out', not L.applies(minDur, Fx.FIRE_NUKE))
local instant = L.fromEffects('I', { { attrib = 124, base = 5 }, { attrib = 141, base = 1 } })[1]
check('instant only: nuke in', L.applies(instant, Fx.FIRE_NUKE))
check('instant only: DoT out', not L.applies(instant, Fx.FIRE_DOT))

local exclSpell = L.fromEffects('X', { { attrib = 124, base = 5 }, { attrib = 139, base = -1001 } })[1]
check('spell exclude hits that spell', not L.applies(exclSpell, Fx.POISON_DOT))
check('spell exclude leaves others', L.applies(exclSpell, Fx.FIRE_DOT))
local inclSpell = L.fromEffects('Y', { { attrib = 124, base = 5 }, { attrib = 139, base = 1002 }, { attrib = 139, base = 1003 } })[1]
check('spell include list: any match passes', L.applies(inclSpell, Fx.FIRE_NUKE))
check('spell include list: no match fails', not L.applies(inclSpell, Fx.POISON_DOT))

local inclTarget = L.fromEffects('T', { { attrib = 124, base = 5 }, { attrib = 136, base = 5 } })[1]
check('unmapped target type never passes an include', not L.applies(inclTarget, Fx.POISON_DOT))

local odd, unk = L.fromEffects('Odd', { { attrib = 124, base = 5 }, { attrib = 999, base = 1 } })
check('unknown limit SPA reported', unk ~= nil and unk[1] == 999)
check('focus with an unknown limit never applies', not L.applies(odd[1], Fx.POISON_DOT))

local blanks = L.fromEffects('B', { { attrib = 124, base = 5 }, { attrib = 254, base = 0 }, { attrib = 10, base = 0 }, { attrib = 0, base = 0 } })
check('blank slots ignored', #blanks == 1 and blanks[1].unknown == nil)
check('a worn effect with no focus slot is not a focus', #L.fromEffects('Haste', { { attrib = 11, base = 121 } }) == 0)

io.write(string.format('test_limits: %d passed, %d failed\n', pass, fail))
os.exit(fail == 0 and 0 or 1)
