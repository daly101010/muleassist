-- muleassist/pull.lua
-- Phase 5b: pulling. Ports FindMobToPull @11653 / Pull @12354 / SetPullRange @11563 as a
-- NON-BLOCKING state machine (the macro spins in /delay loops; here each tick issues one
-- command and returns). Pull-with spell/AA/disc/melee/ranged. Chain/calm/pet/advpath/arc/
-- grab-dead deferred. No MQ2Melee.
local mq    = require('mq')
local Write = require('muleassist.Write')
local cast  = require('muleassist.cast')
local cond  = require('muleassist.cond')
local move  = require('muleassist.move')
local pull  = {}

local PULLER_ROLES = { puller=1, pullertank=1, hunter=1, pullerpettank=1, hunterpettank=1 }
local HUNTER_ROLES = { hunter=1, hunterpettank=1 }

local function mqbool(v)
  local t = type(v)
  if t == 'boolean' then return v end
  if t == 'number'  then return v ~= 0 end
  if t == 'string'  then local u = v:upper(); return u == 'TRUE' or u == '1' end
  return false
end
local function nav_loaded() return mqbool(mq.TLO.Navigation.MeshLoaded()) end
local function nav_active() return mqbool(mq.TLO.Navigation.Active()) end
local function is_puller(st) return PULLER_ROLES[(st.combat.role or ''):lower()] ~= nil end
local function is_hunter(st) return HUNTER_ROLES[(st.combat.role or ''):lower()] ~= nil end

----------------------------------------------------------------------
-- setup: resolve range/type from PullWith + parse level/mob lists (SetPullRange @11563).
----------------------------------------------------------------------
function pull.setup(st)
  local p = st.pull
  local w = p.with or 'Melee'
  if w == 'Melee' then
    p.range, p.range_type = 15, 'Melee'
  elseif w == 'Pet' then
    p.range, p.range_type = 185, 'Pet'           -- pet pull deferred (treated near-melee)
  elseif w:find('|') then
    local item = w:match('^(.-)|')
    local r = mq.TLO.FindItem('=' .. item).Range() or 50
    p.range, p.range_type, p.with = (r > 0 and r or 50) * 0.9, 'Ranged', item
  else
    local r = mq.TLO.Spell(w).Range() or 0
    if r == 0 then r = mq.TLO.FindItem('=' .. w).Spell.Range() or 0 end
    local divisor = is_hunter(st) and 2.75 or 1.11
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

  if p.mobs and p.mobs ~= '' and p.mobs:lower() ~= 'all' then
    p.mob_list = {}
    for n in (p.mobs .. ','):gmatch('([^,]*),') do
      n = n:gsub('^%s+', ''):gsub('%s+$', ''); if n ~= '' then p.mob_list[n:lower()] = true end
    end
  end
  Write.Info('pull.setup: with=%s range=%.0f(%s) lvl=%d-%d', tostring(p.with), p.range,
    p.range_type, p.pull_min, p.pull_max)
end

----------------------------------------------------------------------
-- find + validate (FindMobToPull @11653 / PullValidate @12092, core filters).
----------------------------------------------------------------------
local function validate(st, id)
  local p = st.pull
  local sp = mq.TLO.Spawn(id)
  if not sp.ID() or sp.Type() ~= 'NPC' then return false end
  if p.mob_list and not p.mob_list[(sp.CleanName() or ''):lower()] then return false end
  local camp_d = mq.TLO.Math.Distance(string.format('%f,%f:%f,%f',
    sp.Y() or 0, sp.X() or 0, st.camp.y or 0, st.camp.x or 0))() or 9999
  if camp_d > p.max_radius then return false end
  local lvl = sp.Level() or 0
  if lvl < p.pull_min or lvl > p.pull_max then return false end
  if (sp.PctHPs() or 100) <= 99 then return false end          -- already engaged
  if not nav_loaded() and not mqbool(sp.LineOfSight()) then return false end
  if mqbool(sp.Named()) and (st.combat.mob_count or 0) > 0 then return false end
  return true
end

function pull.find_mob(st)
  local p = st.pull
  local query
  if is_hunter(st) then
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
    if id and validate(st, id) then
      local sp = mq.TLO.Spawn(id)
      local score
      if p.namedsfirst and mqbool(sp.Named()) then
        score = -1
      elseif nav_loaded() then
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

----------------------------------------------------------------------
-- state machine: idle -> outbound (nav + execute) -> inbound (drag to camp) -> idle.
----------------------------------------------------------------------
function pull.reset(st)
  local p = st.pull
  p.state = 'idle'; p.target_id = nil; p.attempts = 0
  st.combat.pulled = nil
  if nav_active() then mq.cmd('/nav stop') end
  if mqbool(mq.TLO.MoveTo.Moving()) then mq.cmd('/moveto off') end
end

-- Execute the pull-with on the targeted, in-range mob. Sets state='inbound' when pulled.
local function execute(st, id)
  local p = st.pull
  if mq.TLO.Target.ID() ~= id then
    mq.cmdf('/target id %d', id)
    mq.delay(500, function() return mq.TLO.Target.ID() == id end)
  end
  mq.cmd('/face fast nolook')
  if p.range_type == 'Melee' then
    if not mqbool(mq.TLO.Me.Combat()) then mq.cmd('/attack on') end
    mq.cmdf('/stick %d id %d', 12, id)
    if (mq.TLO.Spawn(id).PctHPs() or 100) < 100 or st.combat.aggro_target_id then
      mq.cmd('/attack off'); mq.cmd('/stick off'); p.state = 'inbound'
    end
  elseif p.range_type == 'Ranged' then
    mq.cmd('/range')
    if st.combat.aggro_target_id then p.state = 'inbound' end
  else
    if cast.cast(p.with, 'Pull', id) == 'CAST_SUCCESS' or st.combat.aggro_target_id then
      p.state = 'inbound'
    end
  end
  p.attempts = (p.attempts or 0) + 1
  if p.state ~= 'inbound' and p.attempts > 7 then pull.reset(st) end   -- give up on this mob
end

local function outbound(st)
  local p = st.pull
  local id = p.target_id
  local sp = mq.TLO.Spawn(id)
  if not sp.ID() or sp.Type() == 'Corpse' or os.clock() > p.abort_deadline then pull.reset(st); return end
  if st.combat.aggro_target_id then
    p.state = 'inbound'; if nav_active() then mq.cmd('/nav stop') end; return
  end
  local dist = sp.Distance() or 9999
  if dist <= p.range and mqbool(sp.LineOfSight()) then
    if nav_active() then mq.cmd('/nav stop') end
    execute(st, id)
  elseif nav_loaded() then
    if not nav_active() then mq.cmdf('/nav spawn id %d | dist=%d', id, math.max(p.range - 3, 5)) end
  elseif not mqbool(mq.TLO.MoveTo.Moving()) then
    mq.cmdf('/moveto id %d mdist %d', id, math.floor(p.range))
  end
end

local function inbound(st)
  local p = st.pull
  local sp = mq.TLO.Spawn(p.target_id)
  if not sp.ID() or sp.Type() == 'Corpse' then pull.reset(st); return end
  st.combat.pulled = true
  if is_hunter(st) then pull.reset(st); return end       -- hunters fight in place
  if move.in_camp(st) then pull.reset(st); return end    -- arrived; combat takes over
  move.return_now(st)
end

function pull.tick(st)
  local p = st.pull
  if not is_puller(st) then return end
  if st.flags.buff_mode or st.flags.zombie_mode then return end
  if mq.TLO.Me.Hovering() then return end

  if p.state == 'outbound' then outbound(st); return end
  if p.state == 'inbound'  then inbound(st);  return end

  -- idle: don't start a pull while engaged or during a post-fail wait.
  if st.combat.aggro_target_id then return end
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
