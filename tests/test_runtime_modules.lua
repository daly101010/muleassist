-- muleassist/tests/test_runtime_modules.lua  (runs in-game; module setup may read MQ TLOs)
local config = require('muleassist.config')
local state  = require('muleassist.state')
local afk    = require('muleassist.afk')
local bard   = require('muleassist.bard')
local merc   = require('muleassist.merc')
local loot   = require('muleassist.loot')

local here = debug.getinfo(1, 'S').source:sub(2):gsub('[^/\\]+$', '')
local FIXTURE = here .. 'fixtures/sample.ini'

local t = {}
function t.run()
  local cfg = config.load(FIXTURE)
  assert(cfg, 'config.load returned nil for ' .. FIXTURE)
  local st = state.new(cfg)

  afk.setup(st)
  bard.setup(st)
  merc.setup(st)
  loot.setup(st)

  assert(type(afk.tick) == 'function', 'afk.tick exported')
  assert(type(bard.tick) == 'function', 'bard.tick exported')
  assert(type(bard.stop) == 'function', 'bard.stop exported')
  assert(type(merc.tick) == 'function', 'merc.tick exported')
  assert(type(loot.tick) == 'function', 'loot.tick exported')

  assert(st.afk.last_alert ~= nil, 'afk setup preserved alert throttle')
  assert(st.bard.twisting == false, 'bard setup initialized twisting')
  assert(st.merc.assisting == 0, 'merc setup initialized assisting')
  assert(st.loot.last_check == 0, 'loot setup initialized last_check')

  print('test_runtime_modules: PASS')
  return true
end
return t
