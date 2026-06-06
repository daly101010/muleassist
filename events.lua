-- muleassist/events.lua
-- Phase 7b-1: cast-outcome events. Ports Event_CastFailed/CastInterrupted/CastResist/
-- CastMezImmune/CastDistr (@17369-17398) + their #Event patterns (@199-207). These write
-- cast.last_result, which cast.wait_cast returns -- unlocking mez immune learning and the
-- charm fail-count -> CharmRecover path that were stubbed in Phases 6.
--
-- Deferred (later 7b): MezBroke, GotHit/MoveWhenHit, TankTarget, Charmed/CannotCharm, Chat,
-- WornOff, Zoned, and the KissTools (KT*) command events.
local mq    = require('mq')
local Write = require('muleassist.Write')
local cast  = require('muleassist.cast')
local events = {}

function events.register(st)
  -- Fizzles -> CAST_FIZZLED (macro @199-200, Event_CastFailed)
  mq.event('ma_cast_fizzle1', 'Your #1# spell fizzles!', function() cast.last_result = 'CAST_FIZZLED' end)
  mq.event('ma_cast_fizzle2', 'Your spell fizzles!',     function() cast.last_result = 'CAST_FIZZLED' end)

  -- Interrupt -> CAST_INTERRUPTED (macro @201, Event_CastInterrupted)
  mq.event('ma_cast_interrupt', 'Your #1# spell is interrupted.',
    function() cast.last_result = 'CAST_INTERRUPTED' end)

  -- Resist -> CAST_RESIST (macro @202, Event_CastResist). Pattern "#2#resisted your #1#!"
  -- maps param1=spell, param2=resister-name; we only need the result class here.
  mq.event('ma_cast_resist', '#2#resisted your #1#!',
    function(_line, _spell, _rname) cast.last_result = 'CAST_RESIST' end)

  -- Distracted / can't-cast-on-pet -> treat as success to avoid re-cast loops (macro @203-204)
  mq.event('ma_cast_distr1', 'You are too distracted to cast a spell now!',
    function() cast.last_result = 'CAST_SUCCESS' end)
  mq.event('ma_cast_distr2', 'You cannot cast this spell on your pet',
    function() cast.last_result = 'CAST_SUCCESS' end)

  -- Mez immune -> CAST_IMMUNE + remember the mob so mez/charm stop retrying (macro @207/17383)
  mq.event('ma_cast_mezimmune', 'Your target cannot be mesmerized.', function()
    cast.last_result = 'CAST_IMMUNE'
    local tid = mq.TLO.Target.ID() or 0
    if tid > 0 and st.mez and st.mez.immune_ids then
      st.mez.immune_ids[tid] = true
      Write.Info('Mez immune: %s', mq.TLO.Target.CleanName() or tostring(tid))
    end
  end)

  Write.Info('events: cast-outcome handlers registered')
end

return events
