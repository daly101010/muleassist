-- focusswap/limits.lua — pure focus maths: a focus spell's raw effect slots -> focus records, whether
-- a record applies to a spell, and what it is worth. No mq dependency.
-- The limit SPA numbers follow eqlib's SPA_FOCUS_* enum as recalled on 2026-09-23; /focusswap dump
-- (plan Task 8) confirms them against Magelo. Fix them here if the dump disagrees.
local M = {}

-- the focus types (SPA_FOCUS_DAMAGE_MOD .. SPA_FOCUS_STUNTIME_MOD)
M.VALUE_SPAS = { [124] = true, [125] = true, [126] = true, [127] = true, [128] = true,
    [129] = true, [130] = true, [131] = true, [132] = true, [133] = true }

M.LIMIT = {
    LEVEL_MAX = 134, RESIST = 135, TARGET = 136, EFFECT = 137, BENEFICIAL = 138, SPELL = 139,
    DURATION_MIN = 140, INSTANT = 141, LEVEL_MIN = 142, CAST_MIN = 143, CAST_MAX = 144, PROCS = 311,
}
local KNOWN_LIMIT = {}
for _, spa in pairs(M.LIMIT) do KNOWN_LIMIT[spa] = true end

-- SPA 135 base -> the Spell TLO's ResistType, lowercased (same order as F:\lua\FocusEffects.lua)
M.RESISTS = { 'magic', 'fire', 'cold', 'poison', 'disease', 'chromatic', 'prismatic', 'physical', 'corruption' }

-- Spell TLO TargetType string -> SPA 136 target id. Empty until /focusswap dump shows real ids: an
-- unmapped target matches nothing, so a target exclude never fires and a target include never passes.
M.TARGET_IDS = {}

-- filler slots in spell data: SPA 254 (placeholder), and SPA 10 / SPA 0 with nothing in them
function M.isBlank(e)
    local a = tonumber(e.attrib) or 0
    if a == 254 then return true end
    return (a == 10 or a == 0) and (tonumber(e.base) or 0) == 0 and (tonumber(e.base2) or 0) == 0
end

-- effects: { { attrib, base, base2 }, ... }. One focus record per value slot, all sharing the spell's
-- limits. A spell with no value slot is not a focus: returns {}. unknown lists SPAs this file does not
-- know; a record carrying them never applies.
function M.fromEffects(spellName, effects)
    local values, limits, unknown = {}, {}, {}
    for _, e in ipairs(effects or {}) do
        local a = tonumber(e.attrib) or 0
        if M.isBlank(e) then
            -- nothing in this slot
        elseif M.VALUE_SPAS[a] then
            values[#values + 1] = e
        elseif KNOWN_LIMIT[a] then
            limits[#limits + 1] = { spa = a, base = tonumber(e.base) or 0, base2 = tonumber(e.base2) or 0 }
        else
            unknown[#unknown + 1] = a
        end
    end
    local unk = (#unknown > 0) and unknown or nil
    local out = {}
    for _, v in ipairs(values) do
        local lo = tonumber(v.base) or 0
        local b2 = tonumber(v.base2) or 0
        out[#out + 1] = { spa = tonumber(v.attrib), lo = lo, hi = (b2 ~= 0) and b2 or lo,
            limits = limits, spell = spellName, unknown = unk }
    end
    return out, unk
end

-- include/exclude style limits: does the spell carry this key?
local function matches(spa, key, spell)
    local L = M.LIMIT
    if spa == L.RESIST then return M.RESISTS[key] ~= nil and M.RESISTS[key] == spell.resist end
    if spa == L.TARGET then return M.TARGET_IDS[spell.targetType or ''] == key end
    if spa == L.EFFECT then return spell.spas ~= nil and spell.spas[key] == true end
    if spa == L.SPELL then return spell.id == key end
    return false
end

-- spell: { id, level, resist, beneficial, durTicks, castMs, targetType, spas }
function M.applies(f, spell)
    if f.unknown then return false end
    local L = M.LIMIT
    local included = {}   -- include-style limit SPA -> matched by any of its entries
    for _, l in ipairs(f.limits or {}) do
        local s, b = l.spa, l.base
        if s == L.LEVEL_MAX then
            -- a decaying cap is priced in value(); a cap without decay is a hard cutoff
            if spell.level > b and l.base2 == 0 then return false end
        elseif s == L.LEVEL_MIN then
            if spell.level < b then return false end
        elseif s == L.BENEFICIAL then
            if (b == 1) ~= (spell.beneficial == true) then return false end
        elseif s == L.DURATION_MIN then
            if spell.durTicks < b then return false end
        elseif s == L.INSTANT then
            if b == 1 and spell.durTicks > 0 then return false end
            if b == 0 and spell.durTicks == 0 then return false end
        elseif s == L.CAST_MIN then
            if spell.castMs < b then return false end
        elseif s == L.CAST_MAX then
            if spell.castMs > b then return false end
        elseif s == L.PROCS then
            if b == 1 then return false end   -- procs only: a gem cast is never a proc
        else
            local hit = matches(s, math.abs(b), spell)
            if b < 0 then
                if hit then return false end
            else
                included[s] = included[s] or hit
            end
        end
    end
    for _, hit in pairs(included) do
        if not hit then return false end
    end
    return true
end

-- expected value: the middle of a lo..hi roll (or the fixed value), less level decay past the cap
function M.value(f, spell)
    local v = (f.lo + f.hi) / 2
    for _, l in ipairs(f.limits or {}) do
        if l.spa == M.LIMIT.LEVEL_MAX and spell.level > l.base then
            v = v * math.max(0, 1 - (spell.level - l.base) * l.base2 / 100)
        end
    end
    return v
end

return M
