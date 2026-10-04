-- core/stats.lua: the /healreport counters (the macro's HS* outers) and the one-line summary
-- (HealStatsBuild). Every cast site bumps a counter here; the report module prints and broadcasts them.
-- Pure apart from the clock, so the summary format is tested offline.
local M = { hs = nil, clock = nil }

local KEYS = { 'fights', 'single', 'self', 'tank', 'groupT', 'pet', 'oog', 'tap', 'mob',
    'intHeal', 'intTap', 'intMob', 'intNPC', 'intEmergency', 'dpsCut', 'fail', 'group', 'groupRange',
    'smart', 'smartFail', 'cure', 'cureGroup', 'cureHeld', 'cureUnready', 'skip' }
M.KEYS = KEYS

--- Seconds (Macro.RunTime stood in for this in the macro). Tests inject a clock.
function M.now()
    if M.clock then return M.clock() end
    local mq = require('mq')
    return math.floor((mq.gettime() or 0) / 1000)
end

--- Zero every counter (HealStatsReset) and restart the window.
function M.reset()
    local hs = { since = M.now(), failLast = '', cureUnreadyLast = '', lowPct = 100, lowName = '', tankLow = 100,
        line = {}, gline = {} }
    for _, k in ipairs(KEYS) do hs[k] = 0 end
    M.hs = hs
end
M.reset()

function M.bump(key, n)
    local hs = M.hs
    assert(hs[key] ~= nil, 'unknown stat ' .. tostring(key))
    hs[key] = hs[key] + (n or 1)
end

--- Per heal line (HSLine[i]) and per group heal line (HSGLine[i]).
function M.bumpLine(i) M.hs.line[i] = (M.hs.line[i] or 0) + 1 end
function M.bumpGLine(i) M.hs.gline[i] = (M.hs.gline[i] or 0) + 1 end

--- A failed cast: HSFail + HSFailLast = "<result> <spell>".
function M.fail(result, spell)
    M.bump('fail')
    M.hs.failLast = tostring(result) .. ' ' .. tostring(spell)
end

--- A cure that was not ready: HSCureUnready + HSCureUnreadyLast.
function M.cureUnready(spell)
    M.bump('cureUnready')
    M.hs.cureUnreadyLast = tostring(spell)
end

--- The lowest anyone was seen (HSLowPct/HSLowName) and the lowest the heal tank was seen (HSTankLow).
function M.low(name, pct)
    pct = tonumber(pct) or 100
    if pct < M.hs.lowPct then M.hs.lowPct = pct M.hs.lowName = tostring(name) end
end
function M.tankLow(pct)
    pct = tonumber(pct) or 100
    if pct >= 1 and pct < M.hs.tankLow then M.hs.tankLow = pct end
end

function M.elapsed() return M.now() - M.hs.since end

local function mmss(sec)
    sec = math.max(0, math.floor(sec))
    return string.format('%dm%ds', math.floor(sec / 60), sec % 60)
end
M.mmss = mmss

--- The one-line summary (HealStatsBuild), observed by MAUI and broadcast by /healreport bc.
function M.build(myName)
    local h = M.hs
    local s = string.format('%s: %d heals (tank %d grp %d self %d pet %d oog %d)', tostring(myName), h.single, h.tank, h.groupT, h.self, h.pet, h.oog)
    if h.group > 0 or h.groupRange > 0 then
        s = s .. string.format(', %d group heals', h.group)
        if h.groupRange > 0 then s = s .. string.format(' (%d withheld: nobody in range)', h.groupRange) end
    end
    if h.smart > 0 or h.smartFail > 0 then
        s = s .. string.format(', %d smart heals', h.smart)
        if h.smartFail > 0 then s = s .. string.format(' (%d failed)', h.smartFail) end
    end
    if h.cure > 0 or h.cureUnready > 0 then
        s = s .. string.format(', %d cures', h.cure)
        if h.cureUnready > 0 then s = s .. string.format(' (%d not ready)', h.cureUnready) end
    end
    local int = h.intHeal + h.intTap + h.intMob + h.intNPC
    if int > 0 then s = s .. string.format(', %d interrupted', int) end
    if h.dpsCut > 0 then s = s .. string.format(', %d nukes cut for a heal', h.dpsCut) end
    if h.fail > 0 then s = s .. string.format(', %d failed casts', h.fail) end
    if h.lowPct < 100 then s = s .. string.format(', lowest %s %d%%', h.lowName, h.lowPct) end
    if h.tankLow < 100 then s = s .. string.format(', tank low %d%%', h.tankLow) end
    s = s .. string.format(' [%d fights, %s]', h.fights, mmss(M.elapsed()))
    return s
end

return M
