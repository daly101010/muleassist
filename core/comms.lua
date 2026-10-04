-- core/comms.lua: DanNet messaging with the smallest-audience rule. /dgt for chat, /dex for one box,
-- /dgge for the group, /dgze for the zone; `/dgexecute all` only through comms.all() so a reader can
-- grep for it. A box without DanNet falls back to /echo (and /bc when EQBC is loaded) so the script
-- still runs; nothing is designed around EQBC.
local mq = require('mq')
local T = require('core.tlo')
local State = require('core.state')

local M = {}

--- DanNet is usable: the plugin is loaded and [General] DanNetOn is not 0.
function M.danNet() return State.danNetOn ~= false and T.pluginLoaded('MQ2DanNet') end
function M.eqbc() return T.pluginLoaded('MQ2EQBC') end

local function stamp() return os.date('%H:%M:%S') end

--- Chat to the group's DanNet channel (what the macro's BroadCast did under DanNet, colour-coded).
--- color: a chat colour letter (g, r, y, w ...).
function M.say(color, fmt, ...)
    local msg = select('#', ...) > 0 and string.format(fmt, ...) or tostring(fmt)
    if M.danNet() then
        mq.cmdf('/dgt \\a%s [%s] %s \\aw', color or 'w', stamp(), msg)
    elseif M.eqbc() then
        mq.cmdf('/bc [+%s+] [%s] %s [+x+]', color or 'w', stamp(), msg)
    else
        print(msg)
    end
end

--- Tell one box (BCTell).
function M.tell(peer, fmt, ...)
    local msg = select('#', ...) > 0 and string.format(fmt, ...) or tostring(fmt)
    if M.danNet() then mq.cmdf('/dgt %s [%s] %s', peer, stamp(), msg)
    elseif M.eqbc() then mq.cmdf('/bct %s [%s] %s', peer, stamp(), msg) end
end

--- Run a command on one box (BCTExec).
function M.exec(peer, command)
    if M.danNet() then mq.cmdf('/squelch /dex %s %s', peer, command)
    elseif M.eqbc() then mq.cmdf('/bct %s /%s', peer, command) end
end

--- Run a command on every box in my group (not me).
function M.group(command)
    if M.danNet() then mq.cmdf('/dgge %s', command)
    elseif M.eqbc() then mq.cmdf('/bcga /%s', command) end
end

--- Run a command on every box in my zone (not me).
function M.zone(command)
    if M.danNet() then mq.cmdf('/dgze %s', command)
    elseif M.eqbc() then mq.cmdf('/bcaa /%s', command) end
end

--- Every connected box in every zone. Use only when that is truly the intent.
function M.all(command)
    if M.danNet() then mq.cmdf('/dgae %s', command)
    elseif M.eqbc() then mq.cmdf('/bcaa /%s', command) end
end

--- Every connected DanNet peer name (the macro's DanNet.Peers[all] split on |), me excluded.
--- The list is rebuilt only when the Peers string changes (one TLO read per call, no allocation).
local peerCache = { raw = nil, me = nil, list = {}, set = {} }
local EMPTY = {}
function M.peers()
    if not M.danNet() then return EMPTY end
    local me = T.myName():lower()
    local list = T.str(function() return mq.TLO.DanNet.Peers('all')() end)
    if list == peerCache.raw and me == peerCache.me then return peerCache.list end
    local out, set = {}, {}
    for p in list:gmatch('[^|]+') do
        if p ~= '' and p:lower() ~= me then out[#out + 1] = p set[p:lower()] = true end
    end
    peerCache.raw, peerCache.me, peerCache.list, peerCache.set = list, me, out, set
    return out
end

--- DanNet peers (names) with a PC spawn in this zone, optionally filtered by pred(spawn, name).
function M.peersInZone(pred)
    local out = {}
    for _, peer in ipairs(M.peers()) do
        local sp = T.spawnByName(peer, 'pc')
        if sp and (not pred or pred(sp, peer)) then out[#out + 1] = peer end
    end
    return out
end

function M.isPeer(name)
    if not name or name == '' then return false end
    local list = M.peers()
    if list == EMPTY then return false end
    return peerCache.set[name:lower()] == true
end

return M
