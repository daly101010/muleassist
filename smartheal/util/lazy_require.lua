--- Lazy-require utility: eliminates duplicated pcall/require/cache boilerplate.
--- Returns a getter function that lazy-loads a module on first access.
---
--- Usage:
---   local lazy = require('smartheal.util.lazy_require')
---
---   -- Retry mode (retries on failure each call, like Form A):
---   local getPaths = lazy('smartheal.util.paths')
---
---   -- Once mode (tries once, returns nil forever after failure, like Form B/C):
---   local getMonitor = lazy.once('smartheal.ui.monitor')
---
---   -- Init mode (like retry, but calls module.init() on first successful load):
---   local getCC = lazy.init('smartheal.util.automation.cc')

local _cache = {}      -- shared cache: modulePath -> loaded module (or false sentinel)

local lazy = {}

--- Retry mode: returns nil on failure, retries next call.
--- Replaces Form A pattern (underscore-prefixed, `if not _X` guard).
local function retryLoader(modulePath)
    return function()
        local cached = _cache[modulePath]
        if cached then return cached end
        local ok, m = pcall(require, modulePath)
        if ok and m then
            _cache[modulePath] = m
            return m
        end
        return nil
    end
end

--- Once mode: tries once, returns nil forever on failure.
--- Replaces Form B (PascalCase + false sentinel) and Form C (loaded-flag boolean).
function lazy.once(modulePath)
    local attempted = false
    return function()
        if attempted then
            return _cache[modulePath] or nil
        end
        attempted = true
        local ok, m = pcall(require, modulePath)
        if ok and m then
            _cache[modulePath] = m
            return m
        end
        _cache[modulePath] = false
        return nil
    end
end

--- Init mode: like retry, but calls module.init() on first successful load.
--- Replaces deferred init patterns where a module needs init() on first access.
--- init() is only called once; if init() throws, it will be retried on next call.
function lazy.init(modulePath)
    local inited = false
    local getter = retryLoader(modulePath)
    return function()
        local m = getter()
        if m and not inited then
            if type(m.init) == 'function' then
                local ok, err = pcall(m.init)
                if ok then
                    inited = true
                end
                -- On failure, inited stays false so next call retries init()
            else
                inited = true  -- No init method, nothing to retry
            end
        end
        return m
    end
end

-- Make lazy callable as lazy('path') for retry mode, and indexable for lazy.once() / lazy.init()
setmetatable(lazy, { __call = function(_, modulePath) return retryLoader(modulePath) end })

return lazy
