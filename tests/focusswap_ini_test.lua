-- Run: luajit tests/test_ini.lua   (from lua/muleassist)
package.path = './?.lua;./?/init.lua;' .. package.path
local pass, fail = 0, 0
local function check(name, cond, detail)
  if cond then pass = pass + 1 else fail = fail + 1; io.write('FAIL: ' .. name .. (detail ~= nil and (' -- ' .. tostring(detail)) or '') .. '\n') end
end
local Ini = require('focusswap.ini')

local text = table.concat({
  '[General]', 'Role=Assist',
  '[DPS]', 'DPSOn=1', 'DPSSize=5',
  'DPS1=Chaos Venom|99', 'DPS2=Ignite Blood|95|once', 'DPS3=NULL', 'DPS4=Chaos Venom|50', 'DPS5=',
  'DPSCond1=TRUE',
  '[FocusSwap]', 'FocusSwapOn=1', 'FocusSwapMinGain=5', 'Weight132=0.8', 'WeightX=abc', 'Weight124=oops',
}, '\r\n')
local s = Ini.parse(text)
check('sections parsed across CRLF', s.General and s.General.Role == 'Assist' and s.DPS and s.DPS.DPSSize == '5')
local names = Ini.dpsSpells(s)
check('DPS spells in order, deduped, NULL and blank skipped', #names == 2 and names[1] == 'Chaos Venom' and names[2] == 'Ignite Blood', table.concat(names, ','))
check('MinGain readable', s.FocusSwap.FocusSwapMinGain == '5')
local w = Ini.weights(s, { [124] = 1.0, [132] = 0.5 })
check('override applied', w[132] == 0.8, w[132])
check('bad values ignored', w[124] == 1.0, w[124])
check('defaults not mutated', Ini.weights({}, { [132] = 0.5 })[132] == 0.5)

local noSize = Ini.parse('[DPS]\nDPS1=Chaos Venom\nDPS3=Ignite Blood|99\n')
local n2 = Ini.dpsSpells(noSize)
check('no DPSSize: every DPS<n> up to the highest', #n2 == 2 and n2[2] == 'Ignite Blood', #n2)
check('no DPS section: empty list', #Ini.dpsSpells(Ini.parse('[General]\nx=1\n')) == 0)

io.write(string.format('test_ini: %d passed, %d failed\n', pass, fail))
os.exit(fail == 0 and 0 or 1)
