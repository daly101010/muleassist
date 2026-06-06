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
  -- inject a debuffall DPS entry to exercise the DebuffAll bucket (clear list cache first)
  cfg.sections['DPS'] = cfg.sections['DPS'] or {}
  cfg.sections['DPS']['DPSSize'] = '3'
  cfg.sections['DPS']['DPS3'] = 'Malosini|101|debuffall'
  cfg._lists = {}
  local st  = state.new(cfg)
  combat.setup(st)
  assert(type(st.combat.debuff_all) == 'table', 'debuff_all is a table')
  local found_da = false
  for _, e in ipairs(st.combat.debuff_all) do if e.target == 'debuffall' then found_da = true end end
  assert(found_da, 'Malosini|101|debuffall bucketed into debuff_all')
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
