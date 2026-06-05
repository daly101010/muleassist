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

  assert(type(st.rez) == 'table', 'st.rez missing')
  assert(st.rez.radius == 150, 'rez radius const')
  assert(type(st.rez.battle_timers) == 'table', 'battle_timers missing')
  assert(type(st.rez.ooc_timers) == 'table', 'ooc_timers missing')

  assert(type(st.buff) == 'table', 'st.buff missing')
  assert(st.buff.check_secs == 10, 'default CheckBuffsTimer should be 10')
  assert(type(st.buff.entries) == 'table' and type(st.buff.timers) == 'table',
    'st.buff.entries/timers should be tables')

  assert(type(st.combat) == 'table', 'st.combat missing')
  assert(st.combat.assist_at == 95, 'default AssistAt 95')
  assert(type(st.combat.dps_timers) == 'table' and type(st.combat.entries) == 'table',
    'combat tables missing')
  assert(type(st.combat.aggro) == 'table' and type(st.combat.debuffs) == 'table',
    'combat aggro/debuffs tables missing')
  assert(st.combat.aggro_on == false, 'default AggroOn false')

  assert(type(st.med) == 'table', 'st.med missing')
  assert(st.med.start == 20, 'MedStart from fixture (20)')

  assert(type(st.move) == 'table', 'st.move missing')
  assert(st.move.chase_distance == 25, 'default ChaseDistance 25')

  assert(type(st.pull) == 'table', 'st.pull missing')
  assert(st.pull.max_radius == 350, 'MaxRadius from fixture (350)')
  assert(st.pull.state == 'idle', 'pull starts idle')

  print('test_state: PASS')
  return true
end
return t
