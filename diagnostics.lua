-- muleassist/diagnostics.lua
-- Read-only runtime diagnostics for MAUI and future slash commands. This module must not
-- cast, target, navigate, or delay; it only summarizes existing state and readiness.
local action = require('muleassist.action')
local cond   = require('muleassist.cond')

local diagnostics = {}

local function count(t)
  local n = 0
  for _ in pairs(t or {}) do n = n + 1 end
  return n
end

local function safe(label, fn, default)
  local ok, result = pcall(fn)
  if ok then return result end
  return default
end

local function timer_remaining(st, entry, target_id)
  local idx = entry and entry.index
  if not idx or not target_id then return 0 end
  local row = st.combat and st.combat.dps_timers and st.combat.dps_timers[idx]
  local deadline = row and row[target_id]
  if not deadline then return 0 end
  local remaining = deadline - os.clock()
  return remaining > 0 and remaining or 0
end

local function condition_status(st, entry)
  if not entry or not entry.cond or entry.cond == '' then
    return true, 'none'
  end
  if st.combat and st.combat.dps_cond_on == false then
    return true, 'disabled'
  end
  local ok, result = pcall(cond.eval, entry.cond)
  if not ok then return false, 'error: ' .. tostring(result) end
  return result == true, result == true and 'true' or 'false'
end

local function last_result(entry)
  local lr = entry and entry.last_run
  if not lr then return 'never' end
  local result = tostring(lr.result or 'NOT_RUN')
  if lr.error and lr.error ~= '' then result = result .. ': ' .. tostring(lr.error) end
  return result
end

local function summarize_entry(st, kind, entry, target_id)
  local ready = safe('ready_detail', function()
    return action.ready_detail(entry.spell or entry.name, entry.action_type, { allow_mem = false })
  end, { ready = false, action_type = 'unknown', reason = 'ready_check_error' })
  local cond_ok, cond_reason = condition_status(st, entry)
  local timer = timer_remaining(st, entry, target_id)
  local blocked_by
  if timer > 0 then
    blocked_by = 'timer'
  elseif not cond_ok then
    blocked_by = 'condition'
  elseif not ready.ready then
    blocked_by = ready.reason
  else
    blocked_by = 'ready'
  end
  return {
    kind = kind,
    index = entry.index or 0,
    spell = entry.spell or entry.name or '',
    target = entry.target or 'Mob',
    action_type = ready.action_type,
    ready = ready.ready == true,
    ready_reason = ready.reason or '',
    condition = entry.cond or '',
    condition_state = cond_reason,
    timer_remaining = timer,
    last_result = last_result(entry),
    last_success = entry.last_run and entry.last_run.success == true or false,
    blocked_by = blocked_by,
  }
end

local function append_entries(rows, st, kind, entries, target_id)
  for _, entry in ipairs(entries or {}) do
    rows[#rows + 1] = summarize_entry(st, kind, entry, target_id)
  end
end

function diagnostics.combat_summary(st)
  st = st or {}
  local c = st.combat or {}
  return {
    role = st.role or c.role or '',
    main_assist = st.main_assist or '',
    main_assist_id = st.main_assist_id or 0,
    my_target_id = c.my_target_id or 0,
    my_target_name = c.my_target_name or '',
    called_target_id = c.called_target_id or 0,
    aggro_target_id = c.aggro_target_id or 0,
    hostile_count = c.hostile_count or 0,
    mob_count = c.mob_count or 0,
    passive_mob_count = c.passive_mob_count or 0,
    dps_on = c.dps_on == true,
    melee_on = c.melee_on == true,
    aggro_on = c.aggro_on == true,
    tank_all_mobs = c.tank_all_mobs == true,
    burning = c.burning == true,
    wrangle_hold_target_id = c.wrangle_hold_target_id or 0,
    wrangle_hold_remaining = math.max(0, (c.wrangle_hold_until or 0) - os.clock()),
    peer_buff_count = count(st.buff and st.buff.peer_buffs_by_name),
  }
end

function diagnostics.action_rows(st)
  st = st or {}
  local c = st.combat or {}
  local rows = {}
  local tid = c.my_target_id or 0
  append_entries(rows, st, 'DPS', c.entries, tid)
  append_entries(rows, st, 'Debuff', c.debuffs, tid)
  append_entries(rows, st, 'DebuffAll', c.debuff_all, tid)
  append_entries(rows, st, 'Aggro', c.aggro, tid)
  append_entries(rows, st, 'Burn', c.burn, tid)
  table.sort(rows, function(a, b)
    if a.kind ~= b.kind then return a.kind < b.kind end
    return (a.index or 0) < (b.index or 0)
  end)
  return rows
end

return diagnostics
