-- muleassist/tests/test_charm.lua  (runs in-game; charm.setup parses config + lists)
local config = require('muleassist.config')
local state  = require('muleassist.state')
local charm  = require('muleassist.charm')

local here = debug.getinfo(1, 'S').source:sub(2):gsub('[^/\\]+$', '')
local FIXTURE = here .. 'fixtures/sample.ini'

local t = {}
function t.run()
  local cfg = config.load(FIXTURE)
  assert(cfg, 'config.load returned nil for ' .. FIXTURE)

  -- Inject a charm config without disturbing the shared fixture (lists are cached on first
  -- access, so mutate sections BEFORE state.new builds st.lists).
  local C = cfg.sections['Charm'] or {}
  cfg.sections['Charm'] = C
  C['CharmOn']         = '1'
  C['CharmAutoOn']     = '1'
  C['CharmStunOn']     = '1'
  C['CharmRetashOn']   = '0'
  C['CharmMaxFails']   = '2'
  C['CharmDoNotList']  = 'a guard,a sentry'
  C['CharmDoNotClass'] = 'WAR|CLR'
  C['CharmSize']       = '1'
  C['Charm1']          = 'Beguile the Smoosher|10|55|0'

  local st = state.new(cfg)
  charm.setup(st)

  assert(st.charm.on == true, 'CharmOn parsed')
  assert(st.charm.auto_on == true, 'CharmAutoOn parsed')
  assert(st.charm.stun_on == true, 'CharmStunOn parsed')
  assert(st.charm.retash_on == false, 'CharmRetashOn parsed (0)')
  assert(st.charm.max_fails == 2, 'CharmMaxFails parsed')
  assert(#st.charm.list == 1, 'one charm entry parsed')
  assert(st.charm.list[1].spell == 'Beguile the Smoosher', 'charm spell name')
  assert(st.charm.list[1].min == 10, 'charm min level')
  assert(st.charm.list[1].max == 55, 'charm max level')
  assert(st.charm.list[1].mana == 0, 'charm mana override')
  assert(st.charm.donot and #st.charm.donot == 2, 'do-not-name list parsed')
  assert(st.charm.donot_class and st.charm.donot_class['WAR'] and st.charm.donot_class['CLR'],
    'do-not-class set parsed (pipe-delimited)')
  assert(st.charm.pet_id == 0 and st.charm.fail_count == 0, 'charm runtime init')

  print('test_charm: PASS')
  return true
end
return t
