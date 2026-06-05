-- muleassist/tests/test_combat.lua
-- Offline: DPS/Burn parse + setup. Cast/engage paths verified in-game.
local config = require('muleassist.config')
local state  = require('muleassist.state')
local combat = require('muleassist.combat')

local here = debug.getinfo(1, 'S').source:sub(2):gsub('[^/\\]+$', '')
local FIXTURE = here .. 'fixtures/sample.ini'

local t = {}
function t.run()
  local cfg = config.load(FIXTURE)
  local st  = state.new(cfg)
  combat.setup(st)
  assert(type(st.combat.entries) == 'table', 'entries missing')
  assert(type(st.combat.burn) == 'table', 'burn missing')
  for _, e in ipairs(st.combat.entries) do
    assert(e.spell and e.spell ~= '', 'dps entry missing spell')
    assert(not e.is_debuff, 'debuff entry leaked into rotation')
    assert(type(e.hp_pct) == 'number', 'hp_pct should be number')
  end
  print('test_combat: PASS (' .. #st.combat.entries .. ' dps, ' .. #st.combat.burn .. ' burn)')
  return true
end
return t
