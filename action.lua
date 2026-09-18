-- muleassist/action.lua
-- Small action executor inspired by RGMercs rotations. It keeps MuleAssist INI entries
-- authoritative while centralizing action type resolution, readiness, cast dispatch, and
-- last-run diagnostics for DPS/Burn/utility lists.
local mq    = require('mq')
local cast  = require('muleassist.cast')
local util  = require('muleassist.util')

local action = {}

local function known(v)
  return v ~= nil and v ~= '' and tostring(v):upper() ~= 'NULL' and tostring(v):upper() ~= 'FALSE'
end

local function safe(label, fn, default)
  local ok, result = pcall(fn)
  if ok then return result end
  return default
end

local function safe_bool(label, fn)
  return util.mqbool(safe(label, fn, false))
end

local function safe_present(label, fn)
  return known(safe(label, fn, nil))
end

local function safe_num(label, fn)
  return tonumber(safe(label, fn, 0)) or 0
end

function action.resolve_type(name)
  if not known(name) then return 'invalid' end
  if cast.is_command(name) then return 'command' end
  if (mq.TLO.Me.AltAbility(name).ID() or 0) > 0 or (mq.TLO.Me.AltAbility(name).Rank() or 0) > 0 then
    return 'aa'
  end
  if (mq.TLO.FindItem('=' .. name).ID() or 0) > 0 then return 'item' end

  local rank = mq.TLO.Spell(name).RankName() or name
  if known(mq.TLO.Me.CombatAbility(name)()) or known(mq.TLO.Me.CombatAbility(rank)()) then
    return 'disc'
  end
  if (mq.TLO.Me.Skill(name)() or 0) > 0 then return 'ability' end
  return 'spell'
end

function action.ready(name, action_type, opts)
  return action.ready_detail(name, action_type, opts).ready
end

function action.ready_detail(name, action_type, opts)
  opts = opts or {}
  if not known(name) then
    return { ready = false, action_type = 'invalid', reason = 'invalid' }
  end
  action_type = action_type or safe('resolve_type', function() return action.resolve_type(name) end, 'spell')
  if action_type == 'command' then
    return { ready = true, action_type = action_type, reason = 'command' }
  end
  if action_type == 'aa' then
    local ready = safe_bool('aa ready', function() return mq.TLO.Me.AltAbilityReady(name)() end)
    return { ready = ready, action_type = action_type, reason = ready and 'ready' or 'aa_not_ready' }
  end
  if action_type == 'item' then
    local ready = safe_bool('item exact ready', function() return mq.TLO.Me.ItemReady('=' .. name)() end)
        or safe_bool('item ready', function() return mq.TLO.Me.ItemReady(name)() end)
    return { ready = ready, action_type = action_type, reason = ready and 'ready' or 'item_not_ready' }
  end
  if action_type == 'disc' then
    local rank = safe('disc rank', function() return mq.TLO.Spell(name).RankName() end, name) or name
    local ready = safe_bool('disc ready', function() return mq.TLO.Me.CombatAbilityReady(rank)() end)
    return { ready = ready, action_type = action_type, reason = ready and 'ready' or 'disc_not_ready' }
  end
  if action_type == 'ability' then
    local ready = safe_bool('ability ready', function() return mq.TLO.Me.AbilityReady(name)() end)
    return { ready = ready, action_type = action_type, reason = ready and 'ready' or 'ability_not_ready' }
  end

  local rank = safe('spell rank', function() return mq.TLO.Spell(name).RankName() end, name) or name
  if safe_bool('spell ready', function() return mq.TLO.Me.SpellReady(rank)() end) then
    return { ready = true, action_type = action_type, reason = 'ready' }
  end
  local in_book = safe_present('spell book rank', function() return mq.TLO.Me.Book(rank)() end)
      or safe_present('spell book base', function() return mq.TLO.Me.Book(name)() end)
  local memmed = safe_present('spell gem rank', function() return mq.TLO.Me.Gem(rank)() end)
      or safe_present('spell gem base', function() return mq.TLO.Me.Gem(name)() end)
  if opts.allow_mem and in_book then
    return { ready = true, action_type = action_type, reason = 'can_mem', memmed = memmed, known = in_book }
  end
  if in_book and not memmed then
    return { ready = false, action_type = action_type, reason = 'spell_not_memmed', memmed = false, known = true }
  end
  if in_book then
    return { ready = false, action_type = action_type, reason = 'spell_not_ready', memmed = memmed, known = true }
  end
  if safe_num('spell id', function() return mq.TLO.Spell(name).ID() end) > 0 then
    return { ready = false, action_type = action_type, reason = 'spell_not_known', memmed = false, known = false }
  end
  return { ready = false, action_type = action_type, reason = 'spell_unknown', memmed = false, known = false }
end

local function run_hook(label, fn, ...)
  if not fn then return true end
  local ok, result = pcall(fn, ...)
  if not ok then return false, result end
  return result ~= false, result
end

function action.execute(st, entry, target_id, opts)
  opts = opts or {}
  entry = entry or {}
  local name = entry.spell or entry.name
  local action_type = entry.action_type or opts.action_type or action.resolve_type(name)
  local sent_from = opts.sent_from or entry.sent_from or action_type
  local cast_target = opts.cast_target_id or target_id

  entry.last_run = {
    target_id = target_id or 0,
    cast_target_id = cast_target or 0,
    action_type = action_type,
    at = os.clock(),
    pass = false,
    success = false,
    result = 'NOT_RUN',
  }

  if not action.ready(name, action_type, opts) then
    entry.last_run.result = 'CAST_NOT_READY'
    return false, 'CAST_NOT_READY'
  end

  if opts.condition and not opts.condition(entry, target_id, st) then
    entry.last_run.result = 'CONDITION_FAILED'
    return false, 'CONDITION_FAILED'
  end

  local ok_pre, pre_err = run_hook('pre_activate', entry.pre_activate, st, entry, target_id)
  if not ok_pre then
    entry.last_run.result = 'PRE_ACTIVATE_FAILED'
    entry.last_run.error = tostring(pre_err)
    return false, 'PRE_ACTIVATE_FAILED'
  end

  entry.last_run.pass = true
  local result = cast.cast(name, sent_from, cast_target)
  local success = result == 'CAST_SUCCESS'

  entry.last_run.result = result
  entry.last_run.success = success

  run_hook('post_activate', entry.post_activate, st, entry, target_id, result)
  return success, result
end

return action
