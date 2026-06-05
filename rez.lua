-- muleassist/rez.lua
-- Phase 2b: resurrection. Ports Sub RezCheck @9924.
-- Combat-gated branches (AutoRezOn==2 / !CombatStart) read st.combat.* defensively;
-- nil => "no aggro"/"not in combat", so rez works pre-Phase-4 in safe zones.
-- BroadCast -> Write.Info (real EQBC in Phase 7); CastMount deferred to Phase 5.
local mq    = require('mq')
local Write = require('muleassist.Write')
local cast  = require('muleassist.cast')
local rez   = {}

local function bt_ready(st, i)
  local d = st.rez.battle_timers[i]; return (not d) or os.clock() >= d
end
local function bt_arm(st, i, secs) st.rez.battle_timers[i] = os.clock() + secs end
local function ooc_ready(st, id)
  local d = st.rez.ooc_timers[id]; return (not d) or os.clock() >= d
end
local function ooc_arm(st, id, secs) st.rez.ooc_timers[id] = os.clock() + secs end

local function rez_ready(name)
  return mq.TLO.Me.SpellReady(name)() or mq.TLO.Me.AltAbilityReady(name)()
      or mq.TLO.Me.ItemReady('=' .. name)()
end

-- Strip the trailing "'s corpse" so corpse name -> player name (macro: .Left[-9]).
local function corpse_base(name)
  return (name or ''):gsub("'s corpse$", '')
end

function rez.check(st)
  if st.flags.buff_mode or st.flags.zombie_mode then return end
  local auto = st.rez.auto
  if auto == 0 then return end
  local with = st.rez.with
  if not with or with == '' then return end
  if mq.TLO.Me.Hovering() then return end
  local aggro = st.combat.aggro_target_id          -- nil until Phase 4
  if mq.TLO.Me.Invis() and not aggro then return end
  if auto == 2 and aggro then return end            -- AutoRezOn==2: wait until combat ends

  local is_call = with:find('Call of', 1, true) ~= nil
  local radius  = st.rez.radius

  -- 1) Group member corpses (battle rez)
  local gn = tonumber(mq.TLO.Group()) or 0
  for i = 1, gn do
    local gm    = mq.TLO.Group.Member(i)
    local mname = gm.Name()
    if mname then
      local pccorpse = mq.TLO.Spawn(mname .. ' pccorpse')
      local corpse   = mq.TLO.Spawn(mname .. ' corpse')
      if pccorpse.ID() and rez_ready(with)
         and not (is_call and gm.OtherZone() == false)
         and bt_ready(st, i)
         and (corpse.Distance() or 9999) < radius then
        if (mq.TLO.Me.CurrentMana() or 0) > (mq.TLO.Spell(with).Mana() or 0) then
          mq.cmdf('/target id %d', corpse.ID())
          mq.delay(1000, function() return mq.TLO.Target.ID() == corpse.ID() end)
          mq.cmd('/corpse')
          mq.delay(200)
          if mq.TLO.Me.Invulnerable.ID() then
            mq.cmdf('/removebuff %s', mq.TLO.Me.Invulnerable())
            mq.delay(5000, function() return not mq.TLO.Me.Invulnerable.ID() end)
          end
          if cast.cast(with, 'RezCheck', mq.TLO.Target.ID()) == 'CAST_SUCCESS' then
            Write.Info('BATTLE REZZED >> %s <<', mname)
            bt_arm(st, i, is_call and 360 or 180)
            mq.cmd('/target clear')
          elseif mname ~= st.main_assist then
            bt_arm(st, i, 60)
          end
        end
      end
    end
  end

  -- 2) My own corpse
  local me       = mq.TLO.Me.CleanName()
  local mecorpse = mq.TLO.Spawn('corpse ' .. me .. ' radius ' .. radius .. ' zradius 50')
  local rezme    = mecorpse.ID()
  if rezme and ooc_ready(st, rezme) and rez_ready(with) then
    mq.cmdf('/target id %d', rezme)
    mq.delay(1000, function() return mq.TLO.Target.ID() == rezme end)
    if (mq.TLO.Target.Distance() or 0) > st.camp.radius then mq.cmd('/corpse') end
    if cast.cast(with, 'RezCheck', mq.TLO.Target.ID()) == 'CAST_SUCCESS' then
      ooc_arm(st, rezme, 180)
      -- TODO(Phase 5): CastMount when outdoor/no-combat/MountOn and no corpses remain
    end
  end

  -- 3) Out-of-combat rez of nearby pccorpses (guild/fellowship/XTar/raid)
  local in_combat = st.combat.combat_start          -- nil until Phase 4 => not in combat
  local count = mq.TLO.SpawnCount('corpse radius ' .. radius .. ' zradius 50')() or 0
  if count > 0 and not in_combat then
    for j = 1, count do
      local sp  = mq.TLO.NearestSpawn(j .. ',pccorpse radius ' .. radius .. ' zradius 50')
      local rid = sp.ID()
      if rid and (mq.TLO.Spell(with).Mana() or 0) < (mq.TLO.Me.CurrentMana() or 0)
         and mq.TLO.Spawn(rid).Type() == 'corpse' then
        local base = corpse_base(mq.TLO.Spawn(rid).CleanName())

        -- XTar membership
        local xtar = false
        if st.heal.xtar and st.heal.xtar ~= '' and st.heal.xtar ~= '0' then
          for slot in (st.heal.xtar .. '|'):gmatch('([^|]*)|') do
            local s = tonumber(slot)
            if s and mq.TLO.Me.XTarget(s).ID() == rid then xtar = true break end
          end
        end

        local mg     = mq.TLO.Spawn(rid).Guild()
        local guild  = mg ~= nil and mg ~= '' and mg == mq.TLO.Me.Guild()
        local fellow = false
        pcall(function()
          fellow = mq.TLO.Me.Fellowship.Member(base)() ~= nil
                   and mq.TLO.Spawn(base .. ' pccorpse').ID() ~= nil
        end)
        local raid = mq.TLO.Raid.Member(base).ID() ~= nil

        if ooc_ready(st, rid) and (guild or fellow or xtar or raid) then
          if not (is_call and mq.TLO.Spawn('pc ' .. base).ID()) then
            if (mq.TLO.Spawn(rid).Distance() or 9999) <= radius then
              mq.cmdf('/target id %d', rid)
              mq.delay(1000, function() return mq.TLO.Target.ID() == rid end)
              if cast.cast(with, 'RezCheck', mq.TLO.Target.ID()) == 'CAST_SUCCESS' then
                Write.Info('Rezzing >> %s <<', mq.TLO.Target.CleanName() or base)
                ooc_arm(st, rid, 300)
                mq.delay(3000, function() return not mq.TLO.Me.Casting.ID() end)
                mq.cmd('/target clear')
              end
            end
          end
        end
      end
    end
  end
end

return rez
