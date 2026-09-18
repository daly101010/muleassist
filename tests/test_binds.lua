-- muleassist/tests/test_binds.lua  (runs in-game; exercises settings.set/toggle re-derive)
-- NOTE: settings.set persists via config.save(cfg). We point cfg.path at a temp file so the
-- shared fixture on disk is never modified, then clean it up.
local config   = require('muleassist.config')
local state    = require('muleassist.state')
local settings = require('muleassist.settings')
local binds    = require('muleassist.binds')

local here = debug.getinfo(1, 'S').source:sub(2):gsub('[^/\\]+$', '')
local FIXTURE = here .. 'fixtures/sample.ini'
local TMP     = here .. 'fixtures/_tmp_test_binds.ini'

local t = {}
function t.run()
  local cfg = config.load(FIXTURE)
  assert(cfg, 'config.load returned nil for ' .. FIXTURE)
  local st = state.new(cfg)
  st.cfg.path = TMP                      -- redirect persistence away from the fixture

  -- settings.set re-derives the relevant st field live
  settings.set(st, 'Melee', 'AssistAt', 77)
  assert(st.combat.assist_at == 77, 'settings.set updated combat.assist_at live')
  settings.set(st, 'Melee', 'MeleeOn', 1)
  assert(st.combat.melee_on == true, 'settings.set enabled melee live')

  -- settings.toggle flips a 0/1 flag and re-derives
  settings.set(st, 'Pet', 'PetOn', 0)
  assert(st.pet.on == false, 'PetOn set to 0')
  local v = settings.toggle(st, 'Pet', 'PetOn')
  assert(st.pet.on == true, 'toggle flipped PetOn to on')
  assert(v == '1', 'toggle returned new value 1')

  -- bind tables are present and well-formed
  assert(type(binds.TOGGLES) == 'table' and binds.TOGGLES.buffson[1] == 'Buffs',
    'TOGGLES table exposes buffson -> Buffs')
  assert(binds.TOGGLES.cureson[1] == 'Cures' and binds.TOGGLES.cureson[2] == 'CuresOn',
    'TOGGLES table exposes cureson -> Cures.CuresOn')
  assert(binds.TOGGLES.targetswitching[1] == 'Melee'
    and binds.TOGGLES.targetswitching[2] == 'TargetSwitchingOn',
    'TOGGLES table exposes targetswitching -> Melee.TargetSwitchingOn')
  assert(binds.TOGGLES.mercon[1] == 'Merc' and binds.TOGGLES.mercon[2] == 'MercOn',
    'TOGGLES table exposes mercon -> Merc.MercOn')
  assert(type(binds.INTS) == 'table' and binds.INTS.assistat[2] == 'AssistAt',
    'INTS table exposes assistat -> AssistAt')
  assert(binds.INTS.mercassistat[1] == 'Merc' and binds.INTS.mercassistat[2] == 'MercAssistAt',
    'INTS table exposes mercassistat -> Merc.MercAssistAt')
  assert(binds.INTS.afktoolson[1] == 'AFKTools' and binds.INTS.afktoolson[2] == 'AFKToolsOn',
    'INTS table exposes afktoolson -> AFKTools.AFKToolsOn')

  os.remove(TMP)
  print('test_binds: PASS')
  return true
end
return t
