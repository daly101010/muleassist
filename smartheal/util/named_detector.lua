local mq = require('mq')

local M = {}

M.settings = nil

local RESULT_TTL_MS = 750
local PLUGIN_TTL_MS = 3000
local _resultCache = {}
local _pluginCache = {}
local _customRaw = nil
local _customSet = {}
local _lastPrune = 0

local function normalizeName(value)
    value = tostring(value or '')
    value = value:gsub('_', ' ')
    value = value:gsub('^%s+', ''):gsub('%s+$', '')
    return value:lower()
end

local function customNameSet(settings)
    local raw = tostring((settings and settings.NamedDetectionCustomNames) or '')
    if raw == _customRaw then return _customSet end
    local set = {}
    for token in raw:gmatch('[^,]+') do
        local name = normalizeName(token)
        if name ~= '' then set[name] = true end
    end
    _customRaw = raw
    _customSet = set
    return _customSet
end

local function pluginLoaded(name)
    local now = mq.gettime()
    local cached = _pluginCache[name]
    if cached and (now - cached.at) < PLUGIN_TTL_MS then
        return cached.loaded
    end
    local ok, loaded = pcall(function()
        local plugin = mq.TLO.Plugin(name)
        if not plugin then return false end
        if plugin.IsLoaded then return plugin.IsLoaded() == true end
        return plugin() == true
    end)
    loaded = ok and loaded == true
    _pluginCache[name] = { loaded = loaded, at = now }
    return loaded
end

local function spawnMasterHas(spawn)
    if not spawn or not spawn() or not spawn.ID then return false end
    local id = tonumber(spawn.ID()) or 0
    if id <= 0 then return false end
    local ok, result = pcall(function()
        if not mq.TLO.SpawnMaster or not mq.TLO.SpawnMaster.HasSpawn then return false end
        return mq.TLO.SpawnMaster.HasSpawn(id)() == true
    end)
    return ok and result == true
end

local function alertMasterHas(spawn)
    if not spawn or not spawn() then return false end
    local displayName = spawn.DisplayName and spawn.DisplayName() or spawn.CleanName()
    if not displayName or displayName == '' then return false end
    local ok, result = pcall(function()
        if not mq.TLO.AlertMaster or not mq.TLO.AlertMaster.IsNamed then return false end
        return mq.TLO.AlertMaster.IsNamed(displayName)() == true
    end)
    return ok and result == true
end

function M.init(settings)
    M.settings = settings
    _resultCache = {}
    _pluginCache = {}
    _customRaw = nil
    _customSet = {}
    _lastPrune = 0
end

function M.isNamed(spawn, settings)
    settings = settings or M.settings or {}
    if not spawn or not spawn() then return false end

    local id = spawn.ID and (tonumber(spawn.ID()) or 0) or 0
    local cleanName = normalizeName(spawn.CleanName and spawn.CleanName() or spawn.Name())
    local rawName = normalizeName(spawn.Name and spawn.Name() or cleanName)
    local signature = table.concat({
        tostring(settings.NamedDetectionMinLevel or 0),
        tostring(settings.NamedDetectionForceNamed == true),
        tostring(settings.NamedDetectionUseSpawnMaster ~= false),
        tostring(settings.NamedDetectionUseAlertMaster ~= false),
        tostring(settings.NamedDetectionCustomNames or ''),
    }, '|')
    local cacheKey = tostring(id) .. '|' .. cleanName .. '|' .. rawName .. '|' .. signature
    local now = mq.gettime()
    if (now - _lastPrune) >= 5000 then
        for key, entry in pairs(_resultCache) do
            if (now - entry.at) >= RESULT_TTL_MS then _resultCache[key] = nil end
        end
        _lastPrune = now
    end
    local cached = _resultCache[cacheKey]
    if cached and (now - cached.at) < RESULT_TTL_MS then return cached.value end

    local function finish(value)
        value = value == true
        _resultCache[cacheKey] = { value = value, at = now }
        return value
    end

    local minLevel = tonumber(settings.NamedDetectionMinLevel) or 0
    if minLevel > 0 and spawn.Level and (tonumber(spawn.Level()) or 0) < minLevel then
        return finish(false)
    end

    if settings.NamedDetectionForceNamed == true then return finish(true) end

    if spawn.Named and spawn.Named() == true then return finish(true) end

    local body = spawn.Body and spawn.Body() or ''
    if body == 'Giant' then return finish(true) end

    local custom = customNameSet(settings)
    if custom[cleanName] or custom[rawName] then return finish(true) end

    if settings.NamedDetectionUseSpawnMaster ~= false then
        if pluginLoaded('MQ2SpawnMaster') and spawnMasterHas(spawn) then return finish(true) end
    end

    if settings.NamedDetectionUseAlertMaster ~= false and alertMasterHas(spawn) then
        return finish(true)
    end

    return finish(false)
end

return M
