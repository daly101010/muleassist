--- Unified Logger for SideKick
--- Provides leveled logging with console + file output, caller tracing, and filtering.
---
--- Usage:
---   local Logger = require('smartheal.util.logger')
---   local log = Logger.new('MyModule')
---   log.error('Failed to load: %s', err)
---   log.warn('Missing spell: %s', name)
---   log.info('Loaded %d spells', count)
---   log.debug('Checking target %d', id)
---   log.verbose('Cache hit for %s', key)
---
--- Global controls:
---   Logger.setLevel(4)              -- 1=error .. 5=verbose
---   Logger.setFilter('heal|spell')  -- pipe-separated pattern match
---   Logger.setFileLogging(true)     -- enable file output

local mq = require('mq')

local M = {}

-- ============================================================
-- LOG LEVELS
-- ============================================================

local LEVELS = {
    error   = { num = 1, tag = 'ERROR  ', color = '\ar' },
    warn    = { num = 2, tag = 'WARN   ', color = '\ay' },
    info    = { num = 3, tag = 'INFO   ', color = '\ao' },
    debug   = { num = 4, tag = 'DEBUG  ', color = '\am' },
    verbose = { num = 5, tag = 'VERBOSE', color = '\ap' },
}

-- ============================================================
-- GLOBAL STATE
-- ============================================================

local _globalLevel = 3        -- Default: info and above
local _consoleLevel = nil     -- nil = same as _globalLevel
local _fileLevel = nil        -- nil = same as _globalLevel
local _filter = nil           -- nil = no filter
local _fileLogging = false    -- File logging off by default
local _fileHandle = nil       -- Lazy file handle
local _filePath = nil         -- Current log file path
local _fileDate = nil         -- Date for log rotation
local _tracerEnabled = true   -- Caller tracing on by default
local _scriptLabel = 'SK'     -- Short script prefix for console output
local _moduleLevels = {}      -- canonical module name -> 0(off), 1..5

local function monotonicMs()
    local ok, value = pcall(mq.gettime)
    if ok and tonumber(value) then return math.floor(tonumber(value)) end
    return math.floor(os.clock() * 1000)
end

--- Timestamp shared by console and file diagnostics.
--- Wall time is human-readable; mq time is monotonic and lets logs from
--- separate SideKick worker processes be ordered to millisecond precision.
function M.timestamp()
    return string.format('%s|mq:%d', os.date('%H:%M:%S'), monotonicMs())
end

--- MQ-colored timestamp prefix for direct console diagnostics that cannot use
--- the leveled logger (for example explicit /status command responses).
function M.consoleTimestamp()
    return string.format('\aw[%s]\ax', M.timestamp())
end

local KNOWN_MODULES = {
    { key = 'coordinator', label = 'Coordinator' },
    { key = 'emergency', label = 'Emergency' },
    { key = 'support', label = 'Support' },
    { key = 'healing', label = 'Healing' },
    { key = 'cures', label = 'Cures' },
    { key = 'resurrection', label = 'Resurrection' },
    { key = 'cc', label = 'Crowd Control' },
    { key = 'tank', label = 'Tank' },
    { key = 'combat', label = 'Combat' },
    { key = 'pull', label = 'Pull' },
    { key = 'assist', label = 'Assist' },
    { key = 'dps', label = 'DPS' },
    { key = 'items', label = 'Items' },
    { key = 'resources', label = 'Resources' },
    { key = 'maintenance', label = 'Maintenance' },
    { key = 'buffs', label = 'Buffs' },
    { key = 'disciplines', label = 'Disciplines' },
    { key = 'feign', label = 'Feign Safety' },
    { key = 'next_meditation', label = 'Meditation' },
    { key = 'fidget', label = 'Fidget' },
}

local MODULE_ALIASES = {
    rez = 'resurrection',
    resurrection = 'resurrection',
    buff = 'buffs',
    buffs = 'buffs',
    heal = 'healing',
    healing = 'healing',
    med = 'next_meditation',
    meditation = 'next_meditation',
    nextmeditation = 'next_meditation',
    sk_meditation = 'next_meditation',
    skmeditation = 'next_meditation',
    sk_coordinator = 'coordinator',
    skcoordinator = 'coordinator',
}

local LEVEL_NAMES = {
    off = 0,
    error = 1,
    warn = 2,
    warning = 2,
    info = 3,
    debug = 4,
    verbose = 5,
    trace = 5,
}

local function canonicalModuleName(value)
    local name = tostring(value or ''):lower():match('^%s*(.-)%s*$') or ''
    name = name:gsub('[^%w_]', '')
    return MODULE_ALIASES[name] or name
end

local function parseLevel(value)
    if type(value) == 'number' then
        return math.max(0, math.min(5, math.floor(value)))
    end
    local text = tostring(value or ''):lower():match('^%s*(.-)%s*$') or ''
    if LEVEL_NAMES[text] ~= nil then return LEVEL_NAMES[text] end
    local numeric = tonumber(text)
    if numeric then return math.max(0, math.min(5, math.floor(numeric))) end
    return nil
end

local function decodeModuleLevels(serialized)
    local levels = {}
    for entry in tostring(serialized or ''):gmatch('[^,;]+') do
        local moduleName, rawLevel = entry:match('^%s*([^=:]+)%s*[=:]%s*([^=:]+)%s*$')
        local canonical = canonicalModuleName(moduleName)
        local level = parseLevel(rawLevel)
        if canonical ~= '' and level ~= nil then levels[canonical] = level end
    end
    return levels
end

local function moduleOverride(moduleName)
    return _moduleLevels[canonicalModuleName(moduleName)]
end

local function effectiveLevel(moduleName, fallback)
    local override = moduleOverride(moduleName)
    if override ~= nil then return override end
    return fallback
end

-- ============================================================
-- GLOBAL CONTROL API
-- ============================================================

--- Set the global minimum log level (1=error, 2=warn, 3=info, 4=debug, 5=verbose)
function M.setLevel(level)
    _globalLevel = math.max(1, math.min(5, tonumber(level) or 3))
end

--- Get the current global log level
function M.getLevel()
    return _globalLevel
end

function M.getKnownModules()
    local result = {}
    for i, entry in ipairs(KNOWN_MODULES) do
        result[i] = { key = entry.key, label = entry.label }
    end
    return result
end

function M.decodeModuleLevels(serialized)
    return decodeModuleLevels(serialized)
end

function M.encodeModuleLevels(levels)
    levels = levels or _moduleLevels
    local normalized = {}
    for moduleName, level in pairs(levels) do
        local canonical = canonicalModuleName(moduleName)
        local parsed = parseLevel(level)
        if canonical ~= '' and parsed ~= nil then normalized[canonical] = parsed end
    end
    local keys = {}
    for moduleName in pairs(normalized) do keys[#keys + 1] = moduleName end
    table.sort(keys)
    local encoded = {}
    for _, moduleName in ipairs(keys) do
        encoded[#encoded + 1] = string.format('%s=%d', moduleName, normalized[moduleName])
    end
    return table.concat(encoded, ',')
end

function M.setModuleLevel(moduleName, level)
    local canonical = canonicalModuleName(moduleName)
    if canonical == '' then return false, 'invalid_module' end
    if level == nil or tostring(level):lower() == 'inherit' then
        _moduleLevels[canonical] = nil
        return true
    end
    local parsed = parseLevel(level)
    if parsed == nil then return false, 'invalid_level' end
    _moduleLevels[canonical] = parsed
    return true
end

function M.getModuleLevel(moduleName)
    return moduleOverride(moduleName)
end

function M.getModuleLevels()
    local result = {}
    for moduleName, level in pairs(_moduleLevels) do result[moduleName] = level end
    return result
end

--- True when a message would reach at least one configured sink.
function M.wouldLog(moduleName, level)
    local levelDef = LEVELS[tostring(level or ''):lower()]
    if not levelDef then return false end
    local consoleMin = effectiveLevel(moduleName, _consoleLevel or _globalLevel)
    local fileMin = effectiveLevel(moduleName, _fileLevel or _globalLevel)
    return levelDef.num <= consoleMin
        or (_fileLogging and levelDef.num <= fileMin)
end

--- Set minimum level for console output (nil = use global level)
function M.setConsoleLevel(level)
    _consoleLevel = level and math.max(1, math.min(5, tonumber(level) or 3)) or nil
end

--- Set minimum level for file output (nil = use global level)
function M.setFileLevel(level)
    _fileLevel = level and math.max(1, math.min(5, tonumber(level) or 3)) or nil
end

--- Set a pipe-separated filter pattern. Only messages matching the pattern are shown.
--- Pass nil to clear the filter.
function M.setFilter(pattern)
    _filter = pattern
end

--- Enable or disable file logging
function M.setFileLogging(enabled)
    _fileLogging = enabled
    if not enabled and _fileHandle then
        _fileHandle:close()
        _fileHandle = nil
    end
end

--- Enable or disable caller tracing (file::func():line)
function M.setTracerEnabled(enabled)
    _tracerEnabled = enabled
end

--- Set the script label prefix for console output (default: 'SK')
function M.setScriptLabel(label)
    _scriptLabel = label or 'SK'
end

--- Apply persisted SideKick logging settings in the current Lua process.
--- Each coordinated worker has its own module globals, so this must run after
--- that process reloads Core settings rather than only in the UI host.
---@param settings table|nil
function M.configure(settings)
    settings = settings or {}
    M.setLevel(settings.SideKickLogLevel or 3)
    M.setFileLogging(settings.SideKickLogFile == true)
    local filter = tostring(settings.SideKickLogFilter or '')
    M.setFilter(filter ~= '' and filter or nil)
    _moduleLevels = decodeModuleLevels(settings.SideKickModuleLogLevels)
end

function M.getConfiguration()
    return {
        level = _globalLevel,
        fileLogging = _fileLogging,
        filter = _filter or '',
        moduleLevels = M.getModuleLevels(),
        moduleLevelsEncoded = M.encodeModuleLevels(),
    }
end

-- ============================================================
-- INTERNAL HELPERS
-- ============================================================

--- Get caller info from the call stack
--- @param stackDepth number Frames to skip (caller of log function)
local function getCallerInfo(stackDepth)
    if not _tracerEnabled then return '' end

    local info = debug.getinfo(stackDepth, 'Snl')
    if not info then return '' end

    local file = 'unknown'
    if info.short_src then
        file = info.short_src:match('[^\\^/]*.lua$') or info.short_src:match('[^\\^/]*$') or 'unknown'
    end
    local func = info.name or '?'
    local line = info.currentline or 0

    return string.format(' \aw(\at%s\aw::\at%s()\aw:\at%d\aw)', file, func, line)
end

--- Get or create the file handle for today's log
local function getFileHandle()
    if not _fileLogging then return nil end

    local today = os.date('%Y-%m-%d')
    if _fileDate == today and _fileHandle then
        return _fileHandle
    end

    -- Close old handle if date changed
    if _fileHandle then
        _fileHandle:close()
        _fileHandle = nil
    end

    _fileDate = today

    -- Build log path using Paths module if available
    local ok, Paths = pcall(require, 'smartheal.util.paths')
    if ok and Paths then
        _filePath = Paths.getLogPath('debug', today)
    else
        -- Fallback: write to mq.configDir directly
        local charName = 'Character'
        local cOk, cName = pcall(function() return mq.TLO.Me.CleanName() end)
        if cOk and cName then charName = cName end
        _filePath = string.format('%s/SideKick_%s_%s.log', mq.configDir, charName, today)
    end

    _fileHandle = io.open(_filePath, 'a')
    if _fileHandle then
        _fileHandle:write(string.format('\n=== SideKick Logger started %s ===\n', os.date('%Y-%m-%d %H:%M:%S')))
        _fileHandle:flush()
    end

    return _fileHandle
end

--- Format message safely (handles missing varargs, bad format strings)
local function formatMessage(fmt, ...)
    if select('#', ...) == 0 then
        return tostring(fmt)
    end
    local ok, result = pcall(string.format, fmt, ...)
    return ok and result or tostring(fmt)
end

--- Strip MQ color codes for file output
local function stripColors(text)
    return text:gsub('\a.', '')
end

--- Check if a message passes the current filter
local function passesFilter(moduleName, message)
    if not _filter or _filter == '' then return true end

    local combined = (moduleName or '') .. ' ' .. (message or '')
    combined = combined:lower()
    local filterLower = _filter:lower()

    for pattern in filterLower:gmatch('[^|]+') do
        pattern = pattern:match('^%s*(.-)%s*$')  -- trim
        if pattern ~= '' and combined:find(pattern, 1, true) then
            return true
        end
    end

    return false
end

-- ============================================================
-- CORE LOG FUNCTION
-- ============================================================

--- Write a log message at the given level
--- @param levelName string Level name (error, warn, info, debug, verbose)
--- @param moduleName string Module name for context
--- @param depthOffset number Extra stack frames to skip for caller tracing (default 0)
--- @param fmt string Format string
--- @param ... any Format arguments
local function writeLog(levelName, moduleName, depthOffset, fmt, ...)
    local levelDef = LEVELS[levelName]
    if not levelDef then return false end

    local levelNum = levelDef.num

    -- Cheap suppression check BEFORE formatting: suppressed debug/verbose
    -- calls sit on hot paths (per drained actor message in the coordinator)
    -- and must cost next to nothing when no sink would accept the line.
    local suppressConsoleMin = effectiveLevel(moduleName, _consoleLevel or _globalLevel)
    local suppressFileMin = effectiveLevel(moduleName, _fileLevel or _globalLevel)
    if levelNum > suppressConsoleMin
        and (not _fileLogging or levelNum > suppressFileMin) then
        return false
    end

    local message = formatMessage(fmt, ...)

    -- Check filter
    if not passesFilter(moduleName, message) then return false end
    local emitted = false

    -- Console output
    local consoleMin = effectiveLevel(moduleName, _consoleLevel or _globalLevel)
    if levelNum <= consoleMin then
        -- Stack: getCallerInfo → writeLog → log.X → caller = depth 4 + depthOffset
        local callerInfo = getCallerInfo(4 + (depthOffset or 0))
        local consoleLine = string.format('\aw[%s]\ax %s[%s]\ax \aw[\at%s\aw]%s %s%s\ax',
            M.timestamp(), levelDef.color, _scriptLabel,
            moduleName or '?',
            callerInfo,
            levelDef.color, message)
        printf(consoleLine)
        emitted = true
    end

    -- File output
    local fileMin = effectiveLevel(moduleName, _fileLevel or _globalLevel)
    if levelNum <= fileMin then
        local fh = getFileHandle()
        if fh then
            local fileLine = string.format('[%s][%s][%s] %s\n',
                M.timestamp(), levelDef.tag, moduleName or '?', stripColors(message))
            fh:write(fileLine)
            fh:flush()
            emitted = true
        end
    end
    return emitted
end

-- ============================================================
-- LOGGER INSTANCE FACTORY
-- ============================================================

--- Create a new logger instance for a module.
--- @param moduleName string Human-readable module name (e.g., 'HealSelector', 'Coordinator')
--- @param depthOffset? number Extra stack frames for caller tracing (default 0). Use 1 for wrappers.
--- @return table Logger instance with error/warn/info/debug/verbose methods
function M.new(moduleName, depthOffset)
    depthOffset = depthOffset or 0
    local logger = {}

    function logger.error(fmt, ...) return writeLog('error', moduleName, depthOffset, fmt, ...) end
    function logger.warn(fmt, ...)  return writeLog('warn',  moduleName, depthOffset, fmt, ...) end
    function logger.info(fmt, ...)  return writeLog('info',  moduleName, depthOffset, fmt, ...) end
    function logger.debug(fmt, ...) return writeLog('debug', moduleName, depthOffset, fmt, ...) end
    function logger.verbose(fmt, ...) return writeLog('verbose', moduleName, depthOffset, fmt, ...) end

    --- Check if a level would produce output (for expensive message construction)
    function logger.isLevel(level)
        return M.wouldLog(moduleName, level)
    end

    return logger
end

-- ============================================================
-- CONVENIENCE: Module-level logger (backward compat with debug_log patterns)
-- ============================================================

--- Shortcut: create a logger and return just the info-level function.
--- Drop-in replacement for debug_log.tagged() callers.
--- @param tag string Module tag
--- @return fun(fmt: string, ...: any) Info-level log function
function M.tagged(tag)
    local log = M.new(tag)
    return log.info
end

-- ============================================================
-- SHUTDOWN
-- ============================================================

function M.shutdown()
    if _fileHandle then
        _fileHandle:write(string.format('=== SideKick Logger stopped %s ===\n', os.date('%Y-%m-%d %H:%M:%S')))
        _fileHandle:close()
        _fileHandle = nil
    end
end

return M
