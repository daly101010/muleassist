-- core/buffcheck.lua: reading what buffs a spawn has (the MQ buff cache, my own buff window, the live target
-- window), the per-spawn cache refresh (CacheBuffs), stacking tests, and the shared KissAssist_Buffs.ini
-- that macro boxes still read and write (WriteBuffs / WriteBuffsPet / CleanBuffsFile).
local mq = require('mq')
local T = require('core.tlo')
local Timers = require('core.timers')
local State = require('core.state')
local Ini = require('core.ini')

local M = { cacheDelayMs = 300000, FILE = 'KissAssist_Buffs.ini' }

local function targetId() return T.num(function() return mq.TLO.Target.ID() end) end

--- Wait for the current target's buff data (TargetBuffWait): 1 s in inspect range, 0.3 s beyond 200.
function M.targetBuffWait()
    if targetId() == 0 or T.bool(function() return mq.TLO.Target.BuffsPopulated() end) then return end
    local far = T.num(function() return mq.TLO.Target.Distance() end) > 200
    mq.delay(far and 300 or 1000, function() return T.bool(function() return mq.TLO.Target.BuffsPopulated() end) end)
end

--- Make a spawn's buff cache readable by targeting it (once per BuffCacheingDelay for PCs and pets). The
--- target is left on the spawn, as the macro did. Returns false when the spawn is gone.
function M.cacheBuffs(id)
    id = tonumber(id) or 0
    local sp = T.spawn(id)
    if not sp then return false end
    local ty = T.str(function() return sp.Type() end)
    if State.manualOn and ty == 'NPC' then return false end
    local key = 'cache:' .. id
    if targetId() == id then
        M.targetBuffWait()
        Timers.set(key, M.cacheDelayMs)
        return true
    end
    if T.num(function() return sp.CachedBuffCount() end) == -1 or Timers.expired(key) then
        mq.cmdf('/squelch /target id %d', id)
        mq.delay(1000, function() return targetId() == id end)
        M.targetBuffWait()
        if ty == 'PC' or ty == 'Pet' then Timers.set(key, M.cacheDelayMs) end
    end
    return true
end

--- Seconds left of `name` on spawn `id` in the buff cache (0 when absent or unknown).
function M.cachedSeconds(id, name)
    local sp = T.spawn(id)
    if not sp then return 0 end
    if T.num(function() return sp.CachedBuff(name).ID() end) == 0 then return 0 end
    return T.num(function() return sp.CachedBuff(name).Duration.TotalSeconds() end)
end
function M.cachedHas(id, name)
    local sp = T.spawn(id)
    return sp ~= nil and T.num(function() return sp.CachedBuff(name).ID() end) > 0
end

--- Does the buff behind `name` (spell, or an item's / AA's spell) stack on spawn `id`? nil = cannot tell.
function M.stacksSpawn(name, id)
    local checks = {
        function() return mq.TLO.Spell(name).StacksSpawn(id)() end,
        function() return mq.TLO.FindItem('=' .. name).Clicky.Spell.StacksSpawn(id)() end,
        function() return mq.TLO.Me.AltAbility(name).Spell.StacksSpawn(id)() end,
    }
    local known = false
    for _, fn in ipairs(checks) do
        local ok, v = pcall(fn)
        if ok and v ~= nil then
            known = true
            if v == true then return true end
        end
    end
    if not known then return nil end
    return false
end

--- Does it stack on me? (Spell.Stacks, the item's / AA's spell for those names.) nil = cannot tell.
function M.stacksOnMe(name)
    for _, fn in ipairs({
        function() return mq.TLO.Spell(name).Stacks() end,
        function() return mq.TLO.FindItem('=' .. name).Spell.Stacks() end,
        function() return mq.TLO.Me.AltAbility(name).Spell.Stacks() end,
    }) do
        local ok, v = pcall(fn)
        if ok and v ~= nil then return v == true end
    end
    return nil
end

--- My own buff window: seconds left (0 = permanent when present), presence, songs.
function M.myHas(name) return T.num(function() return mq.TLO.Me.Buff(name).ID() end) > 0 end
function M.mySeconds(name) return T.num(function() return mq.TLO.Me.Buff(name).Duration.TotalSeconds() end) end
function M.mySong(name) return T.num(function() return mq.TLO.Me.Song(name).ID() end) > 0 end
--- Mine with more than `sec` seconds left, or permanent.
function M.myFresh(name, sec)
    if not M.myHas(name) then return false end
    local s = M.mySeconds(name)
    return s > (sec or 30) or s == 0
end
--- The live target window: present with more than `sec` left or permanent.
function M.targetFresh(name, sec)
    if T.num(function() return mq.TLO.Target.Buff(name).ID() end) == 0 then return false end
    local s = T.num(function() return mq.TLO.Target.Buff(name).Duration.TotalSeconds() end)
    return s > (sec or 30) or s == 0
end
--- Pet buff window: any pet buff whose name contains `name` (the macro's substring match).
function M.petHas(name)
    local want = tostring(name):lower()
    for j = 1, 50 do
        local n = T.str(function() return mq.TLO.Me.PetBuff(j).Name() end)
        if n == '' then break end
        if n:lower():find(want, 1, true) then return true end
    end
    return false
end

-- ------------------------------------------------------------- KissAssist_Buffs.ini (shared with macro boxes)
local function setFrom(list)
    local out = {}
    for tok in tostring(list or ''):gmatch('[^|]+') do
        tok = tok:gsub('^%s+', ''):gsub('%s+$', '')
        if tok ~= '' then out[tok:lower()] = true end
    end
    return out
end

--- Spawn ids with a section in the buffs file (other boxes publishing their buff lists).
function M.toonIds()
    local out = {}
    for _, s in ipairs(Ini.sections(M.FILE)) do
        local n = tonumber(s)
        if n and n > 0 then out[#out + 1] = n end
    end
    return out
end
--- A toon's published buffs and blocked buffs as lower-cased sets.
function M.toonBuffs(id) return setFrom(Ini.read(M.FILE, tostring(id), 'Buffs')) end
function M.toonBlocked(id) return setFrom(Ini.read(M.FILE, tostring(id), 'Blockedbuffs')) end

local function cleanName(n)
    n = tostring(n or '')
    local paren = n:find('(', 1, true)
    if paren then n = n:sub(1, paren - 1):gsub('%s+$', '') end
    local perm = n:find(':Permanent', 1, true)
    if perm and perm > 1 then n = n:sub(1, perm - 1) end
    return n
end

--- Delete the sections written in another day or hour (CleanBuffsFile), every 10 minutes.
function M.cleanFile()
    if not Timers.expired('buffs:clean') then return end
    Timers.set('buffs:clean', 600000)
    local day = T.str(function() return mq.TLO.Time.Day() end)
    local hour = T.str(function() return mq.TLO.Time.Hour() end)
    for _, s in ipairs(Ini.sections(M.FILE)) do
        local d = Ini.read(M.FILE, s, 'Day')
        local h = Ini.read(M.FILE, s, 'Hour')
        if (d or '') ~= day or (h or '') ~= hour then Ini.deleteSection(M.FILE, s) end
    end
end

--- Publish my buff list and blocked buffs under my spawn id (WriteBuffs), at most every 30 s unless forced.
function M.writeMine(force)
    if not force and not Timers.expired('buffs:write') then return end
    if T.aggroTargetId() > 0 then return end
    Timers.set('buffs:write', 30000)
    M.cleanFile()
    local sec = tostring(T.myId())
    if not Ini.read(M.FILE, sec, 'Day') then Ini.write(M.FILE, sec, 'Day', T.str(function() return mq.TLO.Time.Day() end)) end
    if not Ini.read(M.FILE, sec, 'Hour') then Ini.write(M.FILE, sec, 'Hour', T.str(function() return mq.TLO.Time.Hour() end)) end
    if not Ini.read(M.FILE, sec, 'Zone') then Ini.write(M.FILE, sec, 'Zone', tostring(T.zoneId())) end
    Ini.write(M.FILE, sec, 'MyRole', tostring(State.role))
    local list = ''
    for i = 1, 42 do
        local n = cleanName(T.str(function() return mq.TLO.Me.Buff(i).Name() end))
        if n ~= '' then list = list .. '|' .. n end
    end
    Ini.write(M.FILE, sec, 'Buffs', list)
    local blocked = ''
    for k = 1, 40 do
        local n = T.str(function() return mq.TLO.Me.BlockedBuff(k).Name() end)
        if n ~= '' then blocked = blocked .. '|' .. n end
    end
    if blocked ~= '' then Ini.write(M.FILE, sec, 'Blockedbuffs', blocked) end
end

--- Publish my pet's buffs (WriteBuffsPet): only a pet that tanks or is the main assist, every 30 s.
function M.writeMyPet()
    local petId = T.num(function() return mq.TLO.Me.Pet.ID() end)
    if petId == 0 or T.aggroTargetId() > 0 then return end
    local role = tostring(State.role):lower()
    if role ~= 'pettank' and role ~= 'pullerpettank' and State.mainAssistId ~= petId then return end
    if not Timers.expired('buffs:writepet') then return end
    Timers.set('buffs:writepet', 30000)
    M.cleanFile()
    local sec = tostring(petId)
    if not Ini.read(M.FILE, sec, 'Day') then Ini.write(M.FILE, sec, 'Day', T.str(function() return mq.TLO.Time.Day() end)) end
    if not Ini.read(M.FILE, sec, 'Hour') then Ini.write(M.FILE, sec, 'Hour', T.str(function() return mq.TLO.Time.Hour() end)) end
    if not Ini.read(M.FILE, sec, 'Zone') then Ini.write(M.FILE, sec, 'Zone', tostring(T.zoneId())) end
    local list = ''
    for i = 1, 50 do
        local n = T.str(function() return mq.TLO.Me.PetBuff(i).Name() end)
        if n == '' then break end
        list = list .. '|' .. n
    end
    Ini.write(M.FILE, sec, 'Buffs', list)
end

return M
