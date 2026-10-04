-- healing/persistence.lua
-- Persistence module for Healing Intelligence learned data
-- Handles save/load of learned heal amounts, cast history, and statistical data

local mq = require('mq')
local lazy = require('smartheal.util.lazy_require')
local Paths = require('smartheal.util.paths')

-- Lazy-load Logger to avoid circular requires
local getLogger = lazy.once('smartheal.logger')

local M = {}

-------------------------------------------------------------------------------
-- Data Structure
-------------------------------------------------------------------------------

-- Learned heal data structure
-- {
--     version = 1,
--     lastSaved = timestamp,
--     spells = {
--         ["SpellName"] = {
--             avgHeal = number,           -- Exponential moving average of heal amount
--             minHeal = number,           -- Minimum observed heal
--             maxHeal = number,           -- Maximum observed heal
--             variance = number,          -- Variance estimate for stddev calculation
--             castCount = number,         -- Total number of casts observed
--             lastCastAt = timestamp,     -- Last time this spell was cast
--             critRate = number,          -- Observed critical heal rate (0.0 to 1.0)
--             avgCastTime = number,       -- Average actual cast time (accounting for haste)
--             targetData = {              -- Per-target-type statistics (optional)
--                 ["tank"] = { avgHeal, castCount },
--                 ["squishy"] = { avgHeal, castCount },
--                 ["normal"] = { avgHeal, castCount },
--             },
--         },
--     },
--     targets = {
--         ["CharacterName"] = {
--             maxHp = number,             -- Last known max HP
--             class = string,             -- Character class
--             lastSeenAt = timestamp,
--         },
--     },
-- }

-- Runtime data store
M.data = {
    version = 1,
    lastSaved = 0,
    spells = {},
    targets = {},
}

-------------------------------------------------------------------------------
-- File Path Helpers
-------------------------------------------------------------------------------

local function getDataPath()
    return Paths.getHealingDataPath()
end

-------------------------------------------------------------------------------
-- Serialization Helpers
-------------------------------------------------------------------------------

local function serializeValue(value, indent)
    indent = indent or ''
    local t = type(value)

    if t == 'nil' then
        return 'nil'
    elseif t == 'boolean' then
        return value and 'true' or 'false'
    elseif t == 'number' then
        -- Handle special float values
        if value ~= value then
            return '0' -- NaN
        elseif value == math.huge then
            return tostring(math.huge)
        elseif value == -math.huge then
            return tostring(-math.huge)
        end
        return tostring(value)
    elseif t == 'string' then
        return string.format('%q', value)
    elseif t == 'table' then
        local lines = {}
        table.insert(lines, '{')
        local nextIndent = indent .. '    '

        -- Check if array-like
        local isArray = true
        local maxIndex = 0
        for k, _ in pairs(value) do
            if type(k) ~= 'number' or k < 1 or math.floor(k) ~= k then
                isArray = false
                break
            end
            if k > maxIndex then maxIndex = k end
        end

        if isArray and maxIndex > 0 then
            for i = 1, maxIndex do
                local v = value[i]
                local comma = i < maxIndex and ',' or ''
                table.insert(lines, nextIndent .. serializeValue(v, nextIndent) .. comma)
            end
        else
            local keys = {}
            for k in pairs(value) do
                table.insert(keys, k)
            end
            table.sort(keys, function(a, b)
                if type(a) == type(b) then
                    return tostring(a) < tostring(b)
                end
                return type(a) < type(b)
            end)
            for i, k in ipairs(keys) do
                local v = value[k]
                local keyStr
                if type(k) == 'string' and k:match('^[%a_][%w_]*$') then
                    keyStr = k
                else
                    keyStr = '[' .. serializeValue(k, nextIndent) .. ']'
                end
                local comma = i < #keys and ',' or ''
                table.insert(lines, nextIndent .. keyStr .. ' = ' .. serializeValue(v, nextIndent) .. comma)
            end
        end
        table.insert(lines, indent .. '}')
        return table.concat(lines, '\n')
    else
        return 'nil -- unsupported type: ' .. t
    end
end

-------------------------------------------------------------------------------
-- Data Validation
-------------------------------------------------------------------------------

local function validateSpellData(spellData)
    if type(spellData) ~= 'table' then return false end
    if type(spellData.avgHeal) ~= 'number' then return false end
    if type(spellData.castCount) ~= 'number' then return false end
    return true
end

local function validateData(data)
    if type(data) ~= 'table' then return false end
    if type(data.version) ~= 'number' then return false end
    if type(data.spells) ~= 'table' then return false end
    return true
end

-------------------------------------------------------------------------------
-- Data Cleanup
-------------------------------------------------------------------------------

--- Remove stale data older than maxAge seconds
-- @param maxAge number Maximum age in seconds (default 7 days)
local function pruneStaleData(maxAge)
    maxAge = maxAge or 604800 -- 7 days default
    local now = os.time()
    local cutoff = now - maxAge

    -- Prune old spell data
    local spellsToRemove = {}
    for spellName, spellData in pairs(M.data.spells) do
        if type(spellData.lastCastAt) == 'number' and spellData.lastCastAt < cutoff then
            table.insert(spellsToRemove, spellName)
        end
    end
    for _, spellName in ipairs(spellsToRemove) do
        M.data.spells[spellName] = nil
    end

    -- Prune old target data
    local targetsToRemove = {}
    for targetName, targetData in pairs(M.data.targets) do
        if type(targetData.lastSeenAt) == 'number' and targetData.lastSeenAt < cutoff then
            table.insert(targetsToRemove, targetName)
        end
    end
    for _, targetName in ipairs(targetsToRemove) do
        M.data.targets[targetName] = nil
    end

    if #spellsToRemove > 0 or #targetsToRemove > 0 then
        local log = getLogger()
        if log then log.info('persistence', 'Pruned %d stale spells, %d stale targets', #spellsToRemove, #targetsToRemove) end
    end
end

-------------------------------------------------------------------------------
-- Public API
-------------------------------------------------------------------------------

--- Load heal data from file
-- @param maxAge number Optional maximum age for data (default 7 days)
-- @return table The loaded heal data
function M.loadHealData(maxAge)
    local log = getLogger()
    local path = getDataPath()
    local file = io.open(path, 'r')

    if file then
        local content = file:read('*all')
        file:close()

        if content and content ~= '' then
            local fn, err = load('return ' .. content, 'healdata', 't', {})
            if fn then
                local ok, loaded = pcall(fn)
                if ok and validateData(loaded) then
                    M.data = loaded
                    -- Ensure required fields exist
                    M.data.spells = M.data.spells or {}
                    M.data.targets = M.data.targets or {}

                    -- Prune stale data
                    pruneStaleData(maxAge)

                    if log then log.info('persistence', 'Loaded heal data from %s (%d spells, %d targets)',
                        path, M.countSpells(), M.countTargets()) end
                else
                    if log then log.error('persistence', 'Heal data parse error: %s', tostring(loaded)) end
                    M.data = { version = 1, lastSaved = 0, spells = {}, targets = {} }
                end
            else
                if log then log.error('persistence', 'Heal data load error: %s', tostring(err)) end
                M.data = { version = 1, lastSaved = 0, spells = {}, targets = {} }
            end
        else
            M.data = { version = 1, lastSaved = 0, spells = {}, targets = {} }
        end
    else
        if log then log.info('persistence', 'No heal data found, starting fresh') end
        M.data = { version = 1, lastSaved = 0, spells = {}, targets = {} }
    end

    return M.data
end

--- Save heal data to file
-- @param data table Optional data to save (uses M.data if not provided)
-- @return boolean True if save succeeded
function M.saveHealData(data)
    local log = getLogger()
    local path = getDataPath()

    -- Use provided data or fall back to M.data
    local dataToSave = data or M.data

    -- Update timestamp
    dataToSave.lastSaved = os.time()

    local content = serializeValue(dataToSave)

    local safeWrite = require('smartheal.util.safe_write')
    local ok, err = safeWrite(path, content)
    if not ok then
        if log then log.error('persistence', 'Heal data save error: %s', tostring(err)) end
        return false
    end
    if log then log.info('persistence', 'Heal data saved to %s', path) end
    return true
end

--- Get learned data for a spell
-- @param spellName string The spell name
-- @return table|nil Spell data or nil if not found
function M.getSpellData(spellName)
    if not spellName then return nil end
    return M.data.spells[spellName]
end

--- Update learned data for a spell
-- @param spellName string The spell name
-- @param healAmount number The observed heal amount
-- @param castTime number The actual cast time (seconds)
-- @param wasCrit boolean Whether this was a critical heal
-- @param targetType string Optional target type (tank/squishy/normal)
-- @param learningWeight number Optional learning rate (default 0.1, from config.learningWeight)
function M.updateSpellData(spellName, healAmount, castTime, wasCrit, targetType, learningWeight)
    if not spellName or not healAmount then return end

    local alpha = learningWeight or 0.1  -- EMA learning rate (caller passes config.learningWeight)
    local now = os.time()
    local existing = M.data.spells[spellName]

    if not existing then
        -- First observation
        M.data.spells[spellName] = {
            avgHeal = healAmount,
            minHeal = healAmount,
            maxHeal = healAmount,
            variance = 0,
            castCount = 1,
            lastCastAt = now,
            critRate = wasCrit and 1.0 or 0.0,
            avgCastTime = castTime or 0,
            targetData = {},
        }
    else
        -- Update with exponential moving average
        local prevAvg = existing.avgHeal

        -- Update average
        existing.avgHeal = (1 - alpha) * existing.avgHeal + alpha * healAmount

        -- Update min/max
        if healAmount < existing.minHeal then
            existing.minHeal = healAmount
        end
        if healAmount > existing.maxHeal then
            existing.maxHeal = healAmount
        end

        -- Update variance (Welford's online algorithm)
        local delta = healAmount - prevAvg
        local delta2 = healAmount - existing.avgHeal
        existing.variance = (1 - alpha) * existing.variance + alpha * delta * delta2

        -- Update cast count
        existing.castCount = existing.castCount + 1

        -- Update timestamp
        existing.lastCastAt = now

        -- Update crit rate
        if existing.critRate then
            local critVal = wasCrit and 1.0 or 0.0
            existing.critRate = (1 - alpha) * existing.critRate + alpha * critVal
        end

        -- Update cast time
        if castTime and castTime > 0 then
            if existing.avgCastTime and existing.avgCastTime > 0 then
                existing.avgCastTime = (1 - alpha) * existing.avgCastTime + alpha * castTime
            else
                existing.avgCastTime = castTime
            end
        end
    end

    -- Update per-target-type stats if provided
    if targetType then
        local spellData = M.data.spells[spellName]
        spellData.targetData = spellData.targetData or {}
        local td = spellData.targetData[targetType]
        if not td then
            spellData.targetData[targetType] = {
                avgHeal = healAmount,
                castCount = 1,
            }
        else
            td.avgHeal = (1 - alpha) * td.avgHeal + alpha * healAmount
            td.castCount = td.castCount + 1
        end
    end
end

--- Get learned data for a target
-- @param targetName string The target character name
-- @return table|nil Target data or nil if not found
function M.getTargetData(targetName)
    if not targetName then return nil end
    return M.data.targets[targetName]
end

--- Update learned data for a target
-- @param targetName string The target character name
-- @param maxHp number The target's max HP
-- @param class string The target's class
function M.updateTargetData(targetName, maxHp, class)
    if not targetName then return end

    local now = os.time()
    M.data.targets[targetName] = {
        maxHp = maxHp or 0,
        class = class or '',
        lastSeenAt = now,
    }
end

--- Get the expected heal amount for a spell
-- Falls back to spell data if no learned data available
-- @param spellName string The spell name
-- @param targetType string Optional target type for type-specific estimate
-- @return number|nil Expected heal amount or nil
function M.getExpectedHeal(spellName, targetType)
    local data = M.getSpellData(spellName)
    if not data then return nil end

    -- Try target-type specific data first
    if targetType and data.targetData and data.targetData[targetType] then
        local td = data.targetData[targetType]
        if td.castCount and td.castCount >= 5 then
            return td.avgHeal
        end
    end

    -- Fall back to general average
    return data.avgHeal
end

--- Get the standard deviation for a spell's heal amount
-- @param spellName string The spell name
-- @return number Standard deviation (0 if not enough data)
function M.getHealStdDev(spellName)
    local data = M.getSpellData(spellName)
    if not data or not data.variance then return 0 end
    return math.sqrt(data.variance)
end

--- Check if we have enough data to trust learned values
-- @param spellName string The spell name
-- @param minCasts number Minimum casts required (default 5)
-- @return boolean True if learned data is trustworthy
function M.hasReliableData(spellName, minCasts)
    minCasts = minCasts or 5
    local data = M.getSpellData(spellName)
    if not data then return false end
    return (data.castCount or 0) >= minCasts
end

--- Count tracked spells
-- @return number Number of spells with learned data
function M.countSpells()
    local count = 0
    for _ in pairs(M.data.spells) do
        count = count + 1
    end
    return count
end

--- Count tracked targets
-- @return number Number of targets with learned data
function M.countTargets()
    local count = 0
    for _ in pairs(M.data.targets) do
        count = count + 1
    end
    return count
end

--- Clear all learned data
function M.clear()
    M.data = {
        version = 1,
        lastSaved = 0,
        spells = {},
        targets = {},
    }
    local log = getLogger()
    if log then log.info('persistence', 'Learned data cleared') end
end

return M
