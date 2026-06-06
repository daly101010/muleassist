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
local util  = require('muleassist.util')
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

  ----------------------------------------------------------------------
  -- 7b-2: CC / charm lifecycle events.
  ----------------------------------------------------------------------
  local function lc(s) return (s or ''):lower() end

  -- MezBroke @11046: a mob woke up. Re-mez it (clear its timer) unless the MA broke it.
  mq.event('ma_mezbroke', '#1# has been awakened by #2#.', function(_line, mezmob, breaker)
    if (st.mez.on or 0) == 0 then return end
    if st.main_assist and lc(breaker) == lc(st.main_assist) then return end  -- MA broke it on purpose
    for _, e in ipairs(st.mez.array) do
      if lc(e.name) == lc(mezmob) then
        e.timer = 0
        Write.Info('Mez broke on %s (by %s) - will re-mez', tostring(mezmob), tostring(breaker))
      end
    end
  end)

  -- WornOff @14972: our mez spell faded off a tracked mob -> re-mez it next tick.
  mq.event('ma_wornoff', 'Your #1# spell has worn off of #2#.', function(_line, spell, who)
    if st.mez.spell and lc(spell) == lc(st.mez.spell) then
      for _, e in ipairs(st.mez.array) do
        if lc(e.name) == lc(who) then e.timer = 0 end
      end
    end
  end)

  -- Charmed @19048: a charm landed -> adopt the new pet as our charm target.
  mq.event('ma_charmed', '#1# has been charmed.', function()
    if not util.CHARM_CLASSES[(mq.TLO.Me.Class.ShortName() or ''):upper()] then return end
    local pid = mq.TLO.Me.Pet.ID() or 0
    if pid > 0 then
      st.charm.pet_id, st.charm.fail_count = pid, 0
      Write.Info('Charm pet acquired: %s', mq.TLO.Me.Pet.CleanName() or tostring(pid))
    end
  end)

  -- CannotCharm @19252: this NPC is uncharmable -> drop the charm target.
  mq.event('ma_cannotcharm', 'This NPC cannot be charmed.', function()
    Write.Info('%s cannot be charmed - clearing charm target', mq.TLO.Target.CleanName() or '?')
    st.charm.pet_id = 0
  end)

  -- ConCheck @19303: rare-spawn alert.
  mq.event('ma_concheck', '#1# -#*#a rare creature#*#', function(_line, mob)
    Write.Warn('Rare creature spotted: %s', tostring(mob))
  end)

  Write.Info('events: cast-outcome + CC/charm handlers registered')
end

return events
