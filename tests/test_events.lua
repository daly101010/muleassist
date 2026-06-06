-- muleassist/tests/test_events.lua  (runs in-game; smoke test — real triggers are game text)
-- The cast-outcome events fire on combat-log messages, which can't be synthesized here, so
-- this just guards that the module loads, registers without error, and wires cast.last_result.
local config = require('muleassist.config')
local state  = require('muleassist.state')
local cast   = require('muleassist.cast')
local events = require('muleassist.events')

local here = debug.getinfo(1, 'S').source:sub(2):gsub('[^/\\]+$', '')
local FIXTURE = here .. 'fixtures/sample.ini'

local t = {}
function t.run()
  local cfg = config.load(FIXTURE)
  assert(cfg, 'config.load returned nil for ' .. FIXTURE)
  local st = state.new(cfg)

  assert(type(events.register) == 'function', 'events.register exists')
  events.register(st)                       -- must not error (registers mq.event handlers)

  -- cast exposes the result slot the events write and wait_cast returns
  cast.last_result = 'CAST_RESIST'
  assert(cast.last_result == 'CAST_RESIST', 'cast.last_result is settable')
  cast.last_result = nil

  print('test_events: PASS')
  return true
end
return t
