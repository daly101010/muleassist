-- muleassist/pet.lua
-- Phase 6: pet management. Ports the summon/stance core of DoPetStuff @8360 as a NON-BLOCKING
-- tick: summon PetSpell when petless (out of combat), dismiss a summoned familiar, and set
-- post-summon stance (guard/follow by role + camp, /pet hold, taunt for pet-tanks).
-- Pet ATTACK is already handled in combat.lua (PetCombatOn/PetAssistAt); pet BUFFS in
-- petbuff.lua; pet PULL in pull.lua. Deferred (advanced): PetFocus item swap, Companion's
-- Suspension AA, PetToys. No MQ2Melee.
local mq    = require('mq')
local Write = require('muleassist.Write')
local cast  = require('muleassist.cast')
local pet   = {}

local GUARD_ROLES   = { puller=1, pullertank=1, pettank=1, pullerpettank=1 }
local PETTANK_ROLES = { pettank=1, pullerpettank=1 }

local function mqbool(v)
  local t = type(v)
  if t == 'boolean' then return v end
  if t == 'number'  then return v ~= 0 end
  if t == 'string'  then local u = v:upper(); return u == 'TRUE' or u == '1' end
  return false
end
local function role(st) return (st.combat.role or ''):lower() end

function pet.setup(st)
  Write.Info('pet.setup: on=%s spell=%s', tostring(st.pet.on), tostring(st.pet.spell))
end

-- Summon the configured pet when we have none (DoPetStuff @8397). Returns true if it cast.
local function summon(st)
  local p = st.pet
  if not p.on or not p.spell or p.spell == '' or p.spell == 'YourPetSpell' then return false end
  if mqbool(mq.TLO.Me.Pet.ID()) then return false end
  if os.clock() < (p.summon_until or 0) then return false end
  if mqbool(mq.TLO.Me.Casting.ID()) then return false end
  if not mqbool(mq.TLO.Me.Book(p.spell)()) then return false end       -- spell must be scribed

  -- reagent check (macro @8377): if the pet spell needs a focus reagent we lack, stop trying.
  local reagent = mq.TLO.Spell(p.spell).ReagentID(1)() or 0
  if reagent > 0 then
    local need = mq.TLO.Spell(p.spell).ReagentCount(1)() or 0
    if (mq.TLO.FindItemCount(reagent)() or 0) < need then
      Write.Warn('Pet spell %s needs a reagent you lack; disabling pet summon', p.spell)
      p.on = false
      return false
    end
  end

  if (mq.TLO.Spell(p.spell).Mana() or 0) > (mq.TLO.Me.CurrentMana() or 0) then return false end

  Write.Info('No pet -- summoning %s', p.spell)
  cast.cast(p.spell, 'DoPetStuff', mq.TLO.Me.ID())     -- cast.cast restores the misc gem
  p.summon_until = os.clock() + 60                      -- PetSummonTimer 60s throttle
  return true
end

-- Post-summon stance: guard/follow, hold, taunt (DoPetStuff @8506-8514).
local function manage_stance(st)
  local pid = mq.TLO.Me.Pet.ID() or 0
  if pid == 0 then return end
  local p = st.pet
  local r = role(st)

  if pid ~= p.last_pet_id then p.taunt_set = false; p.last_pet_id = pid end  -- new pet

  if GUARD_ROLES[r] and st.camp.x then
    local pd = mq.TLO.Me.Pet.Distance() or 0
    if pd <= (st.camp.radius or 60) then
      if mq.TLO.Me.Pet.Stance() ~= 'GUARD' then mq.cmd('/pet guard') end
    else
      mq.cmd('/pet follow')
    end
  end

  if p.hold_on and p.hold and p.hold ~= '' then
    -- /pet hold on (idempotent enough; only nudge when not already holding)
    if not mqbool(mq.TLO.Me.Pet.Hold()) then mq.cmdf('/pet %s on', p.hold) end
  end

  if PETTANK_ROLES[r] and not p.taunt_set then
    mq.cmd('/pet taunt on'); p.taunt_set = true
  end
end

function pet.tick(st)
  local p = st.pet
  if st.flags.buff_mode or st.flags.zombie_mode then return end
  if mqbool(mq.TLO.Me.Hovering()) or mqbool(mq.TLO.Me.Invis()) then return end
  if st.combat.aggro_target_id then return end                  -- don't summon mid-combat
  if st.pull and st.pull.state ~= 'idle' then return end

  -- dismiss an auto-summoned familiar so it doesn't block the real pet (macro @8395)
  local pn = mq.TLO.Me.Pet.CleanName()
  if pn and pn:lower() == ((mq.TLO.Me.Name() or '') .. "`s familiar"):lower() then
    mq.cmd('/pet get lost')
    return
  end

  summon(st)
  manage_stance(st)
end

return pet
