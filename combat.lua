-- muleassist/combat.lua
-- Phase 4a: assist + DPS/melee + burn. Ports CheckForCombat @1727 / Assist @1860 /
-- Combat @2508 / CombatCast @3077 / Event_Burn @14392 (core paths only). Tank/aggro/mez/
-- merc/weave/pull/debuff-all are Phase 4b+. Casts via cast.cast; conditions via cond.eval.
-- Populates st.combat.* which heal/buff/rez read defensively.
local mq    = require('mq')
local Write = require('muleassist.Write')
local cast  = require('muleassist.cast')
local cond  = require('muleassist.cond')
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

-- Temporary diagnostics (toggle off once combat is verified).
combat.debug = true
local function dbg(fmt, ...) if combat.debug then Write.Info('[cbtdbg] ' .. fmt, ...) end end

----------------------------------------------------------------------
-- setup: parse DPS/Burn lists, find the XTarget Auto-Hater slot.
----------------------------------------------------------------------
-- Parse a DPS entry's pipe fields with the if/notif arg-shift (CombatCast @3167-3185).
local function parse_dps(e)
  local a = e.args
  local part1 = a[1] or e.spell or ''
  local part2 = tonumber(a[2] or '') or 0
  local target, cond_tag, cond_spell
  local a3 = a[3] or ''
  if a3 == 'if' or a3 == 'ifme' or a3 == 'notif' or a3 == 'notifme' then
    target = 'Mob'; cond_tag = a3; cond_spell = a[4]
  else
    target = (a3 ~= '' and a3) or 'Mob'; cond_tag = a[4]; cond_spell = a[5]
  end
  return {
    index = e.index, spell = part1, hp_pct = part2, target = target,
    cond_tag = cond_tag, cond_spell = cond_spell, cond = e.cond,
    is_debuff = part2 >= 101,
  }
end

function combat.setup(st)
  local dps = {}
  for _, e in ipairs(st.lists.dps) do
    local entry = parse_dps(e)
    if not entry.is_debuff and entry.spell ~= '' and entry.spell:lower() ~= 'null' then
      dps[#dps + 1] = entry
    end
  end
  st.combat.entries = dps

  local burn = {}
  for _, e in ipairs(st.lists.burn) do
    local a = e.args
    if (a[1] or '') ~= '' and (a[1] or ''):lower() ~= 'null' then
      burn[#burn + 1] = { spell = a[1], target = (a[2] ~= '' and a[2]) or 'Mob',
                          cond_tag = a[3], cond_spell = a[4], cond = e.cond, index = e.index }
    end
  end
  st.combat.burn = burn

  -- First XTarget "Auto Hater" slot (macro XTSlot @1175-1178).
  st.combat.xtslot = 1
  for i = 1, 13 do
    if (mq.TLO.Me.XTarget(i).TargetType() or '') == 'Auto Hater' then st.combat.xtslot = i; break end
  end
  Write.Info('combat.setup: %d dps, %d burn (xtslot=%d)', #dps, #burn, st.combat.xtslot)
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
-- Assist (Sub Assist @1860, core): set my_target_id from the MA's target.
----------------------------------------------------------------------
local function assist(st)
  local c = st.combat
  local ma = st.main_assist
  if not ma or ma == '' or ma == mq.TLO.Me.CleanName() then dbg('assist bail: no MA (%s)', tostring(ma)); return end
  if not (c.mob_count > 0 or c.aggro_target_id) then dbg('assist bail: no mob/aggro'); return end
  local maSpawn = mq.TLO.Spawn('=' .. ma)
  if not maSpawn.ID() or (maSpawn.Distance() or 9999) >= 200 then
    dbg('assist bail: MA spawn id=%s dist=%s', tostring(maSpawn.ID()), tostring(maSpawn.Distance())); return
  end

  local tmp
  if c.assist_outside then
    local an = maSpawn.AssistName()
    tmp = (an and mq.TLO.Spawn(an).ID()) or mq.TLO.Me.GroupAssistTarget.ID()
  else
    tmp = mq.TLO.Me.GroupAssistTarget.ID()
  end
  dbg('assist: assist_outside=%s GroupAssistTarget=%s tmp=%s', tostring(c.assist_outside),
      tostring(mq.TLO.Me.GroupAssistTarget.ID()), tostring(tmp))
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
  if (sp.PctHPs() or 100) > c.assist_at then return false end
  local dist = sp.Distance() or 9999
  if dist < c.melee_dist then return true end
  local ma = mq.TLO.Spawn('=' .. (st.main_assist or ''))
  if ma.ID() then
    local d = mq.TLO.Math.Distance(string.format('%f,%f:%f,%f',
      sp.Y() or 0, sp.X() or 0, ma.Y() or 0, ma.X() or 0))()
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
    mq.cmdf('/stick %s id %d', c.stick_how or '12', id)
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
end

----------------------------------------------------------------------
-- tick: CheckForCombat -> Assist -> Combat ordering (4a subset).
----------------------------------------------------------------------
function combat.tick(st)
  local c = st.combat
  if st.flags.buff_mode or st.flags.zombie_mode then return end
  if mq.TLO.Me.Hovering() then return end
  if dmz() then return end
  if not (c.dps_on or c.melee_on) then refresh_state(st); return end

  refresh_state(st)
  dbg('tick: MA=%s aggro=%s mob_count=%d dps_on=%s melee_on=%s',
      tostring(st.main_assist), tostring(c.aggro_target_id), c.mob_count,
      tostring(c.dps_on), tostring(c.melee_on))

  if not c.aggro_target_id and c.mob_count == 0 then
    if c.combat_start then combat.reset(st) end
    return
  end

  assist(st)
  local tid = c.my_target_id
  dbg('after assist: my_target_id=%s (%s)', tostring(tid),
      tid and (mq.TLO.Spawn(tid).CleanName() or '?') or 'none')
  if not tid then return end
  local sp = mq.TLO.Spawn(tid)
  if sp.Type() == 'Corpse' or not sp.ID() then combat.reset(st); return end

  local csc = can_start_combat(st)
  dbg('can_start_combat=%s (tgtHP=%s assistAt=%d dist=%s meleeDist=%d)', tostring(csc),
      tostring(sp.PctHPs()), c.assist_at, tostring(sp.Distance()), c.melee_dist)
  if csc then
    c.combat_start = true
    engage(st)
    combat.rotation(st)
    if c.burning then combat.burn(st) end
  end
end

return combat
