-- healing/damage_parser.lua
local mq = require('mq')

local M = {}

local Config = nil
local _handlers = {}
local _listeners = {}  -- external observers of incoming damage (death forensics, etc.)
local _damageWindow = {}  -- [targetId] = { {time, amount, source}, ... }
local WINDOW_DURATION = 6  -- seconds (default, overridden by Config.damageWindowSec)
local WINDOW_DURATION_MS = WINDOW_DURATION * 1000
local _initialized = false

-- Statistics for burst detection
local _dpsHistory = {}  -- [targetId] = { dps1, dps2, ... }
local MAX_HISTORY = 20

function M.init(config)
    if _initialized then return end  -- Prevent double initialization
    _initialized = true

    Config = config
    -- Use config window duration if available
    if Config and Config.damageWindowSec then
        WINDOW_DURATION = Config.damageWindowSec
    end
    WINDOW_DURATION_MS = WINDOW_DURATION * 1000
    M.registerEvents()
end

function M.registerEvents()
    -- Melee damage TO group members (mob hits player)
    mq.event('DmgMelee', '#1# hits #2# for #3# points of damage.', function(_, attacker, target, amount)
        M.recordDamage(target, tonumber(amount) or 0, attacker, 'melee')
    end)

    -- Note: Critical melee ("#1# scores a critical hit! (#2#)") not tracked
    -- because it doesn't specify target - would need context tracking

    -- Spell damage TO group members
    mq.event('DmgSpell', '#1# hit #2# for #3# points of #4# damage by #5#.', function(_, caster, target, amount, dmgType, spell)
        M.recordDamage(target, tonumber(amount) or 0, caster, 'spell')
    end)

    -- DoT damage TO group members
    mq.event('DmgDot', '#1# has taken #2# damage from #3# by #4#.', function(_, target, amount, spell, caster)
        M.recordDamage(target, tonumber(amount) or 0, caster, 'dot')
    end)

    -- DS damage (on self when mob hits you)
    mq.event('DmgDs', '#1# is burned by YOUR #2# for #3# points of damage.', function(_, mob, spell, amount)
        -- DS damage is on mob, not relevant for healing
    end)
end

--- Register an external observer of incoming damage (called for every recorded hit)
-- Listener signature: fn(targetId, targetName, amount, source, dmgType)
function M.addListener(fn)
    if type(fn) == 'function' then
        table.insert(_listeners, fn)
    end
end

function M.recordDamage(targetName, amount, source, dmgType)
    if amount <= 0 then return end

    -- Find target ID by name
    local targetId = M.findTargetIdByName(targetName)
    if not targetId then return end

    local now = mq.gettime()

    _damageWindow[targetId] = _damageWindow[targetId] or {}
    table.insert(_damageWindow[targetId], {
        time = now,
        amount = amount,
        source = source,
        dmgType = dmgType,
    })

    for _, fn in ipairs(_listeners) do
        pcall(fn, targetId, targetName, amount, source, dmgType)
    end
end

-- Per-group-signature cache for name → spawn ID. The previous implementation
-- ran a full TLO group iteration on every damage event (multiple per second
-- in AE fights), each with pcall overhead. Caching keyed by a stable group
-- signature (concatenation of member IDs) lets us serve hits in O(1) and
-- only rebuild when group composition changes.
local _idCache = {}
local _lastGroupSignature = ''

local function _currentGroupSignature()
    local me = mq.TLO.Me
    local myId = (me and me() and me.ID()) or 0
    local sig = tostring(myId)
    local groupCount = 0
    local ok, n = pcall(function() return mq.TLO.Group.Members() end)
    if ok and n then groupCount = tonumber(n) or 0 end
    for i = 1, groupCount do
        local member = mq.TLO.Group.Member(i)
        if member and member() then
            local id = member.ID and member.ID()
            if id and id > 0 then sig = sig .. ',' .. id end
        end
    end
    return sig, myId, groupCount
end

function M.findTargetIdByName(name)
    if not name or name == '' then return nil end

    local lname = tostring(name):lower()
    if lname == 'you' then
        local me = mq.TLO.Me
        return (me and me() and me.ID()) or nil
    end

    -- Refresh the cache only when group membership changes.
    local sig, myId, groupCount = _currentGroupSignature()
    if sig ~= _lastGroupSignature then
        _idCache = {}
        _lastGroupSignature = sig

        local me = mq.TLO.Me
        if me and me() then
            local myName = me.CleanName and me.CleanName() or nil
            if myName and myName ~= '' and myName ~= 'NULL' then
                _idCache[myName:lower()] = myId
            end
        end
        for i = 1, groupCount do
            local ok, _ = pcall(function()
                local member = mq.TLO.Group.Member(i)
                if not member or not member() then return end
                local spawn = member
                if member.Spawn and member.Spawn() then
                    spawn = member.Spawn()
                end
                if spawn and spawn() then
                    local cleanName = spawn.CleanName and spawn.CleanName() or nil
                    local id = spawn.ID and spawn.ID() or 0
                    if cleanName and cleanName ~= '' and cleanName ~= 'NULL' and id > 0 then
                        _idCache[cleanName:lower()] = id
                    end
                end
            end)
        end
    end

    return _idCache[lname]
end

function M.getLogDps(targetId)
    local entries = _damageWindow[targetId]
    if not entries or #entries == 0 then return 0 end

    local now = mq.gettime()
    local cutoff = now - WINDOW_DURATION_MS

    -- Sum damage in window
    local total = 0
    local count = 0
    local oldest = now

    for i = #entries, 1, -1 do
        local entry = entries[i]
        if entry.time >= cutoff then
            total = total + entry.amount
            count = count + 1
            if entry.time < oldest then
                oldest = entry.time
            end
        end
    end

    if count == 0 then return 0 end

    local durationMs = math.max(1000, now - oldest)
    return total / (durationMs / 1000)
end

function M.checkBurst(targetId, currentDps)
    local history = _dpsHistory[targetId] or {}

    -- Need history for statistical analysis
    if #history < 5 then
        table.insert(history, currentDps)
        _dpsHistory[targetId] = history
        return false
    end

    -- Calculate mean and stddev
    local sum = 0
    for _, dps in ipairs(history) do
        sum = sum + dps
    end
    local mean = sum / #history

    local variance = 0
    for _, dps in ipairs(history) do
        variance = variance + (dps - mean) ^ 2
    end
    local stddev = math.sqrt(variance / #history)

    -- Burst threshold: mean + (stddev * multiplier) (multiplier from config)
    local multiplier = (Config and Config.burstStddevMultiplier ~= nil) and Config.burstStddevMultiplier or 1.5
    local threshold = mean + (stddev * multiplier)

    -- Update history (rolling window)
    table.insert(history, currentDps)
    if #history > MAX_HISTORY then
        table.remove(history, 1)
    end
    _dpsHistory[targetId] = history

    return currentDps > threshold and stddev > 0
end

function M.tick()
    mq.doevents()

    -- Prune old entries
    local now = mq.gettime()
    local cutoff = now - WINDOW_DURATION_MS

    for targetId, entries in pairs(_damageWindow) do
        local newEntries = {}
        for _, entry in ipairs(entries) do
            if entry.time >= cutoff then
                table.insert(newEntries, entry)
            end
        end
        if #newEntries > 0 then
            _damageWindow[targetId] = newEntries
        else
            _damageWindow[targetId] = nil
        end
    end
end

return M
