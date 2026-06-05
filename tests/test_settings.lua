-- muleassist/tests/test_settings.lua  (runs in-game; setups call mq.TLO)
local config   = require('muleassist.config')
local state    = require('muleassist.state')
local settings = require('muleassist.settings')

local here = debug.getinfo(1, 'S').source:sub(2):gsub('[^/\\]+$', '')
local FIXTURE = here .. 'fixtures/sample.ini'

local t = {}
function t.run()
  local cfg = config.load(FIXTURE)
  assert(cfg, 'config.load returned nil for ' .. FIXTURE)
  local st = state.new(cfg)

  -- plant runtime sentinels that must survive a reapply
  st.camp.x, st.camp.y, st.camp.z = 10, 20, 30
  st.pull.state = 'outbound'; st.pull.target_id = 4242
  st.combat.combat_start = 12345

  local ok = settings.reapply(st)
  assert(ok, 'settings.reapply returned true')

  assert(st.camp.x == 10, 'reapply preserved camp.x')
  assert(st.pull.state == 'outbound', 'reapply preserved pull.state')
  assert(st.pull.target_id == 4242, 'reapply preserved pull.target_id')
  assert(st.combat.combat_start == 12345, 'reapply preserved combat runtime')

  assert(type(st.combat.entries) == 'table', 'combat entries rebuilt')
  assert(type(st.buff.entries) == 'table', 'buff entries rebuilt')
  assert(type(st.heal.single) == 'table', 'heal single rebuilt')

  print('test_settings: PASS')
  return true
end
return t
