-- muleassist/binds.lua
-- Phase 7a: runtime command binds. Ports the macro's /alias command surface (DeclareBinds
-- @~520) for the subsystems implemented so far. Two generic kinds:
--   TOGGLES  -> togglevariable (flip a 0/1 config flag)        e.g. /buffson
--   INTS     -> changevarint   (set a numeric config value)     e.g. /assistat 95
-- Each bind writes through settings.set/toggle, which re-derives state in place AND persists
-- to the INI (so a toggle survives a /mareload or restart). Faithful KissAssist-style names.
--
-- Deferred to later 7a/7b work: iniwrite list-adds (/setbuffs /setdps ...), per-subsystem
-- debug-flag granularity, unimplemented-feature toggles (autofire/scatter/pettoys/merc/loot/
-- AFKTools), and the full /charmthis bind set + events.
local mq       = require('mq')
local Write    = require('muleassist.Write')
local settings = require('muleassist.settings')
local move     = require('muleassist.move')
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
  buffwhilechase = { 'General', 'BuffWhileChasing' },
  pethold        = { 'Pet',     'PetHoldOn' },
  medon          = { 'General', 'MedOn' },
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
}

local function count(t) local n = 0; for _ in pairs(t) do n = n + 1 end; return n end

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

  -- loglevel toggle (stands in for the macro's many Debug* flags)
  mq.bind('/madebug', function()
    Write.loglevel = (Write.loglevel == 'debug') and 'info' or 'debug'
    Write.Info('loglevel = %s', Write.loglevel)
  end)

  Write.Info('binds: registered %d toggles + %d setters', count(TOGGLES), count(INTS))
end

-- exposed for tests
binds.TOGGLES = TOGGLES
binds.INTS    = INTS

return binds
