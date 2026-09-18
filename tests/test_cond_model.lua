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
  local m = cm.parse('mq.TLO.Target.CachedBuff("Snare")() == nil')
  assert(m.rows[1].key == 'target_missing_buff' and m.rows[1].value == 'Snare', 'missing-buff row')

  -- parameterized Group.Injured choices used by generated AOE/group heal conditions
  local gi = cm.parse('mq.TLO.Group.Injured(80)() >= 3')
  assert(gi.mode == 'rows' and gi.rows[1].key == 'group_injured_80'
    and gi.rows[1].op == '>=' and gi.rows[1].value == '3', 'group injured row')
  local gm = cm.parse('mq.TLO.Group.LowMana(75)() > 0')
  assert(gm.mode == 'rows' and gm.rows[1].key == 'group_low_mana_75'
    and gm.rows[1].op == '>' and gm.rows[1].value == '0', 'group low mana row')
  local spawns = cm.parse("mq.TLO.SpawnCount('npc radius 30 targetable')() >= 3")
  assert(spawns.mode == 'rows' and spawns.rows[1].key == 'nearby_npcs_30'
    and spawns.rows[1].value == '3', 'spawn count row')

  -- tank/warrior-style primitive gates
  local tank = cm.parse('mq.TLO.Me.ActiveDisc.ID() == 0 and mq.TLO.Target.PctAggro() <= 99 and mq.TLO.Target.Level() > 110 and mq.TLO.Target.Slowed.ID() == 0 and mq.TLO.Target.Tashed.ID() == 0')
  assert(tank.mode == 'rows' and #tank.rows == 5 and tank.rows[1].key == 'active_disc'
    and tank.rows[2].key == 'target_aggro' and tank.rows[3].key == 'target_level'
    and tank.rows[4].key == 'target_slowed' and tank.rows[5].key == 'target_tashed', 'tank rows')
  local caster = cm.parse('mq.TLO.Target.Beneficial.ID() > 0 and mq.TLO.Target.BuffsPopulated() == true and mq.TLO.Target.AggroHolder.ID() == 123')
  assert(caster.mode == 'rows' and #caster.rows == 3 and caster.rows[1].key == 'target_beneficial'
    and caster.rows[2].key == 'target_buffs_populated' and caster.rows[3].key == 'target_aggro_holder',
    'caster rows')
  local shaman = cm.parse('mq.TLO.Target.Height() > 1.91 and mq.TLO.Raid.Members() == 0')
  assert(shaman.mode == 'rows' and #shaman.rows == 2 and shaman.rows[1].key == 'target_height'
    and shaman.rows[2].key == 'raid_members', 'shaman rows')
  local monk = cm.parse('mq.TLO.Me.TargetOfTarget.ID() ~= mq.TLO.Me.ID()')
  assert(monk.mode == 'rows' and #monk.rows == 1 and monk.rows[1].key == 'target_not_targeting_me',
    'monk target-of-target row')
  local enc = cm.parse('mq.TLO.Target.Aggressive() == true and mq.TLO.Me.PctHPs() < 50')
  assert(enc.mode == 'rows' and #enc.rows == 2 and enc.rows[1].key == 'target_aggressive',
    'enchanter aggressive target row')
  local misc = cm.parse('mq.TLO.Target.Type() == "NPC" and mq.TLO.Me.Combat() == true and mq.TLO.Me.State() ~= "FEIGN"')
  assert(misc.mode == 'rows' and #misc.rows == 3 and misc.rows[1].key == 'target_type'
    and misc.rows[2].key == 'me_combat' and misc.rows[3].key == 'me_state', 'misc state rows')
  local mb = cm.parse('mq.TLO.Me.Buff[Two-Handed Proficiency]() == nil')
  assert(mb.mode == 'rows' and mb.rows[1].key == 'me_missing_buff'
    and mb.rows[1].value == 'Two-Handed Proficiency', 'me missing buff row')
  local ms = cm.parse('mq.TLO.Me.Song[Battle Leap Warcry]() == nil')
  assert(ms.mode == 'rows' and ms.rows[1].key == 'me_missing_song'
    and ms.rows[1].value == 'Battle Leap Warcry', 'me missing song row')
  local pet = cm.parse('mq.TLO.Me.Pet.ID() > 0 and mq.TLO.Me.Pet.PctHPs() < 50 and mq.TLO.Me.PetBuff("Bestial Bloodrage")() == nil')
  assert(pet.mode == 'rows' and #pet.rows == 3 and pet.rows[1].key == 'pet_id'
    and pet.rows[2].key == 'pet_hp' and pet.rows[3].key == 'pet_missing_buff', 'pet rows')

  local known_or = cm.parse('mq.TLO.Target.Named() == true or mq.TLO.Me.PctMana() < 80')
  assert(known_or.mode == 'rows' and #known_or.rows == 2 and known_or.logic[1] == 'or',
    'known or parses to rows')

  local legacy_mana = cm.parse('${Me.ManaPct} > 80')
  assert(legacy_mana.mode == 'rows' and legacy_mana.rows[1].key == 'my_mana'
    and legacy_mana.rows[1].op == '>' and legacy_mana.rows[1].value == '80', 'legacy mana converts')
  local legacy_debuff = cm.parse('!${Target.Tashed.ID} && ${Target.Level} >55')
  assert(legacy_debuff.mode == 'rows' and #legacy_debuff.rows == 2
    and legacy_debuff.rows[1].key == 'target_tashed'
    and legacy_debuff.rows[2].key == 'target_level', 'legacy debuff converts')
  local legacy_named_or = cm.parse('${Target.Named} || ${Me.PctMana} < 80')
  assert(legacy_named_or.mode == 'rows' and legacy_named_or.logic[1] == 'or'
    and legacy_named_or.rows[1].key == 'target_named', 'legacy or converts')

  -- parens / unresolved ${} / unknown -> raw
  assert(cm.parse('a or b').mode == 'raw', 'or -> raw')
  assert(cm.parse('(x and y)').mode == 'raw', 'parens -> raw')
  assert(cm.parse('${Spawn[Medkit].PctMana} < 90').mode == 'raw', 'unresolved legacy ${} -> raw')
  assert(cm.parse('mq.TLO.Foo.Bar() < 5').mode == 'raw', 'unknown subject -> raw')

  -- emit round-trips
  local rows = { { key='target_hp', op='<', value='70' }, { key='my_mana', op='>=', value='40' } }
  local s = cm.emit(rows)
  assert(s == 'mq.TLO.Target.PctHPs() < 70 and mq.TLO.Me.PctMana() >= 40', 'emit format: '..s)
  local rp = cm.parse(s)
  assert(rp.mode == 'rows' and #rp.rows == 2 and rp.rows[1].key == 'target_hp', 'emit/parse round-trip')
  local gis = cm.emit({ { key='group_injured_75', op='>=', value='3' } })
  assert(gis == 'mq.TLO.Group.Injured(75)() >= 3', 'group injured emit: '..gis)
  local lowMana = cm.emit({ { key='group_low_mana_75', op='>', value='0' } })
  assert(lowMana == 'mq.TLO.Group.LowMana(75)() > 0', 'group low mana emit: '..lowMana)
  local spawnCount = cm.emit({ { key='nearby_npcs_50', op='>=', value='2' } })
  assert(spawnCount == "mq.TLO.SpawnCount('npc radius 50 targetable')() >= 2", 'spawn count emit: '..spawnCount)
  local ws = cm.emit({
    { key='active_disc', op='==', value='0' },
    { key='target_aggro', op='<=', value='99' },
    { key='me_missing_buff', value='Two-Handed Proficiency' },
  })
  assert(ws == 'mq.TLO.Me.ActiveDisc.ID() == 0 and mq.TLO.Target.PctAggro() <= 99 and mq.TLO.Me.Buff("Two-Handed Proficiency")() == nil',
    'warrior-style emit: '..ws)
  local ps = cm.emit({
    { key='pet_id', op='>', value='0' },
    { key='pet_missing_buff', value='Bestial Bloodrage' },
  })
  assert(ps == 'mq.TLO.Me.Pet.ID() > 0 and mq.TLO.Me.PetBuff("Bestial Bloodrage")() == nil',
    'pet-style emit: '..ps)
  local mts = cm.emit({ { key='target_targeting_me' }, { key='target_not_targeting_me' } })
  assert(mts == 'mq.TLO.Me.TargetOfTarget.ID() == mq.TLO.Me.ID() and mq.TLO.Me.TargetOfTarget.ID() ~= mq.TLO.Me.ID()',
    'target-of-target emit: '..mts)
  local ts = cm.emit({ { key='target_type', op='==', value='NPC' } })
  assert(ts == 'mq.TLO.Target.Type() == "NPC"', 'target type emit: '..ts)
  local ors = cm.emit({
    { key='target_named', op='==', value='true' },
    { key='my_mana', op='<', value='80' },
  }, { 'or' })
  assert(ors == 'mq.TLO.Target.Named() == true or mq.TLO.Me.PctMana() < 80', 'or emit: '..ors)

  assert(cm.describe({ { key='my_mana', op='>', value='80' } }) == 'My mana is above 80%',
    'describe my mana')
  assert(cm.describe({ { key='group_injured_80', op='>=', value='3' } })
    == 'At least 3 group members are below 80% HP', 'describe group injured')
  assert(cm.describe({ { key='target_slowed', op='==', value='0' } }) == 'Target is not slowed',
    'describe target not slowed')
  assert(cm.describe({ { key='target_type', op='==', value='NPC' } }) == 'Target is NPC',
    'describe target type')
  assert(cm.describe({ { key='me_missing_buff', value='Two-Handed Proficiency' } })
    == 'I am missing Two-Handed Proficiency', 'describe missing buff')
  assert(cm.describe({ { key='nearby_npcs_50', op='>=', value='2' } }) == 'At least 2 NPCs are within 50',
    'describe spawn count')
  assert(cm.describe({
      { key='target_named', op='==', value='true' },
      { key='my_mana', op='<', value='80' },
    }, { 'or' }) == 'Target is named or My mana is below 80%', 'describe or')
  local preset_rows = cm.preset_rows(1)
  assert(preset_rows and preset_rows[1].key == 'target_type', 'preset rows')

  -- empty / nil
  assert(cm.parse('').mode == 'rows' and #cm.parse('').rows == 0, 'empty -> zero rows')
  assert(cm.parse(nil).mode == 'rows' and #cm.parse(nil).rows == 0, 'nil -> zero rows (no throw)')

  print('test_cond_model: PASS')
  return true
end
return t
