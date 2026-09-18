local action = require('muleassist.action')
local diagnostics = require('muleassist.diagnostics')

local t = {}

local function find_row(rows, spell)
  for _, row in ipairs(rows or {}) do
    if row.spell == spell then return row end
  end
  return nil
end

function t.run()
  local old_ready_detail = action.ready_detail
  action.ready_detail = function(name)
    if name == 'Blocked Spell' then
      return { ready = false, action_type = 'spell', reason = 'spell_not_ready' }
    end
    return { ready = true, action_type = 'spell', reason = 'ready' }
  end

  local ok, err = pcall(function()
    local now = os.clock()
    local st = {
      role = 'Assist',
      main_assist = 'Tank',
      main_assist_id = 123,
      buff = { peer_buffs_by_name = { Bob = {} } },
      combat = {
        my_target_id = 999,
        my_target_name = 'a_mob',
        called_target_id = 999,
        aggro_target_id = 999,
        hostile_count = 1,
        mob_count = 2,
        passive_mob_count = 3,
        dps_on = true,
        melee_on = true,
        aggro_on = false,
        tank_all_mobs = true,
        wrangle_hold_target_id = 999,
        wrangle_hold_until = now + 2,
        dps_cond_on = true,
        dps_timers = { [2] = { [999] = now + 10 } },
        entries = {
          { index = 1, spell = 'Ready Spell', target = 'Mob', cond = 'TRUE', last_run = { result = 'CAST_SUCCESS', success = true } },
          { index = 2, spell = 'Timer Spell', target = 'Mob' },
          { index = 3, spell = 'Cond Spell', target = 'Mob', cond = 'FALSE' },
          { index = 4, spell = 'Blocked Spell', target = 'Mob' },
        },
        debuffs = {},
        debuff_all = {},
        aggro = {},
        burn = {},
      },
    }

    local summary = diagnostics.combat_summary(st)
    assert(summary.role == 'Assist', 'summary should prefer top-level role')
    assert(summary.main_assist == 'Tank', 'summary should include main assist')
    assert(summary.peer_buff_count == 1, 'summary should count peer buff cache')
    assert(summary.wrangle_hold_remaining > 0, 'summary should include wrangle hold remaining')

    local rows = diagnostics.action_rows(st)
    assert(#rows == 4, 'expected four action rows')
    assert(find_row(rows, 'Ready Spell').blocked_by == 'ready', 'ready row should be available')
    assert(find_row(rows, 'Timer Spell').blocked_by == 'timer', 'timer row should be timer blocked')
    assert(find_row(rows, 'Cond Spell').blocked_by == 'condition', 'false condition should block row')
    assert(find_row(rows, 'Blocked Spell').blocked_by == 'spell_not_ready', 'readiness reason should block row')
    assert(find_row(rows, 'Ready Spell').last_result == 'CAST_SUCCESS', 'last result should be shown')
  end)

  action.ready_detail = old_ready_detail
  if not ok then error(err) end

  print('test_diagnostics: PASS')
  return true
end

return t
