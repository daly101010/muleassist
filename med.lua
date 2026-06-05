-- muleassist/med.lua
-- Meditation: sit to recover mana/endurance when idle and out of combat. Ports Sub DoWeMed
-- @6151, but NON-BLOCKING -- the macro sits in a /delay loop; here each tick makes a sit/stand
-- decision and returns, so heals/combat keep reacting. Casting/attacking auto-stands you in EQ,
-- so med naturally fills the gaps between actions.
local mq    = require('mq')
local Write = require('muleassist.Write')
local med   = {}

-- Casters (incl. hybrids) meditate Mana; pure melee meditate Endurance (Sub DoWeMed @6160-6161).
local CASTER_MED = { BST=1,BRD=1,CLR=1,DRU=1,ENC=1,MAG=1,NEC=1,PAL=1,RNG=1,SHM=1,SHD=1,WIZ=1 }

local function mqbool(v)
  local t = type(v)
  if t == 'boolean' then return v end
  if t == 'number'  then return v ~= 0 end
  if t == 'string'  then local u = v:upper(); return u == 'TRUE' or u == '1' end
  return false
end

local function med_stat()
  return CASTER_MED[mq.TLO.Me.Class.ShortName() or ''] and 'Mana' or 'Endurance'
end
local function pct_of(stat)
  if stat == 'Mana' then return mq.TLO.Me.PctMana() or 100 end
  return mq.TLO.Me.PctEndurance() or 100
end

function med.tick(st)
  local m = st.med
  if not m.on then return end
  if mq.TLO.Me.Hovering() or mq.TLO.Me.Mount.ID() then return end
  -- In combat / threat present: stand up (so we're ready) and stop medding.
  if st.combat.aggro_target_id ~= nil or mq.TLO.Me.CombatState() == 'COMBAT' or mqbool(mq.TLO.Me.Combat()) then
    if m.medding and mqbool(mq.TLO.Me.Sitting()) then mq.cmd('/stand') end
    m.medding = false
    return
  end
  -- Busy or moving: don't sit (mid-cast, navigating, or sticking/returning to camp).
  if mq.TLO.Me.Moving() or mq.TLO.Me.Casting.ID() then return end
  if mq.TLO.Navigation.Active() or mqbool(mq.TLO.Stick.Active()) then return end

  local stat = med_stat()
  local pct  = pct_of(stat)
  if pct < m.start then
    if not mqbool(mq.TLO.Me.Sitting()) then
      mq.cmd('/sit on')
      Write.Info('Medding %s (%d%% < %d%%)', stat, pct, m.start)
    end
    m.medding = true
  elseif m.medding and pct >= 100 then
    -- Recovered to full -> stop and stand.
    m.medding = false
    if mqbool(mq.TLO.Me.Sitting()) then mq.cmd('/stand') end
  end
end

return med
