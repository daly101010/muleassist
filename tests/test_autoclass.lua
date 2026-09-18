-- muleassist/tests/test_autoclass.lua  (pure resolver + INI persistence helpers)
local resolver = require('muleassist.autoclass.resolver')
local persist  = require('muleassist.autoclass.persist')
local live     = require('muleassist.autoclass.live')
local config   = require('muleassist.config')

local here = debug.getinfo(1, 'S').source:sub(2):gsub('[^/\\]+$', '')
local FIXTURE = here .. 'fixtures/sample.ini'

local fake_data = {
  family = 'Test',
  classes = {
    wiz = {
      sets = {
        Nuke = { 'Small Nuke', 'Big Nuke' },
        Snare = { 'Snare I' },
      },
      loadouts = {
        Default = {
          style = 'priority',
          candidates = { 'Nuke', 'Snare', 'MissingSet', 'Direct Spell' },
        },
      },
    },
    mag = {
      sets = {
        Fire = { 'Low Fire', 'High Fire' },
        Pet = { 'Pet Spell' },
      },
      loadouts = {
        Default = {
          style = 'gems',
          gems = {
            { gem = 1, candidates = { 'Fire' } },
            { gem = 2, candidates = { 'Missing', 'Pet' } },
            { gem = 9, candidates = { 'Direct Spell' } },
          },
        },
      },
    },
  },
}

local known = {
  ['Small Nuke'] = { rank_name = 'Small Nuke Rk. II', level = 10 },
  ['Big Nuke'] = { rank_name = 'Big Nuke Rk. II', level = 20 },
  ['Snare I'] = { rank_name = 'Snare I', level = 5 },
  ['Direct Spell'] = { rank_name = 'Direct Spell', level = 1 },
  ['Low Fire'] = { rank_name = 'Low Fire', level = 10 },
  ['High Fire'] = { rank_name = 'High Fire', level = 30 },
  ['Pet Spell'] = { rank_name = 'Pet Spell', level = 12 },
}

local function provider(name) return known[name] end

local function live_cfg(class_key, names, gem_count)
  local known_live = {}
  for _, name in ipairs(names or {}) do
    known_live[name] = { rank_name = name, level = 125 }
  end
  local res = resolver.resolve(live, class_key, 125, function(name) return known_live[name] end, gem_count or 13, 'Default')
  local cfg = config.default{ path = 'memory.ini', class = class_key, level = 125 }
  persist.apply_fill_empty_lists(cfg, res)
  return res, cfg
end

local t = {}
function t.run()
  assert(live.classes.nec and live.classes.clr and live.classes.wiz, 'Live data missing caster classes')
  assert(live.classes.war and live.classes.rog and live.classes.mnk, 'Live data missing melee classes')

  local res = resolver.resolve(fake_data, 'WIZ', 20, provider, 2, 'Default')
  assert(#res.gems == 2, 'priority resolver should respect gem count')
  assert(res.gems[1].name == 'Big Nuke Rk. II', 'priority resolver should pick highest known spell')
  assert(res.gems[2].name == 'Snare I', 'priority resolver should continue through candidates')

  local unknown = resolver.resolve(fake_data, 'clr', 20, provider, 8, 'Default')
  assert(#unknown.gems == 0, 'unknown class should resolve to empty gem list')

  local gems = resolver.resolve(fake_data, 'mag', 30, provider, 2, 'Default')
  assert(#gems.gems == 2, 'gem resolver should respect max gems')
  assert(gems.gems[1].gem == 1 and gems.gems[1].name == 'High Fire', 'gem resolver picked wrong gem 1')
  assert(gems.gems[2].gem == 2 and gems.gems[2].name == 'Pet Spell', 'gem resolver picked wrong gem 2')

  local cfg = config.load(FIXTURE)
  assert(cfg, 'config.load returned nil for ' .. FIXTURE)
  local changed = persist.apply_fill_empty(cfg, {
    gems = {
      { gem = 1, name = 'Should Not Replace', source = 'Nuke' },
      { gem = 2, name = 'Filled Spell', source = 'Snare' },
      { gem = 3, name = 'Filled Null Spell', source = 'Pet' },
    },
  }, 13)
  assert(#changed == 2, 'fill-empty should only fill blank/NULL slots')
  assert(cfg.sections.MySpells.Gem1 == 'Envenomed Bolt', 'fill-empty replaced user gem')
  assert(cfg.sections.MySpells.Gem2 == 'Filled Spell', 'fill-empty did not fill blank gem')
  assert(cfg.sections.MySpells.Gem3 == 'Filled Null Spell', 'fill-empty did not fill NULL gem')

  persist.write_cache(cfg, {
    family = 'Test',
    class = 'wiz',
    level = 20,
    mode = 'Default',
    gems = {
      { gem = 1, name = 'Suggested Nuke', source = 'Nuke' },
      { gem = 2, name = 'Filled Spell', source = 'Snare' },
    },
  }, persist.read_my_spells(cfg, 13))
  assert(cfg.sections.AutoClassCache.Gem1Suggestion == 'Suggested Nuke',
    'cache should record suggestions for occupied differing gems')
  assert(cfg.sections.AutoClassCache.Gem2Suggestion == nil,
    'cache should not suggest when current gem already matches')

  local blank_cfg = config.default{ path = 'memory.ini', class = 'Cleric', level = 40 }
  local list_changes = persist.apply_fill_empty_lists(blank_cfg, {
    gems = {
      { gem = 1, name = 'Superior Healing', source = 'HealingLight' },
      { gem = 2, name = 'Complete Heal', source = 'CompleteHeal' },
      { gem = 3, name = 'Word of Health', source = 'GroupHealNoCure' },
      { gem = 4, name = 'Cure Disease', source = 'CureDisease' },
      { gem = 5, name = 'Smite', source = 'MagicNuke' },
    },
  })
  assert(#list_changes == 5, 'list baseline should seed heal/cure/dps entries')
  assert(blank_cfg.sections.Heals.HealsOn == 1, 'heals should be enabled when heal entries are seeded')
  assert(blank_cfg.sections.Heals.Heals1 == 'Superior Healing|80|MA', 'single heal baseline wrong')
  assert(blank_cfg.sections.Heals.Heals2 == 'Complete Heal|60|MA', 'complete heal baseline wrong')
  assert(blank_cfg.sections.Heals.Heals3 == 'Word of Health|80', 'group heal baseline wrong')
  assert(blank_cfg.sections.Heals.HealsCond3 == 'mq.TLO.Group.Injured(80)() >= 3',
    'group heal baseline condition wrong')
  assert(blank_cfg.sections.Cures.CuresOn == 1 and blank_cfg.sections.Cures.Cures1 == 'Cure Disease|Disease',
    'cure baseline wrong')
  assert(blank_cfg.sections.DPS.DPSOn == 1 and blank_cfg.sections.DPS.DPS1 == 'Smite|99', 'dps baseline wrong')

  local pet_cfg = config.default{ path = 'memory.ini', class = 'Beastlord', level = 115 }
  persist.apply_fill_empty_lists(pet_cfg, {
    gems = {
      { gem = 1, name = 'Spirit of Panthea', source = 'PetSpell' },
      { gem = 2, name = 'Salve of Jaegir', source = 'PetHealSpell' },
      { gem = 3, name = 'Protective Warder', source = 'PetHealProc' },
      { gem = 4, name = "Sha's Reprisal", source = 'SlowSpell' },
      { gem = 5, name = 'Akhevan Blood', source = 'BloodDot' },
      { gem = 6, name = 'Attack of the Warders', source = 'SwarmPet' },
    },
  })
  assert(pet_cfg.sections.Pet.PetOn == 1 and pet_cfg.sections.Pet.PetSpell == 'Spirit of Panthea',
    'pet spell baseline wrong')
  assert(pet_cfg.sections.Heals.Heals1 == 'Salve of Jaegir|50|pet'
    and pet_cfg.sections.Heals.HealsCond1 == 'mq.TLO.Me.Pet.ID() > 0', 'pet heal baseline wrong')
  assert(pet_cfg.sections.Pet.PetBuffsOn == 1 and pet_cfg.sections.Pet.PetBuffs1 == 'Protective Warder',
    'pet buff baseline wrong')
  assert(pet_cfg.sections.DPS.DPS1 == "Sha's Reprisal|99|slow"
    and pet_cfg.sections.DPS.DPSCond1 == 'mq.TLO.Target.Slowed.ID() == 0', 'slow baseline condition wrong')
  assert(pet_cfg.sections.DPS.DPS2 == 'Akhevan Blood|99'
    and pet_cfg.sections.DPS.DPSCond2 == 'mq.TLO.Me.PctMana() > 50 and mq.TLO.Target.PctHPs() > 70',
    'dot baseline condition wrong')
  assert(pet_cfg.sections.DPS.DPS3 == 'Attack of the Warders|99'
    and pet_cfg.sections.DPS.DPSCond3 == 'mq.TLO.Target.Named() == true', 'swarm pet baseline condition wrong')

  local caster_cfg = config.default{ path = 'memory.ini', class = 'Wizard', level = 125 }
  persist.apply_fill_empty_lists(caster_cfg, {
    gems = {
      { gem = 1, name = 'Harvest of Druzzil', source = 'HarvestSpell' },
      { gem = 2, name = 'Twincast', source = 'TwincastSpell' },
      { gem = 3, name = 'Ethereal Immolation', source = 'FireEtherealNuke' },
      { gem = 4, name = 'Claw of Ingot', source = 'FireClaw' },
      { gem = 5, name = 'Anodyne Gambit', source = 'GambitSpell' },
      { gem = 6, name = 'Concussive Blast', source = 'JoltSpell' },
      { gem = 7, name = 'Annul Magic', source = 'Dispel' },
      { gem = 8, name = 'Shield of Memories', source = 'SelfHPBuff' },
    },
  })
  assert(caster_cfg.sections.Buffs.BuffsOn == 1 and caster_cfg.sections.Buffs.Buffs1 == 'Harvest of Druzzil|Mana|75'
    and caster_cfg.sections.Buffs.BuffsCond1 == 'mq.TLO.Me.PctMana() < 75', 'harvest buff baseline wrong')
  assert(caster_cfg.sections.Buffs.Buffs2 == 'Shield of Memories|Me', 'self shield baseline wrong')
  assert(caster_cfg.sections.DPS.DPS1 == 'Twincast|99'
    and caster_cfg.sections.DPS.DPSCond1 == 'mq.TLO.Me.Buff("Twincast")() == nil and mq.TLO.Target.PctHPs() > 10',
    'twincast baseline condition wrong')
  assert(caster_cfg.sections.DPS.DPS2 == 'Ethereal Immolation|99'
    and caster_cfg.sections.DPS.DPSCond2 == 'mq.TLO.Me.PctMana() > 30 and mq.TLO.Target.PctHPs() > 20',
    'ethereal baseline condition wrong')
  assert(caster_cfg.sections.DPS.DPS3 == 'Claw of Ingot|99'
    and caster_cfg.sections.DPS.DPSCond3 == 'mq.TLO.Me.PctMana() > 20 and mq.TLO.Target.PctHPs() > 10',
    'nuke baseline condition wrong')
  assert(caster_cfg.sections.DPS.DPS4 == 'Anodyne Gambit|99'
    and caster_cfg.sections.DPS.DPSCond4 == 'mq.TLO.Me.PctMana() < 80 and mq.TLO.Target.PctHPs() >= 30 and mq.TLO.Target.PctHPs() <= 99',
    'gambit baseline condition wrong')
  assert(caster_cfg.sections.DPS.DPS5 == 'Concussive Blast|99'
    and caster_cfg.sections.DPS.DPSCond5 == 'mq.TLO.Target.PctAggro() > 80', 'jolt baseline condition wrong')
  assert(caster_cfg.sections.DPS.DPS6 == 'Annul Magic|99'
    and caster_cfg.sections.DPS.DPSCond6 == 'mq.TLO.Target.Beneficial.ID() > 0', 'dispel baseline condition wrong')

  local shm_cfg = config.default{ path = 'memory.ini', class = 'Shaman', level = 100 }
  persist.apply_fill_empty_lists(shm_cfg, {
    gems = {
      { gem = 1, name = 'Ancestral Pact', source = 'CanniSpell' },
      { gem = 2, name = "Turgur's Insects", source = 'SlowSpell' },
      { gem = 3, name = 'Wind of Malisene', source = 'AEMaloSpell' },
      { gem = 4, name = 'Nectar of Pain', source = 'NectarDot' },
      { gem = 5, name = "Antecessor's Intervention", source = 'InterventionHeal' },
      { gem = 6, name = 'Spiritual Shower', source = 'AESpiritualHeal' },
      { gem = 7, name = 'Talisman of the Snow Leopard', source = 'MeleeProcBuff' },
      { gem = 8, name = 'Rampant Growth', source = 'TempHPBuff' },
      { gem = 9, name = 'Blood of Mayong', source = 'CureSpell' },
    },
  })
  assert(shm_cfg.sections.Buffs.Buffs1 == 'Ancestral Pact|Mana|70|90'
    and shm_cfg.sections.Buffs.BuffsCond1 == 'mq.TLO.Me.PctMana() < 70 and mq.TLO.Me.PctHPs() > 60',
    'shaman canni baseline wrong')
  assert(shm_cfg.sections.Buffs.Buffs2 == 'Talisman of the Snow Leopard|melee',
    'shaman melee proc baseline wrong')
  assert(shm_cfg.sections.Buffs.Buffs3 == 'Rampant Growth|class|war,pal,shd',
    'shaman temp HP baseline wrong')
  assert(shm_cfg.sections.DPS.DPS1 == "Turgur's Insects|99|slow"
    and shm_cfg.sections.DPS.DPSCond1 == 'mq.TLO.Target.Slowed.ID() == 0', 'shaman slow baseline wrong')
  assert(shm_cfg.sections.DPS.DPS2 == 'Wind of Malisene|99|debuffall|malo'
    and shm_cfg.sections.DPS.DPSCond2 == 'TRUE', 'shaman malo baseline wrong')
  assert(shm_cfg.sections.DPS.DPS3 == 'Nectar of Pain|99'
    and shm_cfg.sections.DPS.DPSCond3 == 'mq.TLO.Me.PctMana() > 50 and mq.TLO.Target.PctHPs() > 70',
    'shaman dot baseline wrong')
  assert(shm_cfg.sections.Heals.Heals1 == "Antecessor's Intervention|50|MA"
    and shm_cfg.sections.Heals.HealsCond1 == 'mq.TLO.Me.CombatState() == "COMBAT"',
    'shaman intervention heal baseline wrong')
  assert(shm_cfg.sections.Heals.Heals2 == 'Spiritual Shower|80'
    and shm_cfg.sections.Heals.HealsCond2 == 'mq.TLO.Group.Injured(80)() >= 3',
    'shaman AE spiritual heal baseline wrong')
  assert(shm_cfg.sections.Cures.Cures1 == 'Blood of Mayong|All', 'shaman cure baseline wrong')

  local mnk_known = {
    ["Master's Aura"] = { rank_name = "Master's Aura", level = 100 },
    ['Rest'] = { rank_name = 'Rest', level = 80 },
    ['Seven Breaths'] = { rank_name = 'Seven Breaths', level = 100 },
    ['Ironfist Discipline'] = { rank_name = 'Ironfist Discipline', level = 90 },
    ['Terrorpalm Discipline'] = { rank_name = 'Terrorpalm Discipline', level = 100 },
    ["Eagle's Poise"] = { rank_name = "Eagle's Poise", level = 90 },
    ['Eye of the Storm'] = { rank_name = 'Eye of the Storm', level = 100 },
    ['Crane Stance'] = { rank_name = 'Crane Stance', level = 100 },
  }
  local mnk_res = resolver.resolve(live, 'MNK', 100, function(name) return mnk_known[name] end, 8, 'Default')
  assert(#mnk_res.gems == 8 and mnk_res.gems[1].source == 'MonkAura'
    and mnk_res.gems[4].source == 'FistDisc', 'monk default loadout resolution wrong')

  local mnk_cfg = config.default{ path = 'memory.ini', class = 'Monk', level = 100 }
  persist.apply_fill_empty_lists(mnk_cfg, mnk_res)
  assert(mnk_cfg.sections.Buffs.Buffs1 == "Master's Aura|aura", 'monk aura baseline wrong')
  assert(mnk_cfg.sections.Buffs.Buffs2 == 'Rest|end|20', 'monk endurance recovery baseline wrong')
  assert(mnk_cfg.sections.Buffs.Buffs3 == 'Seven Breaths|end|80', 'monk breath recovery baseline wrong')
  assert(mnk_cfg.sections.DPS.DPS1 == 'Ironfist Discipline|99'
    and mnk_cfg.sections.DPS.DPSCond1 == 'mq.TLO.Me.TargetOfTarget.ID() ~= mq.TLO.Me.ID()',
    'monk disc baseline condition wrong')
  assert(mnk_cfg.sections.DPS.DPS2 == 'Terrorpalm Discipline|99'
    and mnk_cfg.sections.DPS.DPSCond2 == 'mq.TLO.Me.TargetOfTarget.ID() ~= mq.TLO.Me.ID()',
    'monk palm baseline condition wrong')

  local mnk_heal_cfg = config.default{ path = 'memory.ini', class = 'Monk', level = 100 }
  persist.apply_fill_empty_lists(mnk_heal_cfg, {
    gems = {
      { gem = 1, name = 'Mend', source = 'Mend' },
      { gem = 2, name = 'Inner Rejuvenation', source = 'InnerRejuvenation' },
    },
  })
  assert(mnk_heal_cfg.sections.Heals.Heals1 == 'Mend|66|Me', 'monk mend baseline wrong')
  assert(mnk_heal_cfg.sections.Heals.Heals2 == 'Inner Rejuvenation|66|Me'
    and mnk_heal_cfg.sections.Heals.HealsCond2 == 'mq.TLO.Me.CombatState() == "RESTING"',
    'monk inner rejuvenation baseline wrong')

  local enc_known = {
    ['Chaotic Enticement X'] = { rank_name = 'Chaotic Enticement X', level = 95 },
    ['Baffle'] = { rank_name = 'Baffle', level = 80 },
    ['Serene Wave'] = { rank_name = 'Serene Wave', level = 95 },
    ["Baffler's Aura"] = { rank_name = "Baffler's Aura", level = 95 },
    ['Runic Gleam Aura'] = { rank_name = 'Runic Gleam Aura', level = 95 },
    ['Bite of Tashani'] = { rank_name = 'Bite of Tashani', level = 95 },
    ['Desolate Deeds'] = { rank_name = 'Desolate Deeds', level = 95 },
    ['Slowing Helix'] = { rank_name = 'Slowing Helix', level = 95 },
    ['Voice of Prescience'] = { rank_name = 'Voice of Prescience Rk. II', level = 95 },
    ['Speed of Novak'] = { rank_name = 'Speed of Novak', level = 95 },
    ['Spectral Rune'] = { rank_name = 'Spectral Rune', level = 90 },
    ['Polychaotic Rune'] = { rank_name = 'Polychaotic Rune Rk. II', level = 95 },
    ['Gather Mana'] = { rank_name = 'Gather Mana', level = 95 },
    ['Spectral Assault'] = { rank_name = 'Spectral Assault', level = 95 },
  }
  local enc_res = resolver.resolve(live, 'ENC', 95, function(name) return enc_known[name] end, 20, 'Default')
  assert(#enc_res.gems >= 8 and enc_res.gems[1].source == 'TwinCastMez'
    and enc_res.gems[2].source == 'MezSpell' and enc_res.gems[3].source == 'MezAESpell',
    'enchanter default loadout resolution wrong')

  local enc_cfg = config.default{ path = 'memory.ini', class = 'Enchanter', level = 95 }
  persist.apply_fill_empty_lists(enc_cfg, enc_res)
  assert(enc_cfg.sections.Mez.MezOn == 1 and enc_cfg.sections.Mez.MezSpell == 'Baffle',
    'enchanter mez spell baseline wrong')
  assert(enc_cfg.sections.Mez.MezAESpell == 'Serene Wave|2', 'enchanter AE mez baseline wrong')
  assert(enc_cfg.sections.DPS.DPS2 == 'Bite of Tashani|99|debuffall|tash'
    and enc_cfg.sections.DPS.DPSCond2 == 'TRUE', 'enchanter tash baseline wrong')
  assert(enc_cfg.sections.DPS.DPS3 == 'Slowing Helix|99|slow'
    and enc_cfg.sections.DPS.DPSCond3 == 'TRUE', 'enchanter cripple slow baseline wrong')
  assert(enc_cfg.sections.DPS.DPS4 == 'Desolate Deeds|99|slow'
    and enc_cfg.sections.DPS.DPSCond4 == 'mq.TLO.Target.Slowed.ID() == 0', 'enchanter slow baseline wrong')
  assert(enc_cfg.sections.Buffs.Buffs1 == "Baffler's Aura|aura",
    'enchanter learner aura baseline wrong')
  assert(enc_cfg.sections.Buffs.Buffs2 == 'Runic Gleam Aura|aura',
    'enchanter rune aura baseline wrong')
  assert(enc_cfg.sections.Buffs.Buffs3 == 'Voice of Prescience Rk. II|caster',
    'enchanter mana regen baseline wrong')
  assert(enc_cfg.sections.Buffs.Buffs4 == 'Speed of Novak|melee',
    'enchanter haste baseline wrong')
  assert(enc_cfg.sections.Buffs.Buffs5 == 'Spectral Rune|Me',
    'enchanter self rune baseline wrong')
  assert(enc_cfg.sections.Buffs.Buffs6 == 'Polychaotic Rune Rk. II|Me',
    'enchanter second rune baseline wrong')
  assert(enc_cfg.sections.Buffs.Buffs7 == 'Gather Mana|Mana|10',
    'enchanter gather mana baseline wrong')
  assert(enc_cfg.sections.DPS.DPS5 == 'Spectral Assault|99'
    and enc_cfg.sections.DPS.DPSCond5 == 'mq.TLO.Me.PctMana() > mq.TLO.Target.PctHPs()',
    'enchanter nuke baseline wrong')

  local clr_res, clr_cfg = live_cfg('CLR', {
    'Holy Remedy XIV', 'Complete Heal', 'Word of Wellbeing', 'Sanctified Blood',
    'Shining Rampart IX', 'Yaulp V', 'Veto', 'Reviviscence',
  })
  assert(#clr_res.gems == 8, 'cleric default loadout resolution wrong')
  assert(clr_cfg.sections.Heals.Heals3 == 'Word of Wellbeing|80'
    and clr_cfg.sections.Heals.HealsCond3 == 'mq.TLO.Group.Injured(80)() >= 3',
    'cleric group heal baseline wrong')
  assert(clr_cfg.sections.Buffs.Buffs1 == 'Yaulp V|Me|combat', 'cleric yaulp baseline wrong')
  assert(clr_cfg.sections.DPS.DPS1 == 'Veto|99' and clr_cfg.sections.DPS.DPS2 == nil,
    'cleric DPS baseline should not seed rez spells')

  local _, dru_cfg = live_cfg('DRU', {
    'Ecliptic Winds', 'Rejuvilation IX', 'Survival of the Fittest XI', 'Horde of Spitewasps',
    'Skin of the Reptile XII', "Mastery: Nightwhisper's Breeze", 'Wild Growth X',
  })
  assert(dru_cfg.sections.Buffs.Buffs1 == 'Skin of the Reptile XII|MA|combat',
    'druid reptile baseline wrong')
  assert(dru_cfg.sections.Heals.Heals2 == 'Survival of the Fittest XI|80'
    and dru_cfg.sections.Heals.HealsCond2 == 'mq.TLO.Group.Injured(80)() >= 3',
    'druid group heal baseline wrong')
  assert(dru_cfg.sections.Cures.Cures1 == "Mastery: Nightwhisper's Breeze|All",
    'druid group cure baseline wrong')

  local _, mag_cfg = live_cfg('MAG', {
    'Spear of Ro X', 'Chaotic Fire VI', 'Raging Servant XIII', 'Malaise XVI',
    'Gather Potential VIII', 'Renewal of Magmath', 'Searing Skin XI',
  })
  assert(mag_cfg.sections.DPS.DPS4 == 'Malaise XVI|99|debuffall|malo'
    and mag_cfg.sections.DPS.DPSCond4 == 'TRUE', 'magician malo baseline wrong')
  assert(mag_cfg.sections.Heals.Heals1 == 'Renewal of Magmath|50|pet'
    and mag_cfg.sections.Heals.HealsCond1 == 'mq.TLO.Me.Pet.ID() > 0',
    'magician pet heal baseline wrong')
  assert(mag_cfg.sections.Buffs.Buffs2 == 'Gather Potential VIII|Mana|10',
    'magician gather baseline wrong')

  local _, nec_cfg = live_cfg('NEC', {
    'Schisming Venin', 'Soulrip VII', 'Clinging Darkness XIX', 'Scent of Dusk XIII',
    'Otherside XX', 'Call Raging Skeleton X', 'Flesh to Toxin', 'Necrotize Ally X',
  })
  assert(nec_cfg.sections.Buffs.Buffs1 == 'Otherside XX|Me|combat', 'necromancer lich baseline wrong')
  assert(nec_cfg.sections.DPS.DPS3 == 'Clinging Darkness XIX|99'
    and nec_cfg.sections.DPS.DPSCond3 == 'mq.TLO.Target.Snared.ID() == 0',
    'necromancer snare baseline wrong')
  assert(nec_cfg.sections.DPS.DPS4 == 'Scent of Dusk XIII|99|debuffall|scent'
    and nec_cfg.sections.DPS.DPSCond4 == 'TRUE', 'necromancer scent baseline wrong')
  assert(nec_cfg.sections.Pet.PetBuffs1 == 'Necrotize Ally X', 'necromancer pet buff baseline wrong')

  local _, pal_cfg = live_cfg('PAL', {
    'Eminent Touch', 'Splash of Eminence', 'Valiant Defiance', 'Crush of Eminence',
    'Preservation of Quellious', 'Unyielding Stance', 'Mastery: Balanced Purity',
  })
  assert(pal_cfg.sections.Heals.Heals2 == 'Splash of Eminence|80'
    and pal_cfg.sections.Heals.HealsCond2 == 'mq.TLO.Group.Injured(80)() >= 3',
    'paladin splash baseline wrong')
  assert(pal_cfg.sections.DPS.DPS1 == 'Valiant Defiance|99'
    and pal_cfg.sections.DPS.DPSCond1 == 'mq.TLO.Target.Type() == "NPC"',
    'paladin heal-taunt baseline wrong')
  assert(pal_cfg.sections.Buffs.Buffs1 == 'Preservation of Quellious|Me',
    'paladin preservation baseline wrong')

  local _, rng_cfg = live_cfg('RNG', {
    'Desperate Deluge IX', 'Volcanic Ash XVIII', 'Spitestinger Swarm', 'Concealed Shot',
    "Summer's Dew XII", 'Shadowveil', 'Frenzy of Arrows',
  })
  assert(rng_cfg.sections.Heals.Heals1 == 'Desperate Deluge IX|80|MA',
    'ranger heal baseline wrong')
  assert(rng_cfg.sections.DPS.DPS1 == 'Volcanic Ash XVIII|99'
    and rng_cfg.sections.DPS.DPSCond1 == 'mq.TLO.Me.PctMana() > 20 and mq.TLO.Target.PctHPs() > 10',
    'ranger nuke baseline wrong')

  local _, shd_cfg = live_cfg('SHD', {
    'Spear of Wremm', 'Touch of Bonesplinter', 'Festering Darkness XI', 'Dread Gaze XIII',
    'Unyielding Stance', "Spitetangle's Skin", 'Harmonious Disruption',
  })
  assert(shd_cfg.sections.Buffs.Buffs1 == "Spitetangle's Skin|Me"
    and shd_cfg.sections.Buffs.Buffs3 == 'Harmonious Disruption|Me',
    'shadowknight self buff baseline wrong')
  assert(shd_cfg.sections.DPS.DPS3 == 'Festering Darkness XI|99'
    and shd_cfg.sections.DPS.DPSCond3 == 'mq.TLO.Target.Snared.ID() == 0',
    'shadowknight snare baseline wrong')
  assert(shd_cfg.sections.DPS.DPS4 == 'Dread Gaze XIII|99'
    and shd_cfg.sections.DPS.DPSCond4 == 'mq.TLO.Target.Named() == true or mq.TLO.Me.XTarget() >= 3',
    'shadowknight AE taunt baseline wrong')

  local tank_cfg = config.default{ path = 'memory.ini', class = 'Warrior', level = 125 }
  persist.apply_fill_empty_lists(tank_cfg, {
    gems = {
      { gem = 1, name = 'Final Stand Discipline VI', source = 'StandDisc' },
      { gem = 2, name = 'Gut Punch', source = 'AggroKick' },
    },
  })
  assert(tank_cfg.sections.DPS.DPS1 == 'Final Stand Discipline VI|99'
    and tank_cfg.sections.DPS.DPSCond1 == 'mq.TLO.Target.Named() == true or mq.TLO.Me.XTarget() >= 3',
    'tank defensive baseline wrong')
  assert(tank_cfg.sections.DPS.DPS2 == 'Gut Punch|99'
    and tank_cfg.sections.DPS.DPSCond2 == 'mq.TLO.Target.Type() == "NPC"',
    'tank aggro baseline wrong')

  local ber_known = {
    ['Aura of Rage'] = { rank_name = 'Aura of Rage', level = 70 },
    ['Rest'] = { rank_name = 'Rest', level = 85 },
    ['Shared Bloodlust'] = { rank_name = 'Shared Bloodlust', level = 90 },
    ['War Cry'] = { rank_name = 'War Cry', level = 10 },
    ['Brutal Discipline'] = { rank_name = 'Brutal Discipline', level = 60 },
  }
  local ber_res = resolver.resolve(live, 'BER', 100, function(name) return ber_known[name] end, 8, 'Default')
  assert(#ber_res.gems == 5 and ber_res.gems[1].source == 'BerAura'
    and ber_res.gems[5].source == 'PrimaryBurnDisc', 'berserker default loadout resolution wrong')
  local ber_cfg = config.default{ path = 'memory.ini', class = 'Berserker', level = 100 }
  persist.apply_fill_empty_lists(ber_cfg, ber_res)
  assert(ber_cfg.sections.Buffs.Buffs1 == 'Aura of Rage|aura', 'berserker aura baseline wrong')
  assert(ber_cfg.sections.Buffs.Buffs2 == 'Rest|end|20', 'berserker endurance baseline wrong')
  assert(ber_cfg.sections.Buffs.Buffs3 == 'Shared Bloodlust|melee', 'berserker shared buff baseline wrong')
  assert(ber_cfg.sections.Buffs.Buffs4 == 'War Cry|melee', 'berserker war cry baseline wrong')
  assert(ber_cfg.sections.DPS.DPS1 == 'Brutal Discipline|99'
    and ber_cfg.sections.DPS.DPSCond1 == 'mq.TLO.Target.Named() == true',
    'berserker burn baseline wrong')

  local rog_known = {
    ['Rest'] = { rank_name = 'Rest', level = 85 },
    ['Weapon Covenant'] = { rank_name = 'Weapon Covenant', level = 90 },
    ["Thief's Vision"] = { rank_name = "Thief's Vision", level = 50 },
    ['Fatal Aim Discipline'] = { rank_name = 'Fatal Aim Discipline', level = 70 },
    ['Assault'] = { rank_name = 'Assault', level = 10 },
  }
  local rog_res = resolver.resolve(live, 'ROG', 100, function(name) return rog_known[name] end, 8, 'Default')
  assert(#rog_res.gems == 5 and rog_res.gems[4].source == 'AimDisc'
    and rog_res.gems[5].source == 'FellStrike', 'rogue default loadout resolution wrong')
  local rog_cfg = config.default{ path = 'memory.ini', class = 'Rogue', level = 100 }
  persist.apply_fill_empty_lists(rog_cfg, rog_res)
  assert(rog_cfg.sections.Buffs.Buffs1 == 'Rest|end|20', 'rogue endurance baseline wrong')
  assert(rog_cfg.sections.Buffs.Buffs2 == 'Weapon Covenant|Me', 'rogue proc buff baseline wrong')
  assert(rog_cfg.sections.Buffs.Buffs3 == "Thief's Vision|Me", 'rogue thief buff baseline wrong')
  assert(rog_cfg.sections.DPS.DPS1 == 'Fatal Aim Discipline|99'
    and rog_cfg.sections.DPS.DPSCond1 == 'mq.TLO.Target.Named() == true',
    'rogue aim baseline wrong')
  assert(rog_cfg.sections.DPS.DPS2 == 'Assault|99'
    and rog_cfg.sections.DPS.DPSCond2 == 'mq.TLO.Me.TargetOfTarget.ID() ~= mq.TLO.Me.ID()',
    'rogue strike baseline wrong')

  local war_known = {
    ["Champion's Aura"] = { rank_name = "Champion's Aura", level = 70 },
    ['Rest'] = { rank_name = 'Rest', level = 85 },
    ['Field Armorer'] = { rank_name = 'Field Armorer', level = 70 },
    ['Bracing Defense'] = { rank_name = 'Bracing Defense', level = 80 },
    ['Final Stand Discipline'] = { rank_name = 'Final Stand Discipline', level = 60 },
  }
  local war_res = resolver.resolve(live, 'WAR', 100, function(name) return war_known[name] end, 8, 'Default')
  assert(#war_res.gems == 5 and war_res.gems[1].source == 'AuraBuff'
    and war_res.gems[5].source == 'StandDisc', 'warrior default loadout resolution wrong')
  local war_cfg = config.default{ path = 'memory.ini', class = 'Warrior', level = 100 }
  persist.apply_fill_empty_lists(war_cfg, war_res)
  assert(war_cfg.sections.Buffs.Buffs1 == "Champion's Aura|aura", 'warrior aura baseline wrong')
  assert(war_cfg.sections.Buffs.Buffs2 == 'Rest|end|20', 'warrior endurance baseline wrong')
  assert(war_cfg.sections.Buffs.Buffs3 == 'Field Armorer', 'warrior group armor baseline wrong')
  assert(war_cfg.sections.Buffs.Buffs4 == 'Bracing Defense|Me', 'warrior defense baseline wrong')
  assert(war_cfg.sections.DPS.DPS1 == 'Final Stand Discipline|99'
    and war_cfg.sections.DPS.DPSCond1 == 'mq.TLO.Target.Named() == true or mq.TLO.Me.XTarget() >= 3',
    'warrior stand baseline wrong')

  print('test_autoclass: PASS')
  return true
end

return t
