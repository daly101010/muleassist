-- muleassist/tests/test_cast_mem.lua
-- cast.mem_spell pure-logic guards: invalid args (nil/empty/'null' spell, gem 0) must be
-- no-ops that issue no /memspell or /notify. cast.lua shares the same `mq` table we patch,
-- so command counters here see its calls. Live mem/swap behavior is verified in-game.
local mq   = require('mq')
local cast = require('muleassist.cast')

local t = {}
function t.run()
  local issued = 0
  local orig_cmdf, orig_cmd = mq.cmdf, mq.cmd
  mq.cmdf = function(...) issued = issued + 1 end
  mq.cmd  = function(...) issued = issued + 1 end

  local ok, err = pcall(function()
    cast.mem_spell(nil,          8, 0, '')
    cast.mem_spell('',           8, 0, '')
    cast.mem_spell('null',       8, 0, '')
    cast.mem_spell('Some Spell', 0, 0, '')
  end)

  mq.cmdf, mq.cmd = orig_cmdf, orig_cmd
  assert(ok, 'mem_spell raised on invalid args: ' .. tostring(err))
  assert(issued == 0, 'mem_spell issued commands for invalid args (' .. issued .. ')')

  local seen_cmd
  local orig_delay = mq.delay
  orig_cmd = mq.cmd
  mq.cmd = function(cmd) seen_cmd = cmd end
  mq.delay = function() end
  local result = cast.cast('command:/sit', 'test-command')
  mq.cmd, mq.delay = orig_cmd, orig_delay
  assert(result == 'CAST_SUCCESS', 'command cast should report success')
  assert(seen_cmd == '/docommand /sit', 'command cast issued unexpected command: ' .. tostring(seen_cmd))

  print('test_cast_mem: PASS (guards no-op)')
  return true
end
return t
