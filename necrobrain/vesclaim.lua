-- necrobrain/vesclaim.lua — Blade of Vesagran mutual-exclusion claim (pure, no mq).
--
-- One participant at a time may have Spirit of Vesagran up. Three participants
-- (parsaxx, Calbuss, Beyonce), each with a fixed priority (lower wins). The wire
-- is three broadcast messages, delivered however the host likes (MQ actors on the
-- necros, the same mailbox from medley on parsaxx):
--   * claim   — I intend to fire; sent once when I leave idle
--   * ping    — I have Spirit of Vesagran up (owner heartbeat, on a cadence)
--   * release — mine dropped / I died / I zoned
--
-- The state machine is polled from the host loop via tick(now, ctx) and returns
-- the actions to perform this tick. It never blocks and never touches mq, so the
-- whole thing is unit-tested offline. Timers are seconds (any monotonic clock).
--
-- Race safety: two idle-eligible participants can both claim in the same instant
-- (neither is active yet). Each then waits out CLAIM_GRACE; a claimant that sees a
-- higher-priority claim (or any active owner) in that window yields, so exactly one
-- fires. A crashed owner stops pinging and frees the claim after PING_TTL.

local M = {}
M.__index = M

M.CLAIM_GRACE = 0.4   -- s to wait after claiming before firing (the race window)
M.CLAIM_TTL   = 2.0   -- s a peer's claim stays live without becoming active
M.PING_TTL    = 6.0   -- s a peer's owner-ping stays live (a crash frees it)
M.PING_EVERY  = 2.0   -- s between my pings while I own it
M.FIRE_WAIT   = 3.0   -- s to wait for my Spirit of Vesagran to land before giving up

-- me: my character key. priority: integer, lower wins. opts overrides the timers.
function M.new(me, priority, opts)
    opts = opts or {}
    return setmetatable({
        me = me,
        prio = tonumber(priority) or 99,
        peers = {},            -- char -> { prio, claimAt, pingAt }
        state = 'idle',        -- idle | claiming | firing | owner
        claimAt = 0,
        firedAt = 0,
        pingNext = 0,
        grace = opts.grace or M.CLAIM_GRACE,
        claimTtl = opts.claimTtl or M.CLAIM_TTL,
        pingTtl = opts.pingTtl or M.PING_TTL,
        pingEvery = opts.pingEvery or M.PING_EVERY,
        fireWait = opts.fireWait or M.FIRE_WAIT,
    }, M)
end

-- Record an incoming peer message. kind: 'claim' | 'ping' | 'release'. Own messages
-- are ignored (the host may echo the broadcast back to the sender).
function M:onMessage(kind, char, prio, now)
    if not char or char == self.me then return end
    local p = self.peers[char] or {}
    if prio ~= nil then p.prio = tonumber(prio) end
    if kind == 'claim' then
        p.claimAt = now
    elseif kind == 'ping' then
        p.pingAt = now
        p.claimAt = nil          -- an active owner no longer needs its claim tracked
    elseif kind == 'release' then
        p.pingAt = nil
        p.claimAt = nil
    end
    self.peers[char] = p
end

-- The character key of a peer that currently holds Spirit of Vesagran, or nil.
function M:activePeer(now)
    for c, p in pairs(self.peers) do
        if p.pingAt and (now - p.pingAt) <= self.pingTtl then return c end
    end
    return nil
end

-- A peer with a live claim that outranks me (lower priority number), or nil.
function M:_higherClaim(now)
    for c, p in pairs(self.peers) do
        if p.claimAt and (now - p.claimAt) <= self.claimTtl and (p.prio or 99) < self.prio then
            return c
        end
    end
    return nil
end

-- Someone else owns it right now. External callers (the DPS gate) also read this.
function M:heldByOther(now)
    return self:activePeer(now) ~= nil
end

-- Drive one tick. ctx = { eligible = bool (I want to fire now), active = bool (my
-- Spirit of Vesagran is up) }. Returns { claim, ping, release, fire } booleans -
-- the host broadcasts for claim/ping/release and casts for fire.
function M:tick(now, ctx)
    ctx = ctx or {}
    local act = {}
    local active = ctx.active and true or false

    if active then
        -- I hold it: I am the owner, heartbeat on cadence.
        if self.state ~= 'owner' then
            self.state = 'owner'
            act.ping = true
            self.pingNext = now + self.pingEvery
        elseif now >= self.pingNext then
            act.ping = true
            self.pingNext = now + self.pingEvery
        end
        return act
    end

    -- not active
    if self.state == 'owner' then
        self.state = 'idle'          -- had it, it just dropped
        act.release = true
        return act
    end

    if self.state == 'claiming' then
        if self:activePeer(now) or self:_higherClaim(now) then
            self.state = 'idle'      -- someone outranks me / already active: yield
            return act
        end
        if (now - self.claimAt) >= self.grace then
            act.fire = true          -- won the window: fire and wait for it to land
            self.firedAt = now
            self.state = 'firing'
        end
        return act
    end

    if self.state == 'firing' then
        -- waiting for my Spirit of Vesagran to register (handled by `active` above);
        -- if it never lands, fall back to idle so the rotation is not wedged.
        if (now - self.firedAt) > self.fireWait then self.state = 'idle' end
        return act
    end

    -- idle
    if ctx.eligible and not self:heldByOther(now) and not self:_higherClaim(now) then
        self.state = 'claiming'
        self.claimAt = now
        act.claim = true
    end
    return act
end

-- Death / zone / disable: drop everything and tell the others.
function M:reset()
    self.state = 'idle'
    self.claimAt, self.firedAt, self.pingNext = 0, 0, 0
end

return M
