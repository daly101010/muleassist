-- muleassist/tests/run_local.lua
require('muleassist.tests.local_bootstrap')
local ok = dofile('F:/lua/muleassist/tests/run.lua')
if ok == false then os.exit(1) end
