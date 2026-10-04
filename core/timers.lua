-- core/timers.lua: named countdown timers in milliseconds. Replaces the macro's dynamic-name timers
-- (Spell${i}GM${WhoNum}, CureHold${id}, WhyNotHeal${id} ...). A timer that was never set reads as expired.
local M = { _t = {}, _now = nil, _sweepAt = nil }

local mq
local function now()
    if M._now then return M._now() end
    mq = mq or require('mq')
    return mq.gettime()
end

--- Drop every expired entry (per-spawn keys are never read again once the spawn is gone).
local function sweep(t)
    for k, at in pairs(M._t) do
        if at <= t then M._t[k] = nil end
    end
    M._sweepAt = t
end

--- Use a custom clock (tests).
function M.setClock(fn) M._now = fn end

--- Arm timer `name` for ms milliseconds (a string like '30s' or '500ms' is accepted).
function M.set(name, ms)
    if type(ms) == 'string' then
        local n, unit = ms:match('^(%d+%.?%d*)(%a*)$')
        n = tonumber(n) or 0
        if unit == 's' then n = n * 1000 elseif unit == 'm' then n = n * 60000 end
        ms = n
    end
    local t = now()
    M._t[name] = t + (tonumber(ms) or 0)
    if M._sweepAt == nil then M._sweepAt = t elseif t - M._sweepAt >= 60000 then sweep(t) end
end

--- Milliseconds left (0 when expired or never set).
function M.left(name)
    local at = M._t[name]
    if not at then return 0 end
    local l = at - now()
    if l <= 0 then M._t[name] = nil return 0 end
    return l
end

--- True while the timer runs.
function M.running(name) return M.left(name) > 0 end

--- True when expired or never set.
function M.expired(name) return M.left(name) == 0 end

function M.clear(name) M._t[name] = nil end

function M.clearPrefix(prefix)
    for k in pairs(M._t) do
        if k:sub(1, #prefix) == prefix then M._t[k] = nil end
    end
end

--- Clear every timer whose name matches fn(name).
function M.clearIf(fn)
    for k in pairs(M._t) do
        if fn(k) then M._t[k] = nil end
    end
end

function M.reset() M._t = {} M._sweepAt = nil M._sigs = {} end

--- Line timers are keyed by list position (heal:<i>:<id>, dps:<index>:<id>, buff:<index>:<id>). When a
--- reload changes a list, clear its prefixes so a replacement line does not inherit the old line's timer.
M._sigs = {}
function M.resetOnChange(owner, sig, prefixes)
    local prev = M._sigs[owner]
    M._sigs[owner] = sig
    if prev == nil or prev == sig then return false end
    for _, p in ipairs(prefixes) do M.clearPrefix(p) end
    return true
end

return M
