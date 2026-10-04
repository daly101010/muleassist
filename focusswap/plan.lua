-- focusswap/plan.lua — pure: which item each covered spell wants in which contested slot, and the
-- FocusMap string the macro reads. No mq dependency.
local Limits = require('focusswap.limits')
local M = {}

M.DEFAULT_WEIGHTS = { [124] = 1.0, [125] = 1.0, [127] = 0.5, [128] = 1.0, [132] = 0.5 }
M.MAX_LEN = 2000   -- macro string limit (2048) less the '/varset FocusMap ' prefix

-- EQ applies only the best focus of each type, so a set of items scores the sum over types of
-- weight * the best value that applies to this spell.
function M.setScore(items, spell, weights)
    weights = weights or M.DEFAULT_WEIGHTS
    local best = {}
    for _, it in ipairs(items) do
        for _, f in ipairs(it.foci or {}) do
            if (weights[f.spa] or 0) ~= 0 and Limits.applies(f, spell) then
                local v = Limits.value(f, spell)
                if best[f.spa] == nil or v > best[f.spa] then best[f.spa] = v end
            end
        end
    end
    local total = 0
    for spa, v in pairs(best) do
        local w = weights[spa] or 0
        -- a longer duration only pays on a DoT
        if spa == 128 and not (spell.durTicks > 0 and not spell.beneficial) then w = 0 end
        total = total + w * v
    end
    return total
end

-- Candidates for a slot: the item worn there, then every unblocked bag item that fits it. Returns the
-- contested slots (two or more candidates), worn slots in name order, then slots only bag items fit.
function M.candidates(inv, blocked)
    blocked = blocked or {}
    local bySlot, order = {}, {}
    local function add(slot, it)
        if not bySlot[slot] then bySlot[slot] = {}; order[#order + 1] = slot end
        table.insert(bySlot[slot], it)
    end
    local wornSlots = {}
    for slot in pairs(inv.worn or {}) do wornSlots[#wornSlots + 1] = slot end
    table.sort(wornSlots)
    for _, slot in ipairs(wornSlots) do add(slot, inv.worn[slot]) end
    for _, it in ipairs(inv.bag or {}) do
        if not blocked[it.name] then
            for _, slot in ipairs(it.fits or {}) do add(slot, it) end
        end
    end
    local out = {}
    for _, slot in ipairs(order) do
        if #bySlot[slot] >= 2 then out[#out + 1] = { slot = slot, items = bySlot[slot] } end
    end
    return out
end

-- spells: spell records (limits.lua shape; name = the INI name, key = the spell's RankName falling
-- back to name - the map is keyed on this, since it's what CastWhat receives as castWhat). opts:
-- { weights, minGain (3), blocked = { [item name] = true }, maxLen (2000) }. The map is absolute:
-- it names the best item for every contested spell, worn or not, so it only changes when the
-- inventory does.
function M.build(inv, spells, opts)
    opts = opts or {}
    local weights = opts.weights or M.DEFAULT_WEIGHTS
    local minGain = tonumber(opts.minGain) or 3
    local maxLen = tonumber(opts.maxLen) or M.MAX_LEN
    local contested = M.candidates(inv, opts.blocked)
    local entries = {}
    for _, spell in ipairs(spells or {}) do
        local pick
        for _, c in ipairs(contested) do
            -- every other slot stays as worn
            local others = {}
            for slot, it in pairs(inv.worn or {}) do
                if slot ~= c.slot then others[#others + 1] = it end
            end
            local bestItem, best, second
            for _, it in ipairs(c.items) do
                others[#others + 1] = it
                local s = M.setScore(others, spell, weights)
                others[#others] = nil
                if best == nil or s > best then
                    second, best, bestItem = best, s, it
                elseif second == nil or s > second then
                    second = s
                end
            end
            local gain = best - (second or best)
            if gain >= minGain and (pick == nil or gain > pick.gain) then
                pick = { spell = spell.key or spell.name, item = bestItem.name, slot = c.slot, gain = gain }
            end
        end
        if pick then entries[#entries + 1] = pick end
    end
    local map, truncated = '', false
    if #entries > 0 then
        map = '|'
        for _, e in ipairs(entries) do
            local nxt = map .. e.spell .. '>' .. e.item .. '>' .. e.slot .. '|'
            if #nxt > maxLen then truncated = true; break end
            map = nxt
        end
        if map == '|' then map = '' end
    end
    return { entries = entries, map = map, truncated = truncated }
end

return M
