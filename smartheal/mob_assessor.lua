-- healing/mob_assessor.lua
-- Detects named mobs and their difficulty tier via /consider
-- Scans on zone-in and periodically when out of combat

local mq = require('mq')
local lazy = require('smartheal.util.lazy_require')
local NamedDetector = require('smartheal.util.named_detector')

local M = {}

-- Lazy-load Logger
local getLogger = lazy.once('smartheal.logger')

-- Lazy-load Buff module for isBuffingActive check
local getBuff = lazy.once('smartheal.util.automation.buff')

local getCore = lazy.once('smartheal.util.core')

-- Configuration
local Config = {
    scanIntervalMs = 60000,       -- Rescan interval when idle (60 seconds)
    considerTimeoutMs = 2000,     -- Timeout waiting for consider result
    targetDelayMs = 200,          -- Delay after targeting before consider
    defaultNamedMultiplier = 1.3, -- Multiplier for named mobs without consider data
}

local function isNamedSpawn(spawn)
    local Core = getCore()
    local settings = Core and Core.Settings or nil
    return NamedDetector.isNamed(spawn, settings)
end

-- Consider tier definitions (ordered from hardest to easiest)
-- Multipliers represent expected DPS scaling relative to a normal mob
local CONSIDER_TIERS = {
    { pattern = "would take an army to defeat", tier = "raid", multiplier = 5.0, color = {1.0, 0.2, 0.2, 1.0} },
    { pattern = "would be an almost impossible", tier = "impossible", multiplier = 3.5, color = {1.0, 0.4, 0.1, 1.0} },
    { pattern = "would be an extremely difficult", tier = "extreme", multiplier = 2.5, color = {1.0, 0.6, 0.1, 1.0} },
    { pattern = "would be a difficult", tier = "difficult", multiplier = 2.0, color = {0.9, 0.9, 0.2, 1.0} },
    { pattern = "appears to be quite formidable", tier = "formidable", multiplier = 1.5, color = {0.8, 0.8, 0.4, 1.0} },
    { pattern = "could be easily taken down", tier = "easy", multiplier = 1.0, color = {0.4, 0.9, 0.4, 1.0} },
    { pattern = "would be an even match", tier = "even", multiplier = 1.2, color = {0.6, 0.8, 0.6, 1.0} },
}

-- State
local _mobCache = {}          -- mobName -> { tier, multiplier, level, lastConsidered, manual }
local _considerQueue = {}     -- List of mob names to consider
local _pendingConsider = nil  -- Mob name currently waiting for consider result
local _lastZoneId = nil
local _lastZoneShortName = nil
local _lastScan = 0
local _eventsRegistered = false
local _dirty = false          -- Track if cache has unsaved changes
local _allZoneData = {}       -- All zone data loaded from file: { [zoneName] = { [mobName] = data } }
local _dataLoaded = false     -- Track if we've loaded the data file
local _lastAutoSave = 0       -- Track last auto-save time
local AUTO_SAVE_INTERVAL_MS = 30000  -- Auto-save every 30 seconds when dirty

-- Safe zones to skip scanning (non-combat zones)
local SAFE_ZONES = {
    ['guildlobby'] = true,
    ['guildhall'] = true,
    ['poknowledge'] = true,
    ['potranquility'] = true,
    ['nexus'] = true,
    ['bazaar'] = true,
    ['barter'] = true,
    ['neighborhood'] = true,
    ['crescent'] = true,       -- Crescent Reach (newbie)
    ['tutorial'] = true,
    ['tutoriala'] = true,
    ['tutorialb'] = true,
}

-- ============================================================================
-- Persistence (single file for all zones)
-- ============================================================================

local function getDataFilePath()
    return require('smartheal.util.paths').getMobAssessorPath()
end

local function serializeValue(v, indent)
    indent = indent or ''
    local t = type(v)
    if t == 'string' then
        return string.format('%q', v)
    elseif t == 'number' then
        return tostring(v)
    elseif t == 'boolean' then
        return tostring(v)
    elseif t == 'table' then
        local parts = {}
        for k, val in pairs(v) do
            local key
            if type(k) == 'string' then
                if k:match('^[%a_][%w_]*$') then
                    key = k
                else
                    key = string.format('[%q]', k)
                end
            else
                key = string.format('[%s]', tostring(k))
            end
            table.insert(parts, string.format('%s    %s = %s,', indent, key, serializeValue(val, indent .. '    ')))
        end
        if #parts == 0 then
            return '{}'
        end
        return '{\n' .. table.concat(parts, '\n') .. '\n' .. indent .. '}'
    end
    return 'nil'
end

-- Check if current zone is a safe zone (skip scanning)
function M.isSafeZone(zoneShortName)
    zoneShortName = zoneShortName or mq.TLO.Zone.ShortName() or ''
    return SAFE_ZONES[zoneShortName:lower()] == true
end

-- Save all zone data to single file
function M.saveAllData()
    local path = getDataFilePath()
    local log = getLogger()

    -- Update current zone data in _allZoneData before saving
    local zoneShortName = _lastZoneShortName or mq.TLO.Zone.ShortName() or 'unknown'
    if zoneShortName and zoneShortName ~= '' then
        _allZoneData[zoneShortName] = _allZoneData[zoneShortName] or {}

        -- Merge current cache into zone data
        for name, data in pairs(_mobCache) do
            -- Save if: manually edited OR successfully considered (not timeout/pending)
            if data.manual or (data.tier and data.tier ~= 'timeout' and data.tier ~= 'named_pending') then
                _allZoneData[zoneShortName][name] = {
                    tier = data.tier,
                    multiplier = data.multiplier,
                    level = data.level,
                    manual = data.manual or false,
                }
            end
        end

        -- Remove empty zone entries
        local zoneCount = 0
        for _ in pairs(_allZoneData[zoneShortName]) do zoneCount = zoneCount + 1 end
        if zoneCount == 0 then
            _allZoneData[zoneShortName] = nil
        end
    end

    -- Count total entries
    local totalCount = 0
    local zoneCount = 0
    for zoneName, zoneData in pairs(_allZoneData) do
        zoneCount = zoneCount + 1
        for _ in pairs(zoneData) do
            totalCount = totalCount + 1
        end
    end

    if totalCount == 0 then
        if log then
            log.debug('mob_assessor', 'No data to save')
        end
        return false
    end

    local content = '-- SideKick MobAssessor Data\n'
        .. '-- Named mob difficulty tiers across all zones\n'
        .. '-- Format: { [zoneName] = { [mobName] = { tier, multiplier, level, manual } } }\n'
        .. 'return ' .. serializeValue(_allZoneData) .. '\n'

    local safeWrite = require('smartheal.util.safe_write')
    local ok, err = safeWrite(path, content)
    if not ok then
        if log then
            log.error('mob_assessor', 'Failed to save data: %s', tostring(err))
        end
        return false
    end

    _dirty = false

    if log then
        log.info('mob_assessor', 'Saved %d mobs across %d zones to %s', totalCount, zoneCount, path)
    end

    return true
end

-- Load all zone data from file
function M.loadAllData()
    if _dataLoaded then return true end

    local path = getDataFilePath()
    local log = getLogger()

    local file = io.open(path, 'r')
    if not file then
        if log then
            log.debug('mob_assessor', 'No saved data file found')
        end
        _dataLoaded = true
        return false
    end

    local content = file:read('*a')
    file:close()

    local fn, err = load(content, path, 't', {})
    if not fn then
        if log then
            log.error('mob_assessor', 'Failed to parse data file: %s', err)
        end
        _dataLoaded = true
        return false
    end

    local ok, data = pcall(fn)
    if not ok or type(data) ~= 'table' then
        if log then
            log.error('mob_assessor', 'Invalid data file format')
        end
        _dataLoaded = true
        return false
    end

    -- Store all zone data
    _allZoneData = data

    -- Count entries
    local totalCount = 0
    local zoneCount = 0
    for zoneName, zoneData in pairs(_allZoneData) do
        zoneCount = zoneCount + 1
        for _ in pairs(zoneData) do
            totalCount = totalCount + 1
        end
    end

    if log then
        log.info('mob_assessor', 'Loaded %d mobs across %d zones from %s', totalCount, zoneCount, path)
    end

    _dataLoaded = true
    return true
end

-- Load current zone's data from _allZoneData into _mobCache
function M.loadZoneData(zoneShortName)
    zoneShortName = zoneShortName or mq.TLO.Zone.ShortName() or 'unknown'
    local log = getLogger()

    -- Make sure all data is loaded first
    if not _dataLoaded then
        M.loadAllData()
    end

    -- Get zone-specific data
    local zoneData = _allZoneData[zoneShortName]
    if not zoneData then
        if log then
            log.debug('mob_assessor', 'No saved data for zone %s', zoneShortName)
        end
        return false
    end

    -- Load into current cache
    local count = 0
    for name, mobData in pairs(zoneData) do
        _mobCache[name] = {
            tier = mobData.tier or 'unknown',
            multiplier = mobData.multiplier or Config.defaultNamedMultiplier,
            level = mobData.level,
            manual = mobData.manual or false,
            lastConsidered = 0,
            fromFile = true,
        }
        count = count + 1
    end

    if log then
        log.info('mob_assessor', 'Loaded %d mob entries for zone %s', count, zoneShortName)
    end

    M.state.cacheSize = count
    return true
end

-- Backward compatibility alias
function M.saveZoneData()
    return M.saveAllData()
end

-- Update a mob's multiplier manually
function M.setMobMultiplier(mobName, newMultiplier)
    if not mobName or not _mobCache[mobName] then
        return false
    end

    _mobCache[mobName].multiplier = newMultiplier
    _mobCache[mobName].manual = true
    _dirty = true

    local log = getLogger()
    if log then
        log.info('mob_assessor', 'Manual multiplier set: %s = %.1f', mobName, newMultiplier)
    end

    return true
end

-- Reset a mob to auto-detected values (removes manual flag, queues for reconsider)
function M.resetMobToAuto(mobName)
    if not mobName then return false end

    _mobCache[mobName] = nil
    _dirty = true

    -- Queue for reconsideration
    table.insert(_considerQueue, 1, mobName)
    M.state.queueLength = #_considerQueue

    local log = getLogger()
    if log then
        log.info('mob_assessor', 'Reset to auto: %s (queued for reconsider)', mobName)
    end

    return true
end

-- Check if there are unsaved changes
function M.isDirty()
    return _dirty
end

-- Public state for UI/debugging
M.state = {
    isScanning = false,
    queueLength = 0,
    cacheSize = 0,
    lastScanTime = 0,
    currentZone = nil,
}

function M.init(config)
    if config then
        for k, v in pairs(config) do
            if Config[k] ~= nil then
                Config[k] = v
            end
        end
    end
    M.registerEvents()

    -- Load all data immediately on init
    M.loadAllData()

    -- Initialize zone state and load zone-specific data
    local zoneId = mq.TLO.Zone.ID()
    local zoneName = mq.TLO.Zone.ShortName() or 'unknown'
    if zoneId and zoneId > 0 then
        _lastZoneId = zoneId
        _lastZoneShortName = zoneName
        M.state.currentZone = zoneName
        M.loadZoneData(zoneName)

        local log = getLogger()
        if log then
            log.info('mob_assessor', 'Initialized in zone %s with %d cached mobs', zoneName, M.state.cacheSize)
        end
    end
end

-- Call this when shutting down the script to save any pending data
function M.shutdown()
    if _dirty then
        local log = getLogger()
        if log then
            log.info('mob_assessor', 'Shutdown: saving dirty data')
        end
        M.saveAllData()
    end
end

-- Handle consider result from chat event
function M._handleConsiderResult(line)
    if not _pendingConsider then return end

    local log = getLogger()
    local tier = 'normal'
    local multiplier = Config.defaultNamedMultiplier

    -- Check for tier patterns
    local lineLower = line:lower()
    for _, tierInfo in ipairs(CONSIDER_TIERS) do
        if lineLower:find(tierInfo.pattern:lower(), 1, true) then
            tier = tierInfo.tier
            multiplier = tierInfo.multiplier
            break
        end
    end

    -- Extract level if present (format: "Lvl: 70" or "[Lvl 70]" etc.)
    local level = nil
    local lvlMatch = line:match('[Ll]v[el]*:?%s*(%d+)')
    if lvlMatch then
        level = tonumber(lvlMatch)
    end

    -- Store in cache
    _mobCache[_pendingConsider] = {
        tier = tier,
        multiplier = multiplier,
        level = level,
        lastConsidered = mq.gettime(),
        rawLine = line,
    }

    -- Mark as dirty so it gets saved
    _dirty = true

    if log then
        log.info('mob_assessor', 'Considered %s: tier=%s multiplier=%.1f level=%s',
            _pendingConsider, tier, multiplier, tostring(level))
    end

    _pendingConsider = nil
end

function M.registerEvents()
    if _eventsRegistered then return end
    _eventsRegistered = true

    -- Consider messages have different "stance" phrases before the difficulty
    -- Examples:
    --   "Mob Name scowls at you, ready to attack -- it would take an army to defeat!"
    --   "Mob Name regards you indifferently -- it would take an army to defeat!"
    --   "Mob Name glares at you threateningly -- he appears to be quite formidable."

    -- Capture any consider message that contains difficulty info
    mq.event('MobAssessorArmy', '#*#would take an army to defeat#*#', function(line)
        M._handleConsiderResult(line)
    end)

    mq.event('MobAssessorImpossible', '#*#would be an almost impossible#*#', function(line)
        M._handleConsiderResult(line)
    end)

    mq.event('MobAssessorExtreme', '#*#would be an extremely difficult#*#', function(line)
        M._handleConsiderResult(line)
    end)

    mq.event('MobAssessorDifficult', '#*#would be a difficult#*#', function(line)
        M._handleConsiderResult(line)
    end)

    mq.event('MobAssessorFormidable', '#*#appears to be quite formidable#*#', function(line)
        M._handleConsiderResult(line)
    end)

    mq.event('MobAssessorEasy', '#*#could be easily taken down#*#', function(line)
        M._handleConsiderResult(line)
    end)

    -- Catch-all for other consider messages (even match, etc.)
    mq.event('MobAssessorEvenMatch', '#*#would be an even match#*#', function(line)
        M._handleConsiderResult(line)
    end)

    local log = getLogger()
    if log then
        log.debug('mob_assessor', 'Consider events registered')
    end
end

-- Find all named mobs in the current zone
-- Check if a spawn is likely a combat NPC (not a merchant/quest giver)
local function isLikelyCombatNpc(spawn)
    if not spawn or not spawn() then return false end

    -- Check level - only consider mobs within 3 levels of player
    local myLevel = mq.TLO.Me.Level() or 1
    local mobLevel = spawn.Level and spawn.Level() or 0
    local minLevel = myLevel - 3
    if mobLevel < minLevel then
        return false
    end

    -- Check class - exclude obvious non-combat classes
    local classShort = spawn.Class and spawn.Class.ShortName and spawn.Class.ShortName() or ''
    classShort = classShort:upper()
    local nonCombatClasses = {
        ['SHP'] = true,  -- Shopkeeper
        ['BNK'] = true,  -- Banker
        ['MER'] = true,  -- Merchant (if different from SHP)
        ['ADV'] = true,  -- Adventure Merchant
        ['GLD'] = true,  -- Guild Banker
    }
    if nonCombatClasses[classShort] then
        return false
    end

    -- Check if it's a trader/merchant
    if spawn.Trader and spawn.Trader() then
        return false
    end

    -- Check if untargetable
    if spawn.Targetable and spawn.Targetable() == false then
        return false
    end

    -- Check name for merchant/banker keywords and specific ignored NPCs
    local name = spawn.CleanName and spawn.CleanName() or ''
    local nameLower = name:lower()

    -- Specific NPCs to ignore (exact match)
    local ignoredNames = {
        ['priest of discord'] = true,
        ['agent of change'] = true,
    }
    if ignoredNames[nameLower] then
        return false
    end

    -- Prefix patterns to ignore
    if nameLower:find('^translocator') then
        return false
    end

    local nonCombatNamePatterns = {
        'merchant',
        'banker',
        'vendor',
        'shopkeeper',
        'trader',
        'auctioneer',
        'supplier',
        'provisioner',
    }
    for _, pattern in ipairs(nonCombatNamePatterns) do
        if nameLower:find(pattern, 1, true) then
            return false
        end
    end

    -- Check body type - exclude objects and certain special types
    local bodyType = spawn.Body and spawn.Body.ID and spawn.Body.ID() or 0
    local nonCombatBodies = {
        [0] = true,   -- Unknown/Object
        [21] = true,  -- Object
        [33] = true,  -- Trap
        [66] = true,  -- Node (harvest)
        [67] = true,  -- Object2
    }
    if nonCombatBodies[bodyType] then
        return false
    end

    return true
end

local function findNamedMobs()
    local named = {}
    local count = mq.TLO.SpawnCount('npc')() or 0

    for i = 1, count do
        local spawn = mq.TLO.NearestSpawn(i, 'npc')
        if spawn and spawn() and spawn.ID() > 0 then
            -- Filter to likely combat NPCs only
            if isLikelyCombatNpc(spawn) and isNamedSpawn(spawn) then
                local name = spawn.CleanName()
                local id = spawn.ID()
                if name and name ~= '' then
                    table.insert(named, { name = name, id = id })
                end
            end
        end
    end

    return named
end

-- Start scanning zone for named mobs
function M.startZoneScan()
    local log = getLogger()
    local namedMobs = findNamedMobs()

    _considerQueue = {}
    M.state.isScanning = true

    for _, mob in ipairs(namedMobs) do
        -- Only queue mobs we haven't considered yet
        if not _mobCache[mob.name] then
            table.insert(_considerQueue, mob.name)
        end
    end

    M.state.queueLength = #_considerQueue
    _lastScan = mq.gettime()
    M.state.lastScanTime = _lastScan

    if log then
        log.info('mob_assessor', 'Zone scan started: found %d named, %d new to consider',
            #namedMobs, #_considerQueue)
    end
end

-- Check if it's safe to do targeting/considering
function M.isSafeToConsider()
    local me = mq.TLO.Me
    if not me or not me() then return false end

    -- Not casting (Casting() stringifies to "NULL" when idle)
    local casting = me.Casting()
    if casting and casting ~= '' and casting ~= 'NULL' then
        return false
    end

    -- Not buffing (check buff module state)
    local buff =getBuff()
    if buff and buff.isBuffingActive and buff.isBuffingActive() then
        return false
    end

    -- Not in combat (check XTarget for haters)
    local xtCount = tonumber(me.XTarget()) or 0
    for i = 1, xtCount do
        local xt = me.XTarget(i)
        if xt and xt() and xt.ID() and xt.ID() > 0 then
            local targetType = xt.TargetType and xt.TargetType() or ''
            if targetType:lower():find('hater') then
                return false
            end
        end
    end

    return true
end

-- Process one mob from the consider queue
-- This function blocks (uses mq.delay) so only call when safe
function M.considerNextMob()
    if #_considerQueue == 0 then
        -- Scan complete - save if we have dirty data
        if M.state.isScanning and _dirty then
            local log = getLogger()
            if log then
                log.info('mob_assessor', 'Scan complete, saving data')
            end
            M.saveAllData()
        end
        M.state.isScanning = false
        return false
    end

    local mobName = table.remove(_considerQueue, 1)
    M.state.queueLength = #_considerQueue

    local log = getLogger()

    -- Check if mob still exists in zone
    local spawn = mq.TLO.Spawn(string.format('npc "%s"', mobName))
    if not spawn or not spawn() or spawn.ID() == 0 then
        if log then
            log.debug('mob_assessor', 'Mob no longer in zone: %s', mobName)
        end
        return true -- Continue processing queue
    end

    -- Save current target to restore later
    local previousTarget = mq.TLO.Target.ID() or 0

    -- Target the mob using /mqtar
    mq.cmdf('/mqtar "%s"', mobName)
    mq.delay(Config.targetDelayMs)

    -- Verify we targeted the right mob
    local target = mq.TLO.Target
    if not target or not target() or target.CleanName() ~= mobName then
        if log then
            log.debug('mob_assessor', 'Failed to target: %s', mobName)
        end
        -- Restore previous target if we had one
        if previousTarget > 0 then
            mq.cmdf('/mqtar id %d', previousTarget)
        end
        return true
    end

    -- Issue consider
    _pendingConsider = mobName
    mq.cmd('/consider')

    -- Wait for event to fire (with timeout)
    mq.delay(Config.considerTimeoutMs, function()
        return _pendingConsider == nil
    end)

    -- Handle timeout
    if _pendingConsider then
        if log then
            log.warn('mob_assessor', 'Consider timeout for: %s', mobName)
        end
        _mobCache[_pendingConsider] = {
            tier = 'timeout',
            multiplier = Config.defaultNamedMultiplier,
            lastConsidered = mq.gettime(),
        }
        _pendingConsider = nil
    end

    -- Restore previous target
    if previousTarget > 0 then
        mq.cmdf('/mqtar id %d', previousTarget)
        mq.delay(100)
    else
        -- Clear target if we didn't have one
        mq.cmd('/squelch /target clear')
    end

    M.state.cacheSize = 0
    for _ in pairs(_mobCache) do
        M.state.cacheSize = M.state.cacheSize + 1
    end

    return true -- Continue processing
end

-- Check if safe to do a quick combat consider (relaxed: just not casting)
local function canCombatConsider()
    local me = mq.TLO.Me
    if not me or not me() then return false end

    -- Not casting (critical - don't interrupt heals).
    -- Casting() can stringify to "NULL" when no spell is in flight.
    local casting = me.Casting()
    if casting and casting ~= '' and casting ~= 'NULL' then
        return false
    end

    -- Not buffing (shouldn't happen in combat, but check anyway)
    local buff = getBuff()
    if buff and buff.isBuffingActive and buff.isBuffingActive() then
        return false
    end

    return true
end

-- Check and consider a newly engaged mob if it's a named we haven't assessed
-- Called from combat_assessor when new mobs appear on XTarget
-- Returns: multiplier, tier, wasConsidered
function M.checkEngagedMob(mobId)
    if not mobId or mobId == 0 then
        return 1.0, 'unknown', false
    end

    local spawn = mq.TLO.Spawn(mobId)
    if not spawn or not spawn() then
        return 1.0, 'unknown', false
    end

    local mobName = spawn.CleanName()
    if not mobName or mobName == '' then
        return 1.0, 'unknown', false
    end

    -- Already in cache? Return cached value
    local cached = _mobCache[mobName]
    if cached then
        return cached.multiplier, cached.tier, false
    end

    -- Not a named mob? Skip consider, return normal
    local isNamed = isNamedSpawn(spawn)
    if not isNamed then
        return 1.0, 'normal', false
    end

    -- It's a named mob not in cache - try to consider it now
    local log = getLogger()

    -- Check if we can do a combat consider
    if not canCombatConsider() then
        -- Can't consider right now, queue it for later and return default
        local alreadyQueued = false
        for _, queuedName in ipairs(_considerQueue) do
            if queuedName == mobName then
                alreadyQueued = true
                break
            end
        end
        if not alreadyQueued then
            -- Add to front of queue (priority)
            table.insert(_considerQueue, 1, mobName)
            M.state.queueLength = #_considerQueue
            if log then
                log.debug('mob_assessor', 'Queued engaged named mob (busy): %s', mobName)
            end
        end
        return Config.defaultNamedMultiplier, 'named_pending', false
    end

    -- Do immediate consider
    if log then
        log.info('mob_assessor', 'Combat consider for engaged named: %s', mobName)
    end

    -- Save current target
    local previousTarget = mq.TLO.Target.ID() or 0

    -- Target by ID (faster, more reliable in combat)
    mq.cmdf('/mqtar id %d', mobId)
    mq.delay(Config.targetDelayMs)

    -- Verify target
    local target = mq.TLO.Target
    if not target or not target() or target.ID() ~= mobId then
        if log then
            log.debug('mob_assessor', 'Failed to target engaged mob: %s (id=%d)', mobName, mobId)
        end
        if previousTarget > 0 then
            mq.cmdf('/mqtar id %d', previousTarget)
        end
        -- Queue for later
        table.insert(_considerQueue, 1, mobName)
        M.state.queueLength = #_considerQueue
        return Config.defaultNamedMultiplier, 'named_pending', false
    end

    -- Issue consider
    _pendingConsider = mobName
    mq.cmd('/consider')

    -- Wait for event (shorter timeout in combat)
    mq.delay(1500, function()
        return _pendingConsider == nil
    end)

    -- Handle timeout
    if _pendingConsider then
        if log then
            log.warn('mob_assessor', 'Combat consider timeout: %s', mobName)
        end
        _mobCache[_pendingConsider] = {
            tier = 'timeout',
            multiplier = Config.defaultNamedMultiplier,
            lastConsidered = mq.gettime(),
        }
        _pendingConsider = nil
    end

    -- Restore previous target
    if previousTarget > 0 then
        mq.cmdf('/mqtar id %d', previousTarget)
        mq.delay(50)  -- Shorter delay in combat
    end

    -- Update cache size
    M.state.cacheSize = 0
    for _ in pairs(_mobCache) do
        M.state.cacheSize = M.state.cacheSize + 1
    end

    -- Return the result (should now be cached)
    local result = _mobCache[mobName]
    if result then
        return result.multiplier, result.tier, true
    end

    return Config.defaultNamedMultiplier, 'named_pending', false
end

-- Main tick function - call from healing main loop
function M.tick(opts)
    opts = opts or {}
    local now = mq.gettime()

    -- Zone change detection
    local currentZoneId = mq.TLO.Zone.ID()
    M.state.currentZone = mq.TLO.Zone.ShortName() or 'unknown'

    if currentZoneId ~= _lastZoneId then
        local log = getLogger()
        if log then
            log.info('mob_assessor', 'Zone changed from %s to %s',
                tostring(_lastZoneId), tostring(currentZoneId))
        end

        -- Save current zone data before clearing (if we have previous zone data)
        if _lastZoneShortName and _dirty then
            M.saveAllData()
        end

        _lastZoneId = currentZoneId
        _lastZoneShortName = M.state.currentZone
        _mobCache = {}
        _considerQueue = {}
        _pendingConsider = nil
        _dirty = false

        -- Load saved data for new zone (before scanning)
        M.loadZoneData(_lastZoneShortName)

        -- Skip scanning in safe zones (guild lobby, PoK, etc.)
        if M.isSafeZone(_lastZoneShortName) then
            if log then
                log.debug('mob_assessor', 'Skipping scan in safe zone: %s', _lastZoneShortName)
            end
            M.state.isScanning = false
            return
        end

        -- Start scan (will skip mobs already loaded from file)
        M.startZoneScan()
    end

    -- Skip all processing in safe zones
    if M.isSafeZone(M.state.currentZone) then
        return
    end

    -- Coordinated sensor loops may update/read cached zone facts but must not
    -- target mobs, issue /consider, wait, or restore targets without a lease.
    if opts.readOnly == true then return end

    -- Only process when safe
    if not M.isSafeToConsider() then
        return
    end

    -- Process consider queue if we have items
    if #_considerQueue > 0 then
        M.considerNextMob()
        return
    end

    -- Interval rescan for respawns
    if (now - _lastScan) > Config.scanIntervalMs then
        M.startZoneScan()
    end

    -- Auto-save when dirty (every 30 seconds)
    if _dirty and (now - _lastAutoSave) > AUTO_SAVE_INTERVAL_MS then
        local log = getLogger()
        if log then
            log.debug('mob_assessor', 'Auto-saving dirty data')
        end
        M.saveAllData()
        _lastAutoSave = now
    end
end

-- Get the DPS multiplier for a mob (by name or spawn ID)
-- Returns: multiplier (number), tier (string), isNamed (boolean)
function M.getMobMultiplier(mobNameOrId)
    local name = mobNameOrId
    local spawn = nil

    -- If it's an ID, resolve to name
    if type(mobNameOrId) == 'number' then
        spawn = mq.TLO.Spawn(mobNameOrId)
        if spawn and spawn() then
            name = spawn.CleanName()
        else
            return 1.0, 'unknown', false
        end
    else
        spawn = mq.TLO.Spawn(string.format('npc "%s"', mobNameOrId))
    end

    if not name then
        return 1.0, 'unknown', false
    end

    -- Check cache first
    local cached = _mobCache[name]
    if cached then
        return cached.multiplier, cached.tier, true
    end

    -- Not in cache - check if it's a named mob
    if spawn and spawn() and isNamedSpawn(spawn) then
        -- It's named but we haven't considered it yet
        -- Queue it for consideration if not already queued
        local alreadyQueued = false
        for _, queuedName in ipairs(_considerQueue) do
            if queuedName == name then
                alreadyQueued = true
                break
            end
        end
        if not alreadyQueued then
            table.insert(_considerQueue, name)
            M.state.queueLength = #_considerQueue
        end
        return Config.defaultNamedMultiplier, 'named_pending', true
    end

    -- Regular mob
    return 1.0, 'normal', false
end

-- Get the highest multiplier from all currently engaged mobs
-- mobIds: table of mob IDs from XTarget
function M.getMaxMobMultiplier(mobIds)
    local maxMult = 1.0
    local maxTier = 'normal'
    local hasNamed = false

    for _, mobId in ipairs(mobIds) do
        local mult, tier, isNamed = M.getMobMultiplier(mobId)
        if mult > maxMult then
            maxMult = mult
            maxTier = tier
        end
        if isNamed then
            hasNamed = true
        end
    end

    return maxMult, maxTier, hasNamed
end

-- Check if any raid-tier mobs are in the current fight
function M.hasRaidMob(mobIds)
    for _, mobId in ipairs(mobIds) do
        local _, tier, _ = M.getMobMultiplier(mobId)
        if tier == 'raid' then
            return true
        end
    end
    return false
end

-- Tiers that should be displayed in the UI (actual combat difficulty tiers)
local DISPLAY_TIERS = {
    ['raid'] = true,
    ['impossible'] = true,
    ['extreme'] = true,
    ['difficult'] = true,
    ['formidable'] = true,
    ['easy'] = true,
    ['even'] = true,
}

-- Get all cached mob data (for UI/debugging)
-- If forDisplay is true, only returns mobs with actual combat tiers
function M.getCache(forDisplay)
    local result = {}
    for name, data in pairs(_mobCache) do
        -- Filter for display: only show mobs with meaningful combat tiers
        if forDisplay and not DISPLAY_TIERS[data.tier] and not data.manual then
            -- Skip non-combat tier mobs unless manually edited
        else
            table.insert(result, {
                name = name,
                tier = data.tier,
                multiplier = data.multiplier,
                level = data.level,
                manual = data.manual or false,
                fromFile = data.fromFile or false,
            })
        end
    end
    table.sort(result, function(a, b)
        return a.multiplier > b.multiplier
    end)
    return result
end

-- Force reconsider a specific mob (for manual refresh)
function M.reconsiderMob(mobName)
    _mobCache[mobName] = nil
    table.insert(_considerQueue, 1, mobName) -- Add to front of queue
    M.state.queueLength = #_considerQueue
end

-- Clear cache and rescan
function M.rescan()
    _mobCache = {}
    M.startZoneScan()
end

-- Get tier info for display
function M.getTierInfo()
    return CONSIDER_TIERS
end


return M
