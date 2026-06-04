-- muleassist/tests/test_state.lua  (game-independent)
local config = require('muleassist.config')
local state  = require('muleassist.state')

local here = debug.getinfo(1, 'S').source:sub(2):gsub('[^/\\]+$', '')
local FIXTURE = here .. 'fixtures/sample.ini'

local t = {}
function t.run()
  local cfg = config.load(FIXTURE)
  assert(cfg, 'config.load returned nil for '..FIXTURE)
  local st = state.new(cfg)

  assert(st.role and st.role ~= '', 'role unset')
  assert(type(st.flags) == 'table', 'flags missing')
  assert(st.flags.pet_on == cfg:bool('Pet', 'PetOn', false), 'pet_on mismatch')
  assert(st.camp and st.camp.radius == cfg:num('General', 'CampRadius', 60), 'camp radius mismatch')
  assert(type(st.lists.dps) == 'table', 'dps list not attached')

  assert(type(st.heal) == 'table', 'st.heal missing')
  assert(st.heal.duration_mod ~= nil, 'duration_mod missing')
  assert(type(st.heal.timers) == 'table', 'heal.timers missing')
  assert(type(st.hooks) == 'table', 'st.hooks missing')
  assert(type(st.combat) == 'table', 'st.combat missing')
  assert(st.flags.buff_mode == false, 'buff_mode default')

  print('test_state: PASS')
  return true
end
return t
