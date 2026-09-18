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
  assert(cfg:bool('AutoClass', 'AutoClassOn', false) == true, 'AutoClassOn should be true in fixture')
  assert(cfg:get('AutoClass', 'Family', nil) == 'Live', 'AutoClass.Family missing')
  assert(cfg:get('MySpells', 'Gem1', nil) == 'Envenomed Bolt', 'MySpells.Gem1 missing')
  assert(cfg:get('MySpells', 'Gem3', nil) == 'NULL', 'MySpells.Gem3 should preserve NULL')

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

  local dflt = config.default{ path = 'memory.ini', class = 'Cleric', level = 60, role = 'None' }
  assert(dflt:get('General', 'Role', nil) == 'Assist', 'default should normalize role None to Assist')
  assert(dflt:bool('AutoClass', 'AutoClassOn', false) == true, 'default should enable AutoClass')
  assert(dflt:num('SpellSet', 'LoadSpellSet', 0) == 2, 'default should use MySpells spellset mode')
  assert(dflt:num('Melee', 'AssistAt', 0) == 95, 'default AssistAt missing')
  assert(dflt:bool('AutoClass', 'FillEmptyLists', false) == true, 'default should enable list baseline fill')

  print('test_config: PASS ('..#dps..' dps entries)')
  return true
end
return t
