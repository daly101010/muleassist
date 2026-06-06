-- muleassist/tests/test_util.lua  (mqbool/role-sets/safe are pure; nav/group need a client)
local util = require('muleassist.util')

local t = {}
function t.run()
  -- mqbool coercion (the MQ string-bool footgun)
  assert(util.mqbool(true) == true, 'mqbool(true)')
  assert(util.mqbool(false) == false, 'mqbool(false)')
  assert(util.mqbool(1) == true, 'mqbool(1)')
  assert(util.mqbool(0) == false, 'mqbool(0)')
  assert(util.mqbool('TRUE') == true, "mqbool('TRUE')")
  assert(util.mqbool('FALSE') == false, "mqbool('FALSE')")
  assert(util.mqbool('NULL') == false, "mqbool('NULL')")
  assert(util.mqbool(nil) == false, 'mqbool(nil)')

  -- role predicates against st.combat.role
  local st = { combat = { role = 'pullertank' } }
  assert(util.is_puller(st) == true, 'pullertank is puller')
  assert(util.is_tank(st) == true, 'pullertank is tank')
  assert(util.is_hunter(st) == false, 'pullertank not hunter')
  st.combat.role = 'hunter'
  assert(util.is_hunter(st) == true, 'hunter is hunter')
  assert(util.role_in(st, util.GUARD_ROLES) == false, 'hunter not a guard role')
  st.combat.role = 'pettank'
  assert(util.role_in(st, util.PETTANK_ROLES) == true, 'pettank in PETTANK_ROLES')

  -- class sets present
  assert(util.MEZ_CLASSES.ENC and util.CHARM_CLASSES.DRU and util.CASTER_MED.WIZ and util.HYBRID.PAL,
    'class sets populated')

  -- safe() returns fn result, or default + no throw on error
  assert(util.safe('ok', function() return 42 end, -1) == 42, 'safe returns result')
  assert(util.safe('boom', function() error('x') end, -1) == -1, 'safe returns default on error')

  print('test_util: PASS')
  return true
end
return t
