-- Run: luajit tests/test_procs.lua   (from F:\lua\necrobrain)
package.path = './necrobrain/?.lua;./?.lua;' .. package.path
local F = require('tests.necrobrain_fakes')
local pass, fail = 0, 0
local function check(name, cond, detail)
  if cond then pass = pass + 1 else fail = fail + 1; io.write('FAIL: ' .. name .. (detail and (' -- ' .. tostring(detail)) or '') .. '\n') end
end
local Procs = require('procs')

-- nothing up
F.songs, F.buffs = {}, {}
local fx = Procs.read()
check('nothing up', not fx.gom.up and not fx.power.up and not fx.weakness.up and fx.ok)

-- Gift of Mana (75) in the song window: found by the base name, cap from its SPA 134 slot
F.songs = { ['Gift of Mana (75)'] = { id = 3, ms = 14500, spell = { attrib = { 132, 311, 134, 348 }, base = { 100, 0, 75, 1 } } } }
fx = Procs.read()
check('GoM (75) found by its base name', fx.gom.up and fx.gom.name == 'Gift of Mana (75)', fx.gom.name)
check('GoM window is the song window', fx.gom.window == 'Song', fx.gom.window)
check('GoM time left in seconds', fx.gom.leftSec == 14.5, fx.gom.leftSec)
check('GoM cap from the limit slot', fx.gom.levelCap == 75, fx.gom.levelCap)

-- no readable limit slot: the cap comes from the name
F.songs = { ['Gift of Mana (80)'] = { id = 3, ms = 9000 } }
fx = Procs.read()
check('GoM cap from the name when the slot is unreadable', fx.gom.levelCap == 80, fx.gom.levelCap)

-- the Radiant form, with a cap of 75 in its slot
F.songs = { ['Gift of Radiant Mana'] = { id = 2, ms = 9000, spell = { attrib = { 132, 311, 134, 348 }, base = { 100, 0, 75, 1 } } } }
fx = Procs.read()
check('Radiant form found', fx.gom.up and fx.gom.levelCap == 75, fx.gom.levelCap)

-- plain Gift of Mana with no cap anywhere
F.songs = { ['Gift of Mana'] = { id = 1, ms = 9000 } }
fx = Procs.read()
check('uncapped GoM has no cap', fx.gom.up and fx.gom.levelCap == nil, fx.gom.levelCap)

-- Chaotic Power in the buff window, Chaotic Weakness in the song window: both windows are read
F.songs = { ['Chaotic Weakness'] = { id = 4, ms = 11000 } }
F.buffs = { ['Chaotic Power II'] = { id = 9, ms = 48000 } }
fx = Procs.read()
check('Power found in the buff window', fx.power.up and fx.power.window == 'Buff' and fx.power.leftSec == 48, fx.power.leftSec)
check('Weakness found in the song window', fx.weakness.up and fx.weakness.window == 'Song' and fx.weakness.leftSec == 11, fx.weakness.leftSec)
check('GoM not up', not fx.gom.up)
F.songs, F.buffs = {}, { ['Chaotic Weakness'] = { id = 2, ms = 6000 } }
fx = Procs.read()
check('Weakness found in the buff window too', fx.weakness.up and fx.weakness.window == 'Buff', fx.weakness.window)

-- a TLO failure is reported, never raised
F.tloError = true
local ok, res = pcall(Procs.read)
check('TLO failure does not raise', ok, res)
check('TLO failure is reported as not ok', ok and res.ok == false and not res.power.up, ok and res.ok)
F.tloError = nil

-- gem screen
local entries = {
  { spell = 'Demand for Blood', rankName = 'Demand for Blood' },
  { spell = 'Venin' },
  { spell = 'Life Burn', isAA = true },
}
F.gems = { Venin = 7 }
local mem, known = Procs.memorized(entries)
check('memorized spell reads true', mem['Venin'] == true)
check('missing gem reads false', mem['Demand for Blood'] == false)
check('AA entries are left out', mem['Life Burn'] == nil)
check('known when any spell reads as memorized', known == true)
F.gems = { ['Venin Rk. II'] = 7 }
mem = Procs.memorized({ { spell = 'Venin', rankName = 'Venin Rk. II' } })
check('the rank name is what is looked up', mem['Venin'] == true)
F.gems = {}
mem, known = Procs.memorized(entries)
check('no gem data at all: unknown, so the caller skips the screen', known == false)
F.tloError = true
mem, known = Procs.memorized(entries)
check('TLO failure: unknown', known == false and mem['Venin'] == false)
F.tloError = nil
mem, known = Procs.memorized({ { spell = 'Life Burn', isAA = true } })
check('an AA-only list is known (nothing to screen)', known == true)

io.write(string.format('test_procs: %d passed, %d failed\n', pass, fail))
os.exit(fail == 0 and 0 or 1)
