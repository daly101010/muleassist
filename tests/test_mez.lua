-- muleassist/tests/test_mez.lua  (runs in-game; mez.setup is mq-free for the parsed fields)
local config = require('muleassist.config')
local state  = require('muleassist.state')
local mez    = require('muleassist.mez')

local here = debug.getinfo(1, 'S').source:sub(2):gsub('[^/\\]+$', '')
local FIXTURE = here .. 'fixtures/sample.ini'

local t = {}
function t.run()
  local cfg = config.load(FIXTURE)
  assert(cfg, 'config.load returned nil for ' .. FIXTURE)

  -- Exercise AE "spell|count" + immune parsing without disturbing the shared fixture.
  cfg.sections['Mez'] = cfg.sections['Mez'] or {}
  cfg.sections['Mez']['MezOn']      = '2'
  cfg.sections['Mez']['MezAESpell'] = 'Wave of Sleep|3'
  cfg.sections['Mez']['MezImmune']  = 'a foo,a bar'

  local st = state.new(cfg)
  mez.setup(st)

  assert(st.mez.on == 2, 'MezOn parsed (2)')
  assert(st.mez.spell == 'Screaming Terror', 'MezSpell from fixture')
  assert(st.mez.ae_spell == 'Wave of Sleep', 'AE spell split from |count')
  assert(st.mez.ae_count == 3, 'AE count split')
  assert(st.mez.radius == 50, 'MezRadius from fixture (50)')
  assert(st.mez.stop_hp == 80, 'MezStopHPs from fixture (80)')
  assert(st.mez.max_level == 55, 'MezMaxLevel from fixture (55)')
  assert(st.mez.min_level == 0, 'MezMinLevel non-numeric -> 0')
  assert(st.mez.immune and st.mez.immune['a foo'] and st.mez.immune['a bar'],
    'MezImmune list parsed to a name-set')
  assert(type(st.mez.array) == 'table' and #st.mez.array == 0, 'mez array starts empty')
  assert(st.mez.ae_until == 0 and type(st.mez.immune_ids) == 'table', 'mez runtime init')

  print('test_mez: PASS')
  return true
end
return t
