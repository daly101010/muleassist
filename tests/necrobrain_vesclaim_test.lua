-- tests for vesclaim.lua — pure Blade of Vesagran mutex claim
package.path = './necrobrain/?.lua;./?.lua;' .. package.path
local V = require('vesclaim')

local pass, fail = 0, 0
local function check(desc, cond, extra)
    if cond then pass = pass + 1 else
        fail = fail + 1
        io.write(string.format('  FAIL: %s%s\n', desc, extra ~= nil and (' [' .. tostring(extra) .. ']') or ''))
    end
end

-- fast timers so the tests read clearly
local function inst(me, prio)
    return V.new(me, prio, { grace = 0.4, claimTtl = 2.0, pingTtl = 6.0, pingEvery = 2.0, fireWait = 3.0 })
end

-- ---------------------------------------------------------------- solo lifecycle
do
    local a = inst('calbuss', 2)
    local r = a:tick(0.0, { eligible = true, active = false })
    check('solo: eligible with no peers claims', r.claim == true and a.state == 'claiming')
    r = a:tick(0.2, { eligible = true, active = false })
    check('solo: still inside the grace window, no fire yet', not r.fire and a.state == 'claiming')
    r = a:tick(0.5, { eligible = true, active = false })
    check('solo: grace elapsed -> fire', r.fire == true and a.state == 'firing')
    r = a:tick(0.9, { eligible = true, active = true })
    check('solo: it landed -> owner pings', r.ping == true and a.state == 'owner')
    r = a:tick(1.5, { eligible = true, active = true })
    check('solo: no ping before the cadence', not r.ping)
    r = a:tick(2.95, { eligible = true, active = true })
    check('solo: ping again on cadence', r.ping == true)
    r = a:tick(3.2, { eligible = true, active = false })
    check('solo: it dropped -> release, back to idle', r.release == true and a.state == 'idle')
end

-- ---------------------------------------------------------------- fire never lands
do
    local a = inst('beyonce', 3)
    a:tick(0.0, { eligible = true, active = false })
    a:tick(0.5, { eligible = true, active = false })   -- fires
    check('fire-wait: in firing after the shot', a.state == 'firing')
    local r = a:tick(1.0, { eligible = true, active = false })
    check('fire-wait: still waiting for it to land', a.state == 'firing' and not r.claim)
    r = a:tick(4.0, { eligible = true, active = false }) -- > fireWait after firedAt(0.5)
    check('fire-wait: never landed -> idle, free to reclaim', a.state == 'idle')
end

-- ---------------------------------------------------------------- hold while a peer owns it
do
    local a = inst('beyonce', 3)
    a:onMessage('ping', 'parsaxx', 1, 10.0)          -- parsaxx is the active owner
    local r = a:tick(10.1, { eligible = true, active = false })
    check('hold: a peer owns it -> I do not claim', not r.claim and a.state == 'idle')
    check('hold: heldByOther is true', a:heldByOther(10.1) == true)
    -- owner keeps pinging: still held
    a:onMessage('ping', 'parsaxx', 1, 12.0)
    r = a:tick(12.1, { eligible = true, active = false })
    check('hold: still held while pings continue', not r.claim)
    -- owner releases: now free
    a:onMessage('release', 'parsaxx', 1, 13.0)
    r = a:tick(13.1, { eligible = true, active = false })
    check('hold: owner released -> I claim', r.claim == true)
end

-- ---------------------------------------------------------------- crashed owner frees it
do
    local a = inst('beyonce', 3)
    a:onMessage('ping', 'calbuss', 2, 100.0)         -- calbuss owns, then goes silent (crash)
    local r = a:tick(103.0, { eligible = true, active = false })
    check('crash: within PING_TTL still held', not r.claim)
    r = a:tick(106.5, { eligible = true, active = false })  -- > pingTtl (6s) after 100
    check('crash: ping expired -> I may claim', r.claim == true and a.state == 'claiming')
end

-- ---------------------------------------------------------------- priority race: higher wins
do
    local hi = inst('parsaxx', 1)
    local lo = inst('beyonce', 3)
    -- both idle-eligible in the same instant: both claim (neither active yet)
    local rh = hi:tick(0.0, { eligible = true, active = false })
    local rl = lo:tick(0.0, { eligible = true, active = false })
    check('race: both broadcast a claim', rh.claim == true and rl.claim == true)
    -- they hear each other
    hi:onMessage('claim', 'beyonce', 3, 0.0)
    lo:onMessage('claim', 'parsaxx', 1, 0.0)
    -- grace elapses
    rl = lo:tick(0.45, { eligible = true, active = false })
    check('race: lower priority yields to the higher claim', not rl.fire and lo.state == 'idle')
    rh = hi:tick(0.45, { eligible = true, active = false })
    check('race: higher priority fires', rh.fire == true and hi.state == 'firing')
    -- higher becomes owner and pings; lower now sees an active peer and stays idle
    hi:tick(0.9, { eligible = true, active = true })
    lo:onMessage('ping', 'parsaxx', 1, 0.9)
    rl = lo:tick(1.0, { eligible = true, active = false })
    check('race: loser holds while winner owns it', not rl.claim and lo:heldByOther(1.0))
end

-- ---------------------------------------------------------------- lower claim does not block higher
do
    local hi = inst('parsaxx', 1)
    hi:onMessage('claim', 'beyonce', 3, 5.0)          -- a lower-priority claim is live
    local r = hi:tick(5.05, { eligible = true, active = false })
    check('precedence: a lower claim does not stop me claiming', r.claim == true and hi.state == 'claiming')
    r = hi:tick(5.5, { eligible = true, active = false })
    check('precedence: and I still fire (lower claim is ignored)', r.fire == true)
end

-- ---------------------------------------------------------------- not eligible: never claims
do
    local a = inst('calbuss', 2)
    local r = a:tick(0.0, { eligible = false, active = false })
    check('gate: not eligible -> no claim', not r.claim and a.state == 'idle')
end

-- ---------------------------------------------------------------- own messages ignored
do
    local a = inst('calbuss', 2)
    a:onMessage('ping', 'calbuss', 2, 1.0)           -- echo of my own broadcast
    check('self: my own ping is ignored', a:activePeer(1.1) == nil)
end

-- ---------------------------------------------------------------- claim TTL expiry
do
    local a = inst('beyonce', 3)
    a:onMessage('claim', 'parsaxx', 1, 0.0)          -- higher claim, but it never activates
    local r = a:tick(0.1, { eligible = true, active = false })
    check('ttl: fresh higher claim blocks me', not r.claim)
    r = a:tick(2.2, { eligible = true, active = false })  -- > claimTtl (2s)
    check('ttl: stale claim expired -> I may claim', r.claim == true)
end

io.write(string.format('test_vesclaim: %d passed, %d failed\n', pass, fail))
os.exit(fail == 0 and 0 or 1)
