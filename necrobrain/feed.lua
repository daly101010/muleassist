-- necrobrain/feed.lua — subscribes to companion's normalized combat events and
-- turns MY casts into landed/resisted outcomes (10 s grace). Everything else
-- that hits a mob is re-emitted as 'damage' for HP tracking.
local mq = require('mq')
local Logger = require('necrobrain.logger')
local okA, actors = pcall(require, 'actors')

local M = {}
-- companion emits 'cast' on "You begin casting"; the confirming tick or resist
-- only arrives a full cast-time later (necro casts run 3-6s). 2500ms expired
-- almost every pending cast before its outcome could land, so give it enough
-- room for the slowest cast plus network/parse slack.
local GRACE_MS = 10000
local me, mailbox = '', nil
local listeners = {}
local pending = {}   -- list of {spell, target, at}
local diag = { casts = 0, landed = 0, resisted = 0, expired = 0, damage = 0, dropped = 0 }
-- A spell name without its rank suffix: companion's captures stop at the first period, so a cast or
-- tick line reads 'Foo Rk' while the resist line keeps 'Foo Rk. II', and the INI may name plain 'Foo'.
local function baseSpell(s)
    return (tostring(s or ''):gsub('%s+Rk%.%s*%a+$', ''):gsub('%s+Rk$', ''))
end
M.baseSpell = baseSpell

local function emit(ev)
    for _, fn in ipairs(listeners) do
        local ok, err = pcall(fn, ev)
        if not ok then Logger.write('\arfeed listener error: %s', tostring(err)) end
    end
end

-- Drop pending casts that never got a confirming tick/resist within GRACE_MS,
-- reporting each as its own 'expired' event (not a landed(0)) so callers don't
-- mistake a timeout for a zero-damage hit. Only diag.expired counts it - a
-- cast that never resolved is neither a landed hit nor a resist. Shared by
-- claim() (called on every resist/hit correlation) and tick() (the idle sweep).
local function expirePending(now)
    local i = 1
    while i <= #pending do
        local p = pending[i]
        if (now - p.at) > GRACE_MS then
            table.remove(pending, i)
            diag.expired = diag.expired + 1
            emit({ type = 'expired', spell = p.spell, target = p.target, at = now })
        else
            i = i + 1
        end
    end
end

-- Correlate a resist/hit back to the cast that produced it. Expires stale
-- entries first, then prefers the newest pending entry matching both spell
-- and target. Targets compare without case: the cast carries the spawn's CleanName
-- ('a feran'), the tick or resist line the sentence-start capital ('A feran has taken ...').
-- A spell-only match is taken only when one side has no target (companion's getTarget failed,
-- or the payload has none): a tick of my DoT on one mob must not answer my cast on another.
local function claim(spell, target, now)
    expirePending(now)
    local targetMatch, targetIdx
    local anyMatch, anyIdx
    local want = target and tostring(target):lower() or ''
    for i, p in ipairs(pending) do
        if baseSpell(p.spell) == baseSpell(spell) then
            local pt = tostring(p.target or ''):lower()
            if want ~= '' and pt == want then
                targetMatch, targetIdx = p, i
            elseif want == '' or pt == '' then
                anyMatch, anyIdx = p, i
            end
        end
    end
    if targetMatch then
        table.remove(pending, targetIdx)
        return targetMatch
    elseif anyMatch then
        table.remove(pending, anyIdx)
        return anyMatch
    end
    return nil
end

local function onPayload(c)
    if type(c) ~= 'table' or c.id ~= 'evt' then
        diag.dropped = diag.dropped + 1
        return
    end
    local now = mq.gettime()
    -- mineSelf: this character is the one who cast/was targeted by resist -
    -- pets never own the character's pending casts. mineForDamage additionally
    -- counts the character's own pet's damage as "mine" for HP-tracking.
    local mineSelf = (c.source == me)
    if c.outcome == 'cast' then
        if not mineSelf then return end
        diag.casts = diag.casts + 1
        pending[#pending + 1] = { spell = c.ability, target = c.target or '', at = now }
        emit({ type = 'cast', spell = c.ability, target = c.target or '', at = now })
        return
    end
    if c.outcome == 'resist' then
        if not mineSelf then return end
        local p = claim(c.ability, c.target, now)
        diag.resisted = diag.resisted + 1
        -- claimed: this resist answered one of my pending casts; a repeat of the same line
        -- (another box's companion rebroadcasting it) is unclaimed and must not be counted twice
        emit({ type = 'resisted', spell = c.ability, target = c.target or (p and p.target) or '', claimed = p ~= nil, at = now })
        return
    end
    if c.outcome == 'hit' and c.incoming ~= true then
        local amount = tonumber(c.amount) or 0
        local mineForDamage = mineSelf or (c.myPet == true)
        if amount > 0 and c.kind ~= 'heal' then
            diag.damage = diag.damage + 1
            emit({ type = 'damage', source = c.source, target = c.target, ability = c.ability,
                kind = c.kind, amount = amount, mine = mineForDamage, at = now })
        end
        if mineSelf and (c.kind == 'dot' or c.kind == 'nuke') then
            local p = claim(c.ability, c.target, now)
            if p then
                diag.landed = diag.landed + 1
                emit({ type = 'landed', spell = c.ability, target = c.target or p.target or '', amount = amount, at = now })
            end
        end
    end
end

function M.on(fn) listeners[#listeners + 1] = fn end

function M.start(myName)
    me = myName or ''
    if not okA or not actors then
        Logger.write('\aractors unavailable - no companion feed.')
        return false
    end
    mailbox = actors.register('companion_events', function(message)
        local ok, c = pcall(message)
        if ok then
            onPayload(c)
        else
            diag.dropped = diag.dropped + 1
        end
    end)
    return mailbox ~= nil
end

-- Expire casts that never produced a tick or a resist (buffs, taps, pet spells,
-- instant kills). Reported as 'expired' events so callers can keep counts.
function M.tick()
    expirePending(mq.gettime())
end

function M.stop()
    if mailbox and mailbox.unregister then pcall(mailbox.unregister, mailbox) end
    mailbox = nil
    pending = {}
end

function M.diag() return diag end
return M
