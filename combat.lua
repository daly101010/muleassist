-- muleassist/combat.lua
-- Phase 4a: assist + DPS/melee + burn. Ports CheckForCombat @1727 / Assist @1860 /
-- Combat @2508 / CombatCast @3077 / Event_Burn @14392 (core paths only). Tank/aggro/mez/
-- merc/weave/pull/debuff-all are Phase 4b+. Casts via cast.cast; conditions via cond.eval.
-- Populates st.combat.* which heal/buff/rez read defensively.
local mq    = require('mq')
local Write = require('muleassist.Write')
local cast  = require('muleassist.cast')
local cond  = require('muleassist.cond')
local serialize = require('muleassist.serialize')
local combat = {}

local HUB_ZONES = { poknowledge=1, guildlobby=1, guildhall=1, bazaar=1, nexus=1 }

-- MQ bool TLOs can return the strings "TRUE"/"FALSE" rather than Lua booleans.
local function mqbool(v)
  local t = type(v)
  if t == 'boolean' then return v end
  if t == 'number'  then return v ~= 0 end
  if t == 'string'  then local u = v:upper(); return u == 'TRUE' or u == '1' end
  return false
end

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
-- GetHostilesOnXTarget @18436: count auto-hater NPC XTargets.
local function hostiles()
  local n = 0
  for i = 1, 13 do
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
  local axt = mq.TLO.Me.XTarget(c.xtslot)
  c.aggro_target_id = ((axt.ID() or 0) > 0 and (axt.TargetType() or '') == 'Auto Hater') and axt.ID() or nil
  c.hostile_count = hostiles()
  c.mob_count = tonumber(mq.TLO.SpawnCount('npc targetable radius ' .. c.melee_dist .. ' los')()) or 0
  if c.aggro_target_id and c.mob_count == 0 then c.mob_count = 1 end
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
local TANK_ROLES = { tank=1, pullertank=1, pettank=1, pullerpettank=1 }
local MEZ_ANIM   = { [26]=1, [32]=1, [71]=1, [72]=1, [17]=1, [111]=1, [129]=1 }

local function is_tank(st)
  return TANK_ROLES[(st.combat.role or ''):lower()] ~= nil
      or (st.main_assist ~= nil and st.main_assist == mq.TLO.Me.CleanName())
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
      if mqbool(xt.Named()) then bestNamed = xt.ID(); break end
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
  if is_tank(st) then tank_pick_target(st); return end
  local c = st.combat
  local ma = st.main_assist
  if not ma or ma == '' or ma == mq.TLO.Me.CleanName() then return end
  if not (c.mob_count > 0 or c.aggro_target_id) then return end
  local maSpawn = mq.TLO.Spawn('=' .. ma)
  if not maSpawn.ID() or (maSpawn.Distance() or 9999) >= 200 then return end

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
  local ok = (sp.Type() == 'NPC') or (sp.Type() == 'PET' and sp.Master.Type() ~= 'PC')
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
  local sp = mq.TLO.Spawn(id)
  local ty = sp.Type()
  if ty ~= 'NPC' and ty ~= 'PET' then return false end
  -- Tanks initiate, so they engage at full HP (macro forces AssistAt=100 for tank roles);
  -- assists wait until the MA brings the mob to AssistAt%.
  local at = is_tank(st) and 100 or c.assist_at
  if (sp.PctHPs() or 100) > at then return false end
  local dist = sp.Distance() or 9999
  if dist < c.melee_dist then return true end
  -- Camp-distance gate: anchor on SELF when tanking (we are the camp center), else on the MA.
  local ay, ax
  if is_tank(st) then
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
  local rank = mq.TLO.Spell(name).RankName()
  return mqbool(mq.TLO.Me.SpellReady(rank)()) or mqbool(mq.TLO.Me.AltAbilityReady(name)())
      or mqbool(mq.TLO.Me.CombatAbilityReady(rank)()) or mqbool(mq.TLO.Me.AbilityReady(name)())
      or mqbool(mq.TLO.Me.ItemReady(name)())
end

-- Engage melee: attack + stick + face (re-attack offset -5 handled by can_start_combat gate).
local function engage(st)
  local c = st.combat
  if not c.melee_on then return end
  local id = c.my_target_id
  if not id then return end
  if mq.TLO.Target.ID() ~= id then mq.cmdf('/target id %d', id) end
  if not mqbool(mq.TLO.Me.Combat()) then mq.cmd('/attack on'); c.attacking = true end
  if c.face_on then mq.cmd('/face fast nolook') end
  if not mqbool(mq.TLO.Stick.Active()) then
    -- Tanks always hold the front so the mob faces them; everyone else uses StickHow.
    local how = (is_tank(st) and c.tank_stick) or c.stick_how or '12'
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
       and mq.TLO.Me.Pet.ID() and not mqbool(mq.TLO.Me.Pet.Combat()) then
      mq.cmdf('/pet attack %d', tid)
    end
    local is_cmd = e.spell:find('^command:') ~= nil
    if (is_cmd or spell_ready(e.spell))
       and (sp.PctHPs() or 100) <= e.hp_pct
       and ready(st, e.index, tid)
       and cond_pass(st, e, tid) then
      if cast.cast(e.spell, 'dps', cast_id) == 'CAST_SUCCESS' then
        local dur
        if e.target == 'spam' then
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
      if spell_ready(e.spell) and cond_pass(st, e, tid or 0) then
        cast.cast(e.spell, 'burn', cast_id)
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
  if c.attacking or mqbool(mq.TLO.Me.Combat()) then mq.cmd('/attack off') end
  if mqbool(mq.TLO.Stick.Active()) then mq.cmd('/stick off') end
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
function combat.aggro_check(st, aid)
  local c = st.combat
  if (mq.TLO.Me.Level() or 0) < 20 then return end
  for i, a in ipairs(c.aggro) do
    if aid and i == 1 then cast.cast(a.spell, 'Aggro', aid) end
    if not (c.dps_cond_on and a.cond and a.cond ~= '' and not cond.eval(a.cond)) then
      local pa = mq.TLO.Me.PctAggro() or 0
      local crosses = (a.glt == '<' and pa < a.pct) or (a.glt == '>' and pa > a.pct)
      if crosses and spell_ready(a.spell) then
        local tid
        if a.target == 'Me' then tid = mq.TLO.Me.ID()
        elseif a.target == 'MA' then tid = st.main_assist_id
        elseif a.target == 'Pet' then tid = mq.TLO.Me.Pet.ID()
        else tid = aid or c.my_target_id end
        local inc_close = a.target == 'INC'
          and (mq.TLO.Spawn(c.my_target_id or 0).Distance() or 9999) < c.melee_dist
        if not inc_close and tid and cast.cast(a.spell, 'Aggro', tid) == 'CAST_SUCCESS' then
          return
        end
      end
    end
  end
end

----------------------------------------------------------------------
-- TankAllMobs (Sub TankAllMobs @4363, simplified): grab aggro on camp NPCs not on me.
----------------------------------------------------------------------
function combat.tank_all_mobs(st)
  local c = st.combat
  if not is_tank(st) then return end
  local radius = st.camp.radius or 60
  local n = tonumber(mq.TLO.SpawnCount('npc radius ' .. radius .. ' targetable zradius 10')()) or 0
  local me = mq.TLO.Me.CleanName()
  for j = 1, n do
    if mq.TLO.Me.Hovering() then return end
    local id = mq.TLO.NearestSpawn(j .. ',npc radius ' .. radius .. ' targetable zradius 10').ID()
    if id and id ~= c.my_target_id then
      local sp = mq.TLO.Spawn(id)
      local an = sp.AssistName()
      local on_group = an and an ~= '' and (mq.TLO.Spawn(an .. ' group').ID() or mq.TLO.Spawn(an .. ' raid').ID())
      if an ~= me and on_group and not MEZ_ANIM[sp.Animation() or 0] then
        mq.cmdf('/target id %d', id)
        mq.delay(1000, function() return mq.TLO.Target.ID() == id end)
        if mq.TLO.Target.ID() == id and not mq.TLO.Target.Mezzed.ID() and not mq.TLO.Target.Rooted.ID() then
          if not mqbool(mq.TLO.Me.Combat()) then mq.cmd('/attack on') end
          mq.cmd('/face fast nolook')
          if mqbool(mq.TLO.Me.AbilityReady('taunt')) then mq.cmd('/doability taunt') end
          combat.aggro_check(st, id)
        end
      end
    end
  end
  if c.my_target_id then mq.cmdf('/target id %d', c.my_target_id) end
end

----------------------------------------------------------------------
-- Debuff-all DPS entries (Arg2>=101; DoDebuffStuff core): apply each once to the target.
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
      if cast.cast(e.spell, 'dps', tid) == 'CAST_SUCCESS' then
        arm(st, e.index, tid, math.max(mq.TLO.Spell(e.spell).Duration.TotalSeconds() or 0, c.dps_interval))
      end
    end
  end
end

-- DebuffAll (DoDebuffStuff @10651): apply each `debuffall` entry to every XTarget auto-hater
-- NPC in melee range + LOS that lacks it. DebuffAllOn 1 = skip if already on; 2 = also force.
function combat.debuff_all_tick(st)
  local c = st.combat
  if (c.debuff_all_on or 0) == 0 or #c.debuff_all == 0 then return end
  if (c.mob_count or 0) == 0 then return end
  local force = c.debuff_all_on == 2
  local melee = c.melee_dist or 25
  for i = 1, 13 do
    local xt = mq.TLO.Me.XTarget(i)
    local id = xt.ID() or 0
    if id > 0 and (xt.TargetType() or '') == 'Auto Hater' and (xt.Type() or '') == 'NPC' then
      local sp = mq.TLO.Spawn(id)
      if (sp.Distance() or 9999) < melee and mqbool(sp.LineOfSight()) then
        for _, e in ipairs(c.debuff_all) do
          local has = mq.TLO.Spawn(id).CachedBuff(e.spell).ID() ~= nil
          if (force or not has) and spell_ready(e.spell) and ready(st, e.index, id)
             and cond_pass(st, e, id) then
            if cast.cast(e.spell, 'debuffall', id) == 'CAST_SUCCESS' then
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
  if tid and mqbool(mq.TLO.Spawn(tid).Named()) then
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

  if not c.aggro_target_id and c.mob_count == 0 then
    if c.combat_start then combat.reset(st) end
    return
  end

  assist(st)
  local tid = c.my_target_id
  if not tid then return end
  local sp = mq.TLO.Spawn(tid)
  if sp.Type() == 'Corpse' or not sp.ID() then combat.reset(st); return end

  if can_start_combat(st) then
    c.combat_start = true
    engage(st)
    if is_tank(st) then combat.tank_all_mobs(st) end
    combat.debuff(st)
    combat.named_watch(st)
    combat.rotation(st)
    if c.burning then combat.burn(st) end
  end
end

return combat
