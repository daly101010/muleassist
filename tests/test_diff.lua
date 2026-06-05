-- muleassist/tests/test_diff.lua  (pure; no mq/ImGui)
local diff = require('muleassist.ui.diff')

local t = {}
function t.run()
  assert(diff.changed({A={x=1}}, {A={x=2}}),  'value change detected')
  assert(not diff.changed({A={x=1}}, {A={x=1}}), 'identical -> no change')
  assert(diff.changed({A={x=1}}, {A={}}),     'missing key detected')
  assert(diff.changed({A={x=1}}, {}),         'missing section detected')
  assert(not diff.changed({}, {}),            'empty -> no change')

  local d = diff.debouncer(0.75)
  d:touch(100.0)
  assert(not d:due(100.5), 'not due before delay')
  assert(d:due(100.8),     'due after delay elapses')
  assert(not d:due(100.9), 'fires exactly once per touch')

  print('test_diff: PASS')
  return true
end
return t
