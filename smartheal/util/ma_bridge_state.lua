-- Pure publish/ack bookkeeping for the muleassist heal bridge (ma_healbridge.lua).
-- No mq dependency so it stays testable under plain luajit.
local M = {}

function M.newState()
    return { seq = 0, beat = 0, lastKey = nil }
end

function M.actionKey(action)
    if not action then return nil end
    return string.format('%s|%d|%s',
        tostring(action.spellName or ''),
        tonumber(action.targetId) or 0,
        tostring(action.tier or 'single'))
end

--- Advance one bridge loop. Increments the heartbeat, and decides whether the
--- action needs (re-)publishing: publish when the action changed, or when the
--- macro has consumed the outstanding seq and the action is still wanted.
--- Returns an ordered varset batch ({name, value} pairs) or nil.
--- SmartHealSeq is always last so the macro never pairs a new seq with stale fields.
function M.next(state, action, ackSeq)
    state.beat = state.beat + 1
    if not action then
        local outstanding = state.lastKey ~= nil and (tonumber(ackSeq) or 0) < state.seq
        state.lastKey = nil
        if not outstanding then return nil end
        -- Withdraw an unconsumed recommendation. Seq last makes the clear atomic
        -- to the macro, just like publishing a replacement action.
        state.seq = state.seq + 1
        return {
            { 'SmartHealSpell', 'NULL' },
            { 'SmartHealTargetID', '0' },
            { 'SmartHealTier', 'none' },
            { 'SmartHealSeq', tostring(state.seq) },
        }
    end
    local key = M.actionKey(action)
    local consumed = (tonumber(ackSeq) or 0) >= state.seq
    if key == state.lastKey and not consumed then
        return nil
    end
    state.seq = state.seq + 1
    state.lastKey = key
    return {
        { 'SmartHealSpell', tostring(action.spellName or '') },
        { 'SmartHealTargetID', tostring(tonumber(action.targetId) or 0) },
        { 'SmartHealTier', tostring(action.tier or 'single') },
        { 'SmartHealSeq', tostring(state.seq) },
    }
end

--- Call each loop with the macro's live SmartHealSeq. A macro restart resets
--- its outer variables to 0; when the macro's seq falls behind ours, clear
--- lastKey so the next action republishes at a fresh seq.
function M.noteMacroSeq(state, macroSeq)
    if (tonumber(macroSeq) or 0) < state.seq then
        state.lastKey = nil
    end
end

--- Send only to UI hosts on this character. Never broadcast healer-local seqs.
function M.sendTelemetry(actor, payload, character, server)
    if not character or character == '' or not server or server == '' then return false end
    for _, script in ipairs({ 'companion', 'maui', 'medley' }) do
        actor:send({ mailbox = 'companion_smartheal', script = script,
            character = character, server = server }, payload)
    end
    return true
end

return M
