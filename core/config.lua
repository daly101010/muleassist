-- core/config.lua: the macro's LoadIni, as a schema-driven loader with the same file-level behaviour.
--
-- Semantics kept from Sub LoadIni:
--   * scalar keys: a missing key is written back with its default; the value is read with noparse
--   * arrays: XSize gives the count; X1..XN are read; a missing XN is written as the default ('NULL');
--     a run of NULLs at the end shrinks XSize to the last real entry (the "stop filling inis with 40 NULL
--     entries" rule); a NULL with real entries after it is reported (the macro ended; we warn and keep
--     going, skipping the blank)
--   * conditions: with ConditionsOn, XCondN is read from the conditions file (TRUE written when missing)
--   * string values that are spell names are normalised to the highest rank the character has
--     (Spell_Rk_Check) through an injectable `rankFn`
--   * Heals lines in zones 795/796 get their pct scaled by 0.7, DPS lines tagged debuffall get +100,
--     as before
--
-- A module declares its settings as a schema; Config.load(schema, ctx) returns a plain table.
--
-- Differences from LoadIni, on purpose:
--   * a key that is in the file is never written back, even when its value reads as missing (NULL or
--     empty): only an absent key gets its default. LoadIni rewrote such keys on every start.
--   * Config.round(fn) / beginRound .. endRound hold the INI (core.ini): it is read and parsed once and
--     every read in between is answered from that parse instead of one mq.TLO.Ini read per key.
local Ini = require('core.ini')
local Log = require('core.log')

local M = {}

M.iniFile = nil          -- MuleAssist_<Server>_<Name>.ini
M.condFile = nil         -- the conditions file (same file unless ConditionsFileName differs)
M.conditionsOn = 2
M.rankFn = function(name) return name end   -- Spell_Rk_Check hook (core.spell sets it in game)
M.zoneId = function() return 0 end

local function isNull(v) return v == nil or v == '' or tostring(v):upper() == 'NULL' end

--- File name as the macro built it.
function M.fileName(server, name, level)
    if level then return string.format('MuleAssist_%s_%s_%d.ini', server, name, level) end
    return string.format('MuleAssist_%s_%s.ini', server, name)
end

local function coerce(kind, v, default)
    if kind == 'int' then
        local n = tonumber(v)
        if n == nil then return tonumber(default) or 0 end
        return math.floor(n)
    elseif kind == 'float' then
        return tonumber(v) or tonumber(default) or 0
    elseif kind == 'bool' then
        if v == nil then v = default end
        v = tostring(v):upper()
        return v == '1' or v == 'TRUE' or v == 'ON'
    end
    if v == nil then return default == nil and '' or tostring(default) end
    return tostring(v)
end

local function looksLikeSpellName(v)
    return type(v) == 'string' and v ~= '' and not tonumber(v:sub(1, 1)) and v:upper() ~= 'NULL'
end

--- Load one scalar key: { section=, key=, type='int'|'string'|'bool'|'float', default=, rank=bool }
function M.scalar(spec, file)
    file = file or M.iniFile
    local v = Ini.read(file, spec.section, spec.key)
    if v == nil then
        if spec.default ~= nil and tostring(spec.default) ~= '' and not Ini.exists(file, spec.section, spec.key) then
            Ini.write(file, spec.section, spec.key, spec.default)
        end
        v = spec.default
    end
    local out = coerce(spec.type or 'string', v, spec.default)
    if spec.type == 'string' and spec.rank ~= false and looksLikeSpellName(out) and not spec.key:find('Help') then
        local ranked = M.rankFn(out)
        if ranked and ranked ~= '' then out = ranked end
    end
    return out
end

--- Load an array: { section=, name='Heals', size={key='HealsSize', default=20}, cond='HealsCond' }
--- Returns entries (1..n of strings, 'NULL' for empty), conds (TRUE/FALSE strings), size.
function M.array(spec, file)
    file = file or M.iniFile
    local sizeKey = spec.size and spec.size.key or (spec.name .. 'Size')
    local size = M.scalar({ section = spec.section, key = sizeKey, type = 'int', default = spec.size and spec.size.default or 20 }, file)
    local entries, conds = {}, {}
    local lastReal = 0
    for i = 1, size do
        local key = spec.name .. i
        local v = Ini.read(file, spec.section, key)
        if v == nil then
            if not Ini.exists(file, spec.section, key) then Ini.write(file, spec.section, key, 'NULL') end
            v = 'NULL'
        end
        if not isNull(v) then
            lastReal = i
            if looksLikeSpellName(v) and spec.rank ~= false then
                local nameOnly = v:match('^([^|]*)') or v
                local rest = v:sub(#nameOnly + 1)
                local ranked = M.rankFn(nameOnly)
                if ranked and ranked ~= '' then v = ranked .. rest end
            end
            if spec.section == 'Heals' and (M.zoneId() == 795 or M.zoneId() == 796) then
                local name, pct, rest = v:match('^([^|]*)|(%d+)(.*)$')
                if pct then v = string.format('%s|%d%s', name, math.floor(tonumber(pct) * 0.7), rest) end
            elseif spec.section == 'DPS' then
                local name, pct, rest = v:match('^([^|]*)|(%d+)|debuffall(.*)$')
                if pct then v = string.format('%s|%d|debuffall%s', name, tonumber(pct) + 100, rest) end
            end
        end
        entries[i] = v
        if spec.cond then
            local condKey = spec.cond .. i
            if M.conditionsOn ~= 0 then
                local c = Ini.read(M.condFile or file, spec.section, condKey)
                if c == nil then
                    c = isNull(v) and 'FALSE' or 'TRUE'
                    if not Ini.exists(M.condFile or file, spec.section, condKey) then
                        Ini.write(M.condFile or file, spec.section, condKey, c)
                    end
                end
                conds[i] = c
            else
                conds[i] = 'TRUE'
            end
        end
    end
    -- trailing NULLs shrink the size (and the file), blanks in the middle are reported and skipped
    if lastReal < size then
        Ini.write(file, spec.section, sizeKey, lastReal)
        for i = size, lastReal + 1, -1 do entries[i] = nil conds[i] = nil end
        size = lastReal
    end
    for i = 1, size do
        if isNull(entries[i]) then
            Log.warn('%s%d is blank with entries after it - the blank is skipped; remove it in the editor', spec.name, i)
        end
    end
    return entries, conds, size
end

--- Load a whole schema: { scalars = { {section,key,type,default}, ... }, arrays = { {...}, ... } }
--- Scalars land at out[key]; arrays at out[name] (entries), out[name..'Cond'] (conds), out[name..'Size'].
function M.load(schema, file)
    local out = {}
    for _, s in ipairs(schema.scalars or {}) do out[s.key] = M.scalar(s, file) end
    for _, a in ipairs(schema.arrays or {}) do
        local e, c, n = M.array(a, file)
        out[a.name] = e
        if a.cond then out[a.cond] = c end
        out[a.name .. 'Size'] = n
    end
    return out
end

--- Write one value (the /changevarint, /iniwrite path). A held INI sees the write at once (core.ini).
function M.set(section, key, value, file)
    Ini.write(file or M.iniFile, section, key, value)
end

-- ---------------------------------------------------------------- LoadSettings rounds
-- Between beginRound and endRound the character INI (and the conditions file, when it differs) is held:
-- parsed once, every Config read answered from the parse, writes landing in it as they go to /ini.
-- Rounds nest. Outside a round reads go to mq.TLO.Ini as before, so an edit made in MAUI between
-- rounds is seen by the next one.
local rounds = {}

function M.beginRound()
    local files, seen = {}, {}
    for _, f in ipairs({ M.iniFile or false, M.condFile or false }) do
        if f and not seen[f] then
            seen[f] = true
            if Ini.hold(f) then files[#files + 1] = f end
        end
    end
    rounds[#rounds + 1] = files
end

function M.endRound()
    local files = table.remove(rounds)
    for _, f in ipairs(files or {}) do Ini.release(f) end
end

--- fn(...) inside a round; the round ends even when fn raises (the error is re-raised).
function M.round(fn, ...)
    M.beginRound()
    local ok, err = pcall(fn, ...)
    M.endRound()
    if not ok then error(err, 0) end
end

return M
