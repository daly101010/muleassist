-- muleassist/autoclass.lua
-- MQ runtime wrapper for self-contained AutoClass baseline loadouts and spellset loading.
local mq       = require('mq')
local Write    = require('muleassist.Write')
local config   = require('muleassist.config')
local cast     = require('muleassist.cast')
local live     = require('muleassist.autoclass.live')
local resolver = require('muleassist.autoclass.resolver')
local persist  = require('muleassist.autoclass.persist')

local autoclass = {}

local function trim(s)
  return tostring(s or ''):gsub('^%s*(.-)%s*$', '%1')
end

local function truthy(v)
  if v == nil or v == false then return false end
  if type(v) == 'number' then return v > 0 end
  if type(v) == 'string' then
    local u = trim(v):upper()
    return u ~= '' and u ~= 'FALSE' and u ~= 'NULL' and u ~= '0'
  end
  return true
end

local function safe(label, fn, default)
  local ok, res = pcall(fn)
  if ok then return res end
  Write.Debug('AutoClass %s: %s', label, tostring(res))
  return default
end

local function spell_rank(spell_tlo, fallback)
  return safe('rank', function()
    return spell_tlo.RankName() or spell_tlo.Name() or fallback
  end, fallback)
end

local function known_spell_provider(level)
  level = tonumber(level) or 0
  return function(name)
    local sp = safe('spell', function() return mq.TLO.Spell(name) end, nil)
    if not sp or not safe('spell exists', function() return sp() end, nil) then return nil end
    local spell_level = tonumber(safe('spell level', function() return sp.Level() end, 0)) or 0
    if spell_level > level then return nil end
    local rank = spell_rank(sp, name)
    local in_book = truthy(safe('book rank', function() return mq.TLO.Me.Book(rank)() end, nil))
        or truthy(safe('book base', function() return mq.TLO.Me.Book(name)() end, nil))
    local combat_ability = truthy(safe('combat ability rank', function() return mq.TLO.Me.CombatAbility(rank)() end, nil))
        or truthy(safe('combat ability base', function() return mq.TLO.Me.CombatAbility(name)() end, nil))
    if not in_book and not combat_ability then return nil end
    return {
      name = name,
      rank_name = rank,
      level = spell_level,
      source = in_book and 'book' or 'combat_ability',
    }
  end
end

local function max_gems()
  return tonumber(safe('num gems', function() return mq.TLO.Me.NumGems() end, 8)) or 8
end

local function queue(st, action)
  st.autoclass_rt = st.autoclass_rt or { queue = {} }
  st.autoclass_rt.queue = st.autoclass_rt.queue or {}
  st.autoclass_rt.queue[#st.autoclass_rt.queue + 1] = action
end

local function current_context(st)
  local class_key = trim(safe('class', function() return mq.TLO.Me.Class.ShortName() end, st.autoclass.class or '')):lower()
  local level = tonumber(safe('level', function() return mq.TLO.Me.Level() end, st.autoclass.level or 0)) or 0
  local gems = max_gems()
  local mode = st.autoclass.mode
  return class_key, level, gems, mode
end

function autoclass.scan(st, save_cache)
  local class_key, level, gems, mode = current_context(st)
  local resolved = resolver.resolve(live, class_key, level, known_spell_provider(level), gems, mode)
  if save_cache then
    persist.write_cache(st.cfg, resolved, persist.read_my_spells(st.cfg, gems))
    local ok, err = config.save(st.cfg)
    if not ok then Write.Error('AutoClass cache save failed: %s', tostring(err)) end
  end
  st.autoclass_rt = st.autoclass_rt or { queue = {} }
  st.autoclass_rt.last_resolved = resolved
  return resolved
end

function autoclass.apply(st)
  local gems = max_gems()
  local resolved = autoclass.scan(st, false)
  persist.write_cache(st.cfg, resolved, persist.read_my_spells(st.cfg, gems))
  local list_changed = {}
  if st.autoclass.fill_lists then
    list_changed = persist.apply_fill_empty_lists(st.cfg, resolved)
  end
  if st.autoclass.fill_empty then
    local changed = persist.apply_fill_empty(st.cfg, resolved, gems)
    for _, entry in ipairs(changed) do
      st.my_spells[entry.gem] = entry.name
    end
    local ok, err = config.save(st.cfg)
    if not ok then
      Write.Error('AutoClass apply save failed: %s', tostring(err))
      return false
    end
    Write.Info('AutoClass applied %d empty spell gem%s and %d list entr%s.',
      #changed, #changed == 1 and '' or 's', #list_changed, #list_changed == 1 and 'y' or 'ies')
    if #list_changed > 0 then st.pending_reapply = true; st.pending_ui_reload = true end
    return true
  end

  local ok, err = config.save(st.cfg)
  if not ok then Write.Error('AutoClass cache save failed: %s', tostring(err)); return false end
  Write.Info('AutoClass scan cached. FillEmptyMySpells is off; added %d list entr%s.',
    #list_changed, #list_changed == 1 and 'y' or 'ies')
  if #list_changed > 0 then st.pending_reapply = true; st.pending_ui_reload = true end
  return true
end

function autoclass.status(st)
  local gems = max_gems()
  local resolved = autoclass.scan(st, false)
  local by_gem = {}
  for _, gem in ipairs(resolved.gems or {}) do by_gem[gem.gem] = gem end
  Write.Info('AutoClass: family=%s class=%s mode=%s resolved=%d',
    tostring(resolved.family), tostring(resolved.class), tostring(resolved.mode), #(resolved.gems or {}))
  for i = 1, gems do
    local cur = st.my_spells and st.my_spells[i] or nil
    local gem = by_gem[i]
    if cur or gem then
      local note = (cur and gem and cur ~= gem.name) and ' suggestion' or ''
      Write.Info('  Gem%d current=%s baseline=%s%s',
        i, tostring(cur or ''), tostring(gem and gem.name or ''), note)
    end
  end
end

function autoclass.load_spellset(st)
  local mode = tonumber(st.spellset and st.spellset.load or 0) or 0
  if mode == 0 then return true end
  if mq.TLO.Me.CombatState() == 'COMBAT' then
    st.autoclass_rt = st.autoclass_rt or { queue = {} }
    local now = os.clock()
    if not st.autoclass_rt.last_load_defer or now - st.autoclass_rt.last_load_defer > 15 then
      st.autoclass_rt.last_load_defer = now
      Write.Warn('Spellset load deferred until out of combat.')
    end
    return false
  end

  if mode == 1 then
    local name = trim(st.spellset.name)
    if name == '' or name:upper() == 'NULL' then return true end
    Write.Info('Loading spellset "%s".', name)
    mq.cmdf('/memspellset "%s"', name)
    mq.delay(500)
    return true
  end

  if mode == 2 then
    local gems = max_gems()
    for i = 1, gems do
      local spell = st.my_spells and st.my_spells[i] or nil
      if spell and not persist.blank(spell) then
        cast.mem_spell(spell, i, 0, 'SpellSet')
      end
    end
    return true
  end

  Write.Warn('Unknown LoadSpellSet mode: %s', tostring(mode))
  return true
end

function autoclass.setup(st)
  st.autoclass_rt = st.autoclass_rt or { queue = {} }
  st.autoclass_rt.queue = st.autoclass_rt.queue or {}
  if not st.autoclass_rt.startup_done then
    st.autoclass_rt.startup_done = true
    if st.autoclass.on then queue(st, 'apply') end
    if tonumber(st.spellset and st.spellset.load or 0) ~= 0 then queue(st, 'load') end
  end
end

function autoclass.register(st)
  mq.bind('/maautoclass', function(arg)
    local cmd = trim(arg):match('^(%S+)') or 'status'
    cmd = cmd:lower()
    if cmd == 'scan' or cmd == 'apply' or cmd == 'status' then
      queue(st, cmd)
    elseif cmd == 'load' or cmd == 'loadspellset' then
      queue(st, 'load')
    else
      Write.Warn('Usage: /maautoclass scan|apply|status|load')
    end
  end)
  mq.bind('/maloadspellset', function() queue(st, 'load') end)
end

function autoclass.unregister()
  pcall(mq.unbind, '/maautoclass')
  pcall(mq.unbind, '/maloadspellset')
end

function autoclass.tick(st)
  local rt = st.autoclass_rt
  if not rt or not rt.queue or #rt.queue == 0 then return end
  local action = table.remove(rt.queue, 1)
  if action == 'scan' then
    local resolved = autoclass.scan(st, true)
    Write.Info('AutoClass scan cached %d resolved gem%s.',
      #(resolved.gems or {}), #(resolved.gems or {}) == 1 and '' or 's')
  elseif action == 'apply' then
    autoclass.apply(st)
  elseif action == 'status' then
    autoclass.status(st)
  elseif action == 'load' then
    if not autoclass.load_spellset(st) then
      table.insert(rt.queue, 1, action)
    end
  end
end

return autoclass
