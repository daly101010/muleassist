-- muleassist/binds.lua
-- Phase 7a: runtime command binds. Ports the macro's /alias command surface (DeclareBinds
-- @~520) for the subsystems implemented so far. Two generic kinds:
--   TOGGLES  -> togglevariable (flip a 0/1 config flag)        e.g. /buffson
--   INTS     -> changevarint   (set a numeric config value)     e.g. /assistat 95
-- Each bind writes through settings.set/toggle, which re-derives state in place AND persists
-- to the INI (so a toggle survives a /mareload or restart). Faithful KissAssist-style names.
--
-- Deferred to later 7a/7b work: iniwrite list-adds (/setbuffs /setdps ...), per-subsystem
-- debug-flag granularity, unimplemented-feature toggles (autofire/scatter/pettoys), and
-- the full /charmthis bind set + events.
local mq       = require('mq')
local Write    = require('muleassist.Write')
local settings = require('muleassist.settings')
local move     = require('muleassist.move')
local combat   = require('muleassist.combat')
local binds    = {}

-- command name -> { Section, Key } for a 0/1 flag flip
local TOGGLES = {
  buffson        = { 'Buffs',   'BuffsOn' },
  meleeon        = { 'Melee',   'MeleeOn' },
  peton          = { 'Pet',     'PetOn' },
  charmon        = { 'Charm',   'CharmOn' },
  chase          = { 'General', 'ChaseAssist' },
  returntocamp   = { 'General', 'ReturnToCamp' },
  conditions     = { 'General', 'ConditionsOn' },
  autorezon      = { 'Heals',   'AutoRezOn' },
  cureson        = { 'Cures',   'CuresOn' },
  buffwhilechase = { 'General', 'BuffWhileChasing' },
  pethold        = { 'Pet',     'PetHoldOn' },
  medon          = { 'General', 'MedOn' },
  targetswitching= { 'Melee',   'TargetSwitchingOn' },
  twiston        = { 'General', 'TwistOn' },
  twisthold      = { 'General', 'TwistHold' },
  pulltwiston    = { 'Pull',    'PullTwistOn' },
  mercon         = { 'Merc',    'MercOn' },
  autorevivemerc = { 'Merc',    'AutoRevive' },
  looton         = { 'General', 'LootOn' },
}

-- command name -> { Section, Key } for a numeric set ( /name <value>; no arg echoes current )
local INTS = {
  assistat      = { 'Melee',   'AssistAt' },
  campradius    = { 'General', 'CampRadius' },
  chasedistance = { 'General', 'ChaseDistance' },
  medstart      = { 'General', 'MedStart' },
  maxradius     = { 'Pull',    'MaxRadius' },
  maxzrange     = { 'Pull',    'MaxZRange' },
  meleedistance = { 'Melee',   'MeleeDistance' },
  dpson         = { 'DPS',     'DPSOn' },
  dpsinterval   = { 'DPS',     'DPSInterval' },
  healson       = { 'Heals',   'HealsOn' },
  mezon         = { 'Mez',     'MezOn' },
  meleetwiston  = { 'Melee',   'MeleeTwistOn' },
  mercassistat  = { 'Merc',    'MercAssistAt' },
  afktoolson    = { 'AFKTools','AFKToolsOn' },
  afkgmaction   = { 'AFKTools','AFKGMAction' },
  afkpcradius   = { 'AFKTools','AFKPCRadius' },
}

local function count(t) local n = 0; for _ in pairs(t) do n = n + 1 end; return n end

local function switch_ma(st, new_ma)
  if not new_ma or new_ma == '' then
    Write.Warn('switchma needs a character name')
    return
  end
  st.main_assist = new_ma
  st.combat.my_target_id = nil
  st.combat.my_target_name = nil
  if st.comms and st.comms.broadcast then
    st.comms.broadcast('SWITCHMA', { main_assist = new_ma })
  end
  Write.Info('Main Assist -> %s', new_ma)
end

function binds.register(st)
  for name, m in pairs(TOGGLES) do
    mq.bind('/' .. name, function()
      local v = settings.toggle(st, m[1], m[2])
      Write.Info('%s -> %s', name, tostring(v))
    end)
  end

  for name, m in pairs(INTS) do
    mq.bind('/' .. name, function(arg)
      if not arg or arg == '' then
        Write.Info('%s = %s', name, tostring(st.cfg:get(m[1], m[2], '?'))); return
      end
      if not tonumber(arg) then Write.Warn('%s needs a number, got "%s"', name, tostring(arg)); return end
      settings.set(st, m[1], m[2], math.floor(tonumber(arg)))
      Write.Info('%s -> %s', name, arg)
    end)
  end

  -- explicit on/off variants + camp-here (set flag AND snapshot camp), macro @521-?.
  mq.bind('/chaseon',  function() settings.set(st, 'General', 'ChaseAssist', 1) end)
  mq.bind('/chaseoff', function() settings.set(st, 'General', 'ChaseAssist', 0) end)
  mq.bind('/camphere', function()
    settings.set(st, 'General', 'ReturnToCamp', 1); move.set_camp(st)
  end)
  mq.bind('/maswitchtarget', function(arg) combat.switch_target(st, arg) end)
  mq.bind('/switchtarget',   function(arg) combat.switch_target(st, arg) end)
  mq.bind('/maswitchma',     function(arg) switch_ma(st, arg) end)
  mq.bind('/switchma',       function(arg) switch_ma(st, arg) end)
  mq.bind('/matargetmode', function()
    local v = settings.toggle(st, 'Melee', 'ManualTargetMode')
    Write.Info('Manual Target Mode -> %s', tostring(v))
  end)
  mq.bind('/targetmode', function()
    local v = settings.toggle(st, 'Melee', 'ManualTargetMode')
    Write.Info('Manual Target Mode -> %s', tostring(v))
  end)

  -- loglevel toggle (stands in for the macro's many Debug* flags)
  mq.bind('/madebug', function()
    Write.loglevel = (Write.loglevel == 'debug') and 'info' or 'debug'
    Write.Info('loglevel = %s', Write.loglevel)
  end)

  Write.Info('binds: registered %d toggles + %d setters', count(TOGGLES), count(INTS))
end

function binds.unregister()
  for name in pairs(TOGGLES) do pcall(mq.unbind, '/' .. name) end
  for name in pairs(INTS) do pcall(mq.unbind, '/' .. name) end
  local extras = {
    '/chaseon', '/chaseoff', '/camphere',
    '/maswitchtarget', '/switchtarget',
    '/maswitchma', '/switchma',
    '/matargetmode', '/targetmode',
    '/madebug',
  }
  for _, name in ipairs(extras) do pcall(mq.unbind, name) end
end

-- exposed for tests
binds.TOGGLES = TOGGLES
binds.INTS    = INTS

return binds
