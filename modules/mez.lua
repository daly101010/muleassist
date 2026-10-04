-- modules/mez.lua: crowd control. MezRadar (the hater table), MezNeeded (the DPS hold), DoMezStuff (the AE
-- stun, the AE mez, the single-mez walk with every skip rule), MezSlotWatch (the XTarget-slot mode),
-- MezMobs / MezMobsAE, Event_MezBroke, the DanNet CC protocol (MEZZING2-> / CCCLAIM-> / CCRELEASE->),
-- MezzerUp / GroupMezzerUp, and the per-zone immune lists ([<zone>] MezImmune / CharmImmune in
-- KissAssist_Info.ini, the session id sets, /mezimmune /charmimmune /addimmune), with the same [Mez] keys.
--
-- Not a transliteration: the hater table is a Lua list (the MezArray rows 1-13), my mez timers are
-- `mez:<row>`, claims are `mezclaim:<id>` timers with M.claims, the immune names live in a set instead of
-- alert list 4 (and are rebuilt per zone, so names from an earlier zone do not linger), the bard path casts
-- through the cast engine like everyone else.
local mq = require('mq')
local T = require('core.tlo')
local Config = require('core.config')
local Timers = require('core.timers')
local Spell = require('core.spell')
local Cast = require('core.cast')
local Comms = require('core.comms')
local Log = require('core.log')
local State = require('core.state')
local Ini = require('core.ini')
local Buffcheck = require('core.buffcheck')

local M = { name = 'mez' }

M.INFO_FILE = 'KissAssist_Info.ini'
local MEZ_CLASSES = { BRD = true, ENC = true, NEC = true }
M.Settings = {
    scalars = {
        { section = 'Mez', key = 'MezOn', type = 'int', default = 0 },
        { section = 'Mez', key = 'MezRadius', type = 'int', default = 50 },
        { section = 'Mez', key = 'MezMinLevel', type = 'string', default = '1', rank = false },
        { section = 'Mez', key = 'MezMaxLevel', type = 'string', default = '150', rank = false },
        { section = 'Mez', key = 'MezStopHPs', type = 'int', default = 80 },
        { section = 'Mez', key = 'MezSpell', type = 'string', default = 'Your Mez Spell' },
        { section = 'Mez', key = 'MezDebuffOnResist', type = 'int', default = 0 },
        { section = 'Mez', key = 'MezDebuffSpell', type = 'string', default = 'NULL' },
        { section = 'Mez', key = 'MezXTarSlot', type = 'string', default = '0', rank = false },
        { section = 'Mez', key = 'MezAESpell', type = 'string', default = 'Your AE Mez Spell|0', rank = false },
        { section = 'Mez', key = 'MezAEStunSpell', type = 'string', default = 'Your AE Stun Spell|0', rank = false },
        { section = 'Mez', key = 'MezCCOnlyAt', type = 'int', default = 4 },
        { section = 'Mez', key = 'MezInterruptOK', type = 'string', default = 'Cripple', rank = false },
        { section = 'Mez', key = 'MezBackupRole', type = 'int', default = 0 },
        { section = 'Mez', key = 'MezBackupGapSec', type = 'int', default = 4 },
        { section = 'General', key = 'MezzedEngageRange', type = 'int', default = 100 },
        { section = 'General', key = 'MobZRadius', type = 'int', default = 50 },
        { section = 'General', key = 'MoveCloserIfNoLOS', type = 'int', default = 0 },
        { section = 'General', key = 'MoveForLoSInCampOnly', type = 'int', default = 1 },
        { section = 'Melee', key = 'MeleeDistance', type = 'int', default = 30 },
        { section = 'Melee', key = 'TankAllMobs', type = 'int', default = 0 },
    },
}
M.cfg = { MezOn = 0 }
M.array = {}            -- the hater table: rows { id, level, name } (MezArray 1..13)
M.count = {}            -- my mez casts landed per row (MezCount)
M.claims = {}           -- mob id -> holder name while 'mezclaim:<id>' runs (CCBy)
M.immuneIds = {}        -- session: mob id -> true (MezImmuneIDs)
M.zoneImmune = {}       -- the zone's MezImmune names
M.charmImmune = {}      -- the zone's CharmImmune names
M.charmSkipIds = {}     -- session: charm do-not-retry ids (CharmSkipIDs)
M.mobCount, M.aeCount, M.aeClosest = 0, 0, 0
M.mezMod = 0
M.aeSpell, M.aeCount_need, M.aeStunSpell, M.aeStunNeed = '', 0, '', 0
M.broke = false
M.hooks = { markId = function() return 0 end, inCamp = function(id) return true end }

local MEZ_ANIM = { [26] = true, [32] = true, [71] = true, [72] = true, [17] = true, [111] = true, [129] = true }
local function lower(s) return tostring(s or ''):lower() end
local function role() return lower(State.role) end
local function targetId() return T.num(function() return mq.TLO.Target.ID() end) end
local function iAmMA() return State.mainAssist ~= '' and lower(State.mainAssist) == lower(T.myName()) end
local function maSpawn() if State.mainAssist == '' then return nil end return T.spawnByName(State.mainAssist, lower(State.mainAssistType ~= '' and State.mainAssistType or 'pc')) end
local function mezzedLook(sp)
    return MEZ_ANIM[T.num(function() return sp.Animation() end)] == true or T.num(function() return sp.CachedBuff('^Mezzed').Duration.TotalSeconds() end) > 0
end
local function level(v, default) local n = tonumber(v) if n then return n end return default end
local function maTargetId()
    local ma = maSpawn()
    if not ma then return 0 end
    local an = T.str(function() return ma.AssistName() end)
    if an == '' then return 0 end
    local s = T.spawnByName(an)
    return s and T.num(function() return s.ID() end) or 0
end

-- ------------------------------------------------------------- settings and the zone lists
function M:LoadSettings()
    local cls = T.myClass()
    if MEZ_CLASSES[cls] then self.cfg = Config.load(self.Settings) else self.cfg = { MezOn = 0, MezRadius = 50, MobZRadius = 50, MeleeDistance = 30 } end
    local c = self.cfg
    State.mezOn = (c.MezOn or 0) ~= 0
    c.MinLevel, c.MaxLevel = level(c.MezMinLevel, 1), level(c.MezMaxLevel, 150)
    -- 'Spell|count' settings skip the loader's rank check (the |count is not a spell name): rank the name part
    -- here, or "Wake of Subdual" never matches the "Wake of Subdual Rk. II" in the gem and is never ready
    local ae, n = tostring(c.MezAESpell or ''):match('^([^|]*)|?(.*)$')
    self.aeSpell, self.aeNeed = Spell.rank(ae or ''), tonumber(n) or 0
    local st, sn = tostring(c.MezAEStunSpell or ''):match('^([^|]*)|?(.*)$')
    self.aeStunSpell, self.aeStunNeed = Spell.rank(st or ''), tonumber(sn) or 0
    local mm = T.num(function() return mq.TLO.Me.AltAbility('Mesmerization Mastery').Rank() end)
    self.mezMod = ({ [1] = 6, [2] = 12, [3] = 18, [4] = 24 })[mm] or 0
    self:zoneReload()
end

local function csv(s)
    local out = {}
    s = tostring(s or '')
    if s == '' or s:upper() == 'NULL' or s:lower():find('list up to', 1, true) then return out end
    for n in s:gmatch('[^,]+') do n = n:gsub('^%s+', ''):gsub('%s+$', '') if n ~= '' then out[#out + 1] = n end end
    return out
end
--- ZoneImmuneReload: the zone's MezImmune / CharmImmune lists.
function M:zoneReload()
    local zone = T.str(function() return mq.TLO.Zone.ShortName() end)
    self.zoneImmune = csv(Ini.read(self.INFO_FILE, zone, 'MezImmune'))
    self.charmImmune = csv(Ini.read(self.INFO_FILE, zone, 'CharmImmune'))
    local names = {}
    for _, n in ipairs(self.zoneImmune) do names[lower(n)] = true end
    State.mezImmuneNames = names
    Log.pm('zone: %s mez immune [%s] charm immune [%s]', zone, table.concat(self.zoneImmune, ','), table.concat(self.charmImmune, ','))
end
function M:zoneHas(kind, name)
    for _, n in ipairs(kind == 'charm' and self.charmImmune or self.zoneImmune) do if lower(n) == lower(name) then return true end end
    return false
end
--- ZoneImmunePersist: add a spawn's name to the zone list. Returns true when added.
function M:zonePersist(kind, id)
    local sp = T.spawn(id)
    if not sp then return false end
    local name = T.str(function() return sp.CleanName() end):gsub("'s corpse%d*$", '')
    if name == '' or self:zoneHas(kind, name) then return false end
    local list = kind == 'charm' and self.charmImmune or self.zoneImmune
    list[#list + 1] = name
    local zone = T.str(function() return mq.TLO.Zone.ShortName() end)
    local key = kind == 'charm' and 'CharmImmune' or 'MezImmune'
    Ini.write(self.INFO_FILE, zone, key, table.concat(list, ','))
    Log.pm('zone: %s += %s (%s)', key, name, zone)
    self:zoneReload()
    return true
end
function M:zoneRemove(kind, id)
    local sp = T.spawn(id)
    local name = sp and T.str(function() return sp.CleanName() end) or ''
    local list = kind == 'charm' and self.charmImmune or self.zoneImmune
    local kept, found = {}, false
    for _, n in ipairs(list) do if lower(n) == lower(name) then found = true else kept[#kept + 1] = n end end
    if found then
        Ini.write(self.INFO_FILE, T.str(function() return mq.TLO.Zone.ShortName() end), kind == 'charm' and 'CharmImmune' or 'MezImmune', #kept > 0 and table.concat(kept, ',') or 'NULL')
        self:zoneReload()
    end
    if kind == 'charm' then self.charmSkipIds[id] = nil else self.immuneIds[id] = nil end
    return found, name
end
--- AddMezImmune: a mob that cannot be mezzed (session id + the zone name list + a group notice).
function M:addImmune(id)
    id = tonumber(id) or 0
    if id == 0 or self.immuneIds[id] then return end
    self.immuneIds[id] = true
    local sp = T.spawn(id)
    Comms.say('g', 'MEZ Immune -> %s <- ID:%d Skipping.', sp and T.str(function() return sp.CleanName() end) or '?', id)
    self:zonePersist('mez', id)
end
function M:charmSkipAdd(id)
    id = tonumber(id) or 0
    if id == 0 or self.charmSkipIds[id] then return end
    self.charmSkipIds[id] = true
    local sp = T.spawn(id)
    Log.info('AutoCharm will skip %s (%d).', sp and T.str(function() return sp.CleanName() end) or '?', id)
end

-- ------------------------------------------------------------- the CC protocol
function M.ccHeldByOther(id)
    id = tonumber(id) or 0
    if not Timers.running('mezclaim:' .. id) then return nil end
    local by = M.claims[id]
    if not by or lower(by) == lower(T.myName()) then return nil end
    local sp = T.spawnByName(by, 'pc')
    if not sp or T.bool(function() return sp.Dead() end) then return nil end
    return by
end
local function claim(id, by, ms)
    M.claims[id] = by
    Timers.set('mezclaim:' .. id, ms)
end
--- An ENC in the group, alive and in zone (MezzerUp) / an ENC or BRD (GroupMezzerUp).
local function mezzerUp(classes)
    for i = 0, T.groupCount() do
        local m = T.groupMember(i)
        local cls = T.str(function() return m.Class.ShortName() end)
        if classes[cls] and T.num(function() return m.ID() end) > 0 and T.bool(function() return m.Present() end) and not T.bool(function() return m.Dead() end) and not T.bool(function() return m.Hovering() end) then return true end
    end
    return false
end
function M.mezzerUp() return mezzerUp({ ENC = true }) end
function M.groupMezzerUp() return mezzerUp({ ENC = true, BRD = true }) end

-- ------------------------------------------------------------- MezRadar
local function rowOf(id) for i, r in ipairs(M.array) do if r.id == id then return i end end return nil end
local function removeRow(i)
    table.remove(M.array, i)
    table.remove(M.count, i)
    -- the timers follow the rows
    for j = i, 13 do
        if Timers.running('mez:' .. (j + 1)) then Timers.set('mez:' .. j, Timers.left('mez:' .. (j + 1))) else Timers.clear('mez:' .. j) end
    end
end

function M:radar()
    if State.buffMode or State.zombieMode then return end
    if Timers.running('mez:radar') then return end   -- called per DPS line, per debuff and from the cast wait: 200 ms cache
    Timers.set('mez:radar', 200)
    local c = self.cfg
    local cls = T.myClass()
    self.mobCount, self.aeCount, self.aeClosest = 0, 0, 0
    local closestDist = 99999
    local myZ = T.num(function() return mq.TLO.Me.Z() end)
    local Pet = require('modules.pet')
    local seen = {}
    for i = 1, 13 do
        local xt = mq.TLO.Me.XTarget(i)
        local id = T.num(function() return xt.ID() end)
        local sp = id > 0 and T.spawn(id) or nil
        local ty = sp and T.str(function() return sp.Type() end) or ''
        if sp and not Pet.isProtected(id) and T.str(function() return xt.TargetType() end) == 'Auto Hater' and (ty == 'NPC' or ty == 'Pet') then
            seen[id] = true
            self.mobCount = self.mobCount + 1
            if cls == 'BRD' or cls == 'ENC' then
                local inZ = math.abs(T.num(function() return sp.Z() end) - myZ) <= (c.MobZRadius or 50)
                local dist = T.num(function() return sp.Distance() end)
                if inZ and dist < (c.MezRadius or 50) then
                    if dist < closestDist then closestDist, self.aeClosest = dist, id end
                    if not mezzedLook(sp) then self.aeCount = self.aeCount + 1 end
                end
            end
            if not rowOf(id) and #self.array < 13 then
                self.array[#self.array + 1] = { id = id, level = T.num(function() return sp.Level() end), name = T.str(function() return sp.CleanName() end) }
                self.count[#self.array] = 0
            end
        end
    end
    -- the stale sweep
    local i = 1
    while i <= #self.array do
        local r = self.array[i]
        local sp = T.spawn(r.id)
        local gone = not sp or T.str(function() return sp.Type() end) == 'Corpse'
        local calm = sp and not gone and not T.bool(function() return sp.Aggressive() end) and not Buffcheck.cachedHas(r.id, c.MezSpell or '') and not Buffcheck.cachedHas(r.id, self.aeSpell)
        if gone or calm then
            if gone or M.ccHeldByOther(r.id) == nil then Comms.say('g', 'CCRELEASE-> %s <- ID:%d', r.name, r.id) end
            removeRow(i)
        else i = i + 1 end
    end
    -- the pinned kill target that is not an Auto Hater slot still counts
    local mt = State.myTargetId or 0
    if (cls == 'BRD' or cls == 'ENC') and mt > 0 and not seen[mt] then
        local sp = T.spawn(mt)
        if sp and T.str(function() return sp.Type() end) == 'NPC' and T.num(function() return sp.Distance() end) < (c.MezRadius or 50) and math.abs(T.num(function() return sp.Z() end) - myZ) <= (c.MobZRadius or 50) then
            self.mobCount = self.mobCount + 1
            if not mezzedLook(sp) then self.aeCount = self.aeCount + 1 end
        end
    end
end

-- ------------------------------------------------------------- MezNeeded (the DPS hold)
function M:slots()
    local out = {}
    local s = tostring(self.cfg.MezXTarSlot or '0')
    if tonumber(s) == 0 then return out end
    for n in s:gmatch('[^|]+') do local v = tonumber(n) if v then out[#out + 1] = v end end
    return out
end
function M:needed()
    local c = self.cfg
    local cls = T.myClass()
    if (c.MezOn or 0) == 0 or (cls ~= 'ENC' and cls ~= 'BRD') or State.manualOn then return false end
    self:radar()
    local slots = self:slots()
    if #slots == 0 and (c.MezOn == 1 or c.MezOn == 3) and self.aeNeed > 0 and Timers.expired('mez:ae') and self.aeCount >= self.aeNeed then return true end
    if c.MezOn ~= 1 and c.MezOn ~= 2 then return false end
    if cls ~= 'BRD' and not Spell.memmed(c.MezSpell) then return false end
    local slotSet = {}
    for _, s in ipairs(slots) do slotSet[s] = true end
    for i = 1, 13 do
        if #slots == 0 or slotSet[i] then
            local xt = mq.TLO.Me.XTarget(i)
            local id = T.num(function() return xt.ID() end)
            local sp = id > 0 and T.spawn(id) or nil
            if sp and T.str(function() return xt.TargetType() end) == 'Auto Hater' and T.str(function() return sp.Type() end) == 'NPC'
                and id ~= (State.assistId or 0) and id ~= (State.myTargetId or 0)
                and T.num(function() return sp.Distance3D() end) < (c.MezRadius or 50) and T.bool(function() return sp.LineOfSight() end) then
                local lvl = T.num(function() return sp.Level() end)
                if lvl >= c.MinLevel and lvl <= c.MaxLevel and T.num(function() return sp.PctHPs() end) >= (c.MezStopHPs or 80)
                    and not self:zoneHas('mez', T.str(function() return sp.CleanName() end)) and not self.immuneIds[id]
                    and not T.str(function() return sp.Body.Name() end):find('Giant', 1, true) and not MEZ_ANIM[T.num(function() return sp.Animation() end)] then
                    return true
                end
            end
        end
    end
    return false
end

-- ------------------------------------------------------------- the casts
--- MezMobs: a single mez on row i (ENC / NEC; a bard sings it through the same path).
function M:mezMobs(id, i)
    local c = self.cfg
    if State.buffMode or State.zombieMode or T.bool(function() return mq.TLO.Me.Hovering() end) then return end
    if State.markAssistOn and (self.hooks.markId() == 0 or self.hooks.markId() == id) then return end
    if Timers.running('mezclaim:' .. id) and M.ccHeldByOther(id) then return end
    if T.bool(function() return mq.TLO.Me.Combat() end) then mq.cmd('/attack off') mq.delay(2500, function() return not T.bool(function() return mq.TLO.Me.Combat() end) end) end
    if targetId() ~= id then
        mq.cmdf('/squelch /target id %d', id)
        mq.delay(1000, function() return targetId() == id end)
        Buffcheck.targetBuffWait()
    end
    if targetId() ~= id then return end
    local sp = T.spawn(id)
    if not sp then return end
    local name = T.str(function() return sp.CleanName() end)
    if T.num(function() return mq.TLO.Target.CachedBuff('^Mezzed').ID() end) > 0 and Timers.left('mez:' .. i) > 18000 then self.count[i] = 1 return end
    if not T.bool(function() return mq.TLO.Target.LineOfSight() end) then return end
    local first = (self.count[i] or 0) < 1
    Comms.say('g', '%sMEZZING2-> %s <- ID:%d', first and '' or 'Re', name, id)
    local cls = T.myClass()
    local from = cls == 'BRD' and 'BardMez' or 'Mez'
    local fails = 0
    for _ = 1, 2 do
        local res = Cast.cast(c.MezSpell, id, from, { skipOhShit = true })
        fails = fails + 1
        if res == 'CAST_SUCCESS' then
            local dur = Spell.facts(c.MezSpell).durationSec + self.mezMod
            local ms = cls == 'BRD' and 11000 or math.floor(dur * 1000 * (cls == 'NEC' and 0.95 or 0.75))
            if cls ~= 'NEC' then Comms.say('g', 'JUST %sMEZZED -> %s on %s:%d', first and '' or 'RE', c.MezSpell, name, id) end
            self.count[i] = (self.count[i] or 0) + 1
            Timers.set('mez:' .. i, ms)
            if cls ~= 'BRD' then Comms.say('g', 'CCCLAIM-> %s <- ID:%d BY:%s UNTIL:%d', name, id, T.myName(), math.floor(ms / 1000)) end
            return
        elseif res == 'CAST_RESIST' and fails < 2 then
            Comms.say('g', 'MEZ Resisted -> %s <- ID:%d', name, id)
            local ds = c.MezDebuffSpell or 'NULL'
            if (c.MezDebuffOnResist or 0) ~= 0 and ds ~= '' and ds:upper() ~= 'NULL' and Timers.expired('tashat:' .. id)
                and T.num(function() return mq.TLO.Target.Tashed.ID() end) == 0 and T.num(function() return mq.TLO.Target.Buff(ds).ID() end) == 0 then
                if Cast.cast(ds, id, 'Mez') == 'CAST_SUCCESS' then
                    local d = Spell.facts(ds).durationSec
                    Timers.set('tashat:' .. id, (d > 0 and d or 60) * 1000)
                end
            end
        elseif res == 'CAST_IMMUNE' then
            self:addImmune(id)
            return
        else
            return
        end
    end
end

--- MezMobsAE: the AE mez around `center`.
function M:mezMobsAE(center)
    local c = self.cfg
    if State.buffMode or State.zombieMode then return end
    local f = Spell.facts(self.aeSpell)
    if State.markAssistOn then
        local mark = self.hooks.markId()
        if mark == 0 then return end
        local ms = T.spawn(mark)
        local cs = T.spawn(center)
        if ms and cs then
            local dx, dy = T.num(function() return ms.X() end) - T.num(function() return cs.X() end), T.num(function() return ms.Y() end) - T.num(function() return cs.Y() end)
            if math.sqrt(dx * dx + dy * dy) <= f.aerange then Log.pm('mez: AE held - marked %s is inside %s', T.str(function() return ms.CleanName() end), self.aeSpell) Timers.set('mez:ae', 3000) return end
        end
    end
    if not Spell.ready(self.aeSpell) or T.bool(function() return mq.TLO.Me.Hovering() end) or T.num(function() return mq.TLO.Me.CurrentMana() end) < f.mana then
        Log.pm('mez: AE mez %s not castable (ready %s, mana %d/%d) - retry in 5s', self.aeSpell, tostring(Spell.ready(self.aeSpell)), T.num(function() return mq.TLO.Me.CurrentMana() end), f.mana)
        Timers.set('mez:ae', 5000)
        return
    end
    local wasChasing = State.chaseAssist
    if wasChasing then
        State.chaseAssist = false
        mq.cmd('/stick off') mq.cmd('/moveto off')
        if T.bool(function() return mq.TLO.Navigation.Active() end) then mq.cmd('/nav stop') mq.delay(3000, function() return not T.bool(function() return mq.TLO.Me.Moving() end) end) end
    end
    Log.info('I AM AE MEZZING %s', self.aeSpell)
    local res = Cast.cast(self.aeSpell, center, 'Mez')
    Log.info('I JUST CAST AE MEZ %s (%s)', self.aeSpell, res)
    if res == 'CAST_SUCCESS' then Timers.set('mez:ae', f.durationSec * 1000) elseif res == 'CAST_NO_RESULT' then Timers.set('mez:ae', 10000) else Timers.set('mez:ae', 3000) end
    Comms.say('g', 'AE MEZZING1-> %s ', self.aeSpell)
    if wasChasing then State.chaseAssist = true end
    if res ~= 'CAST_SUCCESS' then return end
    local cs = T.spawn(center)
    for i, r in ipairs(self.array) do
        local sp = T.spawn(r.id)
        if sp and cs and T.str(function() return sp.Type() end) == 'NPC' then
            local dx, dy = T.num(function() return sp.X() end) - T.num(function() return cs.X() end), T.num(function() return sp.Y() end) - T.num(function() return cs.Y() end)
            if math.sqrt(dx * dx + dy * dy) <= f.aerange then
                Buffcheck.cacheBuffs(r.id)
                if mezzedLook(sp) then
                    local ms = math.floor((f.durationSec + self.mezMod) * 1000 * 0.75)
                    Timers.set('mez:' .. i, ms)
                    self.count[i] = 1
                    Comms.say('g', 'CCCLAIM-> %s <- ID:%d BY:%s UNTIL:%d', r.name, r.id, T.myName(), math.floor(ms / 1000))
                else
                    Timers.clear('mez:' .. i)
                    Log.pm('mez: AE missed %s (%d) - single mez next', r.name, r.id)
                end
            end
        end
    end
end

local function aeMezzedNear(q)
    local n = T.num(function() return mq.TLO.SpawnCount(q)() end)
    local mezzed = 0
    for i = 1, n do
        local sp = mq.TLO.NearestSpawn(i, q)
        if MEZ_ANIM[T.num(function() return sp.Animation() end)] or T.num(function() return sp.CachedBuff('^Mezzed').Duration.TotalSeconds() end) > 0 then mezzed = mezzed + 1 end
    end
    return mezzed
end
M.aeMezzedNear = aeMezzedNear

--- MezSlotWatch: the XTarget-slot mode (one cast per call).
function M:slotWatch()
    local c = self.cfg
    for _, slot in ipairs(self:slots()) do
        local id = T.num(function() return mq.TLO.Me.XTarget(slot).ID() end)
        local sp = id > 0 and T.spawn(id) or nil
        if sp and T.str(function() return sp.Type() end) == 'NPC' and id ~= (State.myTargetId or 0) and id ~= (State.assistId or 0) and id ~= self.hooks.markId()
            and not self.immuneIds[id] and T.num(function() return sp.Distance3D() end) <= (c.MezRadius or 50) then
            local lvl = T.num(function() return sp.Level() end)
            if lvl >= c.MinLevel and lvl <= c.MaxLevel and T.num(function() return sp.PctHPs() end) >= (c.MezStopHPs or 80)
                and not MEZ_ANIM[T.num(function() return sp.Animation() end)] and T.num(function() return sp.CachedBuff('^Mezzed').Duration.TotalSeconds() end) <= 6
                and not Timers.running('mezclaim:' .. id) then
                local los = T.bool(function() return sp.LineOfSight() end)
                if not los then
                    local ma = maSpawn()
                    if (c.MoveCloserIfNoLOS or 0) ~= 0 and ma and T.num(function() return ma.Distance3D() end) < 150 and ((c.MoveForLoSInCampOnly or 1) == 0 or self.hooks.inCamp(id)) then
                        Log.info('No LoS on %s (%d) - moving until I can see it.', T.str(function() return sp.CleanName() end), id)
                        mq.cmd('/moveto off') mq.cmd('/stick off')
                        mq.cmdf('/nav id %d', id)
                        Cast.tickDelay(5000, function() return T.bool(function() return sp.LineOfSight() end) or not T.bool(function() return mq.TLO.Navigation.Active() end) end)
                        mq.cmd('/nav stop')
                        los = T.bool(function() return sp.LineOfSight() end)
                    end
                end
                if los then
                    local name = T.str(function() return sp.CleanName() end)
                    Comms.say('g', 'MEZZING2-> %s <- ID:%d', name, id)
                    local res = Cast.cast(c.MezSpell, id, 'Mez')
                    if res == 'CAST_SUCCESS' then
                        local secs = math.floor((Spell.facts(c.MezSpell).durationSec + self.mezMod) * 0.75)
                        Comms.say('g', 'JUST MEZZED -> %s on %s:%d', c.MezSpell, name, id)
                        Comms.say('g', 'CCCLAIM-> %s <- ID:%d BY:%s UNTIL:%d', name, id, T.myName(), secs)
                    elseif res == 'CAST_IMMUNE' then self:addImmune(id) end
                    return
                end
            end
        end
    end
end

-- ------------------------------------------------------------- DoMezStuff
function M:doMezStuff()
    self:brokeTick()
    local c = self.cfg
    if State.buffMode or State.zombieMode or (c.MezOn or 0) == 0 or State.manualOn or State.getAwayOn then return end
    if T.bool(function() return mq.TLO.Me.Hovering() end) then return end
    if State.markAssistOn and self.hooks.markId() == 0 then return end
    if #self:slots() > 0 then self:slotWatch() return end
    local ma = maSpawn()
    if (State.myTargetId or 0) == 0 and ma and T.str(function() return ma.Type() end) ~= 'Mercenary' then return end
    local stopHP = c.MezStopHPs or 80
    if not ma then stopHP = 1 end   -- no MA in zone: mez anything (the macro made this permanent; here it is per pass)
    self:radar()
    local cls = T.myClass()
    if self.mobCount < 2 and ma and T.hostiles() <= 1 then return end
    -- the AE stun (ENC)
    if (c.MezOn == 1 or c.MezOn == 3) and cls == 'ENC' and self.aeStunNeed > 0 and Timers.expired('mez:aestun') and self.aeCount >= self.aeStunNeed and Spell.ready(self.aeStunSpell) then
        local f = Spell.facts(self.aeStunSpell)
        local base = string.format('radius %d zradius %d', f.aerange, c.MobZRadius or 50)
        local haters = T.num(function() return mq.TLO.SpawnCount('npc xtarhater ' .. base .. ' noalert 5')() end)
        local all = T.num(function() return mq.TLO.SpawnCount('npc ' .. base)() end) - aeMezzedNear('npc ' .. base)
        if haters >= self.aeStunNeed and haters >= all then
            Log.pm('mez: AE stun %s first - %d haters within %d', self.aeStunSpell, haters, f.aerange)
            if Cast.cast(self.aeStunSpell, T.myId(), 'Mez') == 'CAST_SUCCESS' then Timers.set('mez:aestun', (f.durationSec > 0 and f.durationSec or 12) * 1000) else Timers.set('mez:aestun', 10000) end
        else
            Timers.set('mez:aestun', 1500)   -- a bystander in range: look again in 1.5 s, not every pass
            if Timers.expired('mez:pmae') then
                Timers.set('mez:pmae', 5000)
                Log.pm('mez: AE stun held - %d haters vs %d mobs within %d of me', haters, all, f.aerange)
            end
        end
    end
    -- the AE mez (BRD / ENC)
    if (c.MezOn == 1 or c.MezOn == 3) and self.aeNeed > 0 and self.aeCount >= self.aeNeed and Timers.expired('mez:ae') and self.aeClosest > 0 then
        local f = Spell.facts(self.aeSpell)
        local cs = T.spawn(self.aeClosest)
        if cs then
            local loc = string.format('loc %d %d %d radius %d zradius %d', T.num(function() return cs.X() end), T.num(function() return cs.Y() end), T.num(function() return cs.Z() end), f.aerange, c.MobZRadius or 50)
            local haters = T.num(function() return mq.TLO.SpawnCount('npc xtarhater ' .. loc .. ' noalert 5')() end)
            local all = T.num(function() return mq.TLO.SpawnCount('npc ' .. loc)() end) - aeMezzedNear('npc ' .. loc)
            local mt = State.myTargetId or 0
            if mt > 0 then
                local ms = T.spawn(mt)
                local pinned = true
                for i = 1, 13 do if T.num(function() return mq.TLO.Me.XTarget(i).ID() end) == mt and T.str(function() return mq.TLO.Me.XTarget(i).TargetType() end) == 'Auto Hater' then pinned = false end end
                if ms and pinned and T.str(function() return ms.Type() end) == 'NPC' then
                    local dx, dy = T.num(function() return ms.X() end) - T.num(function() return cs.X() end), T.num(function() return ms.Y() end) - T.num(function() return cs.Y() end)
                    if math.sqrt(dx * dx + dy * dy) <= f.aerange then haters = haters + 1 end
                end
            end
            if haters >= all and haters >= 2 then self:mezMobsAE(self.aeClosest)
            else
                Timers.set('mez:ae', 1500)
                if Timers.expired('mez:pmae2') then
                    Timers.set('mez:pmae2', 5000)
                    Log.pm('mez: AE held - %d haters vs %d mobs within %d of %s (need haters>=all and >=2)', haters, all, f.aerange, T.str(function() return cs.CleanName() end))
                end
            end
        end
    end
    -- the single mez walk
    if c.MezOn ~= 1 and c.MezOn ~= 2 then return end
    if cls ~= 'BRD' and not Spell.memmed(c.MezSpell) then
        if Timers.expired('mez:notmemmed') then Timers.set('mez:notmemmed', 30000) Log.error('[Mez] MezSpell %s is not memorized - single-target mez is OFF until you mem it', c.MezSpell) end
        return
    end
    local Pet = require('modules.pet')
    local maTid = maTargetId()
    for i = 1, #self.array do
        local r = self.array[i]
        if not r then break end
        local sp = T.spawn(r.id)
        local skip = false
        if (State.myTargetId or 0) > 0 and Pet:wantsAttack(State.myTargetId) then Pet:combatPet(State.myTargetId) end
        if cls ~= 'BRD' and not Spell.ready(c.MezSpell) then skip = true end
        if not skip and (not sp or T.str(function() return sp.Type() end) == 'Corpse') then skip = true end
        if not skip and T.str(function() return sp.Type() end) == 'Pet' and T.str(function() return sp.Master.Type() end) == 'PC' then skip = true end
        if not skip and State.markAssistOn and r.id == self.hooks.markId() then skip = true end
        if not skip and (r.id == (State.assistId or 0) or r.id == maTid or r.id == (State.myTargetId or 0)) then skip = true end
        if not skip and M.ccHeldByOther(r.id) then skip = true end
        if not skip and (c.MezBackupRole or 0) ~= 0 then
            if not Timers.running('mez:ccseen:' .. r.id) and not self.seenSet then self.seenSet = {} end
            if not (self.seenSet or {})[r.id] then self.seenSet[r.id] = true Timers.set('mez:ccseen:' .. r.id, (c.MezBackupGapSec or 4) * 1000) end
            if M.mezzerUp() and Timers.running('mez:ccseen:' .. r.id) then skip = true
            else Log.pm('mez: backup taking %s (%d) - unheld %ds or no enchanter up', r.name, r.id, c.MezBackupGapSec or 4) end
        end
        if not skip and lower(Spell.facts(c.MezSpell).targetType) == 'undead' and not T.str(function() return sp.Body.Name() end):find('Undead', 1, true) then skip = true end
        if not skip and T.num(function() return sp.Distance3D() end) >= (c.MezRadius or 50) then
            if Timers.expired('mez:pmfar:' .. r.id) then Timers.set('mez:pmfar:' .. r.id, 5000) Log.pm('mez: %s (%d) is %d away, beyond MezRadius %d - not mezzing it', r.name, r.id, T.num(function() return sp.Distance3D() end), c.MezRadius or 50) end
            skip = true
        end
        if not skip then
            local groupMA = T.num(function() return mq.TLO.Group.MainAssist.ID() end)
            if groupMA > 0 and ma and groupMA == T.num(function() return ma.ID() end) and r.id == T.num(function() return mq.TLO.Me.GroupAssistTarget.ID() end) and (c.TankAllMobs or 0) == 0 then
                Log.info('Returning from Mez cause mytargetid is stale. let\'s see if this fixes it: %d=%s', r.id, r.name)
                State.myTargetId = 0
                return
            end
        end
        if not skip and T.aggroTargetId() > 0 and (State.myTargetId or 0) == 0 and ma and T.str(function() return ma.Type() end) == 'Mercenary' then skip = true end
        if not skip and T.num(function() return sp.PctHPs() end) < stopHP then skip = true end
        if not skip and (r.level < c.MinLevel or r.level > c.MaxLevel) then skip = true end
        if not skip and (c.MoveCloserIfNoLOS or 0) ~= 0 and not T.bool(function() return sp.LineOfSight() end) and T.bool(function() return mq.TLO.Navigation.MeshLoaded() end) then
            if (c.MoveForLoSInCampOnly or 1) ~= 0 and not self.hooks.inCamp(r.id) then skip = true
            elseif ma and T.num(function() return ma.Distance3D() end) < 150 and T.num(function() return sp.Distance3D() end) <= (Spell.facts(c.MezSpell).range > 0 and Spell.facts(c.MezSpell).range or 100) then
                if MEZ_ANIM[T.num(function() return sp.Animation() end)] or T.num(function() return sp.CachedBuff('^Mezzed').Duration.TotalSeconds() end) > 6 then skip = true
                else
                    mq.cmd('/moveto off') mq.cmd('/stick off')
                    Log.info('No LoS on %s (%d) - moving until I can see it.', r.name, r.id)
                    mq.cmdf('/nav id %d', r.id)
                    Cast.tickDelay(5000, function() return T.bool(function() return sp.LineOfSight() end) or not T.bool(function() return mq.TLO.Navigation.Active() end) end)
                    mq.cmd('/nav stop')
                    if not T.bool(function() return sp.LineOfSight() end) then skip = true end
                end
            else skip = true end
        end
        if not skip and cls == 'BRD' and iAmMA() and r.id == (State.myTargetId or 0) and T.aggroTargetId() > 0 then skip = true end
        if not skip and T.str(function() return sp.Body.Name() end):find('Giant', 1, true) then skip = true end
        if not skip and self:zoneHas('mez', r.name) then
            if Timers.expired('mez:mm:' .. r.id) then Timers.set('mez:mm:' .. r.id, 60000) Comms.say('g', 'MEZ Immune Detected -> %s <- ID:%d', r.name, r.id) end
            skip = true
        end
        if not skip and T.num(function() return mq.TLO.Me.CurrentMana() end) < Spell.facts(c.MezSpell).mana then skip = true end
        if not skip and Timers.running('mez:' .. i) and Buffcheck.cachedHas(r.id, c.MezSpell) then skip = true end
        if not skip and self.mobCount <= 1 and ma and (T.str(function() return ma.Type() end) == 'Mercenary' or T.str(function() return ma.Type() end) == 'Pet') then skip = true end
        if not skip and ma and T.inGroup(T.num(function() return ma.ID() end)) then
            local onXT = false
            for s = 1, 13 do if T.num(function() return mq.TLO.Me.XTarget(s).ID() end) == r.id then onXT = true end end
            if not onXT then skip = true end
        end
        if not skip and self.immuneIds[r.id] then skip = true end
        if not skip then
            mq.cmdf('/squelch /target id %d', r.id)
            mq.delay(500, function() return T.bool(function() return mq.TLO.Target.BuffsPopulated() end) end)
            if T.num(function() return mq.TLO.Target.Mezzed.ID() end) > 0 and Timers.left('mez:' .. i) > 18000 then
                Log.pm('mez: my mez on it still has %ds - skipping', math.floor(Timers.left('mez:' .. i) / 1000))
                skip = true
            end
        end
        if not skip then
            self:mezMobs(r.id, i)
            mq.doevents()
            if r.id == maTargetId() and r.id == (State.assistId or 0) then
                Log.info('Oops we were too quick and mezzed the MA. ')
                Timers.clear('mez:' .. i)
                self.broke = false
            end
        end
    end
end

-- ------------------------------------------------------------- events, hooks
function M:onMezBroke(mob, breaker)
    if State.buffMode or State.zombieMode or (self.cfg.MezOn or 0) == 0 then return end
    if T.num(function() return mq.TLO.Me.Casting.ID() end) > 0 then self.brokePending = { mob = mob, breaker = breaker } return end   -- fired from Cast.wait's doevents
    self.brokePending = nil
    if lower(breaker) == lower(State.mainAssist) then return end
    local ma = maSpawn()
    if ma and T.str(function() return ma.Type() end) == 'Pet' and lower(T.str(function() return ma.Master.CleanName() end)) == lower(breaker) then return end
    local bs = T.spawnByName(breaker)
    if bs then
        local an = T.str(function() return bs.AssistName() end)
        local mt = State.myTargetId or 0
        local mts = mt > 0 and T.spawn(mt) or nil
        if mts and lower(T.str(function() return mts.CleanName() end)) == lower(an) and lower(an):find(lower(mob), 1, true) then return end
    end
    Comms.say('g', '>>  %s << has awakened -> %s<-', breaker, mob)
    for i, r in ipairs(self.array) do
        if lower(r.name) == lower(mob) then
            Log.info('Resetting Mez Timer%d %s', i, mob)
            Timers.clear('mez:' .. i)
            Timers.clear('mezclaim:' .. r.id)   -- a peer's claim on it is over too: the mob is awake
            self.claims[r.id] = nil
        end
    end
    self:doMezStuff()
    self.broke = true
end
--- A mez-broke event that arrived mid-cast is run from the next pass.
function M:brokeTick()
    local p = self.brokePending
    if p and T.num(function() return mq.TLO.Me.Casting.ID() end) == 0 then self.brokePending = nil self:onMezBroke(p.mob, p.breaker) end
end

--- CombatReset's mez part: drop the kill target and the dead from the table, prune the immune ids.
function M:onReset()
    local mt = State.myTargetId or 0
    local i = 1
    while i <= #self.array do
        local r = self.array[i]
        local sp = T.spawn(r.id)
        if r.id == mt or not sp or T.str(function() return sp.Type() end) == 'Corpse' then removeRow(i) else i = i + 1 end
    end
    for id in pairs(self.immuneIds) do
        local sp = T.spawn(id)
        if id == mt or not sp or T.str(function() return sp.Type() end) == 'Corpse' then self.immuneIds[id] = nil end
    end
    for id in pairs(self.charmSkipIds) do if not T.spawn(id) then self.charmSkipIds[id] = nil end end
end

function M:Init()
    local function peerClaim(_, mezzer, id)
        if lower(mezzer) == lower(T.myName()) then return end
        id = tonumber(id) or 0
        if id > 0 then claim(id, mezzer, 8000) end
    end
    mq.event('ma_mezclaim1', '[ #1# (#*#) ]#*#MEZZING2-> #*# <- ID:#2#', peerClaim)
    mq.event('ma_mezclaim2', '<#1#>#*#MEZZING2-> #*# <- ID:#2#', peerClaim)
    local function ccClaim(_, sender, mobName, id, holder, untilSecs)
        id = tonumber(id) or 0
        if id == 0 or lower(holder) == lower(T.myName()) then return end
        claim(id, holder, math.max(tonumber(untilSecs) or 0, 3) * 1000)
    end
    mq.event('ma_ccclaim1', '[ #1# (#*#) ]#*#CCCLAIM-> #2# <- ID:#3# BY:#4# UNTIL:#5#', ccClaim)
    mq.event('ma_ccclaim2', '<#1#>#*#CCCLAIM-> #2# <- ID:#3# BY:#4# UNTIL:#5#', ccClaim)
    local function ccRelease(_, sender, mobName, id)
        id = tonumber(id) or 0
        if id == 0 or not M.claims[id] then return end
        local sp = T.spawn(id)
        if sp and T.str(function() return sp.Type() end) ~= 'Corpse' and lower(M.claims[id]) ~= lower(sender) then return end
        Timers.clear('mezclaim:' .. id)
        M.claims[id] = nil
    end
    mq.event('ma_ccrelease1', '[ #1# (#*#) ]#*#CCRELEASE-> #2# <- ID:#3#', ccRelease)
    mq.event('ma_ccrelease2', '<#1#>#*#CCRELEASE-> #2# <- ID:#3#', ccRelease)
    mq.event('ma_mezbroke', '#1# has been awakened by #2#.', function(_, mob, breaker) M:onMezBroke(mob, breaker) end)
    mq.event('ma_mezimmune', 'Your target cannot be mesmerized.', function()
        local t = targetId()
        if t > 0 and T.str(function() return mq.TLO.Target.Type() end) == 'NPC' then M:addImmune(t) end
    end)
    local Combat = require('modules.combat')
    Combat.hooks.mez = function() M:doMezStuff() end
    Combat.addResetHook('mez', function() M:onReset() end)
    require('modules.healeraggro').hooks.ccHeldByOther = M.ccHeldByOther
    self.hooks.inCamp = function(id) return require('modules.movement').inCamp(id) end
end

function M:Shutdown()
    for _, e in ipairs({ 'ma_mezclaim1', 'ma_mezclaim2', 'ma_ccclaim1', 'ma_ccclaim2', 'ma_ccrelease1', 'ma_ccrelease2', 'ma_mezbroke', 'ma_mezimmune' }) do pcall(mq.unevent, e) end
end

function M:OnZone()
    self.array, self.count, self.seenSet = {}, {}, {}
    for i = 1, 13 do Timers.clear('mez:' .. i) end
    self:zoneReload()
end

function M:GiveTime(ctx)
    self:brokeTick()
    if State.chainPull == 2 or State.getAwayFollow then return end
    if State.mezOn and not ctx.inCombat then self:doMezStuff() end
end

-- ------------------------------------------------------------- binds
local function immuneCmd(self, kind, action, idArg)
    local key = kind == 'charm' and 'CharmImmune' or 'MezImmune'
    local zone = T.str(function() return mq.TLO.Zone.ShortName() end)
    action = lower(action)
    local list = kind == 'charm' and self.charmImmune or self.zoneImmune
    if action == '' or action == 'list' then
        Log.info('%s for %s: %s', key, zone, #list > 0 and table.concat(list, ',') or 'NULL')
        local ids = {}
        for id in pairs(kind == 'charm' and self.charmSkipIds or self.immuneIds) do ids[#ids + 1] = tostring(id) end
        Log.info('Session %s IDs: %s', kind == 'charm' and 'charm-skip' or 'mez-immune', table.concat(ids, '|'))
    elseif action == 'reload' then self:zoneReload()
    elseif action == 'clearsession' then
        if kind == 'charm' then self.charmSkipIds = {} else self.immuneIds = {} end
        Log.info('%s: session skip list cleared.', key)
    elseif action == 'add' or action == 'del' then
        local id = tonumber(idArg) or targetId()
        if id == 0 or not T.spawn(id) then Log.info('%s: %s needs a target or a spawn id.', key, action) return end
        if action == 'add' then
            if kind == 'charm' then self:charmSkipAdd(id) else self.immuneIds[id] = true end
            if not self:zonePersist(kind, id) then Log.info('%s: %s already listed for %s.', key, T.str(function() return T.spawn(id).CleanName() end), zone) end
        else
            local found, name = self:zoneRemove(kind, id)
            if found then Log.pm('zone: %s -= %s (%s)', key, name, zone) else Log.info('%s: %s not listed for %s, nothing removed.', key, name, zone) end
        end
    else
        Log.info('Usage: /%simmune [list | add [id] | del [id] | reload | clearsession]', kind)
    end
end
M.Binds = {
    ['/mezimmune'] = function(self, action, idArg) immuneCmd(self, 'mez', action, idArg) end,
    ['/charmimmune'] = function(self, action, idArg) immuneCmd(self, 'charm', action, idArg) end,
    ['/addimmune'] = function(self, arg)
        local id = tonumber(arg) or 0
        if id == 0 then
            if T.str(function() return mq.TLO.Target.Type() end) ~= 'NPC' then Log.info('No NPCs detected. Nothing added to list.') return end
            id = targetId()
        end
        self.immuneIds[id] = true
        if self:zonePersist('mez', id) then Log.info('MezImmune -> %s <- Adding to Mez Immune  list.', T.str(function() return T.spawn(id).CleanName() end))
        else Log.info('>> %s << already on Mez Immune List.', T.str(function() return T.spawn(id) and T.spawn(id).CleanName() end)) end
    end,
    ['/mezon'] = function(self, arg)
        local v = tonumber(arg)
        if arg == 'on' then v = 1 elseif arg == 'off' then v = 0 end
        if v == nil then v = (self.cfg.MezOn or 0) == 0 and 1 or 0 end
        self.cfg.MezOn = v
        State.mezOn = v ~= 0
        Config.set('Mez', 'MezOn', v)
        Log.info('MezOn %d', v)
    end,
}

return M
