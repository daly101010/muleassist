-- muleassist/cast.lua
-- Casting engine: mem/target/cast a spell|disc|aa|item|ability and wait for it to resolve.
-- Faithful port of Sub Cast @5275, Sub WaitCast @4485, Sub IsDisc @4646, Sub WillItStick @5319.
-- Interrupt policy (KACheckHP/DPS/BUFFS) and DPS weaving are deferred to Phases 2/4;
-- this is the CORE engine sufficient for the self-buff milestone.
local mq    = require('mq')
local Write = require('muleassist.Write')
local cast  = {}

-- AA used to unstick frozen spell gems (General/GemStuckAbility in the INI).
-- init.lua sets this from config; nil/'' disables the recovery path.
cast.gem_stuck_ability = nil

-- Spell-memorization scratch gem (General/MiscGem*, INI defaults 8/0/1). init.lua sets
-- these from config and captures the live gem occupants once at startup. Runtime swap
-- bookkeeping mirrors the macro's ReMem* outer vars.
cast.misc_gem        = 8      -- General/MiscGem     : scratch slot for short-recast spells
cast.misc_gem_lw     = 0      -- General/MiscGemLW   : scratch slot for >30s-recast spells (0=off)
cast.misc_gem_remem  = 1      -- General/MiscGemRemem: re-mem original occupant after cast
cast.remem_misc_gem    = nil  -- name originally in misc_gem    (captured at init)
cast.remem_misc_gem_lw = nil  -- name originally in misc_gem_lw (captured at init)
cast.remem_wait_short  = 'null'
cast.remem_wait_long   = 'null'
cast.remem_cast        = 0
cast.remem_cast_lw     = 0

local function spell(name) return mq.TLO.Spell(name) end

-- Sub IsDisc @4646: a skill-based, lasting ability that doesn't stack with discs
-- (i.e. one that occupies the Combat Ability window).
function cast.is_disc(name)
  local sp = spell(name)
  return (sp.IsSkill() and (sp.Duration() or 0) > 0 and not sp.StacksWithDiscs()) and true or false
end

-- Sub WillItStick @5319: beneficial-spell landability by spell level vs target level.
-- Bands kept verbatim from the source; returns true (GoodStick) / false (BadStick).
local STICK_BANDS = {
  -- {spell_level_min, spell_level_max, min_target_level}
  { 51,  51,  40 },
  { 52,  53,  41 },
  { 54,  55,  42 },
  { 56,  57,  43 },
  { 58,  59,  44 },
  { 60,  61,  45 },
  { 62,  63,  46 },
  { 64,  65,  47 },
  { 66,  95,  61 },
  { 96,  100, 66 },
  { 101, 105, 71 },
  { 106, 110, 76 },
  { 111, 115, 81 },
}

function cast.will_it_stick(what, target_id)
  local slvl = spell(what).Level() or 0
  if slvl <= 50 then return true end
  local tlvl = mq.TLO.Spawn('id ' .. tostring(target_id)).Level() or 0
  for _, b in ipairs(STICK_BANDS) do
    if slvl >= b[1] and slvl <= b[2] then
      if tlvl < b[3] then
        Write.Debug('WillItStick: target lvl %d < %d needed for %s', tlvl, b[3], what)
        return false
      end
      break
    end
  end
  return true
end

-- Sub MemSpell @17866: ensure spellbook spell `pgem` occupies gem slot `i`, clearing the
-- current occupant first. force_it ~= 0 forces a re-mem even if `pgem` is already in some
-- gem (force_it carries the slot index it currently sits in). sent_from suppresses the
-- mid-mem hostile bail when it contains 'Heal'.
-- Bounded waits mirror the macro's decisecond timers: ~2s to clear a slot, ~30s to mem.
function cast.mem_spell(pgem, i, force_it, sent_from)
  force_it  = force_it or 0
  sent_from = sent_from or ''
  if not pgem or pgem == '' or pgem == 'null' or i == 0 then return end
  if (mq.TLO.Me.Gem(pgem)() or 0) > 0 and force_it == 0 then return end

  -- GetHostilesOnXTarget bail (macro @17880/17897/17910). Inert until Phase 4 combat.
  local function hostiles() return false end

  if force_it ~= 0 and (mq.TLO.Me.Gem(pgem)() or 0) > 0 and i ~= force_it then
    mq.cmdf('/notify CastSpellWnd CSPW_Spell%d rightmouseup', force_it - 1)
    local t = os.clock() + 2
    while os.clock() < t do
      if (mq.TLO.Me.Gem(i).ID() or 0) == 0 then break end
      if hostiles() then return end
      mq.delay(1)
    end
  end

  if mq.TLO.Me.Book(pgem)() then
    -- Clear the target slot if occupied.
    if (mq.TLO.Me.Gem(i).ID() or 0) > 0 then
      mq.cmdf('/notify CastSpellWnd CSPW_Spell%d rightmouseup', i - 1)
      local t = os.clock() + 2
      while os.clock() < t do
        if (mq.TLO.Me.Gem(i).ID() or 0) == 0 then break end
        if hostiles() and not sent_from:find('Heal') then return end
        mq.delay(1)
      end
    end
    -- Mem if not already the right spell in this slot.
    local cur = mq.TLO.Me.Gem(i).Name()
    if not cur or cur ~= pgem then
      Write.Debug('MemSpell: memming %s into gem %d', pgem, i)
      mq.cmdf('/memspell %d "%s"', i, pgem)
      local t = os.clock() + 30
      while os.clock() < t do
        if mq.TLO.Me.Gem(i).Name() == pgem then break end
        if hostiles() and not sent_from:find('Heal') then return end
        mq.delay(1)
      end
    end
  else
    Write.Warn('Could not find the spell %s in your spell book.', tostring(pgem))
  end

  if mq.TLO.Me.CombatState() == 'COMBAT' then mq.delay(300) end
  if mq.TLO.Window('SpellBookWnd').Open() then mq.cmd('/windowstate spellbookwnd close') end
end

-- Sub Cast @5275: rank-downgrade, conditional target, gem-ready wait, cast-retry loop.
function cast.cast(what, sent_from, target_id)
  Write.Debug('Cast: %s (%s)', what, tostring(sent_from))

  -- Rank downgrade when SpellRankCap is low (lines 5278-5284).
  if what:find('Rk%.') and (mq.TLO.Me.SpellRankCap() or 3) < 3 then
    local cap = mq.TLO.Me.SpellRankCap() or 3
    if what:find('Rk%. II') and cap < 2 then
      what = what:sub(1, (what:find('Rk%.')) - 2)
    elseif what:find('Rk%. III') and cap == 2 then
      what = what:sub(1, (what:find('Rk%.')) - 2) .. ' Rk. II'
    end
  end

  -- Conditional targeting (lines 5285-5300).
  local tt = spell(what).TargetType()
  if target_id and mq.TLO.Target.ID() ~= target_id and tt ~= 'Self'
     and mq.TLO.Spawn('id ' .. tostring(target_id)).ID() then
    local self_group = (target_id == mq.TLO.Me.ID()) and spell(what).HasSPA(0)()
                       and (tt or ''):lower():find('group')
    if not self_group then
      mq.cmdf('/target id %d', target_id)
      mq.delay(1000, function() return mq.TLO.Target.ID() == target_id end)
    end
  end

  -- Spell memorization swap (CastWhat @5092-5137). Only real spellbook spells can be
  -- memmed; AAs/items/skills fall through untouched (Sub Cast then /casts them as-is).
  if mq.TLO.Me.Book(what)() and not mq.TLO.Me.Gem(what)() then
    -- Combat guard (@5097, simplified to CombatState until Phase 4): don't mem mid-combat
    -- unless this is a heal.
    if mq.TLO.Me.CombatState() == 'COMBAT' and not tostring(sent_from):find('Heal') then
      Write.Debug('Cast: %s not memmed and in combat; skipping mem (Midcombat)', what)
      return 'Midcombat'
    end
    if mq.TLO.Cursor.ID() then mq.cmd('/autoinventory') end

    local recast = spell(what).RecastTime.TotalSeconds() or 0
    if cast.misc_gem_remem ~= 0 and cast.misc_gem_lw > 0 and recast > 30
       and cast.remem_wait_long == 'null' then
      -- Long-recast spell -> dedicated LW scratch gem; mem and return (re-mem next pass).
      cast.remem_wait_long = what
      cast.mem_spell(what, cast.misc_gem_lw, 0, sent_from)
      return 'CAST_NO_RESULT'
    end

    -- Short-recast path: mem into MiscGem, then wait for the gem to become CASTABLE before
    -- falling through. A freshly-memmed gem carries a refresh timer, so SpellReady is false
    -- for a few seconds; without this wait the cast loop fires into a not-ready gem, nothing
    -- casts, and wait_cast still reports CAST_SUCCESS (CastWhat gemdelay @5124-5134).
    cast.remem_wait_short = what
    cast.mem_spell(what, cast.misc_gem, 0, sent_from)
    mq.delay(15000, function() return mq.TLO.Me.SpellReady(what)() end)
  end

  -- Gem-ready wait (lines 5301-5302).
  mq.delay(2000, function() return mq.TLO.Me.SpellReady(what)() end)
  if not mq.TLO.Me.SpellReady(what)() and mq.TLO.Me.CombatState() == 'COMBAT' then return end

  -- Cast retry loop (lines 5303-5312): re-issue if the gem is up but we didn't start casting.
  repeat
    Write.Debug('Casting %s', what)
    mq.cmdf('/cast "%s"', what)
    mq.delay(200)
    local stuck = (mq.TLO.Me.Casting.ID() ~= spell(what).ID())
                  and (not mq.TLO.Me.SpellReady(what)())
                  and (mq.TLO.Me.Gem(what)())
                  and (mq.TLO.Target.Type() ~= 'Corpse')
                  and ((spell(what).MyCastTime() or 0) > 250)
  until not stuck

  if (spell(what).MyCastTime() or 0) ~= 0 then
    mq.delay(500, function() return mq.TLO.Me.Casting.ID() ~= nil end)
  end

  local result = cast.wait_cast(sent_from, spell(what).MyCastTime() or 0, what)

  -- Re-mem the spell originally in the scratch gem (CastWhat @5208-5241). Gated on
  -- MiscGemRemem; only out of combat, no Resurrection Sickness, and not a '-nomem' call.
  if cast.misc_gem_remem ~= 0 then
    local sf = tostring(sent_from)
    if result == 'CAST_SUCCESS' then
      if what == cast.remem_wait_short then cast.remem_cast = 1
      elseif what == cast.remem_wait_long then cast.remem_cast_lw = 1 end
    end
    local sick   = mq.TLO.Me.Buff('Resurrection Sickness').ID() ~= nil
    local combat = mq.TLO.Me.CombatState() == 'COMBAT'
    local nomem  = sf:find('%-nomem') ~= nil

    if (cast.misc_gem_remem == 1 or cast.misc_gem_remem == 2)
       and cast.remem_misc_gem and not mq.TLO.Me.Gem(cast.remem_misc_gem)()
       and cast.remem_cast == 1 and not combat and not sick and not nomem then
      if not sf:find('Heal') then
        cast.mem_spell(cast.remem_misc_gem, cast.misc_gem, 0)
      end
      cast.remem_cast = 0
      cast.remem_wait_short = 'null'
    end

    if (cast.misc_gem_remem == 1 or cast.misc_gem_remem == 3)
       and cast.misc_gem_lw > 0 and cast.remem_wait_long ~= 'null' and not nomem then
      if cast.remem_cast_lw == 1 and not sick then
        if cast.remem_misc_gem_lw then
          cast.mem_spell(cast.remem_misc_gem_lw, cast.misc_gem_lw,
                         mq.TLO.Me.Gem(cast.remem_misc_gem_lw)() or 0)
        end
        cast.remem_cast_lw = 0
        cast.remem_wait_long = 'null'
      end
    end
  end

  return result
end

-- Sub WaitCast @4485 (core): block until the active cast resolves; handle bard songs,
-- gem-stuck recovery (20s -> GemStuckAbility), and stick/nav pause restore.
-- Returns a CastResult string ('CAST_SUCCESS' by default once casting completes).
-- NOTE: the SingleHeal/DPS/BUFFS interrupt branches and the CastResult #events that
-- refine this result are added in Phases 2/4/7.
function cast.wait_cast(sent_from, cast_time, wspell)
  cast_time = cast_time or 0
  Write.Debug('WaitCast Enter SF:%s Ct:%d Sp:%s', tostring(sent_from), cast_time, tostring(wspell))
  -- Cast-outcome events (events.lua) write cast.last_result during the cast; clear it first.
  cast.last_result = nil

  -- cTimer: cast_time + 20 (game uses tenths-of-second timers; ms here for mq.delay).
  local deadline = os.clock() + (cast_time + 2000) / 1000
  local gem_stuck_deadline = os.clock() + 20  -- GemStuckTimer 20s

  local function casting()
    local id = mq.TLO.Me.Casting.ID()
    return id ~= nil and id > 0
  end

  -- Wait for the cast to actually register (lines 4522-4526).
  if cast_time ~= 0 then
    mq.delay(60, casting)
  end

  -- :rewaitcast / :waitcasttime loop — spin while we are still casting.
  while casting() do
    if mq.TLO.Me.Hovering() then return 'CAST_INTERRUPTED' end
    if mq.TLO.Me.BardSongPlaying() then
      if not mq.TLO.Window('CastingWindow').Open() then
        Write.Debug('WaitCast: bard, not actually casting; returning')
        return 'CAST_SUCCESS'
      end
      break  -- bard songs resolve on their own; don't block
    end

    mq.delay(1)

    -- Gem-stuck recovery: still "casting" past the 20s window -> try GemStuckAbility.
    if os.clock() >= gem_stuck_deadline then
      Write.Warn('WaitCast: gems appear stuck')
      mq.delay(1000)
      local ability = cast.gem_stuck_ability
      if ability and ability ~= '' and ability ~= 'NULL' then
        if mq.TLO.Me.AltAbilityReady(ability)() then
          mq.cmdf('/alt act %d', mq.TLO.Me.AltAbility(ability).ID())
          mq.delay(5000, function() return not mq.TLO.Me.SpellInCooldown() end)
          mq.cmd('/stopcast')
        else
          gem_stuck_deadline = os.clock() + 2
        end
      else
        Write.Warn('GemStuckAbility is unset, cannot unstick gems')
        gem_stuck_deadline = os.clock() + 2
      end
    end

    -- Safety: bail if we somehow exceed the cast deadline without resolving.
    if os.clock() > deadline + 30 then
      Write.Warn('WaitCast: exceeded deadline, bailing')
      break
    end
  end

  -- Restore movement that was paused for the cast (lines 4571-4575).
  if mq.TLO.Stick.Status() == 'pause' then
    mq.cmd('/afollow off')
    mq.cmd('/stick unpause')
  end
  if mq.TLO.AdvPath.Paused() and not mq.TLO.Stick.Active() then
    mq.cmd('/afollow unpause')
  end

  mq.doevents()   -- flush cast-outcome events (fizzle/resist/immune/interrupt)
  local result = cast.last_result or 'CAST_SUCCESS'
  Write.Debug('WaitCast Leaving: %s', result)
  return result
end

return cast
