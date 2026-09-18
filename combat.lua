-- muleassist/combat.lua
-- Phase 4a: assist + DPS/melee + burn. Ports CheckForCombat @1727 / Assist @1860 /
-- Combat @2508 / CombatCast @3077 / Event_Burn @14392 (core paths only). Tank/aggro/mez/
-- merc/weave/pull/debuff-all are Phase 4b+. Casts via action.execute; conditions via cond.eval.
-- Populates st.combat.* which heal/buff/rez read defensively.
local mq    = require('mq')
local Write = require('muleassist.Write')
local cast  = require('muleassist.cast')
local action = require('muleassist.action')
local cond  = require('muleassist.cond')
local serialize = require('muleassist.serialize')
local util   = require('muleassist.util')
local combat = {}

local HUB_ZONES = { poknowledge=1, guildlobby=1, guildhall=1, bazaar=1, nexus=1 }

-- Ask a DanNet peer to evaluate an MQ expression against its own state. Returns the string
-- result, or nil if not a peer / no answer.
local function dnet_query(peer, query, timeout)
  if not peer or peer == '' then return nil end
  if not ((mq.TLO.DanNet.Peers() or '') .. '|'):lower():find(peer:lower() .. '|', 1, true) then return nil end
  mq.cmdf('/dquery %s -q "%s"', peer, query)
  mq.delay(25)
  mq.delay(timeout or 500, function() return (mq.TLO.DanNet(peer).Q(query).Received() or 0) > 0 end)
  local v = mq.TLO.DanNet(peer).Q(query)()
  if v == nil or v == '' or tostring(v):lower() == 'null' then return nil end
  return v
end

----------------------------------------------------------------------
-- setup: parse DPS/Burn lists, find the XTarget Auto-Hater slot.
----------------------------------------------------------------------
function combat.setup(st)
  local dps, debuffs, debuff_all = {}, {}, {}
  for _, e in ipairs(st.lists.dps) do
    local entry = serialize.parse_dps(e.raw, e.cond)
    entry.index = e.index
    if entry.spell ~= '' and entry.spell:lower() ~= 'null' then
      if entry.target == 'debuffall' then debuff_all[#debuff_all + 1] = entry
      elseif entry.is_debuff then debuffs[#debuffs + 1] = entry
      else dps[#dps + 1] = entry end
    end
  end
  st.combat.entries = dps
  st.combat.debuffs = debuffs
  st.combat.debuff_all = debuff_all

  local burn = {}
  for _, e in ipairs(st.lists.burn) do
    local a = e.args
    if (a[1] or '') ~= '' and (a[1] or ''):lower() ~= 'null' then
      burn[#burn + 1] = { spell = a[1], target = (a[2] ~= '' and a[2]) or 'Mob',
                          cond_tag = a[3], cond_spell = a[4], cond = e.cond, index = e.index }
    end
  end
  st.combat.burn = burn

  -- Aggro list: Spell|PCT|GLT(< or >)|Target (Sub AggroCheck @4319-4323).
  local aggro = {}
  for _, e in ipairs(st.lists.aggro) do
    local a = e.args
    if (a[1] or '') ~= '' and (a[1] or ''):lower() ~= 'null' then
      aggro[#aggro + 1] = { spell = a[1], pct = tonumber(a[2] or '') or 0,
                            glt = (a[3] ~= '' and a[3]) or '<', target = (a[4] ~= '' and a[4]) or 'Mob',
                            cond = e.cond, index = e.index }
    end
  end
  st.combat.aggro = aggro

  -- First XTarget "Auto Hater" slot (macro XTSlot @1175-1178).
  st.combat.xtslot = 1
  for i = 1, 13 do
    if (mq.TLO.Me.XTarget(i).TargetType() or '') == 'Auto Hater' then st.combat.xtslot = i; break end
  end
  Write.Info('combat.setup: %d dps, %d debuff, %d debuffall, %d aggro, %d burn (xtslot=%d)',
    #dps, #debuffs, #debuff_all, #aggro, #burn, st.combat.xtslot)
end

----------------------------------------------------------------------
-- Combat-state refresh (read by heal/buff/rez).
----------------------------------------------------------------------
local function xtarget_slots()
  local slots = tonumber(mq.TLO.Me.XTargetSlots()) or 13
  return slots > 0 and slots or 13
end

-- GetHostilesOnXTarget @18436: count auto-hater NPC XTargets.
local function hostiles()
  local n = 0
  for i = 1, xtarget_slots() do
    local xt = mq.TLO.Me.XTarget(i)
    if (xt.ID() or 0) > 0 and (xt.TargetType() or '') == 'Auto Hater' and (xt.Type() or '') == 'NPC' then
      n = n + 1
    end
  end
  return n
end
combat.hostiles = hostiles

local function refresh_state(st)
  local c = st.combat
  local count, closest_id, closest_slot, closest_dist = 0, nil, nil, nil
  for i = 1, xtarget_slots() do
    local xt = mq.TLO.Me.XTarget(i)
    local id = xt.ID() or 0
    if id > 0 and (xt.TargetType() or '') == 'Auto Hater' and (xt.Type() or '') == 'NPC' then
      local sp = mq.TLO.Spawn(id)
      if sp.Type() ~= 'Corpse' then
        count = count + 1
        local dist = sp.Distance() or 9999
        if not closest_dist or dist < closest_dist then
          closest_id, closest_slot, closest_dist = id, i, dist
        end
      end
    end
  end

  -- KissAssist only falls back to the current target while the client is already in combat.
  -- This keeps passive nearby NPCs from being treated as active combat out of combat.
  if count == 0 and util.mqbool(mq.TLO.Me.Combat()) then
    local tid = mq.TLO.Target.ID() or 0
    local tt = (mq.TLO.Target.Type() or ''):lower()
    if tid > 0 and (tt == 'npc' or tt == 'pet') then
      count, closest_id = 1, tid
    end
  end

  if closest_slot then c.xtslot = closest_slot end
  c.aggro_target_id = closest_id
  c.hostile_count = count
  c.mob_count = count
  if c.assist_outside then
    c.passive_mob_count = tonumber(mq.TLO.SpawnCount('npc targetable radius ' .. c.melee_dist .. ' los')()) or 0
  else
    c.passive_mob_count = 0
  end
end
-- Public: refresh just the combat-state fields (call early in the loop so heal/buff/rez see
-- current combat state before they run; macro's early CheckForCombat(SkipCombat=1) @1366).
combat.refresh = refresh_state

local function dmz()
  return HUB_ZONES[(mq.TLO.Zone.ShortName() or ''):lower()] ~= nil and not mq.TLO.Me.InInstance()
end

----------------------------------------------------------------------
-- Tank role: acquire own target (Sub Assist @1999-2090, simplified).
----------------------------------------------------------------------
local MEZ_ANIM   = { [26]=1, [32]=1, [71]=1, [72]=1, [17]=1, [111]=1, [129]=1 }
local TAUNT_RANGE = 25
local ADD_NAV_RANGE = 125
local ADD_NAV_TIMEOUT = 2500

local function valid_combat_target(id)
  if not id or id == 0 then return false end
  local sp = mq.TLO.Spawn(id)
  local ty = (sp.Type() or ''):lower()
  if (sp.ID() or 0) == 0 or ty == 'corpse' or ty == 'pc' then return false end
  if ty == 'pet' and (sp.Master.Type() or ''):lower() == 'pc' then return false end
  return ty == 'npc' or ty == 'pet'
end
combat.valid_combat_target = valid_combat_target

function combat.switch_target(st, target_id)
  local c = st.combat
  local id = tonumber(target_id) or mq.TLO.Target.ID() or 0
  c.called_target_id = id
  c.my_target_id = nil
  c.my_target_name = nil
  if id == 0 then
    c.aggro_target_id = nil
    Write.Info('combat target cleared; will pick up the next hater')
    return
  end
  if not valid_combat_target(id) then
    Write.Warn('target %s is not a valid combat target', tostring(id))
    return
  end
  c.aggro_target_id = id
  c.my_target_id = id
  c.my_target_name = mq.TLO.Spawn(id).CleanName()
  Write.Info('switching combat target to %s (ID %d)', c.my_target_name or '?', id)
  if st.comms and st.comms.broadcast then
    st.comms.broadcast('TARGET', { target_id = id, target_name = c.my_target_name })
  end
end

-- Pick a target as the tank from XTarget auto-haters: named first, else closest to camp.
local function tank_pick_target(st)
  local c = st.combat
  if not c.aggro_target_id then return end
  local bestNamed, bestClose, bestCloseDist
  local cy = st.camp.y or (mq.TLO.Me.Y() or 0)
  local cx = st.camp.x or (mq.TLO.Me.X() or 0)
  for i = 1, 13 do
    local xt = mq.TLO.Me.XTarget(i)
    if (xt.ID() or 0) > 0 and (xt.TargetType() or '') == 'Auto Hater' and (xt.Type() or '') == 'NPC' then
      if util.mqbool(xt.Named()) then bestNamed = xt.ID(); break end
      local d = mq.TLO.Math.Distance(string.format('%f,%f:%f,%f', xt.Y() or 0, xt.X() or 0, cy, cx))()
      if not bestCloseDist or (d or 9999) < bestCloseDist then bestClose = xt.ID(); bestCloseDist = d or 9999 end
    end
  end
  local pick = bestNamed or bestClose
  if pick then
    if mq.TLO.Target.ID() ~= pick then
      mq.cmdf('/target id %d', pick)
      mq.delay(1000, function() return mq.TLO.Target.ID() == pick end)
    end
    if mq.TLO.Target.ID() == pick then
      c.my_target_id = pick; c.my_target_name = mq.TLO.Spawn(pick).CleanName()
    end
  end
end

----------------------------------------------------------------------
-- Assist (Sub Assist @1860, core): set my_target_id from the MA's target.
----------------------------------------------------------------------
local function assist(st)
  if util.is_tank(st) then tank_pick_target(st); return end
  local c = st.combat
  if c.manual_target_mode then
    if valid_combat_target(c.my_target_id) then return end
    if valid_combat_target(c.called_target_id) then
      c.my_target_id = c.called_target_id
      c.my_target_name = mq.TLO.Spawn(c.called_target_id).CleanName()
    else
      c.my_target_id = nil
      c.my_target_name = nil
    end
    return
  end
  if (c.wrangle_hold_until or 0) > os.clock() and valid_combat_target(c.wrangle_hold_target_id) then
    local hold_id = c.wrangle_hold_target_id
    if mq.TLO.Target.ID() ~= hold_id then
      mq.cmdf('/target id %d', hold_id)
      mq.delay(1000, function() return mq.TLO.Target.ID() == hold_id end)
    end
    if mq.TLO.Target.ID() == hold_id then
      c.my_target_id = hold_id
      c.my_target_name = mq.TLO.Spawn(hold_id).CleanName()
    end
    return
  end
  if c.target_switching_on and valid_combat_target(mq.TLO.Target.ID() or 0) then
    c.my_target_id = mq.TLO.Target.ID()
    c.my_target_name = mq.TLO.Target.CleanName()
    return
  end
  local ma = st.main_assist
  if not ma or ma == '' or ma == mq.TLO.Me.CleanName() then return end
  local can_assist_ooc = c.assist_outside and (c.passive_mob_count or 0) > 0
  if not c.aggro_target_id and not can_assist_ooc then return end
  if not (c.mob_count > 0 or c.aggro_target_id or can_assist_ooc) then return end
  local maSpawn = mq.TLO.Spawn('=' .. ma)
  if (maSpawn.ID() or 0) == 0 or (maSpawn.Distance() or 9999) >= 200 then return end

  -- Resolve the MA's target. GroupAssistTarget needs the EQ group Main-Assist role; when it's
  -- 0, ask the MA peer directly over DanNet (authoritative, no group-role dependency). Final
  -- fallback: the MA spawn's AssistName (macro AssistOutside path).
  local tmp = mq.TLO.Me.GroupAssistTarget.ID()
  if not tmp or tmp == 0 then
    local r = dnet_query(ma, 'Target.ID', 500)
    if r then tmp = tonumber(r) end
  end
  if not tmp or tmp == 0 then
    local an = maSpawn.AssistName()
    if an and an ~= '' then tmp = mq.TLO.Spawn(an).ID() end
  end
  if not tmp or tmp == 0 then return end

  local sp = mq.TLO.Spawn(tmp)
  local sty = (sp.Type() or ''):lower()
  local ok = (sty == 'npc') or (sty == 'pet' and (sp.Master.Type() or ''):lower() ~= 'pc')
  if not ok then return end
  if mq.TLO.Target.ID() ~= tmp then
    mq.cmdf('/target id %d', tmp)
    mq.delay(1000, function() return mq.TLO.Target.ID() == tmp end)
  end
  if mq.TLO.Target.ID() == tmp then
    c.my_target_id = tmp
    c.my_target_name = sp.CleanName()
  end
end

----------------------------------------------------------------------
-- can_start_combat (#DEFINE CANSTARTCOMBAT @72).
----------------------------------------------------------------------
local function can_start_combat(st)
  local c = st.combat
  local id = c.my_target_id
  if not id then return false end
  if not valid_combat_target(id) then return false end
  local sp = mq.TLO.Spawn(id)
  local ty = sp.Type()
  if ty ~= 'NPC' and ty ~= 'PET' then return false end
  -- Tanks initiate, so they engage at full HP (macro forces AssistAt=100 for tank roles);
  -- assists wait until the MA brings the mob to AssistAt%.
  local at = util.is_tank(st) and 100 or c.assist_at
  if (sp.PctHPs() or 100) > at then return false end
  local dist = sp.Distance() or 9999
  if dist < c.melee_dist then return true end
  -- Camp-distance gate: anchor on SELF when tanking (we are the camp center), else on the MA.
  local ay, ax
  if util.is_tank(st) then
    ay, ax = st.camp.y or mq.TLO.Me.Y(), st.camp.x or mq.TLO.Me.X()
  else
    local ma = mq.TLO.Spawn('=' .. (st.main_assist or ''))
    if ma.ID() then ay, ax = ma.Y(), ma.X() end
  end
  if ay then
    local d = mq.TLO.Math.Distance(string.format('%f,%f:%f,%f',
      sp.Y() or 0, sp.X() or 0, ay, ax))()
    if (d or 9999) <= (st.camp.radius or 60) then return true end
  end
  if (sp.Speed() or 0) == 0 then
    local an = sp.AssistName()
    local anDist = (an and (mq.TLO.Spawn(an).Distance() or 0)) or 0
    if dist <= ((sp.MaxRangeTo() or 0) + anDist) * 1.3 then return true end
  end
  return false
end

----------------------------------------------------------------------
-- DPS timers + readiness + engage.
----------------------------------------------------------------------
local function ready(st, i, tid)
  local row = st.combat.dps_timers[i]
  return (not row) or (not row[tid]) or os.clock() >= row[tid]
end
local function arm(st, i, tid, secs)
  st.combat.dps_timers[i] = st.combat.dps_timers[i] or {}
  st.combat.dps_timers[i][tid] = os.clock() + secs
end

local function spell_ready(name)
  return action.ready(name, nil, { allow_mem = false })
end

local function is_taunt_name(name)
  return tostring(name or ''):lower() == 'taunt'
end

-- Engage melee: attack + stick + face (re-attack offset -5 handled by can_start_combat gate).
local function engage(st)
  local c = st.combat
  if not c.melee_on then return end
  local id = c.my_target_id
  if not id then return end
  if mq.TLO.Target.ID() ~= id then mq.cmdf('/target id %d', id) end
  if not util.mqbool(mq.TLO.Me.Combat()) then mq.cmd('/attack on'); c.attacking = true end
  if c.face_on then mq.cmd('/face fast nolook') end
  if not util.mqbool(mq.TLO.Stick.Active()) then
    -- Tanks always hold the front so the mob faces them; everyone else uses StickHow.
    local how = (util.is_tank(st) and c.tank_stick) or c.stick_how or '12'
    mq.cmdf('/stick %s id %d', how, id)
  end
end

-- Evaluate an entry's DPSCond + if/notif buff tag. tid = target id.
local function cond_pass(st, e, tid)
  if st.combat.dps_cond_on and e.cond and e.cond ~= '' and not cond.eval(e.cond) then return false end
  local tag, bn = e.cond_tag, e.cond_spell
  if not tag or not bn or bn == '' then return true end
  local on_me = tag == 'ifme' or tag == 'notifme'
  local want  = tag == 'if' or tag == 'ifme'      -- true => require the buff present
  local has
  if on_me then
    has = mq.TLO.Me.Buff(bn).ID() ~= nil or mq.TLO.Me.Song(bn).ID() ~= nil
  else
    has = mq.TLO.Spawn(tid).CachedBuff(bn).ID() ~= nil
  end
  if want and not has then return false end
  if (not want) and has then return false end
  return true
end

----------------------------------------------------------------------
-- DPS rotation (CombatCast @3077, core).
----------------------------------------------------------------------
function combat.rotation(st)
  local c = st.combat
  local tid = c.my_target_id
  if not tid then return end
  for _, e in ipairs(c.entries) do
    local sp = mq.TLO.Spawn(tid)
    if sp.Type() == 'Corpse' or not sp.ID() then return end   -- target died
    if c.aggro_on then combat.aggro_check(st) end
    local cast_id = tid
    if e.target == 'Me' then cast_id = mq.TLO.Me.ID()
    elseif e.target == 'MA' then cast_id = st.main_assist_id end
    -- send pet in
    if c.pet_combat_on and (sp.PctHPs() or 100) <= c.pet_assist_at
       and mq.TLO.Me.Pet.ID() and not util.mqbool(mq.TLO.Me.Pet.Combat()) then
      mq.cmdf('/pet attack %d', tid)
    end
    local is_cmd = cast.is_command(e.spell)
    if (sp.PctHPs() or 100) <= e.hp_pct
       and ready(st, e.index, tid)
       and cond_pass(st, e, tid) then
      local ok = action.execute(st, e, tid, {
        sent_from = 'dps',
        cast_target_id = cast_id,
        allow_mem = false,
      })
      if ok then
        local dur
        if is_cmd or e.target == 'spam' then
          dur = c.dps_interval
        else
          dur = math.max(mq.TLO.Spell(e.spell).Duration.TotalSeconds() or 0, c.dps_interval)
        end
        arm(st, e.index, tid, dur)
      end
    end
  end
end

----------------------------------------------------------------------
-- Burn (Event_Burn @14392, core).
----------------------------------------------------------------------
function combat.burn(st)
  local c = st.combat
  local tid = c.my_target_id
  for _, e in ipairs(c.burn) do
    if (e.spell or '') ~= '' then
      local cast_id = tid
      if e.target == 'Me' then cast_id = mq.TLO.Me.ID()
      elseif e.target == 'MA' then cast_id = st.main_assist_id
      elseif e.target == 'Pet' then cast_id = mq.TLO.Me.Pet.ID() end
      if cond_pass(st, e, tid or 0) then
        action.execute(st, e, tid or 0, {
          sent_from = 'burn',
          cast_target_id = cast_id,
          allow_mem = false,
        })
      end
    end
  end
  c.burning = false   -- one-shot per /maburn
end

----------------------------------------------------------------------
-- Reset (CombatReset @4064, core).
----------------------------------------------------------------------
function combat.reset(st)
  local c = st.combat
  if c.attacking or util.mqbool(mq.TLO.Me.Combat()) then mq.cmd('/attack off') end
  if util.mqbool(mq.TLO.Stick.Active()) then mq.cmd('/stick off') end
  c.combat_start = nil
  c.attacking = nil
  c.my_target_id = nil
  c.my_target_name = nil
  c.burning = false
  c.named_check = nil
end

----------------------------------------------------------------------
-- AggroCheck (Sub AggroCheck @4299). aid (optional) = a mob to grab via Aggro entry 1.
----------------------------------------------------------------------
local function aggro_cast_target(st, entry, aid)
  local c = st.combat
  if entry.target == 'Me' then return mq.TLO.Me.ID() end
  if entry.target == 'MA' then return st.main_assist_id end
  if entry.target == 'Pet' then return mq.TLO.Me.Pet.ID() end
  return aid or c.my_target_id
end

function combat.aggro_check(st, aid, opts)
  opts = opts or {}
  local c = st.combat
  if (mq.TLO.Me.Level() or 0) < 20 then return false end
  for i, a in ipairs(c.aggro) do
    if not (c.dps_cond_on and a.cond and a.cond ~= '' and not cond.eval(a.cond)) then
      local pa = mq.TLO.Me.PctAggro() or 0
      local crosses = opts.force or (a.glt == '<' and pa < a.pct) or (a.glt == '>' and pa > a.pct)
      if crosses and spell_ready(a.spell) then
        local taunt = is_taunt_name(a.spell)
        local skip = (taunt and opts.holder_is_me) or (taunt and opts.taunt_in_range == false)
        if not skip then
          local tid = aggro_cast_target(st, a, aid)
          local inc_close = a.target == 'INC'
            and (mq.TLO.Spawn(aid or c.my_target_id or 0).Distance() or 9999) < c.melee_dist
          if not inc_close and tid and action.execute(st, a, aid or c.my_target_id or tid, {
            sent_from = 'Aggro',
            cast_target_id = tid,
            allow_mem = false,
          }) then
            return true
          end
        end
      end
    end
  end
  return false
end

----------------------------------------------------------------------
-- TankAllMobs (Sub TankAllMobs @4363, simplified): controlled add rescue.
----------------------------------------------------------------------
local function spawn_name(id)
  if not id or id == 0 then return '' end
  return mq.TLO.Spawn(id).CleanName() or ''
end

local function group_or_raid_member(name, id)
  name = name or spawn_name(id)
  if not name or name == '' then return false end
  return (mq.TLO.Spawn(name .. ' group').ID() or 0) ~= 0
      or (mq.TLO.Spawn(name .. ' raid').ID() or 0) ~= 0
end

local function target_effect_id(effect)
  if effect == 'Mezzed' then return mq.TLO.Target.Mezzed.ID() or 0 end
  if effect == 'Rooted' then return mq.TLO.Target.Rooted.ID() or 0 end
  return 0
end

local function aggro_tools_ready(st)
  if util.mqbool(mq.TLO.Me.AbilityReady('taunt')) then return true end
  for _, a in ipairs(st.combat.aggro or {}) do
    if a.spell and a.spell ~= '' and spell_ready(a.spell) then return true end
  end
  return false
end

local function target_aggro_info()
  local holder = mq.TLO.Target.AggroHolder
  local holder_id = holder.ID() or 0
  local holder_name = holder.CleanName() or ''
  if holder_id == 0 then
    holder_name = mq.TLO.Target.AssistName() or holder_name
    holder_id = (holder_name ~= '' and mq.TLO.Spawn(holder_name).ID()) or 0
  end
  local me_id = mq.TLO.Me.ID() or 0
  return {
    holder_id = holder_id,
    holder_name = holder_name,
    holder_is_me = holder_id == me_id or (holder_name ~= '' and holder_name == mq.TLO.Me.CleanName()),
    holder_on_group = group_or_raid_member(holder_name, holder_id),
  }
end

local function target_add(id)
  if mq.TLO.Target.ID() ~= id then
    mq.cmdf('/target id %d', id)
    mq.delay(1000, function() return mq.TLO.Target.ID() == id end)
  end
  return mq.TLO.Target.ID() == id
end

local function restore_target(id)
  if id and id ~= 0 and mq.TLO.Target.ID() ~= id then
    mq.cmdf('/target id %d', id)
    mq.delay(1000, function() return mq.TLO.Target.ID() == id end)
  end
end

local function target_distance(id)
  return mq.TLO.Target.Distance() or mq.TLO.Spawn(id).Distance() or 9999
end

local function nav_to_taunt_range(id, taunt_range)
  local dist = target_distance(id)
  if dist <= taunt_range then return true end
  if dist > ADD_NAV_RANGE then return false end
  if not util.nav_loaded() then return false end

  if util.mqbool(mq.TLO.Stick.Active()) then mq.cmd('/stick off') end
  if not util.nav_active() then mq.cmdf('/nav id %d', id) end
  mq.delay(ADD_NAV_TIMEOUT, function()
    return mq.TLO.Target.ID() == id and target_distance(id) <= taunt_range
  end)
  if util.nav_active() then mq.cmd('/nav stop') end
  return mq.TLO.Target.ID() == id and target_distance(id) <= taunt_range
end

function combat.tank_all_mobs(st)
  local c = st.combat
  if not c.tank_all_mobs or not util.is_tank(st) then return end
  if not aggro_tools_ready(st) then return end

  local restore_id = mq.TLO.Target.ID() or c.my_target_id
  local radius = st.camp.radius or 60
  local n = tonumber(mq.TLO.SpawnCount('npc radius ' .. radius .. ' targetable zradius 10')()) or 0
  local function hold_assists(duration)
    if st.comms and st.comms.broadcast_wrangle_hold then
      st.comms.broadcast_wrangle_hold(st, restore_id, duration)
    end
  end
  if n > 0 then hold_assists(math.max(4, math.min(12, n * 3))) end

  local restore_attack = util.mqbool(mq.TLO.Me.Combat())
  if restore_attack then mq.cmd('/attack off') end
  local function finish()
    restore_target(restore_id)
    hold_assists(2)
    if restore_attack and restore_id and restore_id ~= 0 and mq.TLO.Target.ID() == restore_id then
      mq.cmd('/attack on')
    end
  end

  local me = mq.TLO.Me.CleanName()
  for j = 1, n do
    if mq.TLO.Me.Hovering() then finish(); return end
    local id = mq.TLO.NearestSpawn(j .. ',npc radius ' .. radius .. ' targetable zradius 10').ID()
    if id and id ~= c.my_target_id then
      hold_assists(4)
      local sp = mq.TLO.Spawn(id)
      local an = sp.AssistName()
      local on_group = an and an ~= '' and group_or_raid_member(an)
      if an ~= me and on_group and not MEZ_ANIM[sp.Animation() or 0] and target_add(id) then
        local mezzed = target_effect_id('Mezzed') ~= 0
        local rooted = target_effect_id('Rooted') ~= 0
        if not mezzed and not rooted then
          local info = target_aggro_info()
          local dist = mq.TLO.Target.Distance() or sp.Distance() or 9999
          local taunt_range = math.min(c.melee_dist or TAUNT_RANGE, TAUNT_RANGE)
          local taunt_in_range = dist <= taunt_range

          if not info.holder_is_me and info.holder_on_group then
            local taunt_ready = util.mqbool(mq.TLO.Me.AbilityReady('taunt'))
            if not taunt_in_range and taunt_ready and dist <= ADD_NAV_RANGE then
              taunt_in_range = nav_to_taunt_range(id, taunt_range)
            end
            if taunt_in_range and taunt_ready then
              mq.cmd('/doability taunt')
              mq.delay(250)
            end
            combat.aggro_check(st, id, {
              force = true,
              holder_is_me = false,
              taunt_in_range = taunt_in_range,
            })
          end
        end
      end
    end
  end
  finish()
end

----------------------------------------------------------------------
-- Persistent debuffs (Arg2>=101) on the single assist target: apply each once while it holds.
-- (NB: distinct from combat.debuff_all_tick, which spreads `debuffall` entries to all XTargets.)
----------------------------------------------------------------------
function combat.debuff(st)
  local c = st.combat
  local tid = c.my_target_id
  if not tid then return end
  for _, e in ipairs(c.debuffs) do
    local sp = mq.TLO.Spawn(tid)
    if sp.Type() == 'Corpse' or not sp.ID() then return end
    local has = mq.TLO.Spawn(tid).CachedBuff(e.spell).ID() ~= nil
    if not has and spell_ready(e.spell) and ready(st, e.index, tid) and cond_pass(st, e, tid) then
      if action.execute(st, e, tid, {
        sent_from = 'dps',
        cast_target_id = tid,
        allow_mem = false,
      }) then
        arm(st, e.index, tid, math.max(mq.TLO.Spell(e.spell).Duration.TotalSeconds() or 0, c.dps_interval))
      end
    end
  end
end

-- DebuffAll (DoDebuffStuff @10651): apply each `debuffall` entry to every XTarget auto-hater
-- NPC in melee range + LOS that lacks it. DebuffAllOn 1 = skip if already on; 2 = also force.
function combat.debuff_all_tick(st)
  local c = st.combat
  if st.flags.buff_mode or st.flags.zombie_mode then return end   -- same gates as combat.tick
  if dmz() then return end
  if (c.debuff_all_on or 0) == 0 or #c.debuff_all == 0 then return end
  if (c.mob_count or 0) == 0 then return end
  local force = c.debuff_all_on == 2
  local melee = c.melee_dist or 25
  for i = 1, 13 do
    local xt = mq.TLO.Me.XTarget(i)
    local id = xt.ID() or 0
    if id > 0 and (xt.TargetType() or '') == 'Auto Hater' and (xt.Type() or '') == 'NPC' then
      local sp = mq.TLO.Spawn(id)
      if (sp.Distance() or 9999) < melee and util.mqbool(sp.LineOfSight()) then
        for _, e in ipairs(c.debuff_all) do
          local has = sp.CachedBuff(e.spell).ID() ~= nil
          if (force or not has) and spell_ready(e.spell) and ready(st, e.index, id)
             and cond_pass(st, e, id) then
            if action.execute(st, e, id, {
              sent_from = 'debuffall',
              cast_target_id = id,
              allow_mem = false,
            }) then
              arm(st, e.index, id, math.max(mq.TLO.Spell(e.spell).Duration.TotalSeconds() or 0, c.dps_interval))
            end
          end
        end
      end
    end
  end
end

----------------------------------------------------------------------
-- Named-auto-burn (Sub NamedWatch @15546, core): burn once when the target is Named.
----------------------------------------------------------------------
function combat.named_watch(st)
  local c = st.combat
  if not c.burn_all_named or c.named_check then return end
  local tid = c.my_target_id
  if tid and util.mqbool(mq.TLO.Spawn(tid).Named()) then
    Write.Info('*** %s is NAMED -- bursting', mq.TLO.Spawn(tid).CleanName() or '?')
    combat.burn(st)
    c.named_check = true
  end
end

----------------------------------------------------------------------
-- tick: CheckForCombat -> Assist -> Combat ordering (4a subset).
----------------------------------------------------------------------
function combat.tick(st)
  local c = st.combat
  if st.flags.buff_mode or st.flags.zombie_mode then return end
  if mq.TLO.Me.Hovering() then return end
  -- Don't engage while actively pulling (fetching/dragging) -- combat takes over once the
  -- pull resets at camp (hunters reset in-place, so they engage next tick).
  if st.pull and st.pull.state ~= 'idle' then return end
  if dmz() then return end
  if not (c.dps_on or c.melee_on) then refresh_state(st); return end

  refresh_state(st)

  if c.manual_target_mode then
    local manual_id = valid_combat_target(c.my_target_id) and c.my_target_id
      or (valid_combat_target(c.called_target_id) and c.called_target_id)
    if manual_id then
      c.aggro_target_id = manual_id
      c.my_target_id = manual_id
      c.my_target_name = mq.TLO.Spawn(manual_id).CleanName()
    else
      if c.combat_start or c.my_target_id then combat.reset(st) end
      return
    end
  end

  if (c.wrangle_hold_until or 0) > os.clock() and valid_combat_target(c.wrangle_hold_target_id) then
    c.aggro_target_id = c.wrangle_hold_target_id
  end

  local can_assist_ooc = c.assist_outside and (c.passive_mob_count or 0) > 0
  if not c.aggro_target_id and not can_assist_ooc then
    if c.combat_start or c.my_target_id then combat.reset(st) end
    return
  end

  assist(st)
  local tid = c.my_target_id
  if not tid then return end
  local sp = mq.TLO.Spawn(tid)
  if sp.Type() == 'Corpse' or (sp.ID() or 0) == 0 then combat.reset(st); return end

  if can_start_combat(st) then
    c.combat_start = true
    engage(st)
    if c.tank_all_mobs and util.is_tank(st) then combat.tank_all_mobs(st) end
    combat.debuff(st)
    combat.named_watch(st)
    combat.rotation(st)
    if c.burning then combat.burn(st) end
  end
end

return combat
