-- muleassist/init.lua  --  /lua run muleassist/init <Role> [MainAssist]
-- Phase 0 skeleton: load config, build state, idle main loop, /maquit to stop.
local mq     = require('mq')
local Write  = require('muleassist.Write')
local config = require('muleassist.config')
local state  = require('muleassist.state')
local cast   = require('muleassist.cast')
local heal   = require('muleassist.heal')
local rez    = require('muleassist.rez')
local buff   = require('muleassist.buff')
local petbuff = require('muleassist.petbuff')

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

  cast.gem_stuck_ability = cfg:get('General', 'GemStuckAbility', nil)
  cast.misc_gem       = cfg:num('General', 'MiscGem',       8)
  cast.misc_gem_lw    = cfg:num('General', 'MiscGemLW',     0)
  cast.misc_gem_remem = cfg:num('General', 'MiscGemRemem',  1)
  -- Capture whatever currently occupies the scratch gems so we can re-mem after a swap
  -- (macro @804-805; re-captured @18301 after spellset load — we have no static loadout
  -- port yet, so this is the live gem at startup).
  cast.remem_misc_gem = mq.TLO.Me.Gem(cast.misc_gem).Name()
  if cast.misc_gem_lw > 0 then
    cast.remem_misc_gem_lw = mq.TLO.Me.Gem(cast.misc_gem_lw).Name()
  end
  heal.setup(st)
  buff.setup(st)
  petbuff.setup(st)

  Write.Info('MuleAssist-Lua loaded. Role=%s MA=%s AssistAt=%d',
    st.role, tostring(st.main_assist), cfg:num('Melee', 'AssistAt', 95))
  Write.Info('Lists: dps=%d heals=%d buffs=%d burn=%d',
    #st.lists.dps, #st.lists.heals, #st.lists.buffs, #st.lists.burn)

  mq.bind('/maquit', function() st.running = false end)

  while st.running do
    mq.doevents()
    -- Macro main-loop order: state -> move -> heal -> rez -> buff -> DPS. Later
    -- phases insert their ticks around these. rez.check is its own loop slot
    -- (Sub Main @1561), independent of HealsOn, gated internally on AutoRezOn.
    heal.tick(st)
    if st.rez.auto ~= 0 then rez.check(st) end
    -- CastMana (@1566) is its own slot, runs near-combat; gated internally on Invis/cond.
    buff.run_mana(st)
    -- CheckBuffs is gated only on BuffsOn at the macro call site (@1576); its internal
    -- combat gate (aggro + BuffMode) decides whether to act, so call unconditionally.
    buff.tick(st)
    -- CheckPetBuffs (@1569): own slot, gated on PetBuffsOn + pet exists + 60s throttle.
    petbuff.tick(st)
    mq.delay(250)
  end

  Write.Info('MuleAssist-Lua stopped.')
end

main(...)
