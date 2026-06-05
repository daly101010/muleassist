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
  e = S.parse_buff('Aura|caster|OOG:fellowship,range150,xtarget2', nil)
  eq(e.oog.fellowship, true, 'fellowship'); eq(e.oog.range, 150, 'range'); eq(e.oog.xtargets[1], 2, 'xtarget')
  eq(S.buff_to_string(e), 'Aura|caster|OOG:fellowship,range150,xtarget2', 'oog multi roundtrip')

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

  -- heal: name|pct|tag
  local h = S.parse_heal('Greater Healing|85|MA', '${Group.Injured[80]}')
  eq(h.name, 'Greater Healing', 'heal name'); eq(h.pct, 85, 'heal pct'); eq(h.tag, 'MA', 'heal tag')
  eq(h.cond, '${Group.Injured[80]}', 'heal cond')
  eq(S.heal_to_string(h), 'Greater Healing|85|MA', 'heal roundtrip')

  local h2 = S.parse_heal('Superior Healing|70', nil)
  eq(h2.tag, '', 'heal no tag'); eq(S.heal_to_string(h2), 'Superior Healing|70', 'heal no-tag roundtrip')

  print('test_serialize: PASS')
  return true
end
return t
