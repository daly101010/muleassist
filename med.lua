-- muleassist/med.lua
-- Meditation: sit to recover mana/endurance. Ports Sub DoWeMed @6151 NON-BLOCKING -- the macro
-- sits in a /delay loop; here each tick makes a sit/stand decision and returns so heals/combat
-- keep reacting. Casting/attacking auto-stands you in EQ, so med fills the gaps between actions.
--   * Hybrids (PAL/RNG/SHD/BST/BRD) med BOTH mana and endurance.
--   * SitToMed: also sit between casts DURING combat, but only for non-melee characters
--     (healers/pure casters) and only when no mob is on them -- never while in melee.
local mq    = require('mq')
local Write = require('muleassist.Write')
local util  = require('muleassist.util')
local med   = {}

local function pct_of(stat)
  if stat == 'Mana' then return mq.TLO.Me.PctMana() or 100 end
  return mq.TLO.Me.PctEndurance() or 100
end

-- The med stat(s) for this class: primary (+ secondary for hybrids).
local function med_stats()
  local short = mq.TLO.Me.Class.ShortName() or ''
  if util.CASTER_MED[short] then
    return 'Mana', util.HYBRID[short] and 'Endurance' or nil
  end
  return 'Endurance', nil
end

function med.tick(st)
  local m = st.med
  if not m.on then return end
  if mq.TLO.Me.Hovering() or mq.TLO.Me.Mount.ID() then return end

  local self_aggro = st.combat.aggro_target_id ~= nil
  local in_combat  = self_aggro or mq.TLO.Me.CombatState() == 'COMBAT' or util.mqbool(mq.TLO.Me.Combat())
  if in_combat then
    -- Only non-melee characters (healers/pure casters) sit-to-med in combat, and never while
    -- auto-attacking or with a mob on them.
    local caster_safe = m.sit_to_med and not st.combat.melee_on
                        and not util.mqbool(mq.TLO.Me.Combat()) and not self_aggro
    if not caster_safe then
      if m.medding and util.mqbool(mq.TLO.Me.Sitting()) then mq.cmd('/stand') end
      m.medding = false
      return
    end
  end

  -- Busy or moving: don't sit (mid-cast, navigating, or sticking/returning to camp).
  if mq.TLO.Me.Moving() or mq.TLO.Me.Casting.ID() then return end
  if mq.TLO.Navigation.Active() or util.mqbool(mq.TLO.Stick.Active()) then return end

  local primary, secondary = med_stats()
  local need = pct_of(primary) < m.start or (secondary and pct_of(secondary) < m.start)
  local full = pct_of(primary) >= 100 and (not secondary or pct_of(secondary) >= 100)

  if need then
    if not util.mqbool(mq.TLO.Me.Sitting()) then
      mq.cmd('/sit on')
      Write.Info('Medding (%s %d%%%s)', primary, pct_of(primary),
        secondary and (', '..secondary..' '..tostring(pct_of(secondary))..'%') or '')
    end
    m.medding = true
  elseif m.medding and full then
    m.medding = false
    if util.mqbool(mq.TLO.Me.Sitting()) then mq.cmd('/stand') end
  end
end

return med
