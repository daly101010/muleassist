-- muleassist/autoclass/persist.lua
-- Pure INI-section helpers for AutoClass cache and [MySpells] fill-empty behavior.
local persist = {}

local function blank(v)
  if v == nil then return true end
  local s = tostring(v):gsub('^%s*(.-)%s*$', '%1')
  local up = s:upper()
  return s == '' or up == 'NULL' or up:find('^NULL|') ~= nil
end

local function ensure(cfg, section)
  cfg.sections[section] = cfg.sections[section] or {}
  return cfg.sections[section]
end

function persist.read_my_spells(cfg, max_gems)
  local out, sec = {}, cfg.sections.MySpells or {}
  for i = 1, max_gems or 13 do
    local v = sec['Gem' .. i]
    if not blank(v) then out[i] = tostring(v) end
  end
  return out
end

function persist.apply_fill_empty(cfg, resolved, max_gems)
  local sec = ensure(cfg, 'MySpells')
  local changed = {}
  max_gems = max_gems or 13
  for _, gem in ipairs((resolved and resolved.gems) or {}) do
    local idx = tonumber(gem.gem) or 0
    if idx > 0 and idx <= max_gems and not blank(gem.name) then
      local key = 'Gem' .. idx
      if blank(sec[key]) then
        sec[key] = gem.name
        changed[#changed + 1] = { gem = idx, name = gem.name, source = gem.source }
      end
    end
  end
  return changed
end

local LISTS = {
  heals = { section = 'Heals', prefix = 'Heals', cond = 'HealsCond', size = 'HealsSize', on = 'HealsOn', max = 40 },
  cures = { section = 'Cures', prefix = 'Cures', cond = 'CuresCond', size = 'CuresSize', on = 'CuresOn', max = 5 },
  buffs = { section = 'Buffs', prefix = 'Buffs', cond = 'BuffsCond', size = 'BuffsSize', on = 'BuffsOn', max = 20 },
  dps = { section = 'DPS', prefix = 'DPS', cond = 'DPSCond', size = 'DPSSize', on = 'DPSOn', max = 40 },
  petbuffs = { section = 'Pet', prefix = 'PetBuffs', size = 'PetBuffsSize', on = 'PetBuffsOn', max = 12 },
}

local function contains(haystack, needle)
  return tostring(haystack or ''):lower():find(needle, 1, true) ~= nil
end

local function entry_text(section, spell, source)
  local s = tostring(source or ''):lower()
  local n = tostring(spell or ''):lower()
  if section == 'heals' then
    if contains(s, 'mend') or contains(s, 'rejuvenation') then return spell .. '|66|Me' end
    if contains(s, 'petheal') then return spell .. '|50|pet' end
    if contains(s, 'intervention') then return spell .. '|50|MA' end
    if contains(s, 'complete') or contains(n, 'complete heal') then return spell .. '|60|MA' end
    if contains(s, 'group') or contains(s, 'aespiritualheal')
        or contains(s, 'splash') or contains(s, 'wave')
        or contains(n, 'word of') or contains(n, 'syllable') then return spell .. '|80' end
    return spell .. '|80|MA'
  elseif section == 'cures' then
    local typ = 'All'
    if contains(s, 'poison') or contains(n, 'poison') then typ = 'Poison'
    elseif contains(s, 'disease') or contains(n, 'disease') then typ = 'Disease'
    elseif contains(s, 'curse') or contains(n, 'curse') then typ = 'Curse'
    elseif contains(s, 'corrupt') or contains(n, 'corrupt') then typ = 'Corruption'
    end
    return spell .. '|' .. typ
  elseif section == 'dps' then
    if contains(s, 'tash') then return spell .. '|99|debuffall|tash' end
    if contains(s, 'malo') then return spell .. '|99|debuffall|malo' end
    if contains(s, 'scent') then return spell .. '|99|debuffall|scent' end
    if contains(s, 'slow') then return spell .. '|99|slow' end
    return spell .. '|99'
  elseif section == 'buffs' then
    if contains(s, 'aura') then return spell .. '|aura' end
    if contains(s, 'harvest') then return spell .. '|Mana|75' end
    if contains(s, 'gathermana') then return spell .. '|Mana|10' end
    if contains(s, 'canni') then return spell .. '|Mana|70|90' end
    if contains(s, 'yaulp') then return spell .. '|Me|combat' end
    if contains(s, 'lich') then return spell .. '|Me|combat' end
    if contains(s, 'endregen') or contains(s, 'rest') then return spell .. '|end|20' end
    if contains(s, 'breaths') or contains(s, 'wind') then return spell .. '|end|80' end
    if contains(s, 'sharedbuff') or contains(s, 'hhebuff') or contains(s, 'frenzyboost') then return spell .. '|melee' end
    if contains(s, 'meleeproc') or contains(s, 'haste') then return spell .. '|melee' end
    if contains(s, 'manaregen') or contains(s, 'spellproc') then return spell .. '|caster' end
    if contains(s, 'temphp') then return spell .. '|class|war,pal,shd' end
    if contains(s, 'reptilecombat') then return spell .. '|MA|combat' end
    if contains(s, 'defenseacbuff') or contains(s, 'selfbuffsingle') or contains(s, 'selfbuffae')
        or contains(s, 'procbuff') or contains(s, 'thiefbuff') or contains(s, 'runeshield')
        or contains(s, 'dichoshield') or contains(s, 'preservation') or contains(s, 'steelproc')
        or contains(s, 'blessingproc') or contains(s, 'healburn') then
      return spell .. '|Me'
    end
    if contains(s, 'familiar') or contains(s, 'selfhp') or contains(s, 'selfrune') or contains(s, 'selfspellshield')
        or contains(s, 'lich') or contains(s, 'fleshbuff') or contains(s, 'bestowbuff') or contains(s, 'skin') then
      return spell .. '|Me'
    end
  end
  return spell
end

local function is_group_heal(spell, source)
  local s = tostring(source or ''):lower()
  local n = tostring(spell or ''):lower()
  return s:find('groupheal', 1, true) ~= nil
      or s:find('aespiritualheal', 1, true) ~= nil
      or s:find('splash', 1, true) ~= nil
      or s:find('wave', 1, true) ~= nil
      or n:find('word of ', 1, true) ~= nil
      or n:find('syllable', 1, true) ~= nil
end

local function source_key(source)
  return tostring(source or ''):lower():gsub('[^a-z0-9]', '')
end

local C = {
  group_injured_80 = 'mq.TLO.Group.Injured(80)() >= 3',
  combat = "mq.TLO.Me.CombatState() == \"COMBAT\"",
  resting = "mq.TLO.Me.CombatState() == \"RESTING\"",
  target_slow_missing = 'mq.TLO.Target.Slowed.ID() == 0',
  target_beneficial = 'mq.TLO.Target.Beneficial.ID() > 0',
  target_named = 'mq.TLO.Target.Named() == true',
  target_aggro_80 = 'mq.TLO.Target.PctAggro() > 80',
  target_not_targeting_me = 'mq.TLO.Me.TargetOfTarget.ID() ~= mq.TLO.Me.ID()',
  target_named_or_mana = 'mq.TLO.Target.Named() == true or mq.TLO.Me.PctMana() < 80',
  target_named_or_adds = 'mq.TLO.Target.Named() == true or mq.TLO.Me.XTarget() >= 3',
  target_npc = 'mq.TLO.Target.Type() == "NPC"',
  pet_exists = 'mq.TLO.Me.Pet.ID() > 0',
  twincast_ready = 'mq.TLO.Me.Buff("Twincast")() == nil and mq.TLO.Target.PctHPs() > 10',
  gambit = 'mq.TLO.Me.PctMana() < 80 and mq.TLO.Target.PctHPs() >= 30 and mq.TLO.Target.PctHPs() <= 99',
  dot = 'mq.TLO.Me.PctMana() > 50 and mq.TLO.Target.PctHPs() > 70',
  ethereal = 'mq.TLO.Me.PctMana() > 30 and mq.TLO.Target.PctHPs() > 20',
  nuke = 'mq.TLO.Me.PctMana() > 20 and mq.TLO.Target.PctHPs() > 10',
  mana_vs_target_hp = 'mq.TLO.Me.PctMana() > mq.TLO.Target.PctHPs()',
  canni = 'mq.TLO.Me.PctMana() < 70 and mq.TLO.Me.PctHPs() > 60',
  harvest = 'mq.TLO.Me.PctMana() < 75',
}

local function entry_condition(section, spell, source)
  local sk = source_key(source)
  if section == 'heals' and is_group_heal(spell, source) then
    return C.group_injured_80
  elseif section == 'heals' then
    if sk == 'pethealspell' then return C.pet_exists end
    if sk == 'aespiritualheal' then return C.group_injured_80 end
    if sk == 'interventionheal' then return C.combat end
    if sk == 'innerrejuvenation' then return C.resting end
  elseif section == 'dps' then
    if sk == 'slowspell' or sk == 'diseaseslow' or sk == 'aeslowspell' then return C.target_slow_missing end
    if sk == 'cripslowspell' or sk == 'tashspell' then return 'TRUE' end
    if sk == 'dispel' then return C.target_beneficial end
    if sk == 'gambitspell' then return C.gambit end
    if sk == 'twincastspell' then return C.twincast_ready end
    if sk == 'joltspell' then return C.target_aggro_80 end
    if sk == 'blooddot' or sk == 'colddot' or sk == 'endemicdot'
        or sk == 'afflictiondot' or sk == 'chaoticdot' or sk == 'cursedot1' or sk == 'cursedot2'
        or sk == 'malodot' or sk == 'nectardot' or sk == 'pandemicdot' or sk == 'saryrndot'
        or sk == 'ultordot' then
      return C.dot
    end
    if sk == 'swarmpet' or sk == 'furydisc' or sk == 'dmgmoddisc' or sk == 'bestialbuffdisc' then
      return C.target_named
    end
    if sk == 'dichospell' then return C.target_named_or_mana end
    if sk == 'primaryburndisc' or sk == 'cleavingdisc' or sk == 'discondisc'
        or sk == 'resolvedisc' or sk == 'flurrydisc' or sk == 'phantom'
        or sk == 'alliance' or sk == 'aimdisc' or sk == 'executioner'
        or sk == 'frenzied' or sk == 'twisted' or sk == 'knifeplay'
        or sk == 'edgedisc' or sk == 'aspdisc' or sk == 'markdisc'
        or sk == 'cadisc' then
      return C.target_named
    end
    if sk == 'jarringstrike' or sk == 'hatedebuff' then return C.target_aggro_80 end
    if sk == 'malospell' or sk == 'aemalospell' then return 'TRUE' end
    if sk == 'malodebuff' or sk == 'scentdebuff' or sk == 'rodebuff'
        or sk == 'frostdebuff' or sk == 'icebreathdebuff' then return 'TRUE' end
    if sk == 'snaredot' or sk == 'snarespell' or sk == 'snarespells' then return 'mq.TLO.Target.Snared.ID() == 0' end
    if sk == 'aetaunt' or sk == 'aggrorune' or sk == 'runeshield' or sk == 'dichoshield'
        or sk == 'standdisc' or sk == 'defensedisc' or sk == 'earthdisc'
        or sk == 'absorbdisc' or sk == 'absorbtaunt' then
      return C.target_named_or_adds
    end
    if sk == 'healtaunt' or sk == 'healhatesingle' or sk == 'healhateae'
        or sk == 'aggrokick' or sk == 'shieldhit' or sk == 'tonguedisc' then
      return C.target_npc
    end
    if sk == 'cranestance' or sk == 'curse' or sk == 'dicho' or sk == 'fang'
        or sk == 'fistdisc' or sk == 'fists' or sk == 'fistsofwu' or sk == 'heel'
        or sk == 'palm' or sk == 'poise' or sk == 'precision1' or sk == 'precision2'
        or sk == 'precision3' or sk == 'precision4' or sk == 'precision5'
      or sk == 'shuriken' or sk == 'speed' or sk == 'storm' or sk == 'synergy'
      or sk == 'dicho'
        or sk == 'dfrenzy' or sk == 'bfrenzy' or sk == 'dvolley'
        or sk == 'daxethrow' or sk == 'daxeof' or sk == 'ragestrike'
        or sk == 'cheapshot' or sk == 'sappingstrike' or sk == 'snaredisc'
        or sk == 'aevicious' or sk == 'aeslice' or sk == 'fellstrike'
        or sk == 'sneakattack' or sk == 'jugular' or sk == 'slice'
        or sk == 'ambush' or sk == 'pinpoint' or sk == 'puncture'
        or sk == 'secretblade' or sk == 'poisonblade' or sk == 'daggerthrow' then
      return C.target_not_targeting_me
    end
    if sk == 'fireetherealnuke' or sk == 'iceetherealnuke' or sk == 'magicetherealnuke'
        or sk == 'fusenuke' or sk == 'bigfirenuke' or sk == 'bigicenuke' or sk == 'bigmagicnuke' then
      return C.ethereal
    end
    if sk == 'magicnuke' and (contains(spell, 'mind') or contains(spell, 'spectral')
        or contains(spell, 'chromatic') or contains(spell, 'chaos') or contains(spell, 'psychosis')
        or contains(spell, 'madness') or contains(spell, 'insanity') or contains(spell, 'dement')
        or contains(spell, 'discordant') or contains(spell, 'anarchy')) then
      return C.mana_vs_target_hp
    end
    if sk == 'aebeam' or sk == 'pbflame' or sk == 'pbtimer4' then return 'mq.TLO.Me.XTarget() >= 3' end
    if sk:find('nuke', 1, true) or sk:find('claw', 1, true) then
      return C.nuke
    end
  elseif section == 'buffs' then
    if sk == 'harvestspell' then return C.harvest end
    if sk == 'cannispell' then return C.canni end
  end
  return nil
end

local PET_BUFF_SOURCES = {
  petblockauspice = true,
  petblockspell = true,
  petdamageproc = true,
  petdefensebuff = true,
  petgroupendregenproc = true,
  petgrowl = true,
  pethaste = true,
  pethealproc = true,
  petoffensebuff = true,
  petslowproc = true,
  petspellguard = true,
}

local function is_pet_spell_source(source)
  return source_key(source) == 'petspell'
end

local function is_mez_source(source)
  local sk = source_key(source)
  return sk == 'mezspell' or sk == 'mezspellfast'
      or sk == 'mezaespell' or sk == 'mezaespellfast' or sk == 'mezpbaespell'
end

local function is_ignored_source(source)
  local sk = source_key(source)
  return sk == 'rezspell'
end

local function apply_mez(cfg, gem, changed)
  local sk = source_key(gem.source)
  local sec = ensure(cfg, 'Mez')
  if blank(sec.MezOn) or tostring(sec.MezOn) == '0' then sec.MezOn = 1 end
  if blank(sec.MezRadius) then sec.MezRadius = 100 end
  if blank(sec.MezMinLevel) then sec.MezMinLevel = 1 end
  if blank(sec.MezStopHPs) then sec.MezStopHPs = 1 end

  if sk == 'mezaespell' or sk == 'mezaespellfast' or sk == 'mezpbaespell' then
    if blank(sec.MezAESpell) then
      sec.MezAESpell = gem.name .. '|2'
      changed[#changed + 1] = { section = 'Mez', key = 'MezAESpell', value = sec.MezAESpell, source = gem.source }
    end
  elseif blank(sec.MezSpell) then
    sec.MezSpell = gem.name
    changed[#changed + 1] = { section = 'Mez', key = 'MezSpell', value = sec.MezSpell, source = gem.source }
  end
end

local function classify(gem)
  local source = tostring(gem.source or '')
  local spell = tostring(gem.name or '')
  local s = source:lower()
  local n = spell:lower()
  local no_cure_source = s:find('nocure', 1, true) ~= nil
  if (s:find('cure', 1, true) and not no_cure_source) or n:find('cure', 1, true) then return 'cures' end
  local sk = source_key(source)
  if s:find('petbuff', 1, true) or PET_BUFF_SOURCES[sk] then return 'petbuffs' end
  if sk == 'endregen' or sk == 'combatendregen' or sk == 'breaths' then return 'buffs' end
  if sk == 'frenzyboost' then return 'buffs' end
  if sk == 'healtaunt' then return 'dps' end
  if sk == 'yaulpspell' or sk == 'lichspell' or sk == 'fleshbuff' or sk == 'bestowbuff'
      or sk == 'reptilecombatinnate' or sk == 'preservation' or sk == 'temphp'
      or sk == 'steelproc' or sk == 'blessingproc' or sk == 'healburn' or sk == 'skin' then
    return 'buffs'
  end
  if sk == 'malodebuff' or sk == 'scentdebuff' or sk == 'rodebuff' or sk == 'frostdebuff'
      or sk == 'icebreathdebuff' or sk == 'snaredot' or sk == 'snarespell' or sk == 'snarespells' then
    return 'dps'
  end
  if sk == 'aggrorune' or sk == 'gathermana' or sk == 'groupauspicebuff' or sk == 'groupdotshield'
      or sk == 'grouprune' or sk == 'groupspellshield' or sk == 'learnersaura'
      or sk == 'manaregen' or sk == 'mezbuff' or sk == 'ndtbuff'
      or sk == 'selfguardshield' or sk == 'singledotshield' or sk == 'singlemeleeshield'
      or sk == 'singlerune' or sk == 'singlespellshield' or sk == 'spellprocaura'
      or sk == 'spellprocbuff' or sk == 'twincastaura' or sk == 'unityrune' then
    return 'buffs'
  end
  if sk == 'cannispell' or sk == 'groupfocusspell' or sk == 'groupregenbuff'
      or sk == 'grouphealprocbuff' or sk == 'hastebuff' or sk == 'lowlvlagibuff'
      or sk == 'lowlvlatkbuff' or sk == 'lowlvldexbuff' or sk == 'lowlvlhpbuff'
      or sk == 'lowlvlstabuff' or sk == 'lowlvlstrbuff' or sk == 'meleeprocbuff'
      or sk == 'packselfbuff' or sk == 'runspeedbuff' or sk == 'singleregenbuff'
      or sk == 'slowprocbuff' or sk == 'temphpbuff' or sk == 'unitybuff' or sk == 'wardbuff' then
    return 'buffs'
  end
  if sk == 'mend' or sk == 'innerrejuvenation' then return 'heals' end
  if s:find('heal', 1, true) or s:find('remedy', 1, true) or s:find('renewal', 1, true)
      or s:find('elixir', 1, true) or s:find('complete', 1, true) or s:find('clutch', 1, true)
      or n:find('heal', 1, true) or n:find('remedy', 1, true) or n:find('renewal', 1, true)
      or n:find('word of ', 1, true) or n:find('syllable', 1, true) then
    return 'heals'
  end
  if sk == 'harvestspell' or sk == 'familiarbuff' or sk == 'selfhpbuff'
      or sk == 'selfrune1' or sk == 'selfspellshield1' then
    return 'buffs'
  end
  if s:find('buff', 1, true) or s:find('aura', 1, true) or s:find('armor', 1, true)
      or s:find('symbol', 1, true) or s:find('aego', 1, true) or s:find('vie', 1, true)
      or s:find('shining', 1, true) or s:find('skin', 1, true) or s:find('rune', 1, true)
      or s:find('haste', 1, true) or s:find('regen', 1, true) or s:find('lich', 1, true)
      or s:find('shield', 1, true)
      or n:find('armor', 1, true) or n:find('shield', 1, true) or n:find('symbol', 1, true) or n:find('aegolism', 1, true) then
    return 'buffs'
  end
  return 'dps'
end

local function list_has_spell(sec, prefix, maxn, spell)
  local want = tostring(spell or ''):lower()
  for i = 1, maxn do
    local raw = sec[prefix .. i]
    local first = tostring(raw or ''):match('^([^|]+)') or ''
    if first:lower() == want then return true end
  end
  return false
end

local function next_slot(sec, def)
  local size = tonumber(sec[def.size]) or 0
  local maxn = math.max(size, 0)
  for i = 1, math.max(size, def.max) do
    if blank(sec[def.prefix .. i]) then return i, size end
  end
  if maxn < def.max then return maxn + 1, size end
  return nil, size
end

function persist.apply_fill_empty_lists(cfg, resolved)
  local changed = {}
  for _, gem in ipairs((resolved and resolved.gems) or {}) do
    if not blank(gem.name) then
      if is_ignored_source(gem.source) then
        -- Rez spells belong to manual/rez-specific config, not DPS or buff rotations.
      elseif is_pet_spell_source(gem.source) then
        local pet_sec = ensure(cfg, 'Pet')
        if blank(pet_sec.PetSpell) then
          pet_sec.PetSpell = gem.name
          pet_sec.PetOn = 1
          changed[#changed + 1] = { section = 'Pet', key = 'PetSpell', value = gem.name, source = gem.source }
        end
      elseif is_mez_source(gem.source) then
        apply_mez(cfg, gem, changed)
      else
        local kind = classify(gem)
        local def = LISTS[kind]
        local sec = ensure(cfg, def.section)
        if not list_has_spell(sec, def.prefix, def.max, gem.name) then
          local slot, old_size = next_slot(sec, def)
          if slot then
            local key = def.prefix .. slot
            sec[key] = entry_text(kind, gem.name, gem.source)
            if def.cond then
              local cond_key = def.cond .. slot
              local cond_text = entry_condition(kind, gem.name, gem.source)
              if cond_text and blank(sec[cond_key]) then sec[cond_key] = cond_text end
            end
            if slot > old_size then sec[def.size] = slot end
            if def.on and (blank(sec[def.on]) or tostring(sec[def.on]) == '0') then sec[def.on] = 1 end
            changed[#changed + 1] = { section = def.section, key = key, value = sec[key], source = gem.source }
          end
        end
      end
    end
  end
  return changed
end

function persist.write_cache(cfg, resolved, current_gems)
  local sec = ensure(cfg, 'AutoClassCache')
  for key in pairs(sec) do
    if key:match('^Gem%d+') then sec[key] = nil end
  end

  sec.Family = resolved and resolved.family or ''
  sec.Class = resolved and resolved.class or ''
  sec.Level = tostring((resolved and resolved.level) or 0)
  sec.Mode = resolved and resolved.mode or ''
  sec.LastScan = os.date('%Y-%m-%d %H:%M:%S')
  sec.GemCount = tostring(#((resolved and resolved.gems) or {}))

  local current = current_gems or {}
  for _, gem in ipairs((resolved and resolved.gems) or {}) do
    local idx = tonumber(gem.gem) or 0
    if idx > 0 then
      local prefix = 'Gem' .. idx
      sec[prefix .. 'Resolved'] = gem.name or ''
      sec[prefix .. 'Source'] = gem.source or ''
      local cur = current[idx]
      if not blank(cur) and tostring(cur) ~= tostring(gem.name or '') then
        sec[prefix .. 'Suggestion'] = gem.name or ''
      end
    end
  end
end

persist.blank = blank

return persist
