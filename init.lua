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
local combat = require('muleassist.combat')
local med    = require('muleassist.med')
local move   = require('muleassist.move')
local pull   = require('muleassist.pull')
local pet    = require('muleassist.pet')
local mez    = require('muleassist.mez')
local charm  = require('muleassist.charm')
local afk    = require('muleassist.afk')
local bard   = require('muleassist.bard')
local merc   = require('muleassist.merc')
local loot   = require('muleassist.loot')
local autoclass = require('muleassist.autoclass')
local binds  = require('muleassist.binds')
local events = require('muleassist.events')
local comms  = require('muleassist.comms')
local settings = require('muleassist.settings')
local util   = require('muleassist.util')

local function file_exists(p)
  local f = io.open(p, 'r'); if f then f:close(); return true end
  return false
end

local function find_config_path(server, char)
  local cfgdir = mq.TLO.MacroQuest.Path('config')() or '.'
  local level  = tonumber(mq.TLO.Me.Level()) or 0
  local plain, leveled = config.locate(server, char, level)
  -- Macro @454: prefer the level-suffixed INI (MuleAssist_<srv>_<char>_<lvl>.ini) when it
  -- exists, else the plain one (which is also the default when neither exists yet).
  if leveled then
    local lp = cfgdir .. '/' .. leveled
    if file_exists(lp) then return lp end
  end
  return cfgdir .. '/' .. plain
end

local function main(...)
  local args   = { ... }
  for i, v in ipairs(args) do
    if tostring(v):lower() == 'none' then args[i] = '' end
  end
  local server = mq.TLO.EverQuest.Server() or 'Unknown'
  local char   = mq.TLO.Me.CleanName() or 'Unknown'
  local path   = find_config_path(server, char)

  Write.loglevel = 'info'
  local cfg, err = config.load(path)
  if not cfg then
    if tostring(err):find('cannot open', 1, true) then
      Write.Warn('Config not found at %s; creating a default MuleAssist INI.', path)
      cfg, err = config.create_default(path, {
        server = server,
        char = char,
        class = mq.TLO.Me.Class.Name() or 'Unknown',
        level = mq.TLO.Me.Level() or 0,
        role = args[1],
        main_assist = args[2],
      })
      if not cfg then
        Write.Error('Could not create config at %s (%s)', path, tostring(err))
        return
      end
    else
      Write.Error('Could not load config at %s (%s)', path, tostring(err))
      return
    end
  end

  local st = state.new(cfg)
  if args[1] and args[1] ~= '' then st.role = args[1]; st.combat.role = args[1] end
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
  combat.setup(st)
  pull.setup(st)
  pet.setup(st)
  mez.setup(st)
  charm.setup(st)
  afk.setup(st)
  bard.setup(st)
  merc.setup(st)
  loot.setup(st)
  autoclass.setup(st)
  move.set_camp(st)
  st.move.chase_name = st.main_assist

  Write.Info('MuleAssist-Lua loaded. Role=%s MA=%s AssistAt=%d',
    st.role, tostring(st.main_assist), cfg:num('Melee', 'AssistAt', 95))
  Write.Info('Lists: dps=%d heals=%d buffs=%d burn=%d',
    #st.lists.dps, #st.lists.heals, #st.lists.buffs, #st.lists.burn)

  local ui_mod = nil
  local cleaned_up = false
  local function cleanup()
    if cleaned_up then return end
    cleaned_up = true
    st.running = false
    pcall(function() mq.cmd('/attack off') end)
    pcall(function() mq.cmd('/stick off') end)
    pcall(function() mq.cmd('/nav stop') end)
    pcall(bard.stop, st)
    if ui_mod and ui_mod.unmount then pcall(ui_mod.unmount) end
    pcall(comms.shutdown)
    pcall(events.unregister)
    pcall(autoclass.unregister)
    pcall(binds.unregister)
    local local_binds = {
      '/maquit', '/mastop', '/maburn', '/macamp', '/macamphere',
      '/mareload', '/macharm', '/maui',
    }
    for _, name in ipairs(local_binds) do pcall(mq.unbind, name) end
  end

  local function request_stop()
    st.running = false
  end
  mq.bind('/maquit', request_stop)
  mq.bind('/mastop', request_stop)
  mq.bind('/maburn', function() st.combat.burning = true end)
  mq.bind('/macamp', function() move.set_camp(st) end)
  mq.bind('/macamphere', function() st.move.return_to_camp = true; move.set_camp(st) end)
  mq.bind('/mareload', function() st.pending_reapply = true end)
  binds.register(st)   -- Phase 7a: KissAssist-style toggle/set command surface
  autoclass.register(st)
  events.register(st)  -- Phase 7b: cast-outcome events refine cast.cast results
  comms.init(st)       -- MQ Actors bus: debuffs, MA/target/camp/chase broadcasts
  -- Manual charm target (full /charmthis bind set lands in Phase 7): no arg -> current target.
  mq.bind('/macharm', function(arg)
    if arg == 'clear' or arg == 'off' then st.charm.pet_id = 0; Write.Info('Charm target cleared')
    else st.charm.pet_id = mq.TLO.Target.ID() or 0; Write.Info('Charm target set to %d', st.charm.pet_id) end
  end)

  mq.bind('/maui', function(arg)
    arg = tostring(arg or ''):lower():gsub('^%s+', ''):gsub('%s+$', '')
    if arg == 'stop' or arg == 'close' then
      if ui_mod and ui_mod.unmount then pcall(ui_mod.unmount) end
      ui_mod = nil
      return
    elseif arg == 'hide' then
      if ui_mod and ui_mod.unmount then pcall(ui_mod.unmount) end
      ui_mod = nil
      return
    elseif arg == 'show' and ui_mod then
      if ui_mod.show then ui_mod.show() end
      return
    end
    if not ui_mod then
      _G.MULEASSIST_EMBED = true
      local ok, mod = pcall(require, 'muleassist.ui.init')
      _G.MULEASSIST_EMBED = nil    -- load-time guard already ran; don't leak to other scripts
      if not ok then Write.Error('MAUI load failed: %s', tostring(mod)); return end
      ui_mod = mod
      -- No explicit window id: mount() defaults to a bot-unique 'MuleAssistBot' so the
      -- callback registry can't collide with the standalone UI's 'MuleAssist' (crash on unload).
      ui_mod.mount{ ini_path = path,
                    state = st,
                    on_apply = function() st.pending_reapply = true end }
      return                       -- mount() opens the window
    end
    ui_mod.toggle()
  end)

  local ok, err = xpcall(function()
    while st.running do
      mq.doevents()
      if st.pending_reapply then
        st.pending_reapply = false
        settings.reapply(st)
      end
      if st.pending_ui_reload and ui_mod and ui_mod.reload then
        st.pending_ui_reload = false
        pcall(ui_mod.reload)
      end
      if ui_mod and ui_mod.tick then pcall(ui_mod.tick) end
      -- Default MainAssist to the game's group main assist if it wasn't configured/passed.
      if not st.main_assist or st.main_assist == '' then
        local gma = mq.TLO.Group.MainAssist.CleanName()
        if gma and gma ~= '' then st.main_assist = gma end
      end
      -- Keep MainAssistID fresh (macro @1607); heal MA-heals and combat 'MA'-target DPS need it.
      st.main_assist_id = mq.TLO.Spawn('=' .. (st.main_assist or '')).ID() or 0
      -- Each module tick is isolated: util.guard pcalls it so a transient error in one module
      -- (e.g. a bad TLO read mid-zone) can't stall the whole loop -- it logs once and continues.
      -- Macro main-loop order: state -> move -> heal -> rez -> buff -> DPS.
      util.guard('combat.refresh', combat.refresh, st)
      util.guard('autoclass.tick', autoclass.tick, st)
      util.guard('afk.tick', afk.tick, st)
      if st.flags.afk_hold then
        util.guard('bard.stop', bard.stop, st)
      else
        util.guard('heal.check_cures', heal.check_cures, st)
        util.guard('heal.tick', heal.tick, st)
        if st.rez.auto ~= 0 then util.guard('rez.check', rez.check, st) end
        util.guard('buff.run_mana', buff.run_mana, st)
        util.guard('buff.tick', buff.tick, st)
        util.guard('pet.tick', pet.tick, st)               -- summon/maintain pet (before buffing it)
        util.guard('petbuff.tick', petbuff.tick, st)
        util.guard('pull.tick', pull.tick, st)             -- runs before combat (drives pull movement)
        util.guard('mez.tick', mez.tick, st)               -- CC adds before the DPS pass
        util.guard('charm.tick', charm.tick, st)           -- (re)charm when petless (ENC/DRU)
        util.guard('combat.debuff_all_tick', combat.debuff_all_tick, st)
        util.guard('combat.tick', combat.tick, st)         -- assist + DPS/melee
        util.guard('merc.tick', merc.tick, st)
        util.guard('bard.tick', bard.tick, st)
        util.guard('loot.tick', loot.tick, st)
        util.guard('move.tick', move.tick, st)             -- RTC/chase (after combat, before med)
        util.guard('med.tick', med.tick, st)               -- sit to recover when idle
      end
      util.guard('comms.tick', comms.tick, st)
      mq.delay(250)
    end
  end, debug.traceback)

  cleanup()
  if not ok then
    Write.Error('MuleAssist runtime error: %s', tostring(err))
  end

  Write.Info('MuleAssist-Lua stopped.')
end

main(...)
