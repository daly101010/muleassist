-- focusswap/scan.lua — reads worn gear and carried bags into item records for plan.lua, and the
-- covered spells into spell records. Every TLO read is guarded: a failed read is a missing value.
-- Class lists are never read (Lethar has no class restrictions on gear).
-- Cost: MQ budgets Lua VM instructions per frame (turbo), and a pcall'd closure per field is ~20 of them
-- where the read itself is ~4. So each unit of work (an item, its fits, an effect list, the inventory
-- walk, the fingerprint) reads directly under ONE pcall and, should any read raise, is redone through the
-- per-field guards (the *Guarded functions, the reference behaviour), so a failed read still reads as a
-- missing value. Bag items that fit no swappable slot are dropped before their augments and effects are
-- read.
local mq = require('mq')
local Limits = require('focusswap.limits')
local M = {}

M.WORN_FIRST, M.WORN_LAST = 0, 22
M.PACK_FIRST, M.PACK_LAST = 23, 34
-- range, primary, secondary, ammo: never swapped (2H/offhand handling, melee)
M.WEAPON_SLOTS = { [11] = true, [13] = true, [14] = true, [22] = true }
M.EFFECT_FIELDS = { 'Focus', 'Focus2', 'Worn' }

local function get(fn)
    local ok, v = pcall(fn)
    if ok then return v end
    return nil
end
local function num(fn)
    local ok, v = pcall(fn)
    return ok and tonumber(v) or 0
end
local function text(v)
    if v == nil then return nil end
    v = tostring(v)
    if v == '' or v == 'NULL' then return nil end
    return v
end
local function str(fn)
    local ok, v = pcall(fn)
    if ok then return text(v) end
    return nil
end
local function idOf(it) return it.ID() end
local function present(it)
    if it == nil then return false end
    local ok, v = pcall(idOf, it)
    return ok and (tonumber(v) or 0) > 0
end

-- raw effect slots of a spell TLO, or nil when there is no spell
local function readEffectsGuarded(sp)
    if sp == nil or str(function() return sp() end) == nil then return nil end
    local n = num(function() return sp.NumEffects() end)
    if n <= 0 then n = 12 end
    local out = {}
    for i = 1, math.min(12, n) do
        out[#out + 1] = {
            attrib = num(function() return sp.Attrib(i)() end),
            base = num(function() return sp.Base(i)() end),
            base2 = num(function() return sp.Base2(i)() end),
            max = num(function() return sp.Max(i)() end),
        }
    end
    return out
end
-- the same reads unguarded (run under one pcall): up to 48 fields per spell
local function readEffectsDirect(sp)
    if sp == nil or text(sp()) == nil then return nil end
    local n = tonumber(sp.NumEffects()) or 0
    if n <= 0 then n = 12 end
    local out = {}
    for i = 1, math.min(12, n) do
        out[#out + 1] = {
            attrib = tonumber(sp.Attrib(i)()) or 0,
            base = tonumber(sp.Base(i)()) or 0,
            base2 = tonumber(sp.Base2(i)()) or 0,
            max = tonumber(sp.Max(i)()) or 0,
        }
    end
    return out
end
function M.readEffects(sp)
    local ok, out = pcall(readEffectsDirect, sp)
    if ok then return out end
    return readEffectsGuarded(sp)
end

-- the swappable slot names an item fits, in WornSlot order (never a weapon slot); {} for an item that
-- cannot be worn (WornSlots 0)
local function fitsGuarded(it)
    local fits, seen = {}, {}
    for n = 1, num(function() return it.WornSlots() end) do
        local id = tonumber(get(function() return it.WornSlot(n).ID() end))
        if id and id >= M.WORN_FIRST and id <= M.WORN_LAST and not M.WEAPON_SLOTS[id] then
            local slot = str(function() return mq.TLO.InvSlot(id).Name() end)
            if slot and not seen[slot] then
                seen[slot] = true
                fits[#fits + 1] = slot
            end
        end
    end
    return fits
end
local function fitsDirect(it)
    local fits, seen = {}, {}
    for n = 1, tonumber(it.WornSlots()) or 0 do
        local id = tonumber(it.WornSlot(n).ID())
        if id and id >= M.WORN_FIRST and id <= M.WORN_LAST and not M.WEAPON_SLOTS[id] then
            local slot = text(mq.TLO.InvSlot(id).Name())
            if slot and not seen[slot] then
                seen[slot] = true
                fits[#fits + 1] = slot
            end
        end
    end
    return fits
end
function M.fits(it)
    local ok, fits = pcall(fitsDirect, it)
    if ok then return fits end
    return fitsGuarded(it)
end

-- one item and its augments -> item record; fits: M.fits(it), when the caller already read it
local function addFoci(rec, sname, eff)
    local foci, unknown = Limits.fromEffects(sname, eff)
    if #foci > 0 then
        rec.spells[#rec.spells + 1] = { name = sname, effects = eff }
        for _, f in ipairs(foci) do rec.foci[#rec.foci + 1] = f end
        if unknown then rec.unknown[#rec.unknown + 1] = sname end
    end
end
local function readItemGuarded(it, fits)
    local name = str(function() return it.Name() end)
    if not name then return nil end
    local rec = { name = name, id = num(function() return it.ID() end), foci = {}, spells = {}, fits = {}, unknown = {} }
    local function addEffects(src)
        for _, field in ipairs(M.EFFECT_FIELDS) do
            local sp = get(function() return src[field].Spell end)
            local sname = sp and str(function() return sp.Name() end)
            local eff = sname and M.readEffects(sp)
            if eff then addFoci(rec, sname, eff) end
        end
    end
    addEffects(it)
    for i = 1, 6 do
        local aug = get(function() return it.AugSlot(i).Item end)
        if present(aug) then addEffects(aug) end
    end
    rec.fits = fits or fitsGuarded(it)
    -- equipping an unattuned attuneable item pops a confirmation that would hang the /itemnotify swap
    rec.attunePending = get(function() return it.Attuneable() end) == true
        and get(function() return it.NoDrop() end) ~= true
    return rec
end
local function readItemDirect(it, fits)
    local name = text(it.Name())
    if not name then return nil end
    local rec = { name = name, id = tonumber(it.ID()) or 0, foci = {}, spells = {}, fits = {}, unknown = {} }
    local fields = M.EFFECT_FIELDS
    local function addEffects(src)
        for f = 1, #fields do
            local sp = src[fields[f]].Spell
            local sname = sp and text(sp.Name())
            local eff = sname and readEffectsDirect(sp)
            if eff then addFoci(rec, sname, eff) end
        end
    end
    addEffects(it)
    for i = 1, 6 do
        local aug = it.AugSlot(i).Item
        if aug ~= nil and (tonumber(aug.ID()) or 0) > 0 then addEffects(aug) end
    end
    rec.fits = fits or fitsDirect(it)
    rec.attunePending = it.Attuneable() == true and it.NoDrop() ~= true
    return rec
end
function M.readItem(it, fits)
    local ok, rec = pcall(readItemDirect, it, fits)
    if ok then return rec end
    return readItemGuarded(it, fits)
end
M._readItemGuarded = readItemGuarded

-- every worn non-weapon item (focus or not: it is the slot's first candidate), and every carried bag
-- item that has a focus and fits a swappable slot.
-- A bag item is a candidate only if it fits a swappable slot, so that is read first: an item with no
-- WornSlots (tradeskill stuff, consumables) or only weapon slots costs one or two reads, not its
-- augments and effects.
local function considerer(inv)
    return function(it)
        local fits = M.fits(it)
        if #fits == 0 then return end
        local rec = M.readItem(it, fits)
        if not rec or #rec.foci == 0 then return end
        if rec.attunePending then inv.attune[#inv.attune + 1] = rec.name
        else inv.bag[#inv.bag + 1] = rec end
    end
end
local function inventoryGuarded()
    local inv = { worn = {}, bag = {}, attune = {} }
    for id = M.WORN_FIRST, M.WORN_LAST do
        if not M.WEAPON_SLOTS[id] then
            local it = get(function() return mq.TLO.Me.Inventory(id) end)
            if present(it) then
                local rec = M.readItem(it)
                local slot = str(function() return mq.TLO.InvSlot(id).Name() end)
                if rec and slot then
                    rec.slot = slot
                    inv.worn[slot] = rec
                end
            end
        end
    end
    local consider = considerer(inv)
    for id = M.PACK_FIRST, M.PACK_LAST do
        local pack = get(function() return mq.TLO.Me.Inventory(id) end)
        if present(pack) then
            local size = num(function() return pack.Container() end)
            if size > 0 then
                for j = 1, size do
                    local it = get(function() return pack.Item(j) end)
                    if present(it) then consider(it) end
                end
            else
                consider(pack)
            end
        end
    end
    return inv
end
-- the same walk unguarded (M.readItem and M.fits guard themselves); about 10 VM instructions a bag item
local function inventoryDirect()
    local inv = { worn = {}, bag = {}, attune = {} }
    for id = M.WORN_FIRST, M.WORN_LAST do
        if not M.WEAPON_SLOTS[id] then
            local it = mq.TLO.Me.Inventory(id)
            if it ~= nil and (tonumber(it.ID()) or 0) > 0 then
                local rec = M.readItem(it)
                local slot = text(mq.TLO.InvSlot(id).Name())
                if rec and slot then
                    rec.slot = slot
                    inv.worn[slot] = rec
                end
            end
        end
    end
    local consider = considerer(inv)
    for id = M.PACK_FIRST, M.PACK_LAST do
        local pack = mq.TLO.Me.Inventory(id)
        if pack ~= nil and (tonumber(pack.ID()) or 0) > 0 then
            local size = tonumber(pack.Container()) or 0
            if size > 0 then
                for j = 1, size do
                    local it = pack.Item(j)
                    if it ~= nil and (tonumber(it.ID()) or 0) > 0 then consider(it) end
                end
            else
                consider(pack)
            end
        end
    end
    return inv
end
function M.inventory()
    local ok, inv = pcall(inventoryDirect)
    if ok then return inv end
    return inventoryGuarded()
end
M._inventoryGuarded = inventoryGuarded

-- cheap change detector over every carried item ID (worn + bags): their count, sum and sum of squares,
-- which a swap (it only moves items) leaves alone and an item gained, lost or traded changes. It runs
-- every CHECK_MS, so it reads directly under one pcall (about 12 VM instructions per item instead of 75);
-- the guarded walk gives the same answer when a read raises.
local function fingerprintDirect()
    local n, sum, sq = 0, 0, 0
    for id = M.WORN_FIRST, M.PACK_LAST do
        local it = mq.TLO.Me.Inventory(id)
        local iid = it and tonumber(it.ID())
        if iid and iid > 0 then
            n, sum, sq = n + 1, sum + iid, sq + iid * iid
            if id >= M.PACK_FIRST then
                for j = 1, tonumber(it.Container()) or 0 do
                    local sub = it.Item(j)
                    local sid = sub and tonumber(sub.ID())
                    if sid and sid > 0 then n, sum, sq = n + 1, sum + sid, sq + sid * sid end
                end
            end
        end
    end
    return string.format('%d:%.0f:%.0f', n, sum, sq)
end
local function fingerprintGuarded()
    local n, sum, sq = 0, 0, 0
    local function add(it)
        local id = num(function() return it.ID() end)
        if id > 0 then n, sum, sq = n + 1, sum + id, sq + id * id end
    end
    for id = M.WORN_FIRST, M.PACK_LAST do
        local it = get(function() return mq.TLO.Me.Inventory(id) end)
        if present(it) then
            add(it)
            if id >= M.PACK_FIRST then
                for j = 1, num(function() return it.Container() end) do
                    local sub = get(function() return it.Item(j) end)
                    if present(sub) then add(sub) end
                end
            end
        end
    end
    return string.format('%d:%.0f:%.0f', n, sum, sq)
end
function M.fingerprint()
    local ok, fp = pcall(fingerprintDirect)
    if ok then return fp end
    return fingerprintGuarded()
end
M._fingerprintGuarded = fingerprintGuarded

-- a covered spell by its INI name -> the spell record limits.lua reads, or nil when the Spell TLO
-- does not know it (an AA line, a typo). key is the spell's RankName, falling back to the INI name:
-- muleassist's LoadIni runs every DPS<n> entry through Spell_Rk_Check, which rewrites it to
-- Spell[x].RankName when that differs, so CastWhat's castWhat - what the map is looked up by - is
-- the rank name, not necessarily the INI text.
function M.spellInfo(name)
    local sp = get(function() return mq.TLO.Spell(name) end)
    local eff = M.readEffects(sp)
    if not eff then return nil end
    local spas = {}
    for _, e in ipairs(eff) do
        if not Limits.isBlank(e) then spas[e.attrib] = true end
    end
    local stype = str(function() return sp.SpellType() end) or ''
    return {
        name = name,
        key = str(function() return sp.RankName() end) or name,
        id = num(function() return sp.ID() end),
        level = num(function() return sp.Level() end),
        resist = (str(function() return sp.ResistType() end) or ''):lower(),
        beneficial = stype:find('Beneficial', 1, true) ~= nil,
        durTicks = math.floor(num(function() return sp.Duration.TotalSeconds() end) / 6),
        castMs = num(function() return sp.CastTime() end),
        targetType = str(function() return sp.TargetType() end) or '',
        spas = spas,
    }
end

return M
