-- muleassist/heal.lua
-- Phase 2a: healing core. Ports FindSingleHeals @14767, FindGroupHeals @14830,
-- CheckHealth @9363, SingleHeal @9521, DoGroupHealStuff @9841, DoPetHealStuff @9892.
-- Rez (RezCheck) + healer coordination (CheckHealer) are Phase 2b (st.hooks.rez_check).
-- Combat-only branches (Tap/Mob/assist) are ported structurally but guarded on
-- st.combat.* (nil until Phase 4) so they no-op until combat lands.
local mq    = require('mq')
local Write = require('muleassist.Write')
local cast  = require('muleassist.cast')
local cond  = require('muleassist.cond')
local heal  = {}

-- Indirection so categorization is testable offline (overridden in tests).
function heal._resolve_target_type(name)
  return (mq.TLO.Spell(name).TargetType() or '')
end

local function item_self(name)
  local sp = mq.TLO.Spell(mq.TLO.FindItem('=' .. name).Spell())
  return ((sp.TargetType() or ''):lower():find('self')) ~= nil
end

local SPECIAL_SINGLE = {
  'Aegis of Superior Divinity', 'Harmony of the Soul', 'Burst of Life', 'Focused Celestial Regeneration',
}
local function name_has(name, t)
  for _, p in ipairs(t) do if name:find(p, 1, true) then return true end end
  return false
end
local function tag_in(tag, set)
  tag = tag or ''
  for _, v in ipairs(set) do if tag == v then return true end end
  return false
end

----------------------------------------------------------------------
-- Timer model (replaces Spell{i}GM{who} / SpellGH{j} / PetHealTimer{q}).
-- Absolute os.clock() deadlines in seconds; "ready" = now past the deadline.
----------------------------------------------------------------------
local function ready(st, i, who)
  local row = st.heal.timers[i]
  return (not row) or (not row[who]) or os.clock() >= row[who]
end
local function arm(st, i, who, secs)
  st.heal.timers[i] = st.heal.timers[i] or {}
  st.heal.timers[i][who] = os.clock() + secs
end
local function ready_group(st, j)
  return (not st.heal.group_timers[j]) or os.clock() >= st.heal.group_timers[j]
end
local function arm_group(st, j, secs) st.heal.group_timers[j] = os.clock() + secs end
local function arm_pet(st, i, secs) st.heal.pet_timers[i] = os.clock() + secs end

local function heal_dur(st, name)
  if name:find('Promised') then return 24 end
  return (mq.TLO.Spell(name).Duration.TotalSeconds() or 0) * (st.heal.duration_mod or 1)
end

local function spell_ready(name)
  return (mq.TLO.Me.Book(name)() ~= nil and mq.TLO.Me.Book(name)() > 0)
    or mq.TLO.Me.AltAbilityReady(name)()
    or mq.TLO.Me.CombatAbilityReady(name)()
end

----------------------------------------------------------------------
-- Categorization (FindSingleHeals + FindGroupHeals)
----------------------------------------------------------------------
function heal.setup(st, me)
  me = me or {
    class_short = mq.TLO.Me.Class.ShortName() or '',
    class_name  = mq.TLO.Me.Class.Name() or '',
  }
  local single, group, point = {}, {}, 0
  for _, e in ipairs(st.lists.heals) do
    local name = e.spell or ''
    local pct  = tonumber(e.args[2]) or 0
    local tag  = e.args[3] or ''
    local tt   = heal._resolve_target_type(name)

    local ok_item_self = false
    pcall(function() ok_item_self = item_self(name) end)

    local is_single =
      name_has(name, SPECIAL_SINGLE)
      or ((me.class_name == 'Druid' or me.class_name == 'Shaman')
          and (name:find('Intervention', 1, true) or name:find('Survival', 1, true)))
      or (tt == 'Single' or tt == 'Self')
      or ok_item_self
      or (tag:lower():find('tap') ~= nil) or (tag:lower():find('pet') ~= nil)
      or (tt:find('Targeted AE') and tag_in(tag, { 'MA', 'ME', 'pet' }))
      or (tt == 'Free Target')

    if is_single then
      single[#single + 1] = e
      if pct > point then point = pct end
    end

    local skip = (#name == 0) or name:lower() == 'null'
      or tt == 'Single' or tt == 'Self' or ok_item_self
      or name_has(name, SPECIAL_SINGLE)
      or (me.class_name == 'Shaman' and name:find('Intervention', 1, true))
      or (me.class_name == 'Druid'  and name:find('Survival', 1, true))
    if (not skip) and (tt:find('group v') or (tt:find('Targeted AE') and not tag_in(tag, { 'MA', 'ME' }))) then
      group[#group + 1] = e
    end
  end

  local desc = function(a, b) return (tonumber(a.args[2]) or 0) > (tonumber(b.args[2]) or 0) end
  table.sort(single, desc)
  table.sort(group, desc)
  st.heal.single, st.heal.group, st.heal.single_point = single, group, point
  Write.Info('heal.setup: %d single, %d group heals (point=%d)', #single, #group, point)
end

----------------------------------------------------------------------
-- SingleHeal @9521
----------------------------------------------------------------------
function heal.single(st, sheal_name, sheal_type, sheal_hps, who_num, the_heal_id)
  if st.flags.buff_mode or st.flags.zombie_mode then return end
  if st.heal.mode == 0 then return end
  if mq.TLO.Me.Moving() or mq.TLO.Me.Hovering() then return end
  if not the_heal_id or the_heal_id == 0 then return end
  if not (sheal_type == 'PC' or sheal_type == 'Pet' or sheal_type == 'Mercenary') then return end
  if mq.TLO.Me.Invis() and not st.combat.aggro_target_id then return end

  -- Keep MA duration tracking consistent (macro: WhoNum -> 6 for the MainAssist).
  if who_num ~= 6 and the_heal_id == st.main_assist_id then who_num = 6 end

  local single = st.heal.single
  local is_self = (the_heal_id == mq.TLO.Me.ID())

  -- One spell-slot attempt. Returns 'next' (try next slot) or 'done' (stop SingleHeal).
  local function attempt(e, i)
    local name = e.spell
    local pct  = tonumber(e.args[2]) or 0
    local tag  = e.args[3] or ''
    if not name or name == '' or e.args[2] == '0' then return 'next' end

    local range = mq.TLO.Spell(name).MyRange() or 0
    if (mq.TLO.Spell(name).TargetType() or ''):find('Group v') then
      range = mq.TLO.Spell(name).AERange() or 0
    end
    if range == 0 then range = 100 end

    -- Conditional check
    if st.heal.cond_on and e.cond and e.cond ~= '' then
      if is_self then
        if not cond.eval(e.cond) then return 'next' end
        if tag:find('buff!=', 1, true) then
          local b = tag:sub(7)
          if mq.TLO.Me.Buff(b).ID() then return 'next' end
          tag = b
        elseif tag:find('buff==', 1, true) then
          local b = tag:sub(7)
          if not mq.TLO.Me.Buff(b).ID() then return 'next' end
          tag = b
        end
      else
        if (mq.TLO.Spawn(the_heal_id).Distance3D() or 9999) > 250 then return 'next' end
        if e.cond:find('{Target.', 1, true) then
          Write.Error('Heal cond %q uses ${Target...} which is unsupported; use ${Spawn[id]...}. Skipping.', e.cond)
          return 'next'
        end
        if not cond.eval(e.cond) then return 'next' end
        if tag:find('buff!=', 1, true) or tag:find('buff==', 1, true) then
          local want_present = tag:find('buff==', 1, true) ~= nil
          local b = tag:sub(7)
          mq.cmdf('/target id %d', the_heal_id)
          mq.delay(1000, function() return mq.TLO.Target.ID() == the_heal_id end)
          mq.delay(1000, function() return mq.TLO.Target.BuffsPopulated() end)
          local has
          if (mq.TLO.Spell(b).Duration() or 0) > 0 then
            has = (mq.TLO.Spawn(the_heal_id).CachedBuff(b).Duration() or 0) > 0
          else
            has = mq.TLO.Spawn(the_heal_id).CachedBuff(b).ID() ~= nil
          end
          if want_present and not has then return 'next' end      -- buff==: need present
          if (not want_present) and has then return 'next' end     -- buff!=: need absent
          tag = b
        end
      end
    end

    -- Tag gating (@9661-9701)
    if tag == 'Me' and not is_self then return 'next' end
    if mq.TLO.Spawn(the_heal_id).Type() ~= 'Pet' and tag == 'pet' then return 'next' end
    if mq.TLO.Spawn(the_heal_id).Type() == 'Pet' and tag == '!pet' then return 'next' end
    if the_heal_id ~= st.main_assist_id then
      if st.heal.group_pets then
        if tag == 'pet' and mq.TLO.Spawn(the_heal_id).Type() ~= 'Pet' then return 'next' end
      else
        if tag == 'pet' then return 'next' end
      end
      if tag == 'Mob' and mq.TLO.Spawn(the_heal_id).Type() ~= 'NPC' then return 'next' end
      if tag == 'MA' then return 'next' end
    else
      if tag == '!MA' then return 'next' end
    end

    -- Special-spell restrictions (@9704-9724)
    local grouped = mq.TLO.Spawn(sheal_name .. ' ' .. sheal_type .. ' group').ID() ~= nil
    if mq.TLO.Spawn(the_heal_id).Type() == 'Pet'
       and name_has(name, { 'Aegis of Superior Divinity', 'Harmony of the Soul', 'Divine Arbitration' }) then
      return 'next'
    end
    if not grouped
       and name_has(name, { 'Aegis of Superior Divinity', 'Harmony of the Soul', 'Divine Arbitration' }) then
      return 'next'
    end
    if not grouped then
      local cn = mq.TLO.Me.Class.Name()
      if (cn == 'Druid' or cn == 'Shaman') and (name:find('Intervention', 1, true) or name:find('Survival', 1, true)) then
        return 'next'
      end
    end

    -- Tap (lifetap) branch (@9726) -- combat-dependent: deferred to Phase 4.
    if tag:find('Tap', 1, true) then
      if not (st.combat.combat_start and st.combat.my_target_id and not st.combat.pulled) then
        return 'next'  -- Phase 4 fills st.combat.*; until then lifetaps no-op
      end
      -- (full Tap port lands with combat in Phase 4)
      return 'next'
    end

    -- Mob (nuke-heal) branch (@9746) -- combat-dependent: deferred to Phase 4.
    if tag:find('Mob', 1, true) then
      if not st.combat.aggro_target_id then return 'next' end
      -- (full Mob/assist port lands with combat in Phase 4)
      return 'next'
    end

    -- Normal heal (@9776)
    local dist = mq.TLO.Spawn(sheal_name .. ' ' .. sheal_type).Distance() or 9999
    if sheal_hps <= pct and dist <= range and ready(st, i, who_num) and spell_ready(name) then
      st.heal._again = 2

      if mq.TLO.Spell(name).TargetType() == 'Free Target' then
        if mq.TLO.Target.ID() ~= the_heal_id then
          mq.cmdf('/target id %d', the_heal_id)
          mq.delay(2000, function() return mq.TLO.Target.ID() == the_heal_id end)
        end
        if not mq.TLO.Target.CanSplashLand() then return 'next' end
      end

      if (mq.TLO.EverQuest.Server() or ''):lower() == 'zek' then
        if mq.TLO.Target.Type() == 'PC' and mq.TLO.Me.Combat() then
          mq.cmd('/attack off')
          mq.delay(250, function() return not mq.TLO.Me.Combat() end)
        end
      end

      if the_heal_id == st.main_assist_id and mq.TLO.Me.Buff('Divine Barrier').ID() then
        mq.cmd('/removebuff Divine Barrier')
      end

      if (mq.TLO.Spell(name).Mana() or 0) + 20 > (mq.TLO.Me.CurrentMana() or 0) then return 'next' end

      local role = (st.role or ''):lower()
      if (role == 'hunter' or role == 'tank' or role == 'pullertank')
         and mq.TLO.Me.CombatState() == 'COMBAT' and not mq.TLO.Me.Gem(name)() then
        return 'next'
      end

      Write.Info('%s on %s', name, mq.TLO.Spawn(sheal_name .. ' ' .. sheal_type).CleanName() or sheal_name)
      local result = cast.cast(name, 'SingleHeal', the_heal_id)
      if result == 'CAST_SUCCESS' then
        arm(st, i, who_num, heal_dur(st, name))
        st.heal._again = 1
        return 'done'
      elseif result == 'CAST_CANCELLED' then
        return 'done'
      end
    end
    return 'next'
  end

  -- :NoHeal retry loop (@9552 / @9832): retry within 5s if a target qualified but
  -- couldn't be healed (heal_again == 2) after a full pass.
  local start = os.clock()
  repeat
    st.heal._again = 0
    for i, e in ipairs(single) do
      if attempt(e, i) == 'done' then return end
    end
  until not (st.heal._again == 2 and (os.clock() - start) < 5)
  st.heal._again = 0
end

----------------------------------------------------------------------
-- DoGroupHealStuff @9841
----------------------------------------------------------------------
function heal.do_group(st, group_health)
  if st.flags.buff_mode or st.flags.zombie_mode then return end
  for j, g in ipairs(st.heal.group) do
    if not g.spell or g.spell == '' or g.args[2] == '0' then return end
    local pct = tonumber(g.args[2]) or 0
    if st.heal.cond_on and g.cond and g.cond ~= '' and not cond.eval(g.cond) then
      -- condition false: skip this group heal
    elseif group_health <= pct and ready_group(st, j) and mq.TLO.Group() then
      local result = cast.cast(g.spell, 'GroupHeal', mq.TLO.Me.ID())
      if result == 'CAST_SUCCESS' then
        Write.Info('%s on >> Group <<', g.spell)
        arm_group(st, j, heal_dur(st, g.spell))
        st.heal._again = 1
        return
      end
    end
  end
end

----------------------------------------------------------------------
-- DoPetHealStuff @9892
----------------------------------------------------------------------
function heal.do_pet(st)
  if st.flags.buff_mode or st.flags.zombie_mode then return end
  if not mq.TLO.Me.Pet.ID() then return end
  for i, e in ipairs(st.heal.single) do
    if e.args[3] == 'pet' and e.spell and e.spell ~= '' and e.args[2] ~= '0' then
      local pct = tonumber(e.args[2]) or 0
      if (mq.TLO.Me.Pet.PctHPs() or 100) <= pct
         and (mq.TLO.Me.Pet.Distance() or 9999) < (mq.TLO.Spell(e.spell).MyRange() or 100) then
        local result = cast.cast(e.spell, 'Heal', mq.TLO.Me.Pet.ID())
        if result == 'CAST_SUCCESS' then
          Write.Info('%s on >> %s <<', e.spell, mq.TLO.Me.Pet.CleanName() or 'pet')
          arm_pet(st, i, heal_dur(st, e.spell))
          st.heal._again = 1
        end
      end
    end
  end
end

----------------------------------------------------------------------
-- CheckHealth @9363 (orchestration)
----------------------------------------------------------------------
local HEALER_CLASSES   = { BST=true, CLR=true, SHM=true, DRU=true, RNG=true, PAL=true }
local GROUPHEAL_CLASSES = { BST=true, CLR=true, SHM=true, DRU=true, PAL=true }

function heal.tick(st)
  if st.flags.buff_mode or st.flags.zombie_mode then return end
  if st.hooks.oh_shit then st.hooks.oh_shit('CheckHealth') end
  if st.hooks.custom_func then st.hooks.custom_func() end
  if st.heal.mode == 0 then return end
  if mq.TLO.Me.Invis() and not st.combat.aggro_target_id then return end

  local cls = mq.TLO.Me.Class.ShortName() or ''
  local me_id = mq.TLO.Me.ID()
  local mode = st.heal.mode

  repeat
    st.heal._again = 0

    -- self
    if (mq.TLO.Me.PctHPs() or 100) <= st.heal.single_point then
      heal.single(st, mq.TLO.Me.CleanName(), 'PC', mq.TLO.Me.PctHPs(), 0, me_id)
    end

    if HEALER_CLASSES[cls] then
      local ma   = st.main_assist
      local mat  = st.main_assist_type or 'PC'
      -- MA out-of-group heal (mode 1 or 3)
      if (mode == 1 or mode == 3) and ma and mq.TLO.Spawn('=' .. ma).ID() and mq.TLO.Spawn('=' .. ma).ID() ~= me_id then
        local maspawn = mq.TLO.Spawn('=' .. ma .. ' ' .. mat)
        if maspawn.ID() and (maspawn.PctHPs() or 100) < 100 then
          heal.single(st, ma, mat, maspawn.PctHPs(), 0, st.main_assist_id)
        end
      end

      -- rez (Phase 2b)
      if st.hooks.rez_check then st.hooks.rez_check() end

      -- most-hurt group member (mode 1 or 2)
      if (mode == 1 or mode == 2) and mq.TLO.Group() then
        local n = mq.TLO.Group() or 0
        local mh_name, mh_type, mh_id, mh_hp, mh_no = nil, nil, 0, 100, 0
        for i = 0, n do
          local gm = mq.TLO.Group.Member(i)
          if gm.ID() then
            if mode == 2 and (gm.ID() == mq.TLO.Spawn('=' .. (st.main_assist or '') .. ' ' .. mat).ID()) then
              -- skip MA in mode 2
            elseif gm.Type() ~= 'corpse' and (gm.PctHPs() or 0) >= 1 then
              if (gm.PctHPs() or 100) <= mh_hp then
                mh_name, mh_type, mh_id, mh_hp, mh_no = gm.CleanName(), gm.Type(), gm.ID(), gm.PctHPs(), i
              end
              if st.heal.group_pets then
                local pcls = (gm.Class.Name() or ''):lower()
                if pcls ~= 'cleric' and pcls ~= 'wizard' and gm.Pet.ID()
                   and (gm.Pet.PctHPs() or 100) <= mh_hp then
                  mh_name, mh_type, mh_id, mh_hp, mh_no = gm.Pet.CleanName(), 'Pet', gm.Pet.ID(), gm.Pet.PctHPs(), i + 8
                end
              end
            end
          end
        end
        if mh_id ~= 0 and mh_hp <= st.heal.single_point then
          heal.single(st, mh_name, mh_type, mh_hp, mh_no, mh_id)
        end
      end
    end

    -- group heals
    if GROUPHEAL_CLASSES[cls] and mq.TLO.Group() then
      heal.do_group(st, mq.TLO.Group.AvgHPs())
    end

    -- XTarget heals
    if st.heal.xtar and st.heal.xtar ~= '' and st.heal.xtar ~= '0' then
      for slot in (st.heal.xtar .. '|'):gmatch('([^|]*)|') do
        local s = tonumber(slot)
        if s then
          local xid = mq.TLO.Me.XTarget(s).ID()
          if xid and xid > 0 then
            local sp = mq.TLO.Spawn(xid)
            local ty = sp.Type()
            if (ty == 'PC' or ty == 'Mercenary' or ty == 'Pet') and (sp.PctHPs() or 100) <= st.heal.single_point then
              heal.single(st, sp.CleanName(), ty, sp.PctHPs(), 7, xid)
            end
          end
        end
      end
    end

    -- pet
    if st.flags.pet_on and mq.TLO.Me.Pet.ID() and (mq.TLO.Me.Pet.PctHPs() or 100) < 100 then
      heal.do_pet(st)
    end
  until (st.heal._again or 0) == 0  -- re-check health only after a heal landed (HealAgain)

  if st.hooks.write_debuffs then st.hooks.write_debuffs() end
end

return heal
