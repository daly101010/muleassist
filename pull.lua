-- muleassist/pull.lua
-- Phase 5b: pulling. Ports FindMobToPull @11653 / Pull @12354 / SetPullRange @11563 as a
-- NON-BLOCKING state machine (the macro spins in /delay loops; here each tick issues one
-- command and returns). Pull-with spell/AA/disc/melee/ranged/pet. Includes chain-pull (+pause),
-- calm-adds, pet pull, AdvPath routes, pull-arc width, grab-dead corpses, secondary mob list.
-- No MQ2Melee.
local mq    = require('mq')
local Write = require('muleassist.Write')
local cast  = require('muleassist.cast')
local cond  = require('muleassist.cond')
local move  = require('muleassist.move')
local util  = require('muleassist.util')
local pull  = {}

-- Parse a comma list of mob names into a lookup set (nil/empty/"All" -> nil = no filter).
local function parse_list(s)
  if not s or s == '' or s:lower() == 'all' then return nil end
  local t = {}
  for n in (s .. ','):gmatch('([^,]*),') do
    n = n:gsub('^%s+', ''):gsub('%s+$', '')
    if n ~= '' then t[n:lower()] = true end
  end
  return next(t) and t or nil
end

----------------------------------------------------------------------
-- setup: resolve range/type from PullWith + parse level/mob lists (SetPullRange @11563).
----------------------------------------------------------------------
function pull.setup(st)
  local p = st.pull
  local w = p.with or 'Melee'
  if w == 'Melee' then
    p.range, p.range_type = 15, 'Melee'
  elseif w == 'Pet' then
    p.range, p.range_type = 185, 'Pet'           -- pet runs out to the mob (see execute Pet branch)
  elseif w:find('|') then
    local item = w:match('^(.-)|')
    local r = mq.TLO.FindItem('=' .. item).Range() or 50
    p.range, p.range_type, p.with = (r > 0 and r or 50) * 0.9, 'Ranged', item
  else
    local r = mq.TLO.Spell(w).Range() or 0
    if r == 0 then r = mq.TLO.FindItem('=' .. w).Spell.Range() or 0 end
    local divisor = util.is_hunter(st) and 2.75 or 1.11
    p.range, p.range_type = (r > 0 and r / divisor) or 50, 'Spell'
  end

  if (p.level_raw or ''):lower() == 'auto' then
    local lvl = mq.TLO.Me.Level() or 1
    p.pull_min, p.pull_max = math.max(lvl - 5, 1), lvl + 2
  else
    local a, b = (p.level_raw or '0|0'):match('^(%d+)|(%d+)$')
    p.pull_min = tonumber(a) or 0; p.pull_max = tonumber(b) or 0
    if p.pull_min == 0 then p.pull_min = 1 end
    if p.pull_max == 0 then p.pull_max = 200 end
  end

  p.mob_list     = parse_list(p.mobs)
  p.mob_list_sec = parse_list(p.mobs_sec)

  -- Pull arc (SetPullAngles @18108): centered on current heading, width PullArcWidth.
  if p.arc_width and p.arc_width > 0 and util.is_puller(st) then
    pull.set_arc(st, mq.TLO.Me.Heading.Degrees() or 0, p.arc_width)
  end

  -- AdvPath pull route: if a PullPath is loaded, use /play instead of /nav.
  p.path_wp_count = tonumber(mq.TLO.AdvPath.Waypoints()) or 0
  p.move_use = (p.path_wp_count > 0 and util.mqbool(mq.TLO.Plugin('MQ2AdvPath').IsLoaded())) and 'advpath' or 'nav'

  Write.Info('pull.setup: with=%s range=%.0f(%s) lvl=%d-%d chain=%d move=%s', tostring(p.with),
    p.range, p.range_type, p.pull_min, p.pull_max, p.chain or 0, p.move_use)
end

-- SetPullAngles @18108: arc bounds from a facing direction + width.
function pull.set_arc(st, fdir, awidth)
  local p = st.pull
  local half = awidth * 0.5
  p.arc_lside = (fdir - half < 0) and (360 - (half - fdir)) or (fdir - half)
  p.arc_rside = (fdir + half > 360) and (half + fdir - 360) or (fdir + half)
  Write.Info('Pull arc: facing %.0f, L %.0f, R %.0f, width %.0f', fdir, p.arc_lside, p.arc_rside, awidth)
end

-- FigureMobAngle @18138: is the mob's heading-to-camp within the pull arc?
local function in_arc(st, id)
  local p = st.pull
  if not p.arc_width or p.arc_width <= 0 then return true end
  local dir = mq.TLO.Spawn(id).HeadingTo.Degrees() or 0
  if p.arc_lside >= p.arc_rside then
    return not (dir < p.arc_lside and dir > p.arc_rside)
  else
    return not (dir < p.arc_lside or dir > p.arc_rside)
  end
end

----------------------------------------------------------------------
-- find + validate (FindMobToPull @11653 / PullValidate @12092, core filters).
----------------------------------------------------------------------
local function validate(st, id, allow_sec)
  local p = st.pull
  local sp = mq.TLO.Spawn(id)
  if not sp.ID() or sp.Type() ~= 'NPC' then return false end
  -- whitelist: primary list, or secondary list when this pass allows it (FindMobToPull retry)
  local nm = (sp.CleanName() or ''):lower()
  if allow_sec then
    if p.mob_list_sec and not p.mob_list_sec[nm] then return false end
  elseif p.mob_list and not p.mob_list[nm] then
    return false
  end
  local camp_d = mq.TLO.Math.Distance(string.format('%f,%f:%f,%f',
    sp.Y() or 0, sp.X() or 0, st.camp.y or 0, st.camp.x or 0))() or 9999
  if camp_d > p.max_radius then return false end
  local lvl = sp.Level() or 0
  if lvl < p.pull_min or lvl > p.pull_max then return false end
  if (sp.PctHPs() or 100) <= 99 then return false end          -- already engaged
  -- Pull arc (FigureMobAngle @12145): mob must lie within the configured facing arc.
  if not in_arc(st, id) then return false end
  -- Don't poach a mob another player is sitting on (PullValidate @12153): PC within 50.
  local pc_near = tonumber(mq.TLO.SpawnCount(string.format(
    'pc radius 50 loc %f %f', sp.X() or 0, sp.Y() or 0))()) or 0
  if (sp.Distance() or 9999) <= 50 then pc_near = pc_near - 1 end  -- discount myself
  if pc_near > 0 then return false end
  if not util.nav_loaded() and not util.mqbool(sp.LineOfSight()) then return false end
  if util.mqbool(sp.Named()) and (st.combat.mob_count or 0) > 0 then return false end
  return true
end

local function scan(st, allow_sec)
  local p = st.pull
  local query
  if util.is_hunter(st) then
    query = string.format('range %d %d npc radius %d zradius %d targetable',
      p.pull_min, p.pull_max, p.max_radius, p.max_z)
  else
    query = string.format('range %d %d npc loc %f %f radius %d zradius %d targetable',
      p.pull_min, p.pull_max, st.camp.x or 0, st.camp.y or 0, p.max_radius, p.max_z)
  end
  local n = tonumber(mq.TLO.SpawnCount(query)()) or 0
  local best, bestScore
  for i = 1, n do
    local id = mq.TLO.NearestSpawn(i .. ',' .. query).ID()
    if id and validate(st, id, allow_sec) then
      local sp = mq.TLO.Spawn(id)
      local score
      if p.namedsfirst and util.mqbool(sp.Named()) then
        score = -1
      elseif util.nav_loaded() then
        local pl = mq.TLO.Navigation.PathLength(string.format('locxyz %f %f %f',
          sp.X() or 0, sp.Y() or 0, sp.FloorZ() or 0))()
        score = (pl and pl > 0) and pl or (sp.Distance() or 99999)
      else
        score = sp.Distance() or 99999
      end
      if not bestScore or score < bestScore then best, bestScore = id, score end
    end
  end
  return best
end

-- FindMobToPull @11653: primary list first; only if it's dry, retry the secondary list.
function pull.find_mob(st)
  local best = scan(st, false)
  if best then return best end
  if st.pull.mob_list_sec then return scan(st, true) end
  return nil
end

----------------------------------------------------------------------
-- state machine: idle -> outbound (nav + execute) -> inbound (drag to camp) -> idle.
----------------------------------------------------------------------
function pull.reset(st)
  local p = st.pull
  p.state = 'idle'; p.target_id = nil; p.attempts = 0
  st.combat.pulled = nil
  if util.nav_active() then mq.cmd('/nav stop') end
  if util.mqbool(mq.TLO.MoveTo.Moving()) then mq.cmd('/moveto off') end
end

-- Calm adds before a spell pull (Pull @13076): if >1 mob clusters near the pull target,
-- mez/lull the 2nd-nearest with CalmWith, then re-target the pull mob.
local function try_calm(st, mobid)
  local p = st.pull
  if not p.use_calm or not p.calm_with or p.calm_with == '' then return end
  local sp = mq.TLO.Spawn(mobid)
  local q = string.format('npc loc %f %f radius %d', sp.X() or 0, sp.Y() or 0, p.calm_radius)
  if (tonumber(mq.TLO.SpawnCount(q)()) or 0) <= 1 then return end
  local calm_id = mq.TLO.NearestSpawn('2,' .. q).ID()
  if not calm_id or calm_id == mobid then return end
  if util.mqbool(mq.TLO.Spawn(calm_id).Mezzed()) then return end
  Write.Info('Calming add %s', mq.TLO.Spawn(calm_id).CleanName() or tostring(calm_id))
  cast.cast(p.calm_with, 'Pull', calm_id)
  mq.cmdf('/target id %d', mobid)
  mq.delay(300, function() return mq.TLO.Target.ID() == mobid end)
end

-- Execute the pull-with on the targeted, in-range mob. Sets state='inbound' when pulled.
local function execute(st, id)
  local p = st.pull
  if p.range_type ~= 'Pet' and mq.TLO.Target.ID() ~= id then
    mq.cmdf('/target id %d', id)
    mq.delay(500, function() return mq.TLO.Target.ID() == id end)
  end
  if p.range_type == 'Melee' then
    mq.cmd('/face fast nolook')
    if not util.mqbool(mq.TLO.Me.Combat()) then mq.cmd('/attack on') end
    mq.cmdf('/stick %d id %d', 12, id)
    if (mq.TLO.Spawn(id).PctHPs() or 100) < 100 or st.combat.aggro_target_id then
      mq.cmd('/attack off'); mq.cmd('/stick off'); p.state = 'inbound'
    end
  elseif p.range_type == 'Ranged' then
    mq.cmd('/face fast nolook')
    mq.cmd('/range')
    if st.combat.aggro_target_id then p.state = 'inbound' end
  elseif p.range_type == 'Pet' then
    -- Pet pull (Pull @12999): send the pet; it brings the mob back.
    if not mq.TLO.Pet.ID() then pull.reset(st); return end
    mq.cmdf('/pet attack %d', id)
    if (mq.TLO.Spawn(id).PctHPs() or 100) < 100 or util.mqbool(mq.TLO.Pet.Combat())
       or st.combat.aggro_target_id then
      mq.cmd('/pet hold on'); mq.cmd('/pet back off'); p.state = 'inbound'
    end
  else
    mq.cmd('/face fast nolook')
    try_calm(st, id)
    if cast.cast(p.with, 'Pull', id) == 'CAST_SUCCESS' or st.combat.aggro_target_id then
      p.state = 'inbound'
    end
  end
  p.attempts = (p.attempts or 0) + 1
  if p.state ~= 'inbound' and p.attempts > 7 then pull.reset(st) end   -- give up on this mob
end

-- GrabTheDead @12205: drag one nearby group corpse home while pulling. One at a time.
local function grab_dead(st)
  local p = st.pull
  if not p.grab_dead then return end
  if p.dragging ~= 0 then
    -- still escorting a corpse; clear once it's at camp (or gone)
    local d = mq.TLO.Spawn(p.dragging).Distance3D()
    if not mq.TLO.Spawn(p.dragging).ID() or (d and d < 10) then p.dragging = 0 end
    return
  end
  local corpse = mq.TLO.Spawn('group pccorpse')
  if not corpse.ID() then corpse = mq.TLO.Spawn(mq.TLO.Me.CleanName() .. ' pccorpse') end
  local cd = corpse.Distance3D()
  if corpse.ID() and cd and cd < 90 then
    local cid = corpse.ID()
    mq.cmdf('/target id %d', cid)
    mq.delay(1000, function() return mq.TLO.Target.ID() == cid end)
    mq.cmd('/corpsedrag')
    p.dragging = cid
  end
end

local function outbound(st)
  local p = st.pull
  local id = p.target_id
  local sp = mq.TLO.Spawn(id)
  if not sp.ID() or sp.Type() == 'Corpse' or os.clock() > p.abort_deadline then pull.reset(st); return end
  if st.combat.aggro_target_id then
    p.state = 'inbound'; if util.nav_active() then mq.cmd('/nav stop') end
    if util.mqbool(mq.TLO.AdvPath.Following()) then mq.cmd('/afollow off') end
    return
  end
  local dist = sp.Distance() or 9999
  local in_range = dist <= p.range and util.mqbool(sp.LineOfSight())
  -- Pet pull stays put and lets the pet run out (no self-movement).
  if p.range_type == 'Pet' then
    if in_range then execute(st, id) end
    return
  end
  if in_range then
    if util.nav_active() then mq.cmd('/nav stop') end
    if util.mqbool(mq.TLO.AdvPath.Following()) then mq.cmd('/afollow off') end
    execute(st, id)
  elseif p.move_use == 'advpath' then
    -- AdvPath route out to the mob (PullPath; @5684 DoWeMove route playback).
    if not util.mqbool(mq.TLO.AdvPath.Following()) then mq.cmd('/play PullPath nodoor smart normal') end
  elseif util.nav_loaded() then
    if not util.nav_active() then mq.cmdf('/nav spawn id %d | dist=%d', id, math.max(p.range - 3, 5)) end
  elseif not util.mqbool(mq.TLO.MoveTo.Moving()) then
    mq.cmdf('/moveto id %d mdist %d', id, math.floor(p.range))
  end
end

local function inbound(st)
  local p = st.pull
  local sp = mq.TLO.Spawn(p.target_id)
  if not sp.ID() or sp.Type() == 'Corpse' then pull.reset(st); return end
  st.combat.pulled = true
  grab_dead(st)                                          -- haul a fallen group corpse home too
  if util.is_hunter(st) then pull.reset(st); return end       -- hunters fight in place
  if move.in_camp(st) then pull.reset(st); return end    -- arrived; combat takes over
  if p.move_use == 'advpath' then
    if not util.mqbool(mq.TLO.AdvPath.Following()) then mq.cmd('/play PullPath reverse nodoor smart') end
    return
  end
  move.return_now(st)
end

-- Chain-pull pause cycle (DoMiscStuff @11206): pull for Arg1 minutes, hold for Arg2 minutes.
-- Returns false while paused (ChainPullHold). Only active when ChainPull && ChainPullPause!=0.
local function chain_ready(st)
  local p = st.pull
  if (p.chain or 0) == 0 then return true end
  local a, b = (p.chain_pause or '0'):match('^(%d+)|(%d+)$')
  local active = (tonumber(a) or 0) * 60
  local pause  = (tonumber(b) or 0) * 60
  if active <= 0 or pause <= 0 then return true end
  local now = os.clock()
  if p.chain_hold then
    if now >= p.chain_pause_until then
      p.chain_hold = false; p.chain_active_until = now + active
      Write.Info('Chain-pull resuming (%s min)', a)
    else
      return false
    end
  else
    if p.chain_active_until == 0 then p.chain_active_until = now + active end
    if now >= p.chain_active_until then
      p.chain_hold = true; p.chain_pause_until = now + pause
      Write.Info('Chain-pull pausing for %s min', b)
      return false
    end
  end
  return true
end

function pull.tick(st)
  local p = st.pull
  if not util.is_puller(st) then return end
  if st.flags.buff_mode or st.flags.zombie_mode then return end
  if mq.TLO.Me.Hovering() then return end

  if p.state == 'outbound' then outbound(st); return end
  if p.state == 'inbound'  then inbound(st);  return end

  -- idle: gating before starting a fresh pull.
  if not chain_ready(st) then return end               -- chain-pause hold
  if st.combat.aggro_target_id then
    -- Without chain, never pull while engaged (macro @11691: AggroTargetID && !ChainPull).
    if (p.chain or 0) == 0 then return end
    -- Chain: don't over-pull (@11700) and only pull the next when the current mob is low (@11713).
    if (st.combat.mob_count or 0) > 1 then return end
    if util.mqbool(mq.TLO.Me.XTarget(2).ID()) then return end
    local cur = st.combat.my_target_id or st.combat.aggro_target_id
    if (mq.TLO.Spawn(cur).PctHPs() or 100) >= (p.chain_hp or 90) then return end
  end
  if os.clock() < (p.wait_until or 0) then return end
  if p.cond and p.cond ~= '' and not cond.eval(p.cond) then return end
  local mob = pull.find_mob(st)
  if not mob then p.wait_until = os.clock() + (p.wait or 5); return end
  p.target_id = mob
  p.state = 'outbound'
  p.attempts = 0
  p.abort_deadline = os.clock() + 30
  mq.cmdf('/target id %d', mob)
  Write.Info('Pulling %s', mq.TLO.Spawn(mob).CleanName() or tostring(mob))
end

return pull
