-- core/modules.lua: the module registry. A module is a table with optional hooks:
--   Init(ctx), LoadSettings(ctx), Tick(ctx) (every pass, paused or not), GiveTime(ctx) (every pass while
--   running), OnZone(ctx), OnCombatStart(ctx), OnCombatEnd(ctx), Shutdown(ctx), Binds = { ['/cmd'] = fn },
--   Settings = schema (core.config).
-- Hooks run in registration order; one module's error is logged and does not stop the others.
local Log = require('core.log')

local M = { list = {}, byName = {} }

function M.register(mod)
    assert(type(mod) == 'table' and mod.name, 'module needs a name')
    if M.byName[mod.name] then return M.byName[mod.name] end
    M.list[#M.list + 1] = mod
    M.byName[mod.name] = mod
    return mod
end

function M.get(name) return M.byName[name] end

--- Call hook `name` on every module that has it.
function M.execAll(name, ctx)
    for _, mod in ipairs(M.list) do
        local fn = mod[name]
        if type(fn) == 'function' then
            local ok, err = pcall(fn, mod, ctx)
            if not ok then Log.error('%s.%s: %s', mod.name, name, tostring(err)) end
        end
    end
end

--- Register every module's binds through mq.bind (skipped in tests when mq.bind is absent).
function M.bindAll(mq)
    if not mq or not mq.bind then return end
    for _, mod in ipairs(M.list) do
        for cmd, fn in pairs(mod.Binds or {}) do
            pcall(mq.unbind, cmd)
            mq.bind(cmd, function(...)
                local ok, err = pcall(fn, mod, ...)
                if not ok then Log.error('%s %s: %s', mod.name, cmd, tostring(err)) end
            end)
        end
    end
end

return M
