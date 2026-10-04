-- core/lines.lua: the macro's "Spell|pct|tag, tag" entries, parsed once. Pure Lua (no mq).
--
-- parse('Complete Heal|40|MA, buff!=Divine Aura') ->
--   { raw=..., name='Complete Heal', pct=40, tags={ma=true}, tagList={'ma','buff!=divine aura'},
--     buff='Divine Aura', buffOp='!=', args={'Complete Heal','40','MA, buff!=Divine Aura'} }
-- Tags are matched by exact membership of the normalised ,tag, list, as SingleHeal does; the pct is nil
-- when the second field is not a number (DPS lines carry other things there).
local M = {}

local function trim(s) return (tostring(s or ''):gsub('^%s+', ''):gsub('%s+$', '')) end

function M.split(s, sep)
    local out = {}
    s = tostring(s or '')
    local start = 1
    while true do
        local i = s:find(sep, start, true)
        if not i then out[#out + 1] = s:sub(start) break end
        out[#out + 1] = s:sub(start, i - 1)
        start = i + #sep
    end
    return out
end

--- Parse one INI entry. Returns nil for an empty / NULL entry.
function M.parse(entry)
    entry = trim(entry)
    if entry == '' or entry:upper() == 'NULL' then return nil end
    local args = M.split(entry, '|')
    local line = { raw = entry, args = args, name = trim(args[1]), tags = {}, tagList = {} }
    line.pct = tonumber(trim(args[2] or ''))
    local tagField = args[3] or ''
    -- the macro normalises with Replace[ ,] (spaces removed) and tests ,tag, membership
    for _, t in ipairs(M.split(tagField, ',')) do
        local tag = trim(t):lower()
        if tag ~= '' then
            line.tagList[#line.tagList + 1] = tag
            line.tags[tag:gsub('%s+', '')] = true
            local op, buff = tag:match('^buff(%!?=)=?(.+)$')
            if not op then op, buff = tag:match('^buff(==)(.+)$') end
            if op then
                -- keep the buff's own case and spaces: the original tag field has them
                local rawTag = trim(t)
                line.buffOp = op == '!=' and '!=' or '=='
                line.buff = trim(rawTag:sub(#('buff' .. line.buffOp) + 1))
            end
        end
    end
    -- the remaining pipe fields (DPS/Buffs lines carry more)
    line.extra = {}
    for i = 4, #args do line.extra[#line.extra + 1] = trim(args[i]) end
    return line
end

--- Parse an array of entries (nil entries dropped, order kept, original index kept in .index).
function M.parseAll(entries)
    local out = {}
    for i, e in ipairs(entries or {}) do
        local l = M.parse(e)
        if l then l.index = i out[#out + 1] = l end
    end
    return out
end

function M.has(line, tag) return line.tags[tag:lower():gsub('%s+', '')] == true end

--- Does this line land on the heal tank? (no !MA / me / pet / tap tag) - the FindSingleHeals rule.
function M.landsOnTank(line)
    return not (M.has(line, '!ma') or M.has(line, 'me') or M.has(line, 'pet') or M.has(line, 'tap'))
end

--- The macro's single-heal join rule: a line joins SingleHeal when it is not a rez entry and is single
--- target; the caller passes targetType from the spell. Group spells go to GroupHeal.
function M.isRezEntry(line)
    return M.has(line, 'rez') or M.has(line, 'rezooc') or M.has(line, 'rezcombat')
end

return M
