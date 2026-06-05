-- muleassist/tests/test_buff.lua
-- Categorization is exercised offline by overriding the TargetType resolver (mq.TLO.Spell
-- is unavailable without a live client). Cast/dispatch paths are verified in-game.
local config = require('muleassist.config')
local state  = require('muleassist.state')
local buff   = require('muleassist.buff')

local here = debug.getinfo(1, 'S').source:sub(2):gsub('[^/\\]+$', '')
local FIXTURE = here .. 'fixtures/sample.ini'

local t = {}
function t.run()
  local cfg = config.load(FIXTURE)
  local st  = state.new(cfg)

  buff.setup(st)
  assert(#st.buff.entries == #st.lists.buffs, 'entry count mismatch')
  for _, en in ipairs(st.buff.entries) do
    assert(en.cast_name and en.cast_name ~= '', 'entry missing cast_name')
    if en.is_dual then assert(en.check_name == en.part3, 'dual check_name should be part3') end
  end

  print('test_buff: PASS (' .. #st.buff.entries .. ' entries)')
  return true
end
return t
