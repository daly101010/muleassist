-- core/observe.lua: a declared set of DanNet observers kept in sync. A module says which peers and
-- which query it wants; sync() adds the missing observers, drops the ones no longer wanted, and
-- re-issues the whole set every refreshMs (DanNet forgets an observer when the observed box relogs).
-- Reads go through value(peer, query) which returns nil while nothing has arrived.
local mq = require('mq')
local T = require('core.tlo')
local Timers = require('core.timers')

local M = { sets = {} }   -- [setName] = { query=, peers = {name=true}, refreshMs= }

local function observe(peer, query)
    mq.cmdf('/dobserve %s -q "%s"', peer, query)
end
local function drop(peer, query)
    mq.cmdf('/dobserve %s -q "%s" -drop', peer, query)
end

--- Declare/replace a set: name, query, list of peer names, refresh interval.
function M.want(setName, query, peers, refreshMs)
    local set = M.sets[setName] or { peers = {}, query = query, refreshMs = refreshMs or 60000 }
    M.sets[setName] = set
    set.query = query
    local wanted = {}
    for _, p in ipairs(peers) do wanted[p] = true end
    local refresh = Timers.expired('observe:' .. setName)
    if refresh then
        -- drop and re-add everything in the same pass
        for p in pairs(set.peers) do drop(p, set.query) end
        set.peers = {}
        Timers.set('observe:' .. setName, set.refreshMs)
    end
    for p in pairs(set.peers) do
        if not wanted[p] then drop(p, set.query) set.peers[p] = nil end
    end
    for p in pairs(wanted) do
        if not set.peers[p] then observe(p, set.query) set.peers[p] = true end
    end
end

--- Drop a whole set.
function M.release(setName)
    local set = M.sets[setName]
    if not set then return end
    for p in pairs(set.peers) do drop(p, set.query) end
    M.sets[setName] = nil
    Timers.clear('observe:' .. setName)
end

function M.releaseAll()
    for name in pairs(M.sets) do M.release(name) end
end

--- The observed value, or nil when not observed / not yet received.
function M.value(peer, query)
    local ok, v = pcall(function() return mq.TLO.DanNet(peer).Observe(query)() end)
    if not ok or v == nil then return nil end
    v = tostring(v)
    if v == 'NULL' or v == '' then return nil end
    return v
end

return M
