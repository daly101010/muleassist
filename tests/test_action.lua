local action = require('muleassist.action')
local cast = require('muleassist.cast')

local t = {}

function t.run()
  local old_cast = cast.cast
  local calls = {}
  cast.cast = function(name, sent_from, target_id)
    calls[#calls + 1] = { name = name, sent_from = sent_from, target_id = target_id }
    return 'CAST_SUCCESS'
  end

  local entry = { spell = 'command:/say hello' }
  local ok, result = action.execute({}, entry, 123, {
    sent_from = 'dps',
    cast_target_id = 456,
    condition = function(_, tid) return tid == 123 end,
  })

  cast.cast = old_cast

  assert(ok == true, 'command action should succeed')
  assert(result == 'CAST_SUCCESS', 'result should be CAST_SUCCESS')
  assert(#calls == 1, 'cast should be called once')
  assert(calls[1].sent_from == 'dps', 'sent_from should be forwarded')
  assert(calls[1].target_id == 456, 'cast target should be overridden')
  assert(entry.last_run and entry.last_run.success == true, 'last_run should record success')
  assert(entry.last_run.action_type == 'command', 'action type should be resolved')

  print('test_action: PASS')
  return true
end

return t
