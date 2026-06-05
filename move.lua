-- muleassist/move.lua
-- Movement: set/return-to-camp + chase the MainAssist. Ports Sub DoWeMove @5523 NON-BLOCKING:
-- the macro spins in /delay loops; here each tick issues a single nav/stick command and returns
-- so heals/combat/med keep reacting. Nav primary (MQ2Nav), /moveto + /stick fallbacks. No MQ2Melee.
local mq    = require('mq')
local Write = require('muleassist.Write')
local move  = {}

local PULLER_ROLES = { puller=1, pullertank=1, hunter=1, pullerpettank=1, hunterpettank=1 }

local function mqbool(v)
  local t = type(v)
  if t == 'boolean' then return v end
  if t == 'number'  then return v ~= 0 end
  if t == 'string'  then local u = v:upper(); return u == 'TRUE' or u == '1' end
  return false
end

local function nav_loaded() return mqbool(mq.TLO.Navigation.MeshLoaded()) end
local function nav_active() return mqbool(mq.TLO.Navigation.Active()) end

-- Snapshot the current position as camp (macro @577-579 / /camphere @16029).
function move.set_camp(st)
  st.camp.x = mq.TLO.Me.X() or 0
  st.camp.y = mq.TLO.Me.Y() or 0
  st.camp.z = mq.TLO.Me.FloorZ() or mq.TLO.Me.Z() or 0
  Write.Info('Camp set: %.0f, %.0f, %.0f', st.camp.x, st.camp.y, st.camp.z)
end

local function dist_to_camp(st)
  if not st.camp.x then return 0 end
  return mq.TLO.Math.Distance(string.format('%f,%f:%f,%f',
    mq.TLO.Me.Y() or 0, mq.TLO.Me.X() or 0, st.camp.y, st.camp.x))() or 0
end
move.dist_to_camp = dist_to_camp
function move.in_camp(st) return dist_to_camp(st) < (st.camp.radius or 60) end

local function is_puller(st) return PULLER_ROLES[(st.combat.role or ''):lower()] ~= nil end

-- Chase the MA (Sub DoWeMove @5814). Single command per tick.
local function do_chase(st)
  local m = st.move
  local name = m.chase_name or st.main_assist
  if not name or name == '' or name == mq.TLO.Me.CleanName() then return end
  local sp = mq.TLO.Spawn('=' .. name)
  if not sp.ID() then return end
  local d = sp.Distance() or 0
  if d <= m.chase_distance then
    if nav_active() then mq.cmd('/nav stop') end   -- close enough; don't overrun
    return
  end
  if nav_loaded() then
    if not nav_active() then mq.cmdf('/nav id %d', sp.ID()) end
  elseif not mqbool(mq.TLO.AdvPath.Following()) then
    mq.cmdf('/stick %d id %d loose', m.chase_distance, sp.ID())
  end
end

-- Return to camp (Sub DoWeMove @5584). Single command per tick.
local function do_return(st)
  local m = st.move
  if not st.camp.x then return end
  local d = dist_to_camp(st)
  if d > (st.camp.exceed or 400) and not is_puller(st) then m.return_to_camp = false; return end
  if d > m.return_accuracy and d > (st.camp.radius or 60) then
    if nav_loaded() then
      if not nav_active() then mq.cmdf('/nav locxyz %f %f %f', st.camp.x, st.camp.y, st.camp.z) end
    elseif not mqbool(mq.TLO.MoveTo.Moving()) then
      mq.cmdf('/moveto loc %f %f mdist %d', st.camp.y, st.camp.x, m.return_accuracy)
    end
  elseif nav_active() and d <= (st.camp.radius or 60) then
    mq.cmd('/nav stop')
  end
end

-- Force a return-to-camp move this tick, ignoring the return_to_camp flag and combat gate.
-- Used by pull.lua's inbound phase (the pulled mob is aggro'd, so move.tick would otherwise
-- refuse to move). Single command per tick.
function move.return_now(st)
  do_return(st)
end

function move.tick(st)
  local m = st.move
  if st.flags.buff_mode or st.flags.zombie_mode then return end
  if mq.TLO.Me.Hovering() or mq.TLO.Me.Casting.ID() then return end

  -- RTC + chase are mutually exclusive (macro @5576): chase wins. Expose chasing to buff/med.
  if m.chase_assist and m.return_to_camp then m.return_to_camp = false end
  st.combat.chasing = m.chase_assist

  local in_combat = st.combat.aggro_target_id ~= nil or mq.TLO.Me.CombatState() == 'COMBAT'

  if m.chase_assist then
    -- Chase out of combat, or in combat only if the MA ran far (macro @5814).
    local maDist = mq.TLO.Spawn('=' .. (m.chase_name or st.main_assist or '')).Distance() or 0
    if not in_combat or maDist > 100 then do_chase(st) end
    return
  end

  if m.return_to_camp and not in_combat then do_return(st) end
end

return move
