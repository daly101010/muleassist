-- muleassist/autoclass/resolver.lua
-- Pure auto-class baseline resolver. No mq dependency: tests can inject a known-spell provider.
local resolver = {}

local function norm(s)
  return tostring(s or ''):lower()
end

local function first_loadout(loadouts)
  local first_name, first_value
  for name, value in pairs(loadouts or {}) do
    if not first_name or tostring(name) < tostring(first_name) then
      first_name, first_value = name, value
    end
  end
  return first_name, first_value
end

local function get_class(data, class_key)
  if not data or not data.classes then return nil end
  return data.classes[norm(class_key)]
end

local function get_loadout(class_data, mode)
  local loadouts = class_data and class_data.loadouts or nil
  if not loadouts then return nil, nil end
  local requested = mode and mode ~= '' and loadouts[mode] or nil
  if requested then return mode, requested end
  if loadouts.Default then return 'Default', loadouts.Default end
  return first_loadout(loadouts)
end

local function provider_info(provider, spell_name)
  if type(provider) ~= 'function' then return nil end
  local ok, info = pcall(provider, spell_name)
  if not ok or not info then return nil end
  if info == true then return { name = spell_name, rank_name = spell_name, level = 0 } end
  if type(info) == 'string' then return { name = info, rank_name = info, level = 0 } end
  if type(info) == 'table' then
    info.name = info.name or spell_name
    info.rank_name = info.rank_name or info.rank or info.name
    info.level = tonumber(info.level) or 0
    return info
  end
  return nil
end

local function already_used(used, info)
  local key = norm(info and (info.rank_name or info.name))
  if key == '' then return false end
  return used[key] == true
end

local function mark_used(used, info)
  local key = norm(info and (info.rank_name or info.name))
  if key ~= '' then used[key] = true end
end

local function best_from_spell_names(spell_names, provider, used)
  local best
  for _, spell_name in ipairs(spell_names or {}) do
    local info = provider_info(provider, spell_name)
    if info and not already_used(used, info) then
      if not best or (info.level or 0) > (best.level or 0) then
        best = info
      end
    end
  end
  return best
end

local function resolve_candidate(class_data, candidate, provider, used)
  local set = class_data.sets and class_data.sets[candidate]
  if set then return best_from_spell_names(set, provider, used) end
  return best_from_spell_names({ candidate }, provider, used)
end

local function resolve_priority(class_data, loadout, provider, gem_count)
  local out, used = {}, {}
  local gem = 1
  for _, candidate in ipairs(loadout.candidates or {}) do
    if gem > gem_count then break end
    local info = resolve_candidate(class_data, candidate, provider, used)
    if info then
      out[#out + 1] = {
        gem = gem,
        name = info.rank_name or info.name,
        source = candidate,
        level = info.level or 0,
      }
      mark_used(used, info)
      gem = gem + 1
    end
  end
  return out
end

local function resolve_gems(class_data, loadout, provider, gem_count)
  local out, used = {}, {}
  for _, entry in ipairs(loadout.gems or {}) do
    local gem = tonumber(entry.gem) or 0
    if gem > 0 and gem <= gem_count then
      for _, candidate in ipairs(entry.candidates or {}) do
        local info = resolve_candidate(class_data, candidate, provider, used)
        if info then
          out[#out + 1] = {
            gem = gem,
            name = info.rank_name or info.name,
            source = candidate,
            level = info.level or 0,
          }
          mark_used(used, info)
          break
        end
      end
    end
  end
  table.sort(out, function(a, b) return a.gem < b.gem end)
  return out
end

function resolver.resolve(data, class_key, level, known_provider, gem_count, mode)
  local class_data = get_class(data, class_key)
  gem_count = tonumber(gem_count) or 0
  if not class_data or gem_count <= 0 then
    return { family = data and data.family or nil, class = norm(class_key), mode = mode, gems = {} }
  end

  local loadout_name, loadout = get_loadout(class_data, mode)
  if not loadout then
    return { family = data and data.family or nil, class = norm(class_key), mode = mode, gems = {} }
  end

  local gems
  if loadout.style == 'priority' then
    gems = resolve_priority(class_data, loadout, known_provider, gem_count)
  else
    gems = resolve_gems(class_data, loadout, known_provider, gem_count)
  end

  return {
    family = data and data.family or nil,
    class = norm(class_key),
    level = tonumber(level) or 0,
    mode = loadout_name,
    gems = gems,
  }
end

return resolver
