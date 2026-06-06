-- muleassist/util.lua
-- Shared helpers + role/class sets. Replaces the copies of mqbool/nav/group/role-set logic
-- that were duplicated across buff/combat/move/pull/mez/charm/pet/med. One source of truth.
local mq   = require('mq')
local util = {}

----------------------------------------------------------------------
-- MQ bool coercion: MQ bool TLOs can return boolean, number, or the STRING
-- "TRUE"/"FALSE"/"NULL" (all truthy in Lua). Normalize to a real boolean.
----------------------------------------------------------------------
function util.mqbool(v)
  local t = type(v)
  if t == 'boolean' then return v end
  if t == 'number'  then return v ~= 0 end
  if t == 'string'  then local u = v:upper(); return u == 'TRUE' or u == '1' end
  return false
end
local mqbool = util.mqbool

----------------------------------------------------------------------
-- Common TLO reads.
----------------------------------------------------------------------
function util.nav_loaded()  return mqbool(mq.TLO.Navigation.MeshLoaded()) end
function util.nav_active()   return mqbool(mq.TLO.Navigation.Active()) end
-- mq.TLO.Group() returns the STRING "FALSE" when solo -> tonumber guards against the
-- "compare number with string" crash that bit buff/heal/rez early on.
function util.group_size()   return tonumber(mq.TLO.Group()) or 0 end
function util.class_short()  return (mq.TLO.Me.Class.ShortName() or ''):upper() end

----------------------------------------------------------------------
-- Role sets (keyed by lowercase role) and class sets (keyed by UPPER short-name).
----------------------------------------------------------------------
util.TANK_ROLES    = { tank=1, pullertank=1, pettank=1, pullerpettank=1 }
util.PULLER_ROLES  = { puller=1, pullertank=1, hunter=1, pullerpettank=1, hunterpettank=1 }
util.HUNTER_ROLES  = { hunter=1, hunterpettank=1 }
util.GUARD_ROLES   = { puller=1, pullertank=1, pettank=1, pullerpettank=1 }
util.PETTANK_ROLES = { pettank=1, pullerpettank=1 }

util.MEZ_CLASSES   = { ENC=1, BRD=1, NEC=1 }
util.CHARM_CLASSES = { ENC=1, DRU=1 }
util.CASTER_MED    = { BST=1,BRD=1,CLR=1,DRU=1,ENC=1,MAG=1,NEC=1,PAL=1,RNG=1,SHM=1,SHD=1,WIZ=1 }
util.HYBRID        = { BRD=1,BST=1,PAL=1,RNG=1,SHD=1 }

-- Role predicate against a set, using st.combat.role (lowercased).
function util.role_in(st, set) return set[(st.combat.role or ''):lower()] ~= nil end
function util.is_puller(st) return util.PULLER_ROLES[(st.combat.role or ''):lower()] ~= nil end
function util.is_hunter(st) return util.HUNTER_ROLES[(st.combat.role or ''):lower()] ~= nil end
-- Tank if the role is a tank role OR I am the main assist (KissAssist treats the MA as tank).
function util.is_tank(st)
  return util.TANK_ROLES[(st.combat.role or ''):lower()] ~= nil
      or (st.main_assist ~= nil and st.main_assist == mq.TLO.Me.CleanName())
end
function util.is_mezzer()  return util.MEZ_CLASSES[util.class_short()] ~= nil end
function util.is_charmer() return util.CHARM_CLASSES[util.class_short()] ~= nil end

----------------------------------------------------------------------
-- SafeCallFunc: run fn under pcall, returning (default) on error and logging once.
-- Used to isolate per-module ticks and risky TLO chains so one failure can't stall the loop.
----------------------------------------------------------------------
local seen_err = {}
local function log_once(label, res)
  if not seen_err[label] then
    seen_err[label] = true
    require('muleassist.Write').Error('%s: %s', tostring(label), tostring(res))
  end
end

function util.safe(label, fn, default)
  local ok, res = pcall(fn)
  if ok then return res end
  log_once(label, res)
  return default
end

-- Like safe(), but pcalls fn(...) (no closure needed) and returns nothing. For the main loop:
-- isolates each module tick so one module's error can't stall the whole bot.
function util.guard(label, fn, ...)
  local ok, res = pcall(fn, ...)
  if not ok then log_once(label, res) end
end

return util
