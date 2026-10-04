-- tests/stub_mq.lua: a fake `mq` for luajit tests. Build a TLO tree from plain tables: every leaf is a
-- value; calling a node with no arguments returns its value (or nil), so mq.TLO.Me.PctHPs() works like in
-- game; calling it with arguments runs the leaf function and wraps the result as an object, so
-- mq.TLO.Spawn(id)() and mq.TLO.Plugin('MQ2DanNet')() work like in game too.
local M = {}

local function isNode(x) return type(x) == 'table' and rawget(x, '__children') ~= nil end

-- MQ semantics: a call WITH arguments is an index (mq.TLO.Spawn(id), Me.Book('X')) and returns an object;
-- a call WITHOUT arguments evaluates the object (sp(), Me.PctHPs()).
local node
node = function(value)
    local t = setmetatable({}, {
        __call = function(self, ...)
            local v = rawget(self, '__value')
            if select('#', ...) > 0 then
                local r = nil
                if type(v) == 'function' then r = v(...) end
                if isNode(r) then return r end
                return node(r)
            end
            if type(v) == 'function' then return v() end
            return v
        end,
        __index = function(self, k)
            local children = rawget(self, '__children') or {}
            local c = children[k]
            if c == nil then return node(nil) end
            return c
        end,
    })
    rawset(t, '__value', value)
    rawset(t, '__children', {})
    return t
end

--- Build a node from a table spec: { _ = value, Child = {...} | value }
local function build(spec)
    if type(spec) ~= 'table' then return node(spec) end
    local n = node(spec._)
    for k, v in pairs(spec) do
        if k ~= '_' then rawget(n, '__children')[k] = build(v) end
    end
    return n
end

--- A callable node: mq.TLO.Spawn(id) -> looks up spec.Spawn[id] or spec.Spawn._fn(id)
local function callable(fn)
    local n = node(nil)
    rawset(n, '__value', fn)
    return n
end

function M.new(tloSpec)
    local mq = { cmds = {}, events = {}, binds = {}, now = 0 }
    mq.TLO = build(tloSpec or {})
    function mq.cmd(s) mq.cmds[#mq.cmds + 1] = s end
    function mq.cmdf(fmt, ...) mq.cmds[#mq.cmds + 1] = string.format(fmt, ...) end
    function mq.delay(ms, fn)
        if type(ms) == 'number' then mq.now = mq.now + ms end
        if mq.onDelay then mq.onDelay(ms) end
        if fn then fn() end
    end
    function mq.doevents() end
    function mq.flushevents() end
    function mq.event(name, pattern, fn) mq.events[name] = { pattern = pattern, fn = fn } end
    function mq.unevent(name) mq.events[name] = nil end
    function mq.bind(cmd, fn) mq.binds[cmd] = fn end
    function mq.unbind(cmd) mq.binds[cmd] = nil end
    function mq.gettime() return mq.now end
    function mq.parse(s) return s end
    mq.configDir = '/tmp'
    mq.node, mq.build, mq.callable = node, build, callable
    package.loaded.mq = mq
    return mq
end

return M
