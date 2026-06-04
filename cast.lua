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
    mq.delay(500, function() return mq.TLO.Me.Casting.ID() end)
  end

  return cast.wait_cast(sent_from, spell(what).MyCastTime() or 0, what)
end

-- Sub WaitCast @4485 (core): block until the active cast resolves; handle bard songs,
-- gem-stuck recovery (20s -> GemStuckAbility), and stick/nav pause restore.
-- Returns a CastResult string ('CAST_SUCCESS' by default once casting completes).
-- NOTE: the SingleHeal/DPS/BUFFS interrupt branches and the CastResult #events that
-- refine this result are added in Phases 2/4/7.
function cast.wait_cast(sent_from, cast_time, wspell)
  cast_time = cast_time or 0
  Write.Debug('WaitCast Enter SF:%s Ct:%d Sp:%s', tostring(sent_from), cast_time, tostring(wspell))

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

  mq.doevents()
  Write.Debug('WaitCast Leaving: CAST_SUCCESS')
  return 'CAST_SUCCESS'
end

return cast
