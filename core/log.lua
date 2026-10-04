-- core/log.lua: chat output with levels, the [PM] post-mortem breadcrumbs and the /whynot ring.
local M = { level = 2, pmOn = true }

local LEVELS = { debug = 1, info = 2, warn = 3, error = 4 }
local TAG = '\ag[MA]\ax '

local function out(prefix, fmt, ...)
    local ok, msg = pcall(string.format, fmt, ...)
    if not ok then msg = tostring(fmt) end
    print(prefix .. msg)
end

function M.setLevel(name) M.level = LEVELS[name] or M.level end
function M.debug(fmt, ...) if M.level <= 1 then out('\a-w[MA dbg]\ax ', fmt, ...) end end
function M.info(fmt, ...) if M.level <= 2 then out(TAG, fmt, ...) end end
function M.warn(fmt, ...) if M.level <= 3 then out('\ay[MA]\ax ', fmt, ...) end end
function M.error(fmt, ...) out('\ar[MA]\ax ', fmt, ...) end
--- Post-mortem breadcrumb (the macro's [PM] lines): on by default, cheap, meant to be read after a death.
function M.pm(fmt, ...) if M.pmOn then out('\a-t[PM]\ax ', fmt, ...) end end

-- ------------------------------------------------------------- /whynot ring (last 20 skipped casts)
M.whynot = { ring = {}, size = 20, idx = 0, lastKey = nil, count = 0 }

local function clock()
    return os.date('%H:%M:%S')
end

--- Record a cast decision that did not cast. Identical consecutive keys collapse into one (xN) entry.
function M.whyNot(where, what, who, why)
    local w = M.whynot
    local key = string.format('%s: %s -> %s: %s', tostring(where), tostring(what), tostring(who), tostring(why))
    if w.idx > 0 and w.lastKey == key then
        w.count = w.count + 1
        w.ring[w.idx] = string.format('[%s] %s (x%d)', clock(), key, w.count)
        return
    end
    w.lastKey, w.count = key, 1
    require('core.stats').bump('skip')
    w.idx = w.idx + 1
    if w.idx > w.size then w.idx = 1 end
    w.ring[w.idx] = string.format('[%s] %s', clock(), key)
end

--- The ring newest first.
function M.whyNotList()
    local w, out = M.whynot, {}
    if w.idx == 0 then return out end
    local n = w.idx
    for _ = 1, w.size do
        if w.ring[n] then out[#out + 1] = w.ring[n] end
        n = n - 1
        if n < 1 then n = w.size end
    end
    return out
end

return M
