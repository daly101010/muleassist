-- muleassist/tests/test_pet.lua  (runs in-game; pet.setup only logs)
local config = require('muleassist.config')
local state  = require('muleassist.state')
local pet    = require('muleassist.pet')

local here = debug.getinfo(1, 'S').source:sub(2):gsub('[^/\\]+$', '')
local FIXTURE = here .. 'fixtures/sample.ini'

local t = {}
function t.run()
  local cfg = config.load(FIXTURE)
  assert(cfg, 'config.load returned nil for ' .. FIXTURE)
  local st = state.new(cfg)
  pet.setup(st)

  assert(st.pet.on == true, 'PetOn from fixture (1)')
  assert(st.pet.spell == 'Emissary of Thule', 'PetSpell from fixture')
  assert(st.pet.hold == 'hold', 'PetHold defaults to hold')
  assert(st.pet.hold_on == true, 'PetHoldOn from fixture (1)')
  assert(st.pet.taunt_on == false, 'PetTauntOn defaults false')
  assert(st.pet.summon_until == 0, 'pet summon_until runtime init')
  assert(st.pet.taunt_set == false, 'pet taunt_set runtime init')

  print('test_pet: PASS')
  return true
end
return t
