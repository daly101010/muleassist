-- core/spell.lua: spell facts, rank normalisation (Spell_Rk_Check) and readiness, cached per name.
local mq = require('mq')
local T = require('core.tlo')

local M = { _facts = {} }

--- The highest rank the character has of a base spell name ("Remedy" -> "Remedy Rk. III"), else the name.
--- Mirrors Spell_Rk_Check: Rk. III, then Rk. II, then the base; AAs and items are left alone.
function M.rank(name)
    if not name or name == '' then return name end
    if name:find('Rk%.') then return name end
    for _, suffix in ipairs({ ' Rk. III', ' Rk. II' }) do
        local cand = name .. suffix
        if T.num(function() return mq.TLO.Me.Book(cand)() end) > 0 then return cand end
    end
    return name
end

--- What kind of thing a name is: 'spell' (in the book), 'aa', 'item', 'disc', or nil.
function M.kind(name)
    local f = M._facts[name]
    if f and f.kind then return f.kind end
    if T.num(function() return mq.TLO.Me.Book(name)() end) > 0 then return 'spell' end
    if T.num(function() return mq.TLO.Me.AltAbility(name).ID() end) > 0 then return 'aa' end
    if T.num(function() return mq.TLO.FindItem('=' .. name).ID() end) > 0 then return 'item' end
    if T.num(function() return mq.TLO.Me.CombatAbility(name)() end) > 0 then return 'disc' end
    if T.num(function() return mq.TLO.Spell(name).ID() end) > 0 then return 'spell' end
    return nil
end

--- The spell object behind a name (its own, an AA's or an item's clicky), or nil.
function M.spellOf(name, kind)
    kind = kind or M.kind(name)
    if kind == 'aa' then
        local aa = mq.TLO.Me.AltAbility(name)
        if aa and aa() and aa.Spell and aa.Spell() then return aa.Spell end
    elseif kind == 'item' then
        local it = mq.TLO.FindItem('=' .. name)
        if it and it() and it.Spell and it.Spell() then return it.Spell end
    else
        local sp = mq.TLO.Spell(name)
        if sp and sp() then return sp end
    end
    return nil
end

--- Static facts, cached: range, aerange, castMs, mana, targetType, kind ('direct'|'hot'|'group'|'other'),
--- beneficial, spellType.
function M.facts(name)
    local f = M._facts[name]
    if f then return f end
    local kind = M.kind(name)
    f = { name = name, kind = kind, range = 0, aerange = 0, castMs = 0, mana = 0, targetType = '', cat = 'other', beneficial = false,
        durationSec = 0, recastSec = 0, level = 0, spellType = '', subcategory = '' }
    local sp = M.spellOf(name, kind)
    if sp then
        f.range = T.num(function() return sp.MyRange() end)
        f.aerange = T.num(function() return sp.AERange() end)
        f.castMs = T.num(function() return sp.MyCastTime() end)
        f.mana = T.num(function() return sp.Mana() end)
        f.targetType = T.str(function() return sp.TargetType() end)
        f.spellType = T.str(function() return sp.SpellType() end)
        f.subcategory = T.str(function() return sp.Subcategory() end)
        f.beneficial = f.spellType:lower() ~= 'detrimental'
        f.durationSec = T.num(function() return sp.Duration.TotalSeconds() end)
        f.recastSec = T.num(function() return sp.RecastTime.TotalSeconds() end)
        f.level = T.num(function() return sp.Level() end)
        local tt = f.targetType:lower()
        if tt:find('group') then f.cat = 'group'
        elseif not f.beneficial then f.cat = 'other'
        elseif f.subcategory:lower():find('duration') then f.cat = 'hot'
        else f.cat = 'direct' end
        f.hasSPA = function(n) return T.bool(function() return sp.HasSPA(n)() end) end
    end
    if kind then M._facts[name] = f end   -- unknown names are not cached: a later scribe shows up
    return f
end

function M.clearCache() M._facts = {} end

--- Ready to use now (memorised and off cooldown, AA/item/disc off reuse).
function M.ready(name, kind)
    kind = kind or M.facts(name).kind
    if kind == 'spell' then return T.bool(function() return mq.TLO.Me.SpellReady(name)() end) end
    if kind == 'aa' then return T.bool(function() return mq.TLO.Me.AltAbilityReady(name)() end) end
    if kind == 'item' then return T.bool(function() return mq.TLO.Me.ItemReady(name)() end) end
    if kind == 'disc' then return T.bool(function() return mq.TLO.Me.CombatAbilityReady(name)() end) end
    return false
end

function M.memmed(name)
    return T.num(function() return mq.TLO.Me.Gem(name)() end) > 0
end

function M.haveMana(name)
    local f = M.facts(name)
    return f.mana + 20 <= T.num(function() return mq.TLO.Me.CurrentMana() end)
end

return M
