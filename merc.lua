-- muleassist/merc.lua
-- Mercenary assist/revive handling.
local mq    = require('mq')
local Write = require('muleassist.Write')
local util  = require('muleassist.util')

local merc = {}

local function merc_state()
  return util.safe('merc.state', function()
    return mq.TLO.Mercenary.State() or ''
  end, '')
end

local function detect_name()
  return util.safe('merc.detect_name', function()
    local me = mq.TLO.Me.CleanName() or ''
    for i = 1, (tonumber(mq.TLO.Group()) or 0) do
      local member = mq.TLO.Group.Member(i)
      if member() and member.Owner.Name() == me then return member.Name() or '' end
    end
    return ''
  end, '')
end

function merc.setup(st)
  st.merc.assisting = st.merc.assisting or 0
  st.merc.name = st.merc.name or detect_name()
  if merc_state() == 'Active' then st.merc.in_group = true end
end

function merc.tick(st)
  if not st.merc then return end

  local state = merc_state()
  if state == 'Active' then st.merc.in_group = true end
  if not st.merc.name or st.merc.name == '' then st.merc.name = detect_name() end

  if st.merc.auto_revive and st.merc.in_group and state == 'DEAD' then
    local enabled = util.safe('merc.revive_button', function()
      return util.mqbool(mq.TLO.Window('MMGW_ManageWnd').Child('MMGW_SuspendButton').Enabled())
    end, false)
    if enabled then mq.cmd('/notify MMGW_ManageWnd MMGW_SuspendButton LeftMouseUp') end
  end

  if not st.merc.on or state ~= 'Active' then
    if state ~= 'Active' then st.merc.assisting = 0 end
    return
  end

  local target_id = tonumber(st.combat.my_target_id or st.combat.aggro_target_id) or 0
  if target_id == 0 then
    st.merc.assisting = 0
    return
  end

  local pct = util.safe('merc.target_hp', function()
    return tonumber(mq.TLO.Spawn('id ' .. target_id).PctHPs()) or 100
  end, 100)
  local in_combat = st.combat.combat_start or (tonumber(st.combat.aggro_target_id) or 0) > 0

  if pct <= (tonumber(st.merc.assist_at) or 100) and in_combat and st.merc.assisting ~= target_id then
    mq.cmd('/mercassist')
    st.merc.assisting = target_id
    Write.Info('Merc assist -> %d', target_id)
  end
end

return merc
