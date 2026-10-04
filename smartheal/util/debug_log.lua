--- Debug logging factory — backward-compatible wrapper over utils/logger.lua.
---
--- Existing callers continue to work unchanged. New code should use Logger directly:
---   local Logger = require('smartheal.util.logger')
---   local log = Logger.new('MyModule')
---   log.info('hello %s', world)
---
--- Legacy patterns (still supported):
---   local debugLog = require('smartheal.util.debug_log')
---   local log = debugLog.tagged('Main', 'SideKick_Debug.log')
---   log('something happened: %s', detail)

local mq = require('mq')
local Logger = require('smartheal.util.logger')

local M = {}

--- Pattern A: tagged centralized log.
--- Now delegates to Logger at debug level (file + console when level >= 4).
--- @param tag string  Bracket tag like 'Main', 'Heal', 'SpellEngine', 'Med'
--- @param fallbackFile string  Ignored (kept for API compat)
--- @return fun(fmt: string, ...: any)
function M.tagged(tag, fallbackFile)
    local log = Logger.new(tag)
    return log.debug
end

--- Pattern B: per-module debug log with enable flag.
--- @param filename string  Module name (used as Logger tag)
--- @param header string  Header label (used as Logger tag)
--- @param enabled? boolean  Enable flag (default true)
--- @return fun(fmt: string, ...: any)
function M.module(filename, header, enabled)
    if enabled == false then
        return function() end  -- noop
    end
    local log = Logger.new(header or filename)
    return log.debug
end

--- Pattern B variant: per-module with a tag per-call.
--- @param filename string  Module name (used as Logger tag)
--- @param header string  Header label (used as Logger tag)
--- @param enabled? boolean  Enable flag (default true)
--- @return fun(moduleName: string, fmt: string, ...: any)
function M.moduleTagged(filename, header, enabled)
    if enabled == false then
        return function() end  -- noop
    end
    local cache = {}
    return function(moduleName, fmt, ...)
        local tag = moduleName or header or filename
        local log = cache[tag]
        if not log then
            log = Logger.new(tag, 1)  -- depthOffset=1 for extra closure frame
            cache[tag] = log
        end
        log.debug(fmt, ...)
    end
end

return M
