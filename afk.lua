-- muleassist/afk.lua
-- Non-blocking AFKTools monitor. The reference macro holds inside loops; this version sets
-- st.flags.afk_hold so init.lua can pause normal automation without blocking events/comms.
local mq    = require('mq')
local Write = require('muleassist.Write')
local util  = require('muleassist.util')

local afk = {}

local function posse_loaded()
  return util.safe('afk.posse_loaded', function()
    return util.mqbool(mq.TLO.Plugin('MQ2Posse').IsLoaded())
  end, false)
end

local function alert(st, msg)
  local now = os.clock()
  if now < (st.afk.last_alert or 0) then return end
  st.afk.last_alert = now + 10
  Write.Warn('%s', msg)
  mq.cmd('/beep')
  if st.comms and st.comms.broadcast then
    st.comms.broadcast('ALERT', { text = msg })
  end
end

local function stranger_count()
  if not posse_loaded() then return 0 end
  return util.safe('afk.posse_strangers', function()
    return tonumber(mq.TLO.Posse.Strangers()) or 0
  end, 0)
end

local function gm_count()
  return util.safe('afk.gm_count', function()
    return tonumber(mq.TLO.SpawnCount('GM')()) or 0
  end, 0)
end

local function named_count(st)
  return util.safe('afk.named_count', function()
    local radius = math.max(tonumber(st.camp and st.camp.exceed) or 0, tonumber(st.pull and st.pull.max_radius) or 0, 200)
    return tonumber(mq.TLO.SpawnCount(string.format('npc named radius %d', radius))()) or 0
  end, 0)
end

function afk.setup(st)
  st.afk.holding = st.afk.holding or false
  st.afk.last_alert = st.afk.last_alert or 0
  st.afk.last_named_alert = st.afk.last_named_alert or 0

  if (st.afk.on == 1 or st.afk.on == 2) and posse_loaded() then
    mq.cmdf('/posse radius %d', st.afk.pc_radius)
  elseif st.afk.on == 1 or st.afk.on == 2 then
    Write.Warn('AFKTools stranger detection needs MQ2Posse; stranger hold is disabled.')
  end
end

function afk.tick(st)
  if not st.afk then return end

  local hold = false
  local reason = nil
  local on = tonumber(st.afk.on) or 0

  if on == 1 or on == 2 then
    if stranger_count() >= 1 then
      hold = true
      reason = 'PCs detected in camp radius'
    end
  end

  if on == 1 or on == 3 then
    local gms = gm_count()
    if gms >= 1 then
      local action = tonumber(st.afk.gm_action) or 1
      if action == 1 then
        hold = true
        reason = 'GM detected'
      elseif not st.afk.gm_action_taken then
        st.afk.gm_action_taken = true
        if action == 2 then
          Write.Warn('GM detected; stopping MuleAssist.')
          st.running = false
        elseif action == 3 then
          Write.Warn('GM detected; unloading MacroQuest.')
          mq.cmd('/unload')
        elseif action == 4 then
          Write.Warn('GM detected; quitting EverQuest.')
          mq.cmd('/quit')
        end
      end
    else
      st.afk.gm_action_taken = false
    end
  end

  if st.afk.beep_on_named and named_count(st) > 0 then
    local now = os.clock()
    if now >= (st.afk.last_named_alert or 0) then
      st.afk.last_named_alert = now + 30
      alert(st, 'Named NPC detected nearby')
    end
  end

  st.flags.afk_hold = hold
  if hold and not st.afk.holding then
    alert(st, 'AFKTools hold: ' .. tostring(reason or 'safety condition'))
  elseif not hold and st.afk.holding then
    Write.Info('AFKTools hold cleared.')
  end
  st.afk.holding = hold
end

return afk
