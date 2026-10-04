-- necrobrain/procs.lua — self effects the ranker plays around, read from the character's song and
-- buff windows each decision:
--   * Gift of Mana (and its "(NN)" and Radiant forms): the next spell costs no mana, up to a spell
--     level cap carried in the proc's own limit slot (SPA 134);
--   * Chaotic Power: Demand for Blood's 25% recourse, DoT damage up for 60 s;
--   * Chaotic Weakness: its 1% recourse, DoT damage down for 12 s.
-- Both windows are read for every effect: the song window is where Gift of Mana lands, and the
-- Chaotic effects carry buff-window flags in the client data. MQ matches Song[name] / Buff[name] as a
-- case-insensitive substring, so 'Gift of Mana' also finds 'Gift of Mana (75)'.
-- Also the gem check for the DPS list: a spell that is not memorized is refused by the macro as
-- SKIPPED on every pick (its DPS path never re-memorizes).
local mq = require('mq')
local M = {}

M.GOM_NAMES = { 'Gift of Mana', 'Gift of Radiant Mana', 'Gift of Exquisite Radiant Mana' }
M.POWER_NAMES = { 'Chaotic Power' }
M.WEAKNESS_NAMES = { 'Chaotic Weakness' }
M.WINDOWS = { 'Song', 'Buff' }
local LEVEL_CAP_SPA = 134   -- focus limit: max spell level

-- The buff for name in one window, or nil. ok = false when the TLO read itself failed.
local function lookup(window, name)
    local ok, b = pcall(function() return mq.TLO.Me[window](name) end)
    if not ok then return nil, false end
    if not b then return nil, true end
    local okId, id = pcall(function() return b.ID() end)
    if not okId then return nil, false end
    id = tonumber(id)
    if id and id > 0 then return b, true end
    return nil, true
end

local function remainingSec(b)
    local ok, ms = pcall(function() return b.Duration.Raw() end)
    if ok and tonumber(ms) then return tonumber(ms) / 1000 end
    local ok2, s = pcall(function() return b.Duration.TotalSeconds() end)
    if ok2 and tonumber(s) then return tonumber(s) end
    return nil
end

local function nameOf(b, fallback)
    local ok, nm = pcall(function() return b() end)
    if ok and nm then return tostring(nm) end
    return fallback
end

-- Highest spell level the proc applies to: the SPA 134 limit slot, else the '(NN)' in its name.
local function levelCap(b, name)
    local ok, cap = pcall(function()
        local sp = b.Spell
        local n = tonumber(sp.NumEffects()) or 0
        if n <= 0 then n = 12 end
        for i = 1, math.min(12, n) do
            if tonumber(sp.Attrib(i)()) == LEVEL_CAP_SPA then return tonumber(sp.Base(i)()) end
        end
        return nil
    end)
    if ok and cap then return cap end
    return tonumber(tostring(name or ''):match('%((%d+)%)'))
end

-- { up, leftSec, name, window, levelCap } for the first name found, song window first.
-- readOk is false when a TLO read failed (the caller may fall back to a chat-line timer).
local function effect(names, wantCap)
    local readOk = true
    for _, name in ipairs(names) do
        for _, window in ipairs(M.WINDOWS) do
            local b, ok = lookup(window, name)
            if b then
                local nm = nameOf(b, name)
                return { up = true, leftSec = remainingSec(b), name = nm, window = window,
                    levelCap = wantCap and levelCap(b, nm) or nil }, true
            end
            if not ok then readOk = false end
        end
    end
    return { up = false }, readOk
end

-- All three effects in one read. ok = every TLO read worked.
function M.read()
    local gom, okG = effect(M.GOM_NAMES, true)
    local power, okP = effect(M.POWER_NAMES)
    local weakness, okW = effect(M.WEAKNESS_NAMES)
    return { gom = gom, power = power, weakness = weakness, ok = okG and okP and okW }
end

-- Which spell entries sit in a gem: { [spell] = bool }. AA entries are not spells and are left out.
-- known = false when no spell entry reads as memorized at all (zoning, spell set loading, a TLO
-- failure): the caller then skips the screen rather than hold every line.
function M.memorized(entries)
    local out, any, spells = {}, false, 0
    for _, e in ipairs(entries or {}) do
        if not e.isAA then
            spells = spells + 1
            local ok, slot = pcall(function() return mq.TLO.Me.Gem(e.rankName or e.spell)() end)
            slot = ok and tonumber(slot) or nil
            local mem = slot ~= nil and slot > 0
            out[e.spell] = mem
            if mem then any = true end
        end
    end
    return out, any or spells == 0
end

return M
