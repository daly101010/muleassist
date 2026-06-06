-- muleassist/tests/test_cond_model.lua  (pure; no mq)
local cm = require('muleassist.cond_model')

local t = {}
function t.run()
  -- and-chain of known subjects -> rows
  local p = cm.parse('mq.TLO.Target.PctHPs() < 70 and mq.TLO.Me.PctMana() >= 40')
  assert(p.mode == 'rows', 'and-chain parses to rows')
  assert(#p.rows == 2, 'two rows')
  assert(p.rows[1].key == 'target_hp' and p.rows[1].op == '<' and p.rows[1].value == '70',
    'row1 target_hp < 70')
  assert(p.rows[2].key == 'my_mana' and p.rows[2].op == '>=' and p.rows[2].value == '40',
    'row2 my_mana >= 40')

  -- buff has/missing
  local b = cm.parse('mq.TLO.Target.CachedBuff[Slow]() ~= nil')
  assert(b.mode == 'rows' and b.rows[1].key == 'target_has_buff' and b.rows[1].value == 'Slow',
    'has-buff row')
  local m = cm.parse('mq.TLO.Target.CachedBuff[Snare]() == nil')
  assert(m.rows[1].key == 'target_missing_buff' and m.rows[1].value == 'Snare', 'missing-buff row')

  -- or / parens / ${} / unknown -> raw
  assert(cm.parse('a or b').mode == 'raw', 'or -> raw')
  assert(cm.parse('(x and y)').mode == 'raw', 'parens -> raw')
  assert(cm.parse('${Me.Level} > 0').mode == 'raw', 'legacy ${} -> raw')
  assert(cm.parse('mq.TLO.Foo.Bar() < 5').mode == 'raw', 'unknown subject -> raw')

  -- emit round-trips
  local rows = { { key='target_hp', op='<', value='70' }, { key='my_mana', op='>=', value='40' } }
  local s = cm.emit(rows)
  assert(s == 'mq.TLO.Target.PctHPs() < 70 and mq.TLO.Me.PctMana() >= 40', 'emit format: '..s)
  local rp = cm.parse(s)
  assert(rp.mode == 'rows' and #rp.rows == 2 and rp.rows[1].key == 'target_hp', 'emit/parse round-trip')

  -- empty / nil
  assert(cm.parse('').mode == 'rows' and #cm.parse('').rows == 0, 'empty -> zero rows')
  assert(cm.parse(nil).mode == 'rows' and #cm.parse(nil).rows == 0, 'nil -> zero rows (no throw)')

  print('test_cond_model: PASS')
  return true
end
return t
