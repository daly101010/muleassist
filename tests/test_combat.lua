-- muleassist/tests/test_combat.lua
-- Offline: DPS/Burn parse + setup. Cast/engage paths verified in-game.
local config = require('muleassist.config')
local state  = require('muleassist.state')
local combat = require('muleassist.combat')
local action = require('muleassist.action')
local mq     = require('mq')

local here = debug.getinfo(1, 'S').source:sub(2):gsub('[^/\\]+$', '')
local FIXTURE = here .. 'fixtures/sample.ini'

local t = {}
function t.run()
  local cfg = config.load(FIXTURE)
  -- inject a debuffall DPS entry to exercise the DebuffAll bucket (clear list cache first)
  cfg.sections['DPS'] = cfg.sections['DPS'] or {}
  cfg.sections['DPS']['DPSSize'] = '3'
  cfg.sections['DPS']['DPS3'] = 'Malosini|101|debuffall'
  cfg._lists = {}
  local st  = state.new(cfg)
  combat.setup(st)
  assert(type(st.combat.debuff_all) == 'table', 'debuff_all is a table')
  local found_da = false
  for _, e in ipairs(st.combat.debuff_all) do if e.target == 'debuffall' then found_da = true end end
  assert(found_da, 'Malosini|101|debuffall bucketed into debuff_all')
  assert(type(st.combat.entries) == 'table', 'entries missing')
  assert(type(st.combat.burn) == 'table', 'burn missing')
  for _, e in ipairs(st.combat.entries) do
    assert(e.spell and e.spell ~= '', 'dps entry missing spell')
    assert(not e.is_debuff, 'debuff entry leaked into rotation')
    assert(type(e.hp_pct) == 'number', 'hp_pct should be number')
  end

  local function value(v)
    return setmetatable({}, {
      __call = function() return v end,
      __index = function() return value(nil) end,
    })
  end
  local function object(map)
    return setmetatable(map or {}, {
      __call = function(self) return rawget(self, '__value') end,
      __index = function() return value(nil) end,
    })
  end

  local old_ready, old_execute = action.ready, action.execute
  local old_spawn, old_spell, old_me = mq.TLO.Spawn, mq.TLO.Spell, mq.TLO.Me
  local calls = {}
  action.ready = function() return true end
  action.execute = function(_, entry, target_id, opts)
    calls[#calls + 1] = {
      spell = entry.spell,
      target_id = target_id,
      sent_from = opts and opts.sent_from,
      cast_target_id = opts and opts.cast_target_id,
    }
    entry.last_run = { success = true, result = 'CAST_SUCCESS' }
    return true, 'CAST_SUCCESS'
  end
  mq.TLO.Spawn = function(id)
    return object({
      ID = value(tonumber(id) or 777),
      Type = value('NPC'),
      Distance = value(10),
      CachedBuff = function() return object({ ID = value(nil) }) end,
    })
  end
  mq.TLO.Spell = function()
    return object({ Duration = object({ TotalSeconds = value(12) }) })
  end
  mq.TLO.Me = object({
    ID = value(111),
    Level = value(125),
    PctAggro = value(50),
  })

  local st2 = {
    flags = {},
    combat = {
      my_target_id = 777,
      dps_cond_on = false,
      dps_timers = {},
      dps_interval = 10,
      melee_dist = 25,
      debuffs = { { spell = 'Slow Spell', index = 5 } },
      aggro = { { spell = 'Provoke', pct = 90, glt = '<', target = 'Mob', index = 1 } },
    },
  }
  combat.debuff(st2)
  assert(calls[1] and calls[1].spell == 'Slow Spell' and calls[1].sent_from == 'dps',
    'debuff should route through action.execute')
  assert(st2.combat.dps_timers[5] and st2.combat.dps_timers[5][777],
    'debuff success should arm timer')

  combat.aggro_check(st2)
  assert(calls[2] and calls[2].spell == 'Provoke' and calls[2].sent_from == 'Aggro'
    and calls[2].cast_target_id == 777, 'aggro should route through action.execute')

  action.ready, action.execute = old_ready, old_execute
  mq.TLO.Spawn, mq.TLO.Spell, mq.TLO.Me = old_spawn, old_spell, old_me

  print('test_combat: PASS (' .. #st.combat.entries .. ' dps, ' .. #st.combat.burn .. ' burn)')
  return true
end
return t
