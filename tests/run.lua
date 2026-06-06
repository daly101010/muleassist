-- muleassist/tests/run.lua  --  /lua run muleassist/tests/run
-- Game-independent pure-module tests (config, state). Condition tests that need a
-- live client live separately and are added to this list during Phase 1.
local mods = {
  'muleassist.tests.test_config',
  'muleassist.tests.test_state',
  'muleassist.tests.test_cond',
  'muleassist.tests.test_heal',
  'muleassist.tests.test_cast_mem',
  'muleassist.tests.test_buff',
  'muleassist.tests.test_petbuff',
  'muleassist.tests.test_serialize',
  'muleassist.tests.test_combat',
  'muleassist.tests.test_settings',
  'muleassist.tests.test_diff',
  'muleassist.tests.test_mez',
  'muleassist.tests.test_pet',
}

local ok_all = true
for _, name in ipairs(mods) do
  local ok, mod = pcall(require, name)
  if not ok then
    print('LOAD FAIL ' .. name .. ': ' .. tostring(mod)); ok_all = false
  else
    local ran, err = pcall(mod.run)
    if not ran then print('FAIL ' .. name .. ': ' .. tostring(err)); ok_all = false end
  end
end

print(ok_all and 'ALL TESTS PASS' or 'TESTS FAILED')
