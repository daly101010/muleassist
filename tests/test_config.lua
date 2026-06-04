-- muleassist/tests/test_config.lua  (game-independent: pure Lua + io)
local config = require('muleassist.config')

-- locate the fixture relative to THIS file, so cwd doesn't matter
local here = debug.getinfo(1, 'S').source:sub(2):gsub('[^/\\]+$', '')
local FIXTURE = here .. 'fixtures/sample.ini'

local t = {}
function t.run()
  local cfg = config.load(FIXTURE)
  assert(cfg, 'config.load returned nil for '..FIXTURE)
  assert(cfg:get('General', 'Role', 'x') ~= 'x', 'General.Role missing')
  assert(cfg:bool('Pet', 'PetOn', false) == true, 'PetOn should be true in fixture')
  assert(type(cfg:num('Melee', 'AssistAt', 0)) == 'number', 'AssistAt not numeric')

  local dps = cfg:list('dps')
  assert(#dps >= 1, 'dps list empty')
  assert(dps[1].spell and dps[1].spell ~= '', 'dps[1].spell empty')
  -- fixture: DPS1=Envenomed Bolt|99  -> spell/param split
  assert(dps[1].param == '99', 'dps[1].param expected 99, got '..tostring(dps[1].param))
  -- DPSCond1 should be carried
  assert(dps[1].cond and dps[1].cond:find('PctMana'), 'dps[1].cond not parsed')

  -- args[] exposes every pipe field (the macro's .Arg[n,|])
  local heals = cfg:list('heals')
  assert(#heals >= 1, 'no heals in fixture')
  assert(type(heals[1].args) == 'table', 'heals[1].args missing')
  assert(heals[1].args[1] == heals[1].spell, 'args[1] should equal spell')
  -- Heals2=Complete Healing|60|MA -> three fields
  local h2
  for _, e in ipairs(heals) do if e.spell == 'Complete Healing' then h2 = e end end
  assert(h2 and h2.args[2] == '60' and h2.args[3] == 'MA', 'three-field split failed')

  print('test_config: PASS ('..#dps..' dps entries)')
  return true
end
return t
