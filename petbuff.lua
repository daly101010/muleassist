-- muleassist/petbuff.lua
-- Phase 3b: pet buff maintenance. Ports Sub CheckPetBuffs @8546. Casts via cast.cast.
-- Guards read st.combat.* defensively (nil => no aggro). 60s throttle (PetBuffCheck).
local mq    = require('mq')
local Write = require('muleassist.Write')
local cast  = require('muleassist.cast')
local petbuff = {}

local function strip_rk(n) return (n:gsub('%s*Rk%.%s*I+%s*$', '')) end

-- Pet has a buff whose name contains `name` (rk-stripped) in slots 1..50.
local function pet_has(name)
  for j = 1, 50 do
    local bn = mq.TLO.Me.PetBuff(j).Name()
    if bn and bn:find(name, 1, true) then return true end
  end
  return false
end

function petbuff.setup(st)
  st.pet.entries = st.lists.petbuffs
  Write.Info('petbuff.setup: %d pet buff entries', #st.pet.entries)
end

function petbuff.tick(st)
  if not mq.TLO.Me.Pet.ID() then return end
  if not st.pet.buffs_on then return end
  if st.combat.aggro_target_id ~= nil or mq.TLO.Me.CombatState() == 'COMBAT' then return end
  if st.combat.chasing and not st.buff.while_chasing then return end
  if mq.TLO.Me.Invis() then return end
  if os.clock() < (st.pet.check_deadline or 0) then return end
  st.pet.check_deadline = os.clock() + (st.pet.check_secs or 60)

  for _, e in ipairs(st.pet.entries) do
    if st.combat.aggro_target_id ~= nil or mq.TLO.Me.CombatState() == 'COMBAT' then return end
    local name = e.args[1] or e.spell or ''
    if name ~= '' and name:lower() ~= 'null' then
      local pet_id = mq.TLO.Me.Pet.ID()
      if mq.TLO.Me.Book(name)() or mq.TLO.Me.AltAbilityReady(name)() then
        if not pet_has(strip_rk(name)) then
          if cast.cast(name, 'Pet-nomem', pet_id) == 'CAST_SUCCESS' then
            Write.Info('Buffing pet with %s', name)
          end
        end
      elseif e.args[2] == 'Dual' and mq.TLO.FindItem('=' .. name).ID() then
        -- Dual item: item name differs from the buff effect name (args[3]).
        if not pet_has(e.args[3] or name) then
          if cast.cast(name, 'Pet', pet_id) == 'CAST_SUCCESS' then
            Write.Info('Buffing pet with %s (%s)', name, e.args[3] or '')
          end
        end
      elseif mq.TLO.FindItem('=' .. name).ID() then
        -- Same-name item clicky.
        local eff = mq.TLO.FindItem('=' .. name).Spell()
        if not eff or (mq.TLO.Me.PetBuff(eff)() or 0) < 1 then
          cast.cast(name, 'Pet', pet_id)
        end
      end
    end
  end

  -- Pet shrink when oversized.
  if (mq.TLO.Me.Pet.Height() or 0) > 1.35 and st.pet.shrink_on
     and st.pet.shrink_spell and st.pet.shrink_spell ~= '' then
    cast.cast(st.pet.shrink_spell, 'Pet', mq.TLO.Me.Pet.ID())
  end
  if mq.TLO.Target.ID() == mq.TLO.Me.Pet.ID() then mq.cmd('/target clear') end
end

return petbuff
