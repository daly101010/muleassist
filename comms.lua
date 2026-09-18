-- muleassist/comms.lua
-- Lightweight MQ Actors bus for cross-character MuleAssist state. Actor callbacks must not
-- yield, so handlers only validate payloads and mutate in-memory state.
local mq     = require('mq')
local actors = require('actors')
local Write  = require('muleassist.Write')
local combat = require('muleassist.combat')
local util   = require('muleassist.util')

local comms = {}

local MAILBOX = 'muleassist'
local actor, state_ref

local function my_name()
  return mq.TLO.Me.CleanName() or ''
end

local function payload(msg_type, data)
  data = data or {}
  data.msg_type = msg_type
  data.msgType = msg_type       -- accept/emit both spellings for compatibility.
  data.from = data.from or my_name()
  data.server = data.server or (mq.TLO.EverQuest.Server() or '')
  return data
end

local function msg_type(data)
  return data.msg_type or data.msgType
end

local function ignore_self(data)
  return (data.from or ''):lower() == my_name():lower()
end

local function tlo_seconds(duration)
  if not duration then return 0 end
  local ok, total = pcall(function() return duration.TotalSeconds() end)
  if ok and tonumber(total) then return tonumber(total) end
  ok, total = pcall(function() return duration() end)
  return (ok and tonumber(total)) or 0
end

local function effect_duration(name)
  if not name or name == '' then return 0 end
  local best = 0
  local ok, buff_obj = pcall(function() return mq.TLO.Me.Buff(name) end)
  if ok and buff_obj and buff_obj.ID() then
    best = math.max(best, tlo_seconds(buff_obj.Duration))
  end
  ok, buff_obj = pcall(function() return mq.TLO.Me.Song(name) end)
  if ok and buff_obj and buff_obj.ID() then
    best = math.max(best, tlo_seconds(buff_obj.Duration))
  end
  return best
end

local function spell_id(name)
  if not name or name == '' then return 0 end
  local ok, id = pcall(function() return mq.TLO.Spell(name).ID() end)
  return (ok and tonumber(id)) or 0
end

local function blocked_buff(name)
  if not name or name == '' then return false end
  local ok, blocked = pcall(function() return mq.TLO.Me.BlockedBuff(name) end)
  if not ok or not blocked then return false end
  local id = 0
  ok, id = pcall(function() return blocked.ID() end)
  if ok and tonumber(id) and tonumber(id) > 0 then return true end
  local bname
  ok, bname = pcall(function() return blocked.Name() end)
  return ok and bname and bname ~= '' and bname ~= 'NULL'
end

local function trigger_names(name)
  local out = {}
  local sid = spell_id(name)
  if sid == 0 then return out end
  local sp = mq.TLO.Spell(name)
  local max = 12
  local ok, n = pcall(function() return sp.NumEffects() end)
  if ok and tonumber(n) and tonumber(n) > 0 then max = math.min(tonumber(n), 12) end
  for i = 1, max do
    local ok_trig, trig = pcall(function() return sp.Trigger(i) end)
    if not ok_trig or not trig then break end
    local ok_id, tid = pcall(function() return trig.ID() end)
    tid = (ok_id and tonumber(tid)) or 0
    if tid <= 0 then break end
    local ok_name, tname = pcall(function() return trig.Name() end)
    if ok_name and tname and tname ~= '' and tname ~= 'NULL' then
      out[#out + 1] = tname
    end
  end
  return out
end

local function spell_stacks(name)
  local ok, stacks = pcall(function() return mq.TLO.Spell(name).Stacks() end)
  return ok and util.mqbool(stacks)
end

local function self_buff_decision(name)
  local duration = effect_duration(name)
  if duration > 30 then
    return { spell = name, duration = duration, stacks = true, present = true, reason = 'present' }
  end

  if blocked_buff(name) then
    return { spell = name, duration = 0, stacks = false, blocked = true, reason = 'blocked' }
  end

  local triggers = trigger_names(name)
  local best_trigger = 0
  for _, trigger in ipairs(triggers) do
    local tdur = effect_duration(trigger)
    if tdur > best_trigger then best_trigger = tdur end
    if tdur > 30 then
      return {
        spell = name,
        duration = tdur,
        stacks = true,
        present = true,
        trigger = trigger,
        reason = 'trigger_present',
      }
    end
    if blocked_buff(trigger) then
      return {
        spell = name,
        duration = 0,
        stacks = false,
        blocked = true,
        trigger = trigger,
        reason = 'trigger_blocked',
      }
    end
    if not spell_stacks(trigger) then
      return {
        spell = name,
        duration = 0,
        stacks = false,
        trigger = trigger,
        reason = 'trigger_no_stack',
      }
    end
  end

  return {
    spell = name,
    duration = math.max(duration, best_trigger),
    stacks = spell_stacks(name),
    present = false,
    triggers = triggers,
    reason = 'stack_check',
  }
end

local function cache_peer_buffs(st, data)
  st.buff = st.buff or {}
  st.buff.peer_buffs_by_name = st.buff.peer_buffs_by_name or {}
  st.buff.peer_buffs_by_id = st.buff.peer_buffs_by_id or {}
  st.buff.peer_actor_misses = st.buff.peer_actor_misses or {}

  local name = data.name or data.from or ''
  if name == '' then return end
  local buffs = type(data.buffs) == 'table' and data.buffs or {}
  local songs = type(data.songs) == 'table' and data.songs or {}
  local blocked = type(data.blocked) == 'table' and data.blocked or {}
  local pet_buffs = type(data.pet_buffs or data.petBuffs) == 'table' and (data.pet_buffs or data.petBuffs) or {}
  local pet_blocked = type(data.pet_blocked or data.petBlocked) == 'table' and (data.pet_blocked or data.petBlocked) or {}
  local entry = {
    name = name,
    id = tonumber(data.spawn_id or data.spawnID) or 0,
    class = data.class,
    level = tonumber(data.level) or 0,
    zone_id = tonumber(data.zone_id or data.zoneID) or 0,
    instance_id = tonumber(data.instance_id or data.instanceID) or 0,
    buffs = buffs,
    songs = songs,
    blocked = blocked,
    pet_buffs = pet_buffs,
    pet_blocked = pet_blocked,
    updated = os.clock(),
  }
  st.buff.peer_buffs_by_name[name:lower()] = entry
  st.buff.peer_actor_misses[name:lower()] = nil
  if entry.id > 0 then
    st.buff.peer_buffs_by_id[tostring(entry.id)] = entry
  end
end

local function on_message(message)
  local st = state_ref
  if not st then return end
  local data = message.content
  if type(data) ~= 'table' then return end

  local typ = msg_type(data)
  if typ == 'BUFF_QUERY' then
    if ignore_self(data) then return end
    local spell = data.spell or ''
    local decision = spell ~= '' and self_buff_decision(spell) or { spell = spell, duration = 0, stacks = false }
    if message.reply then
      message:reply(0, payload('BUFF_DECISION', decision))
    end
    return
  end

  if ignore_self(data) then return end

  if typ == 'DEBUFFS' then
    local spawn_id = tonumber(data.spawn_id or data.spawnID) or 0
    if spawn_id == 0 then return end
    local total = tonumber(data.total) or 0
    if total > 0 then
      st.heal.group_debuffs[tostring(spawn_id)] = {
        poison  = tonumber(data.poison) or 0,
        disease = tonumber(data.disease) or 0,
        curse   = tonumber(data.curse) or 0,
        corrupt = tonumber(data.corrupt) or 0,
        mezzed  = tonumber(data.mezzed) or 0,
      }
    else
      st.heal.group_debuffs[tostring(spawn_id)] = nil
    end

  elseif typ == 'BUFFS' then
    cache_peer_buffs(st, data)

  elseif typ == 'SWITCHMA' then
    local new_ma = data.main_assist or data.newMA or ''
    if new_ma ~= '' then
      st.main_assist = new_ma
      st.combat.my_target_id = nil
      st.combat.my_target_name = nil
    end

  elseif typ == 'TARGET' then
    local id = tonumber(data.target_id or data.targetID) or 0
    st.combat.called_target_id = id
    if id == 0 then
      st.combat.aggro_target_id = nil
      st.combat.my_target_id = nil
      st.combat.my_target_name = nil
    elseif combat.valid_combat_target(id) then
      st.combat.aggro_target_id = id
      st.combat.my_target_id = id
      st.combat.my_target_name = data.target_name or st.combat.my_target_name
    else
      st.combat.called_target_id = 0
    end

  elseif typ == 'WRANGLE' then
    local id = tonumber(data.target_id or data.targetID) or 0
    local duration = tonumber(data.duration) or 0
    if id > 0 and duration > 0 and combat.valid_combat_target(id) then
      st.combat.wrangle_hold_target_id = id
      st.combat.wrangle_hold_until = os.clock() + duration
    else
      st.combat.wrangle_hold_target_id = 0
      st.combat.wrangle_hold_until = 0
    end

  elseif typ == 'CAMP' then
    st.camp.x = tonumber(data.x) or st.camp.x
    st.camp.y = tonumber(data.y) or st.camp.y
    st.camp.z = tonumber(data.z) or st.camp.z
    st.move.return_to_camp = true
    st.move.chase_assist = false

  elseif typ == 'CHASE' then
    local who = data.who or data.from or ''
    if who ~= '' then
      st.move.chase_name = who
      st.move.chase_assist = true
      st.move.return_to_camp = false
    end
  end
end

function comms.init(st)
  state_ref = st
  actor = actors.register(MAILBOX, on_message)
  st.comms = comms
  Write.Info('comms: actor mailbox [%s] registered', MAILBOX)
end

function comms.shutdown()
  local old_actor = actor
  actor = nil
  state_ref = nil
  if old_actor then
    pcall(function() old_actor:unregister() end)
  end
end

function comms.broadcast(msg_type_name, data)
  if actor then actor:send(payload(msg_type_name, data)) end
end

function comms.send(target_char, msg_type_name, data)
  if not target_char or target_char == '' then return end
  actors.send({
    mailbox = MAILBOX,
    character = target_char,
    server = mq.TLO.EverQuest.Server() or '',
  }, payload(msg_type_name, data))
end

function comms.request(target_char, msg_type_name, data, callback)
  if not target_char or target_char == '' then return end
  actors.send({
    mailbox = MAILBOX,
    character = target_char,
    server = mq.TLO.EverQuest.Server() or '',
  }, payload(msg_type_name, data), callback)
end

function comms.broadcast_debuffs(st, debuffs)
  if not actor then return end
  local id = mq.TLO.Me.ID() or 0
  if id == 0 then return end
  debuffs = debuffs or (st.heal.group_debuffs and st.heal.group_debuffs[tostring(id)]) or {}
  local poison  = tonumber(debuffs.poison) or 0
  local disease = tonumber(debuffs.disease) or 0
  local curse   = tonumber(debuffs.curse) or 0
  local corrupt = tonumber(debuffs.corrupt) or 0
  local mezzed  = tonumber(debuffs.mezzed) or 0
  local data = payload('DEBUFFS', {
    spawn_id = id,
    total = poison + disease + curse + corrupt + mezzed,
    poison = poison,
    disease = disease,
    curse = curse,
    corrupt = corrupt,
    mezzed = mezzed,
  })
  actor:send(data)
  -- Dual-send to the macro-side bridge (madebuffs.lua). Actor mailboxes are always
  -- script-prefixed, so bridge scripts can't hear our own-mailbox broadcast above;
  -- fire-and-forget is safe when no bridge is running.
  actor:send({ mailbox = 'madebuffs', script = 'madebuffs' }, data)
end

function comms.broadcast_buffs(st, snapshot)
  if not actor then return end
  snapshot = snapshot or {}
  snapshot.spawn_id = snapshot.spawn_id or mq.TLO.Me.ID() or 0
  snapshot.name = snapshot.name or my_name()
  comms.broadcast('BUFFS', snapshot)
end

function comms.broadcast_wrangle_hold(st, target_id, duration)
  if not actor then return end
  target_id = tonumber(target_id) or 0
  if target_id == 0 then return end
  comms.broadcast('WRANGLE', {
    target_id = target_id,
    duration = tonumber(duration) or 4,
  })
end

function comms.buff_decision(peer, spell, timeout)
  if not peer or peer == '' or not spell or spell == '' then return nil end
  local done, result = false, nil
  comms.request(peer, 'BUFF_QUERY', { spell = spell }, function(status, data)
    if status and status < 0 then
      done = true
      result = nil
      return
    end
    if type(data) == 'table' then
      result = {
        spell = data.spell or spell,
        duration = tonumber(data.duration) or 0,
        stacks = util.mqbool(data.stacks),
        present = util.mqbool(data.present),
        blocked = util.mqbool(data.blocked),
        reason = data.reason,
        trigger = data.trigger,
      }
    end
    done = true
  end)
  mq.delay(timeout or 500, function() return done end)
  return result
end

function comms.tick() end

return comms
