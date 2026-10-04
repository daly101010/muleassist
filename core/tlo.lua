-- core/tlo.lua: safe TLO reads. Every mq.TLO read in the port goes through these so a NULL member, a
-- missing plugin or a dead spawn yields a default instead of an error.
local mq = require('mq')

local M = {}

--- Evaluate fn() and return a number, or default (0) on nil/error.
function M.num(fn, default)
    local ok, v = pcall(fn)
    if not ok then return default or 0 end   -- a thrown read never leaks its error string to the caller
    v = tonumber(v)
    if v == nil then return default or 0 end
    return v
end

--- Evaluate fn() and return a string, or default ('') on nil/error. 'NULL' reads as default.
function M.str(fn, default)
    local ok, v = pcall(fn)
    if not ok or v == nil then return default or '' end
    v = tostring(v)
    if v == 'NULL' then return default or '' end
    return v
end

--- Evaluate fn() and return true only for a real true / 1 / 'TRUE'.
function M.bool(fn)
    local ok, v = pcall(fn)
    return ok and (v == true or v == 1 or v == 'TRUE')
end

--- A spawn by id (nil when not in zone).
function M.spawn(id)
    id = tonumber(id) or 0
    if id <= 0 then return nil end
    local sp = mq.TLO.Spawn(id)
    if sp and sp() then return sp end
    return nil
end

--- Is a plugin loaded? ${Plugin[x]} is the plugin's name (the macro wraps it in ${Bool[]}), never TRUE.
function M.pluginLoaded(name)
    local ok, v = pcall(function() return mq.TLO.Plugin(name)() end)
    if not ok or v == nil or v == false then return false end
    if v == true then return true end
    v = tostring(v)
    return v ~= '' and v ~= 'NULL' and v ~= 'FALSE'
end

--- A player's corpse ("Name's corpse"): the substring pccorpse search, then the exact clean name,
--- since the =Name form never matches a corpse.
function M.corpseOf(name)
    if not name or name == '' then return nil end
    local sp = mq.TLO.Spawn('pccorpse ' .. name)
    if not (sp and sp()) then return nil end
    local clean = M.str(function() return sp.CleanName() end):lower()
    if clean:find(name:lower() .. "'s corpse", 1, true) == 1 then return sp end
    return nil
end

--- A spawn by exact name and optional type ('pc', 'npc', 'pet', 'pccorpse'): the =Name form, never a quoted search.
function M.spawnByName(name, kind)
    if not name or name == '' then return nil end
    if kind == 'pccorpse' then return M.corpseOf(name) end
    local q = (kind and (kind .. ' ') or '') .. '=' .. name
    local sp = mq.TLO.Spawn(q)
    if sp and sp() then return sp end
    return nil
end

--- The first Auto Hater NPC on XTarget (the macro's live AggroTargetID), 0 when nothing hates me.
--- Scanned at most once per 100 ms.
local xtCache = { at = -1, aggro = 0, hostiles = 0, slots = {}, haters = {} }
local function scanXTarget()
    local now = mq.gettime() or 0
    if xtCache.at >= 0 and now - xtCache.at < 100 then return xtCache end
    local aggro, hostiles = 0, 0
    local slots, haters = {}, {}
    for i = 1, 13 do
        local xt = mq.TLO.Me.XTarget(i)
        local id = xt and M.num(function() return xt.ID() end) or 0
        if id > 0 then
            slots[id] = i
            if M.str(function() return xt.TargetType() end) == 'Auto Hater' then
                local named = M.bool(function() return xt.Named() end)
                haters[#haters + 1] = { id = id, slot = i, named = named }
                if M.str(function() return xt.Type() end) == 'NPC' then
                    hostiles = hostiles + 1
                    if aggro == 0 then aggro = id end
                end
            end
        end
    end
    xtCache.at, xtCache.aggro, xtCache.hostiles, xtCache.slots, xtCache.haters = now, aggro, hostiles, slots, haters
    return xtCache
end
function M.aggroTargetId() return scanXTarget().aggro end
--- How many Auto Hater NPCs are on XTarget (GetHostilesOnXTarget).
function M.hostiles() return scanXTarget().hostiles end
--- Is this spawn id in any XTarget slot? (the slot number or nil)
function M.xtargetSlot(id) return scanXTarget().slots[tonumber(id) or 0] end
function M.onXTarget(id) return M.xtargetSlot(id) ~= nil end
--- The Auto Hater slots as { id, slot, named } (a shared list: copy before changing it).
function M.haters() return scanXTarget().haters end
local grpCache = { at = -1, ids = {} }
function M.xtargetReset() xtCache.at = -1 grpCache.at = -1 end

--- Group members other than me (Group.Members) and the member object for slot i (0 = me).
function M.groupCount() return M.num(function() return mq.TLO.Group.Members() end) end
function M.groupMember(i) return mq.TLO.Group.Member(i) end
--- The group members' spawn ids as a set (me excluded), scanned at most once per 100 ms.
function M.groupIds()
    local now = mq.gettime() or 0
    if grpCache.at >= 0 and now - grpCache.at < 100 then return grpCache.ids end
    local ids = {}
    local n = M.groupCount()
    for i = 1, n do
        local id = M.num(function() return mq.TLO.Group.Member(i).ID() end)
        if id > 0 then ids[id] = true end
    end
    grpCache.at, grpCache.ids = now, ids
    return ids
end
--- Is this spawn id in my group? (0/nil = no)
function M.inGroup(id)
    id = tonumber(id) or 0
    if id <= 0 then return false end
    if id == M.myId() then return true end
    return M.groupIds()[id] == true
end

function M.myId() return M.num(function() return mq.TLO.Me.ID() end) end
function M.myName() return M.str(function() return mq.TLO.Me.CleanName() end) end
function M.myClass() return M.str(function() return mq.TLO.Me.Class.ShortName() end):upper() end
function M.inCombat() return M.str(function() return mq.TLO.Me.CombatState() end) == 'COMBAT' end
function M.zoneId() return M.num(function() return mq.TLO.Zone.ID() end) end
function M.now() return mq.gettime() end

return M
