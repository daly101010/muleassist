-- muleassist/init.lua  --  /lua run muleassist/init <Role> [MainAssist]
-- Phase 0 skeleton: load config, build state, idle main loop, /maquit to stop.
local mq     = require('mq')
local Write  = require('muleassist.Write')
local config = require('muleassist.config')
local state  = require('muleassist.state')

local function find_config_path(server, char)
  local cfgdir = mq.TLO.MacroQuest.Path('config')() or '.'
  local primary = config.locate(server, char)
  return cfgdir .. '/' .. primary
end

local function main(...)
  local args   = { ... }
  local server = mq.TLO.EverQuest.Server() or 'Unknown'
  local char   = mq.TLO.Me.CleanName() or 'Unknown'
  local path   = find_config_path(server, char)

  Write.loglevel = 'info'
  local cfg, err = config.load(path)
  if not cfg then
    Write.Error('Could not load config at %s (%s)', path, tostring(err))
    return
  end

  local st = state.new(cfg)
  if args[1] and args[1] ~= '' then st.role = args[1] end
  if args[2] and args[2] ~= '' then st.main_assist = args[2] end

  Write.Info('MuleAssist-Lua loaded. Role=%s MA=%s AssistAt=%d',
    st.role, tostring(st.main_assist), cfg:num('Melee', 'AssistAt', 95))
  Write.Info('Lists: dps=%d heals=%d buffs=%d burn=%d',
    #st.lists.dps, #st.lists.heals, #st.lists.buffs, #st.lists.burn)

  mq.bind('/maquit', function() st.running = false end)

  while st.running do
    mq.doevents()
    -- Phase 0: no actions. Later phases insert the ordered tick(st) calls here,
    -- in the macro's original sequence (state -> move -> heal -> buff -> DPS).
    mq.delay(250)
  end

  Write.Info('MuleAssist-Lua stopped.')
end

main(...)
