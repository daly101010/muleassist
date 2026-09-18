-- muleassist/bard.lua
-- Bard song twisting using the classic MQ2Twist config surface.
local mq    = require('mq')
local Write = require('muleassist.Write')
local util  = require('muleassist.util')

local bard = {}

local function clean_twist(raw)
  raw = tostring(raw or ''):gsub('^%s*(.-)%s*$', '%1')
  if raw == '' or raw:upper() == 'NULL' then return nil end
  return raw
end

local function is_bard()
  return util.class_short() == 'BRD'
end

local function twist(st, what)
  what = clean_twist(what)
  if not what then
    bard.stop(st)
    return
  end
  if st.bard.current_twist == what and st.bard.twisting then return end
  mq.cmdf('/twist %s', what)
  st.bard.current_twist = what
  st.bard.twisting = true
  Write.Info('Bard twist -> %s', what)
end

function bard.setup(st)
  st.bard.current_twist = st.bard.current_twist
  st.bard.twisting = st.bard.twisting or false
end

function bard.stop(st)
  if not st or not st.bard or not st.bard.twisting then return end
  mq.cmd('/twist off')
  st.bard.current_twist = nil
  st.bard.twisting = false
end

function bard.tick(st)
  if not st.bard or not is_bard() then return end

  if st.flags.afk_hold or st.bard.twist_hold or util.mqbool(mq.TLO.Me.Invis()) then
    bard.stop(st)
    return
  end

  local combat_active = st.combat.combat_start or (tonumber(st.combat.aggro_target_id) or 0) > 0
  if combat_active then
    if (tonumber(st.bard.melee_on) or 0) ~= 0 then
      local what = clean_twist(st.bard.melee_what)
      if not what or what:lower() == 'continuous' then what = clean_twist(st.bard.twist_what) end
      twist(st, what)
    else
      bard.stop(st)
    end
    return
  end

  if st.pull and st.pull.state ~= 'idle' and not st.bard.pull_twist_on then
    bard.stop(st)
    return
  end

  if st.bard.twist_on then
    twist(st, st.bard.twist_what)
  else
    bard.stop(st)
  end
end

return bard
