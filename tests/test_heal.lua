-- muleassist/tests/test_heal.lua
-- Categorization + sort are exercised offline by overriding the TargetType resolver
-- (mq.TLO.Spell is unavailable without a live client). Cast paths are verified in-game.
local config = require('muleassist.config')
local state  = require('muleassist.state')
local heal   = require('muleassist.heal')

local here = debug.getinfo(1, 'S').source:sub(2):gsub('[^/\\]+$', '')
local FIXTURE = here .. 'fixtures/sample.ini'

local t = {}
function t.run()
  local cfg = config.load(FIXTURE)
  cfg.sections['Cures'] = cfg.sections['Cures'] or {}
  cfg.sections['Cures']['CuresOn'] = '3'
  cfg.sections['Cures']['CuresSize'] = '2'
  cfg.sections['Cures']['Cures1'] = 'Remove Greater Curse|curse'
  cfg.sections['Cures']['Cures2'] = 'Purify Soul|me'
  cfg._lists = {}
  local st = state.new(cfg)

  -- Offline resolver: tag/name-based classification only.
  heal._resolve_target_type = function(_) return 'Single' end
  heal.setup(st, { class_short = 'CLR', class_name = 'Cleric' })

  assert(#st.heal.single + #st.heal.group >= 1, 'no heals categorized')
  assert(#st.heal.cures == 2, 'cures not parsed')
  assert(st.heal.cures[1].debuff_type == 'curse', 'cure debuff type not parsed')
  assert(st.heal.cures[2].scope == 'me', 'cure me scope not parsed')
  assert(st.heal.single_point >= 1, 'single_point not computed')
  -- sorted desc by pct
  for k = 2, #st.heal.single do
    assert((tonumber(st.heal.single[k - 1].args[2]) or 0) >= (tonumber(st.heal.single[k].args[2]) or 0),
      'single not sorted desc')
  end

  -- timer helpers
  st.heal.timers[1] = { [0] = os.clock() + 60 }
  assert(st.heal.timers[1][0] > os.clock(), 'timer arm sanity')

  print('test_heal: PASS (single='..#st.heal.single..' group='..#st.heal.group..')')
  return true
end
return t
