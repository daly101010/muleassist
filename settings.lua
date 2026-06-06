-- muleassist/settings.lua
-- Live config reload: re-read the INI from disk and re-derive all config-driven state in
-- place, then rebuild each module's entries. Used by /mareload and the embedded MAUI panel.
-- pcall-guarded: on any failure the running config is left untouched (reapply is a no-op).
local mq      = require('mq')
local config  = require('muleassist.config')
local state   = require('muleassist.state')
local Write   = require('muleassist.Write')
local cast    = require('muleassist.cast')
local heal    = require('muleassist.heal')
local buff    = require('muleassist.buff')
local petbuff = require('muleassist.petbuff')
local combat  = require('muleassist.combat')
local pull    = require('muleassist.pull')
local pet     = require('muleassist.pet')
local mez     = require('muleassist.mez')

local settings = {}

-- Apply one cfg fully: config-derived state + cast scratch-gem fields + rebuild entries.
-- May throw (a setup could fail on malformed config); reapply wraps it in pcall.
local function apply_all(st, cfg)
  local old_misc, old_misc_lw = cast.misc_gem, cast.misc_gem_lw
  state.apply_config(st, cfg)
  -- cast scratch-gem config (mirrors init.lua startup)
  cast.misc_gem          = cfg:num('General', 'MiscGem',      8)
  cast.misc_gem_lw       = cfg:num('General', 'MiscGemLW',    0)
  cast.misc_gem_remem    = cfg:num('General', 'MiscGemRemem', 1)
  cast.gem_stuck_ability = cfg:get('General', 'GemStuckAbility', nil)
  -- Re-capture the scratch-gem occupant ONLY if the slot number changed (a config edit);
  -- re-capturing unconditionally could snapshot a scratch spell mid-swap (init.lua @47).
  if cast.misc_gem ~= old_misc then
    cast.remem_misc_gem = mq.TLO.Me.Gem(cast.misc_gem).Name()
  end
  if cast.misc_gem_lw ~= old_misc_lw then
    cast.remem_misc_gem_lw = (cast.misc_gem_lw > 0)
      and mq.TLO.Me.Gem(cast.misc_gem_lw).Name() or nil
  end
  heal.setup(st); buff.setup(st); petbuff.setup(st); combat.setup(st)
  pull.setup(st); pet.setup(st); mez.setup(st)
end

function settings.reapply(st)
  local path = st.cfg and st.cfg.path
  if not path then Write.Error('settings.reapply: no config path on st'); return false end

  local cfg, err = config.load(path)
  if not cfg then Write.Error('settings.reapply: load failed (%s)', tostring(err)); return false end

  -- apply_config mutates st in place, so a mid-apply throw would leave new scalars beside
  -- stale entries. Capture the last-good cfg and roll back to it on failure.
  local old_cfg = st.cfg
  local ok, e = pcall(apply_all, st, cfg)
  if not ok then
    Write.Error('settings.reapply: %s (rolling back to last-good config)', tostring(e))
    if old_cfg then pcall(apply_all, st, old_cfg) end
    return false
  end

  Write.Info('Settings reloaded from %s', path)
  return true
end

return settings
