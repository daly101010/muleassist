-- muleassist/tests/test_petbuff.lua
-- Offline: setup attaches the pet buff list. Cast paths verified in-game.
local config  = require('muleassist.config')
local state   = require('muleassist.state')
local petbuff = require('muleassist.petbuff')

local here = debug.getinfo(1, 'S').source:sub(2):gsub('[^/\\]+$', '')
local FIXTURE = here .. 'fixtures/sample.ini'

local t = {}
function t.run()
  local cfg = config.load(FIXTURE)
  local st  = state.new(cfg)
  petbuff.setup(st)
  assert(type(st.pet) == 'table', 'st.pet missing')
  assert(type(st.pet.entries) == 'table', 'pet entries missing')
  print('test_petbuff: PASS (' .. #st.pet.entries .. ' entries)')
  return true
end
return t
