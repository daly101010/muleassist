-- muleassist/tests/test_cond.lua  (requires a live client: runs under /lua run)
local cond = require('muleassist.cond')

local t = {}
function t.run()
  -- Pure branches (no mq.parse needed).
  assert(cond.eval(nil) == true, 'nil should be true')
  assert(cond.eval('') == true, 'empty should be true')
  assert(cond.eval('  ') == true, 'whitespace should be true')
  assert(cond.eval('TRUE') == true, 'TRUE should be true')
  assert(cond.eval('true') == true, 'true (lower) should be true')
  assert(cond.eval('NULL') == true, 'NULL should be true')
  assert(cond.eval('FALSE') == false, 'FALSE should be false')

  -- Live MQ TLO evaluation.
  assert(cond.eval('1>2') == false, '1>2 should be false')
  assert(cond.eval('2>1') == true, '2>1 should be true')
  assert(cond.eval('${Me.Level} > 0') == true, 'my level should be > 0')

  -- expand returns the parsed string.
  assert(cond.expand('') == '', 'expand empty')
  local lvl = cond.expand('${Me.Level}')
  assert(tonumber(lvl) ~= nil, 'expand ${Me.Level} should be numeric, got '..tostring(lvl))

  print('test_cond: PASS')
  return true
end
return t
