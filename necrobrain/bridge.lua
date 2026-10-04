-- necrobrain/bridge.lua — pure publish/ack bookkeeping between the brain and
-- muleassist. No mq dependency so it runs under plain luajit.
-- Contract (mirrors the SmartHeals bridge): the macro consumes a pick once
-- (Seq == Ack means handled); we republish when the pick changes or when the
-- macro has consumed the outstanding one and we still want it, and (live) retract
-- an unconsumed pick once we no longer want it. <prefix>Seq is
-- always the LAST varset so the macro never pairs a new seq with stale fields.
local M = {}

function M.newState()
    return { seq = 0, beat = 0, lastKey = nil }
end

function M.actionKey(action)
    if not action then return nil end
    return string.format('%s|%d|%s',
        tostring(action.spellName or ''),
        tonumber(action.targetId) or 0,
        tostring(action.mode or 'eff'))
end

function M.next(state, action, ackSeq, prefix, retract)
    prefix = prefix or 'SmartDPS'
    local consumed = (tonumber(ackSeq) or 0) >= state.seq
    if not action then
        -- Retract a pick the macro has not taken yet (its mob died, or nothing is worth casting
        -- now): a fresh seq naming NULL matches no DPS line, so the macro holds and acks it
        -- NOMATCH instead of casting a pick made for another moment. Once per pick.
        local stale = retract and state.lastKey ~= nil and not consumed
        state.lastKey = nil
        if not stale then return nil end
        state.seq = state.seq + 1
        return {
            { prefix .. 'Spell', 'NULL' },
            { prefix .. 'TargetID', '0' },
            { prefix .. 'Mode', 'eff' },
            { prefix .. 'Seq', tostring(state.seq) },
        }
    end
    local key = M.actionKey(action)
    if key == state.lastKey and not consumed then
        return nil
    end
    state.seq = state.seq + 1
    state.lastKey = key
    return {
        { prefix .. 'Spell', tostring(action.spellName or '') },
        { prefix .. 'TargetID', tostring(tonumber(action.targetId) or 0) },
        { prefix .. 'Mode', tostring(action.mode or 'eff') },
        { prefix .. 'Seq', tostring(state.seq) },
    }
end

function M.heartbeat(state, prefix)
    state.beat = state.beat + 1
    return { (prefix or 'SmartDPS') .. 'Beat', tostring(state.beat) }
end

-- The set of DPS lines the brain ranks, for the macro's live gate: |spell|spell|...| in list
-- order, capped at maxLen characters on whole entries. Returns the string and whether any
-- entries were left out (those fall back to the macro's legacy rules).
function M.rankedSet(spells, maxLen)
    maxLen = tonumber(maxLen) or 2000
    local s, truncated = '|', false
    for _, name in ipairs(spells or {}) do
        local nxt = s .. tostring(name) .. '|'
        if #nxt > maxLen then truncated = true; break end
        s = nxt
    end
    return s, truncated
end

return M
