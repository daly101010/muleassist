-- core/buffrules.lua: pure buff decisions shared by the buffs, pet and beg code (no mq). Each rule names
-- the macro Sub it comes from; the tests pin the thresholds.
local M = {}

M.CASTERS = { CLR = true, DRU = true, SHM = true, BST = true, ENC = true, MAG = true, NEC = true, PAL = true, SHD = true, RNG = true, WIZ = true }
M.MELEE = { BRD = true, BER = true, BST = true, MNK = true, PAL = true, ROG = true, RNG = true, SHD = true, WAR = true }
M.REGEN_CLASSES = {
    endurance = 'BER,BST,MNK,PAL,RNG,ROG,SHD,WAR',
    mana = 'BRD,BST,CLR,DRU,ENC,MAG,NEC,PAL,RNG,SHD,SHM,WIZ',
}
-- zones where a range OOG buff is given once per spawn instance (buffs do not drop there)
M.NODROP_ZONES = { poknowledge = true, nexus = true, guildlobby = true, bazaar = true, guildhall = true }
-- zones where Spell.StacksSpawn is unreliable and ignored
M.STACKS_BROKEN_ZONES = { poknowledge = true, guildlobby = true, guildhall = true }

--- Is `class` in the comma list `list` (case-insensitive, blanks ignored)?
function M.inList(list, class)
    if not list or not class then return false end
    class = tostring(class):upper()
    for tok in tostring(list):gmatch('[^,|]+') do
        tok = tok:gsub('^%s+', ''):gsub('%s+$', ''):upper()
        if tok ~= '' and tok == class then return true end
    end
    return false
end

--- WillItStick: can a buff of this spell level land on a target of this level (level floors, 7809-7921)?
local FLOORS = { { 50, 0 }, { 51, 40 }, { 53, 41 }, { 55, 42 }, { 57, 43 }, { 59, 44 }, { 61, 45 }, { 63, 46 }, { 65, 47 },
    { 95, 61 }, { 100, 66 }, { 105, 71 }, { 110, 76 }, { 115, 81 } }
function M.willStick(spellLevel, targetLevel)
    spellLevel = tonumber(spellLevel) or 0
    targetLevel = tonumber(targetLevel) or 0
    for _, f in ipairs(FLOORS) do
        if spellLevel <= f[1] then return targetLevel >= f[2] end
    end
    return true
end

--- The caster / Melee / class tag filter (OOGBuff 11247-11269, CheckIniBuffs 11923): true = this class is
--- excluded by the line's tags. t2..t5 are the raw |-fields 2..5 of the Buffs line.
function M.classTagSkip(t2, t3, t4, t5, class)
    t2 = tostring(t2 or ''):lower()
    local t3l = tostring(t3 or ''):lower()
    class = tostring(class or ''):upper()
    local listed = M.inList(t3, class) or M.inList(t4, class) or M.inList(t5, class)
    if listed then return false end
    if t2 == 'caster' then return not M.CASTERS[class] end
    if t2 == 'melee' then return not M.MELEE[class] end
    if t2 == 'class' or t3l == 'class' then return true end
    return false
end

-- ------------------------------------------------------------- beg (BegBuff)
--- 'Spell|alias1,alias2[|item]' -> { name, aliases = {...}, item = bool } or nil for NULL/blank.
function M.parseBeg(entry)
    if not entry or entry == '' or entry:upper() == 'NULL' then return nil end
    local parts = {}
    for p in (entry .. '|'):gmatch('([^|]*)|') do parts[#parts + 1] = p end
    local aliases = {}
    for a in tostring(parts[2] or ''):gmatch('[^,]+') do
        a = a:gsub('^%s+', ''):gsub('%s+$', '')
        if a ~= '' then aliases[#aliases + 1] = a:lower() end
    end
    return { name = parts[1], aliases = aliases, item = tostring(parts[3] or ''):lower() == 'item' }
end

--- The first entry one of whose aliases appears in the chat text (case-insensitive substring; 26027-26042).
function M.begMatch(text, entries)
    text = tostring(text or ''):lower()
    for _, e in ipairs(entries or {}) do
        for _, a in ipairs(e.aliases) do
            if text:find(a, 1, true) then return e end
        end
    end
    return nil
end

--- BegPermission chain (26145-26175): perm is the INI string; f = { inRaid, sameGuild, inFellowship, medium, inGroup }.
function M.begApproved(perm, f)
    perm = tostring(perm or ''):lower()
    f = f or {}
    if perm:find('all', 1, true) then return true end
    if f.inRaid and perm:find('raid', 1, true) then return true end
    if f.sameGuild and perm:find('guild', 1, true) then return true end
    if f.inFellowship and perm:find('fellowship', 1, true) then return true end
    if perm:find('tell', 1, true) and tostring(f.medium or ''):lower() == 'tell' then return true end
    if f.inGroup and perm:find('group', 1, true) then return true end
    return false
end

-- ------------------------------------------------------------- range OOG recast rows (OOGBuff 11541-11581)
--- A MuleAssistOOGBuffs.ini row "spawnID|secondsSinceMidnight|count". Returns skip (true = the buff I cast
--- should still be running, or the zone never drops buffs) and the stored cast count.
function M.oogRecast(row, spawnId, nowSec, durationSec, zone)
    local id, at, n = tostring(row or ''):match('^(%d+)|(%d+)|(%d+)')
    if not id or tonumber(id) ~= tonumber(spawnId) then return false, 0 end
    local elapsed = nowSec - tonumber(at)
    if elapsed < 0 then elapsed = elapsed + 86400 end
    if (tonumber(durationSec) or 0) > elapsed then return true, tonumber(n) end
    if M.NODROP_ZONES[tostring(zone or ''):lower()] then return true, tonumber(n) end
    return false, tonumber(n)
end

-- ------------------------------------------------------------- group regen (RegenOther)
--- Pick the first group member (slots 1..5, never me) whose stat percentage is in [1, threshold] and whose
--- class is in `classes` ('0'/blank = the default list for the stat). members = { {id, class, pct}, ... }.
--- The macro compared the absolute current value with the threshold (12026); the port compares the percentage.
function M.regenPick(members, stat, threshold, classes)
    stat = tostring(stat or 'mana'):lower()
    classes = tostring(classes or '')
    if classes == '' or classes == '0' or classes:lower() == 'null' then classes = M.REGEN_CLASSES[stat] or '' end
    threshold = tonumber(threshold) or 0
    for i = 1, math.min(5, #(members or {})) do
        local m = members[i]
        if m and (tonumber(m.id) or 0) > 0 and M.inList(classes, m.class) then
            local pct = tonumber(m.pct) or 0
            if pct >= 1 and pct <= threshold then return m end
        end
    end
    return nil
end

return M
