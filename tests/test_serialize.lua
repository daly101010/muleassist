-- muleassist/tests/test_serialize.lua  (pure; no mq)
local S = require('muleassist.serialize')
local t = {}

local function eq(a, b, msg) assert(a == b, (msg or 'neq') .. ': ' .. tostring(a) .. ' ~= ' .. tostring(b)) end

function t.run()
  -- plain spell
  local e = S.parse_buff('Spirit of Wolf', nil)
  eq(e.name, 'Spirit of Wolf', 'plain name'); eq(e.tag, '', 'plain tag')
  eq(S.buff_to_string(e), 'Spirit of Wolf', 'plain roundtrip')

  -- name|tag
  e = S.parse_buff('Aegolism|Me', nil)
  eq(e.name, 'Aegolism'); eq(e.tag, 'Me')
  eq(S.buff_to_string(e), 'Aegolism|Me', 'tag roundtrip')

  -- OOG with raid + name token
  e = S.parse_buff('Talisman|melee|OOG:raid,Bob', nil)
  eq(e.tag, 'melee'); assert(e.oog, 'oog set')
  eq(e.oog.raid, true, 'raid flag'); eq(e.oog.names[1], 'Bob', 'name token')
  eq(S.buff_to_string(e), 'Talisman|melee|OOG:raid,Bob', 'oog roundtrip')

  -- rangeN + fellowship + xtargetN tokens
  e = S.parse_buff('Aura|caster|OOG:fellowship,actors,range150,xtarget2', nil)
  eq(e.oog.fellowship, true, 'fellowship'); eq(e.oog.range, 150, 'range'); eq(e.oog.xtargets[1], 2, 'xtarget')
  eq(e.oog.actors, true, 'actors')
  eq(S.buff_to_string(e), 'Aura|caster|OOG:fellowship,actors,range150,xtarget2', 'oog multi roundtrip')

  -- non-OOG colon must NOT be treated as OOG
  e = S.parse_buff('Mask|Dual|illusion: foo', nil)
  assert(not e.oog, 'colon without OOG marker is not oog')
  eq(e.part3, 'illusion: foo', 'colon preserved in part3')
  eq(S.buff_to_string(e), 'Mask|Dual|illusion: foo', 'non-oog colon roundtrip')

  -- prefixes
  e = S.parse_buff('item:Worker Sledgemallet|Me', nil)
  eq(e.prefix, 'item'); eq(e.name, 'Worker Sledgemallet')
  eq(S.buff_to_string(e), 'item:Worker Sledgemallet|Me', 'item prefix roundtrip')

  -- Dual + part4 normalization
  e = S.parse_buff('GroupForm|Dual|SingleForm|MA', nil)
  eq(e.tag, 'DualMA', 'dual normalized'); eq(e.part3, 'SingleForm')
  eq(S.buff_to_string(e), 'GroupForm|Dual|SingleForm|MA', 'dual roundtrip emits raw Dual+part4')

  -- condition passthrough
  e = S.parse_buff('Shield|Me', '${Me.PctHPs}<90')
  eq(e.cond, '${Me.PctHPs}<90', 'cond carried')

  -- class tag: list in part3, derived class_list, exact round-trip
  e = S.parse_buff('Aegolism|class|WAR,PAL', nil)
  eq(e.archetype, 'class', 'class archetype'); eq(e.class_list, 'WAR,PAL', 'class_list from part3')
  eq(S.buff_to_string(e), 'Aegolism|class|WAR,PAL', 'class roundtrip')

  -- summoned: prefix round-trip
  e = S.parse_buff('summoned:Modulating Rod|Me', nil)
  eq(e.prefix, 'summoned'); eq(e.name, 'Modulating Rod')
  eq(S.buff_to_string(e), 'summoned:Modulating Rod|Me', 'summoned prefix roundtrip')

  -- combat opt-in token can be appended without stealing tag-specific fields
  e = S.parse_buff('Rune|combat', nil)
  eq(e.tag, '', 'plain combat token is not a tag')
  assert(e.cast_in_combat == true, 'plain combat token parsed')
  eq(S.buff_to_string(e), 'Rune|combat', 'plain combat roundtrip')

  e = S.parse_buff('Symbol|Me|combat', nil)
  eq(e.tag, 'Me', 'combat token preserves tag')
  assert(e.cast_in_combat == true, 'tagged combat token parsed')
  eq(S.buff_to_string(e), 'Symbol|Me|combat', 'tagged combat roundtrip')

  e = S.parse_buff('GroupForm|Dual|SingleForm|MA|combat', nil)
  eq(e.tag, 'DualMA', 'combat token preserves dual fields')
  assert(e.cast_in_combat == true, 'dual combat token parsed')
  eq(S.buff_to_string(e), 'GroupForm|Dual|SingleForm|MA|combat', 'dual combat roundtrip')

  -- heal: name|pct|tag
  local h = S.parse_heal('Greater Healing|85|MA', '${Group.Injured[80]}')
  eq(h.name, 'Greater Healing', 'heal name'); eq(h.pct, 85, 'heal pct'); eq(h.tag, 'MA', 'heal tag')
  eq(h.cond, '${Group.Injured[80]}', 'heal cond')
  eq(S.heal_to_string(h), 'Greater Healing|85|MA', 'heal roundtrip')

  local h2 = S.parse_heal('Superior Healing|70', nil)
  eq(h2.tag, '', 'heal no tag'); eq(S.heal_to_string(h2), 'Superior Healing|70', 'heal no-tag roundtrip')

  -- DPS grammar
  local d1 = S.parse_dps('Ice Comet|95', nil)
  assert(d1.spell == 'Ice Comet' and d1.part2 == 95 and d1.target == 'Mob'
    and d1.persistent == false and d1.once == false and d1.if_tag == nil, 'plain DD')
  assert(d1.hp_pct == 95 and d1.is_debuff == false, 'legacy aliases on plain DD')

  local d2 = S.parse_dps('Fierce Eye|100|Me', nil)
  assert(d2.target == 'Me', 'self target')

  local d3 = S.parse_dps('Malo|101|debuffall', nil)
  assert(d3.target == 'debuffall' and d3.persistent == true and d3.is_debuff == true, 'debuffall + persistent')

  -- arg-shift: keyword in arg3
  local d4 = S.parse_dps('Cripple|95|notif|Cripple', nil)
  assert(d4.if_tag == 'notif' and d4.if_spell == 'Cripple' and d4.target == 'Mob', 'arg-shift notif')
  assert(d4.cond_tag == 'notif' and d4.cond_spell == 'Cripple', 'legacy cond_tag/cond_spell aliases')

  -- non-shift: target then keyword
  local d5 = S.parse_dps('Spell|95|MA|if|Slow', nil)
  assert(d5.target == 'MA' and d5.if_tag == 'if' and d5.if_spell == 'Slow', 'target + if')

  -- once
  local d6 = S.parse_dps('Disc|95|once', nil)
  assert(d6.once == true and d6.target == 'Mob', 'once -> once flag, target Mob')

  -- round-trip (semantic fields preserved)
  for _, raw in ipairs({ 'Ice Comet|95', 'Fierce Eye|100|Me', 'Malo|101|debuffall',
                         'Spell|95|MA|if|Slow', 'Disc|95|once', 'Cripple|95|notif|Cripple' }) do
    local e = S.parse_dps(raw, nil)
    local out = S.dps_to_string(e)
    local e2 = S.parse_dps(out, nil)
    assert(e2.spell == e.spell and e2.part2 == e.part2 and e2.target == e.target
      and e2.if_tag == e.if_tag and e2.if_spell == e.if_spell and e2.once == e.once,
      'dps round-trip for '..raw..' -> '..out)
  end

  print('test_serialize: PASS')
  return true
end
return t
