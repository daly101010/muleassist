-- necrobrain/vesagran.lua — MQ glue for the Blade of Vesagran mutex.
--
-- The decision logic is the pure, unit-tested state machine in vesclaim.lua. This
-- module is only the MQ side: it reads my Spirit of Vesagran state, fans claim /
-- ping / release over DanNet the same way charm.lua and mez do (/squelch /dgge
-- <cmd>, self-excluded), receives peers' fans through /ves* binds, and clicks the
-- Blade when the state machine says I won the window. parsaxx runs the equivalent
-- from medley on the same three commands, so all three share one rotation.
--
-- Strictly one participant has Spirit of Vesagran up at a time. Priority (lower
-- wins) breaks the simultaneous case: parsaxx, then Calbuss, then Beyonce.

local mq = require('mq')
local V = require('necrobrain.vesclaim')
local Logger = require('necrobrain.logger')

local M = {}

M.ITEM = 'Blade of Vesagran'          -- item 77640; its click is Spirit of Vesagran
M.SONG = 'Spirit of Vesagran'
M.PRIORITY = { parsaxx = 1, calbuss = 2, beyonce = 3 }

local claim, me, lastZone, pendingFire
local enabled = false

local function log(fmt, ...) Logger.write(fmt, ...) end
local function now_s() return mq.gettime() / 1000 end

local function dannet_ok()
    local ok, up = pcall(function() return mq.TLO.Plugin('MQ2DanNet').IsLoaded() end)
    return ok and up
end

-- Scope the fan to the claim participants only. /dgge would broadcast to every
-- peer in the group, and non-participants have no /vesping|/vesclaim|/vesdel bind
-- registered (attach runs only here and in medley), so they log
-- "Couldn't parse". /dex <name> reaches exactly the other claimants.
local function fan(cmd)
    if not dannet_ok() then return end
    for name in pairs(M.PRIORITY) do
        if name ~= me then pcall(mq.cmdf, '/squelch /dex %s %s', name, cmd) end
    end
end

-- my Spirit of Vesagran is up (song window first, buff window as fallback)
local function haveSong()
    local ok, up = pcall(function()
        return (mq.TLO.Me.Song(M.SONG).ID() or mq.TLO.Me.Buff(M.SONG).ID()) and true or false
    end)
    return ok and up or false
end

local function itemReady()
    local ok, r = pcall(function()
        local it = mq.TLO.FindItem('=' .. M.ITEM)
        return (it.ID() and (tonumber(it.TimerReady()) or 0) == 0) and true or false
    end)
    return ok and r or false
end

-- I want to fire: engaged on a real NPC, the click is ready, and I don't have it up.
local function eligible()
    local ok, e = pcall(function()
        if tostring(mq.TLO.Me.CombatState()) ~= 'COMBAT' then return false end
        local tid = tonumber(mq.TLO.Target.ID()) or 0
        if tid == 0 then return false end
        return tostring(mq.TLO.Spawn(tid).Type()) == 'NPC'
    end)
    return ok and e and itemReady() and not haveSong()
end

-- safe instant to click: not mid-cast and not in the global spell recovery, so the
-- item click neither interrupts a DoT nor is swallowed by recovery
local function castGap()
    local ok, g = pcall(function()
        return (not mq.TLO.Me.Casting.ID()) and (not mq.TLO.Me.SpellInCooldown())
    end)
    return ok and g or false
end

local function onMsg(kind)
    return function(char, prio)
        if not claim then return end
        claim:onMessage(kind, tostring(char or ''):lower(), tonumber(prio), now_s())
    end
end

function M.init()
    me = tostring(mq.TLO.Me.CleanName() or ''):lower()
    local prio = M.PRIORITY[me]
    if not prio then
        log('vesagran: %s is not a rotation participant - claim off', me)
        return
    end
    claim = V.new(me, prio)
    lastZone = tonumber(mq.TLO.Zone.ID()) or 0
    pcall(mq.bind, '/vesclaim', onMsg('claim'))
    pcall(mq.bind, '/vesping', onMsg('ping'))
    pcall(mq.bind, '/vesdel', onMsg('release'))
    enabled = true
    log('vesagran: claim active (%s, priority %d)', me, prio)
end

-- Call once per loop tick. Drives the state machine and performs its actions.
function M.tick()
    if not enabled or not claim then return end
    local now = now_s()

    -- zone change or death: drop the claim and tell the peers
    local z = tonumber(mq.TLO.Zone.ID()) or 0
    local dead = false
    pcall(function() dead = mq.TLO.Me.Dead() and true or false end)
    if z ~= lastZone or dead then
        lastZone = z
        if claim.state ~= 'idle' then fan('/vesdel ' .. me .. ' ' .. claim.prio) end
        claim:reset()
        pendingFire = false
        if dead then return end
    end

    local active = haveSong()
    local act = claim:tick(now, { eligible = eligible(), active = active })
    if act.claim then fan(string.format('/vesclaim %s %d', me, claim.prio)) end
    if act.ping then fan(string.format('/vesping %s %d', me, claim.prio)) end
    if act.release then fan(string.format('/vesdel %s %d', me, claim.prio)); pendingFire = false end
    if act.fire then pendingFire = true end

    -- fire in the first safe gap after winning; clear the intent once it lands or
    -- the state machine gives up (state left 'firing')
    if active then
        pendingFire = false
    elseif pendingFire and claim.state == 'firing' then
        if castGap() then
            pcall(mq.cmdf, '/useitem "%s"', M.ITEM)
            log('vesagran: fired %s (won the claim)', M.ITEM)
            pendingFire = false
        end
    elseif claim.state ~= 'firing' then
        pendingFire = false
    end
end

-- Release the claim and drop the binds on exit so a restart re-registers cleanly.
function M.shutdown()
    if enabled and claim and claim.state ~= 'idle' then
        fan('/vesdel ' .. me .. ' ' .. claim.prio)
    end
    pcall(mq.unbind, '/vesclaim')
    pcall(mq.unbind, '/vesping')
    pcall(mq.unbind, '/vesdel')
    enabled = false
end

return M
