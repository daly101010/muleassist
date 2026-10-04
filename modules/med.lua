-- modules/med.lua: sitting to med (DoWeMed, SitIfNotBard, SitToMed), the group watch (GroupWatch /
-- CheckStats) and WaitForMedders (CountMedders / RefreshMARole). Same [General] keys as the macro.
--
-- Not a transliteration: the macro held inside a loop and ran WaitSubs (heals, cures, mez...) from there;
-- here medding is a state the module keeps between ticks, so every other module keeps its turn while
-- the box sits. Stat thresholds compare percentages (the macro's CheckStats read a raw value).
local mq = require('mq')
local T = require('core.tlo')
local Config = require('core.config')
local Timers = require('core.timers')
local Cast = require('core.cast')
local Comms = require('core.comms')
local Log = require('core.log')
local State = require('core.state')

local M = { name = 'med' }

M.Settings = {
    scalars = {
        { section = 'General', key = 'MedOn', type = 'int', default = 1 },
        { section = 'General', key = 'MedStart', type = 'int', default = 20 },
        { section = 'General', key = 'SitToMed', type = 'string', default = '0', rank = false },
        { section = 'General', key = 'GroupWatchOn', type = 'string', default = '0', rank = false },
        { section = 'General', key = 'GroupWatchResume', type = 'int', default = 90 },
        { section = 'General', key = 'WaitForMedders', type = 'int', default = 0 },
        { section = 'General', key = 'WaitForMeddersMax', type = 'int', default = 300 },
        { section = 'General', key = 'WaitForMeddersSkipMA', type = 'int', default = 1 },
        { section = 'General', key = 'PullerNoSelfMed', type = 'int', default = 0 },
        { section = 'General', key = 'ReturnToCamp', type = 'int', default = 0 },
        { section = 'General', key = 'ReturnToCampAccuracy', type = 'int', default = 10 },
        { section = 'Melee', key = 'MeleeOn', type = 'int', default = 0 },
    },
}
M.cfg = {}
M.medding = false
M.medStat = 'Mana'
M.hpTo100 = false
M.watch = nil        -- CheckStats hold: { id, name, stat, resume, lastStat }
M.wfm = nil          -- WaitForMedders hold: { first, deadline }
M.waitMA = false
M.maRole = { cacheFor = '', role = nil }

local function lower(s) return tostring(s or ''):lower() end
local PULL_ROLES = { puller = true, pullertank = true, pullerpettank = true, hunter = true, hunterpettank = true }
local function pullRole() return PULL_ROLES[lower(State.role)] == true end
local MANA_CLASSES = { BST = true, BRD = true, CLR = true, DRU = true, ENC = true, MAG = true, NEC = true, PAL = true, RNG = true, SHM = true, SHD = true, WIZ = true }
local HYBRIDS = { BRD = true, BST = true, PAL = true, RNG = true, SHD = true }
local END_CLASSES = { BER = true, MNK = true, ROG = true, WAR = true }

--- GroupWatchOn forms: 0 | 1 | 2 | 1|pct | 2|pct | 3|pct|CLR,SHM
function M.parseGroupWatch(value, resume)
    local v = tostring(value or '0')
    local out = { mode = 0, pct = 20, classes = '', resume = tonumber(resume) or 90 }
    local parts = {}
    for p in (v .. '|'):gmatch('([^|]*)|') do parts[#parts + 1] = p end
    out.mode = tonumber(parts[1]) or 0
    if parts[2] and parts[2] ~= '' then out.pct = tonumber(parts[2]) or 20 end
    if out.mode == 3 then out.classes = parts[3] or '' end
    if out.resume < out.pct then out.resume = out.pct end
    return out
end

function M:LoadSettings()
    self.cfg = Config.load(self.Settings)
    self.gw = M.parseGroupWatch(self.cfg.GroupWatchOn, self.cfg.GroupWatchResume)
    self.sitToMed = tonumber(self.cfg.SitToMed) or 0
end

-- ------------------------------------------------------------- the stat
local function pct(stat)
    if stat == 'Endurance' then return T.num(function() return mq.TLO.Me.PctEndurance() end) end
    return T.num(function() return mq.TLO.Me.PctMana() end)
end
local function hp() return T.num(function() return mq.TLO.Me.PctHPs() end) end
local function mounted() return T.num(function() return mq.TLO.Me.Mount.ID() end) > 0 end
local function moving() return T.bool(function() return mq.TLO.Me.Moving() end) or T.num(function() return mq.TLO.Navigation.Velocity() end) > 0 end
local function navOrStick()
    return T.bool(function() return mq.TLO.Navigation.Active() end) or T.str(function() return mq.TLO.Stick.Status() end):upper() ~= 'OFF'
        or T.num(function() return mq.TLO.AdvPath.State() end) > 0
end

--- The stat this class meds: the hybrids swap to Endurance when it is the one that is low (DoWeMed 9059-9073).
function M:pickStat()
    local cls = T.myClass()
    local stat = END_CLASSES[cls] and 'Endurance' or 'Mana'
    local force = false
    if HYBRIDS[cls] then
        local start = self.cfg.MedStart or 20
        if pct('Endurance') < start and pct('Mana') > start then
            stat = 'Endurance'
        elseif pct('Endurance') < 90 and (lower(State.role) == 'tank' or lower(State.role) == 'assist') then
            stat = 'Endurance'
            force = true
        end
    end
    return stat, force
end

--- The group's main assist has been sitting for more than 4 s: med along (MASitTime).
function M:maSitting()
    local sitting = T.num(function() return mq.TLO.Group.MainAssist.ID() end) > 0 and T.bool(function() return mq.TLO.Group.MainAssist.Sitting() end)
    if not sitting then Timers.clear('med:masit') return false end
    if Timers.expired('med:masit') then Timers.set('med:masit', 30000) return false end
    return Timers.left('med:masit') < 26000
end

--- One /sit per 4 s, never while moving, never with MedOn=0 (SitIfNotBard). `direct` skips the MedOn gate.
function M:sit(direct)
    if not direct and (self.cfg.MedOn or 0) == 0 then return false end
    if moving() then return false end
    if not Timers.expired('med:sit') then return false end
    mq.cmd('/sit')
    mq.delay(2000, function() return T.bool(function() return mq.TLO.Me.Sitting() end) end)
    Timers.set('med:sit', 4000)
    return true
end

local function stand()
    if mounted() or T.bool(function() return mq.TLO.Me.Standing() end) then return true end
    mq.cmd('/stand')
    mq.delay(1000, function() return T.bool(function() return mq.TLO.Me.Standing() end) end)
    return T.bool(function() return mq.TLO.Me.Standing() end)
end

local function setMedding(on)
    M.medding = on
    State.medding = on
end

-- ------------------------------------------------------------- DoWeMed
--- Start medding when the stat is under the line (the sit condition 9083 plus the pull-role HP rule).
function M:medStart()
    local c = self.cfg
    if (c.MedOn or 0) == 0 then return false end
    if T.bool(function() return mq.TLO.Me.Hovering() end) then return false end
    if (c.PullerNoSelfMed or 0) ~= 0 and pullRole() then return false end
    if T.aggroTargetId() > 0 or T.bool(function() return mq.TLO.Me.Moving() end) then return false end
    local stat, force = self:pickStat()
    self.medStat = stat
    if self:maSitting() then force = true end
    local p = pct(stat)
    local start = c.MedStart or 20
    local role = lower(State.role)
    local need = p < start or (State.chainPullHold == 2 and p < 100)
        or (force and p < 90 and not role:find('puller', 1, true)) or (force and hp() < 90)
    local hpRule = pullRole() and role ~= 'pullertank' and hp() <= 50
    if not need and not hpRule then return false end
    if role == 'manual' then return false end
    mq.cmd('/squelch /target clear')
    setMedding(true)
    self.hpTo100 = hpRule and not need
    if State.attacking then Cast.hooks.combatReset('DoWeMed') end
    if pullRole() then
        Comms.say('t', 'PULLER-> My %s is below %d%% time to med. %s %d', stat, start, stat, p)
    end
    if T.num(function() return mq.TLO.Me.XTarget() end) == 0 then
        Log.info('Medding until %s is at 100%%', self.hpTo100 and 'health' or stat)
    end
    return true
end

--- While medding: leave on a populated XTarget or a hater, keep sitting, stand when done.
function M:medTick()
    if T.num(function() return mq.TLO.Me.XTarget() end) > 0 or T.aggroTargetId() > 0 then
        setMedding(false)
        return
    end
    local c = self.cfg
    if ((c.ReturnToCamp or 0) ~= 0 and self:campDistance() > (c.ReturnToCampAccuracy or 10)) or State.chaseAssist then
        Cast.hooks.doWeMove('DoWeMed')
    end
    local p = pct(self.medStat)
    local done
    if self.hpTo100 then done = hp() >= 100 else done = p >= 100 and hp() >= 90 end
    if done then
        setMedding(false)
        self.hpTo100 = false
        stand()
        return
    end
    if not mounted() and not T.bool(function() return mq.TLO.Me.Sitting() end) and not navOrStick()
        and (self.sitToMed == 0 or not T.inCombat()) then
        self:sit(false)
    end
end

function M:campDistance()
    if State.campZone ~= T.zoneId() then return 0 end
    local x = T.num(function() return mq.TLO.Me.X() end)
    local y = T.num(function() return mq.TLO.Me.Y() end)
    return math.sqrt((x - State.campX) ^ 2 + (y - State.campY) ^ 2)
end

-- ------------------------------------------------------------- SitToMed (sit between casts)
function M:sitToMedTick()
    if self.sitToMed <= 0 then return end
    if not Timers.expired('med:sittomed') then return end
    Timers.set('med:sittomed', 1000)
    if (self.cfg.MeleeOn or 0) ~= 0 or mounted() or T.inCombat() then return end
    if not T.bool(function() return mq.TLO.Me.Standing() end) or T.num(function() return mq.TLO.Me.Casting.ID() end) > 0 or moving() then return end
    if T.now() - (Cast.lastCastAt or 0) < self.sitToMed * 1000 then return end
    local tot = T.num(function() return mq.TLO.Me.TargetOfTarget.ID() end)
    if tot == T.myId() and T.num(function() return mq.TLO.Target.ID() end) ~= T.myId() then return end
    self:sit(false)
end

-- ------------------------------------------------------------- GroupWatch / CheckStats
local function memberStat(m, stat)
    if stat == 'Endurance' then return T.num(function() return m.PctEndurance() end) end
    return T.num(function() return m.PctMana() end)
end

--- Start a hold for the first watched member whose stat is at or under the line.
function M:groupWatchStart()
    local gw = self.gw
    if not gw or gw.mode == 0 then return end
    if (T.aggroTargetId() > 0 and State.chainPull == 0) or lower(State.role) == 'manual' then return end
    local role = lower(State.role)
    local tankish = role == 'tank' or role == 'pullertank' or role == 'pettank' or role == 'pullerpettank' or role == 'hunter' or role == 'hunterpettank'
    if State.mainAssist ~= '' and not T.spawnByName(State.mainAssist, 'pc') and not tankish and State.campZone == T.zoneId() then
        Log.info('I am not detecting Main Assist pausing.')
        self.waitMA = true
        return
    end
    if State.chainPullHold == 1 then State.chainPullHold = 0 end
    local corpse = false
    for i = 1, 5 do
        local m = T.groupMember(i)
        local id = T.num(function() return m.ID() end)
        local ty = T.str(function() return m.Type() end)
        if id > 0 and ty == 'Corpse' then corpse = true end
        if id > 0 and ty ~= 'Corpse' then
            local cls = T.str(function() return m.Class.ShortName() end):upper()
            local watched = true
            if gw.mode == 2 and not (cls == 'CLR' or cls == 'DRU' or cls == 'SHM') then watched = false end
            if gw.mode == 3 and not require('core.buffrules').inList(gw.classes, cls) then watched = false end
            if gw.mode == 1 and cls == 'BRD' then watched = false end
            if watched then
                local stats = { END_CLASSES[cls] and 'Endurance' or 'Mana' }
                if cls == 'BST' or cls == 'PAL' or cls == 'RNG' or cls == 'SHD' then stats[2] = 'Endurance' end
                for _, stat in ipairs(stats) do
                    local v = memberStat(m, stat)
                    if v >= 1 and v <= gw.pct then
                        if self:checkStatsStart(m, id, stat, gw.resume) then
                            if corpse then State.chainPullHold = 1 end
                            return
                        end
                    end
                end
            end
        end
    end
    if corpse then State.chainPullHold = 1 end
end

function M:checkStatsStart(m, id, stat, resume)
    local name = T.str(function() return m.CleanName() end)
    if State.chaseAssist and State.mainAssist ~= '' then
        local ma = T.spawnByName(State.mainAssist, 'pc')
        if ma and T.num(function() return ma.Distance() end) > (State.chaseDistance or 25) then return false end
    end
    if moving() then return false end
    local msg = string.format('Waiting for >> %s << to med up to %d%% %s.', name, resume, stat)
    if pullRole() then Comms.say('t', '%s', msg) else Log.info('%s', msg) end
    mq.cmdf('/squelch /target id %d', id)
    State.pulling = false
    setMedding(true)
    self.watch = { id = id, name = name, stat = stat, resume = resume, lastStat = -1 }
    Timers.set('med:stall', 120000)
    return true
end

function M:watchTick()
    local w = self.watch
    local c = self.cfg
    if ((c.ReturnToCamp or 0) ~= 0 and self:campDistance() > 15) or State.chaseAssist then Cast.hooks.doWeMove('CheckStats') end
    if T.aggroTargetId() > 0 then
        self.watch = nil
        setMedding(false)
        return
    end
    if not mounted() and not moving() and not T.bool(function() return mq.TLO.Me.Sitting() end) and T.myClass() ~= 'BRD' then self:sit(false) end
    local sp = T.spawn(w.id)
    local m = nil
    for i = 1, 5 do
        if T.num(function() return T.groupMember(i).ID() end) == w.id then m = T.groupMember(i) end
    end
    local done, reason = false, nil
    if not sp or not m then
        done, reason = true, string.format('[PM] CheckStats: stopped waiting for %s - no longer in zone (camped, zoned or dead).', w.name)
    else
        local v = memberStat(m, w.stat)
        if v < w.resume then
            if v ~= w.lastStat then
                w.lastStat = v
                Timers.set('med:stall', 120000)
            elseif Timers.expired('med:stall') then
                done, reason = true, string.format('[PM] CheckStats: stopped waiting for %s - %s stuck at %d%% for 2m, will check again next pass.', w.name, w.stat, v)
            end
        else
            done = true
            local msg = string.format('%s is now above %d%% %s resuming activity.', w.name, w.resume, w.stat)
            if pullRole() then Comms.say('t', '%s', msg) end
            Log.info('%s', msg)
        end
    end
    if done then
        if reason then Log.info('%s', reason) end
        self.watch = nil
        setMedding(false)
        stand()
        State.chainPullHold = 0
    end
end

function M:waitMATick()
    if State.mainAssist == '' or T.spawnByName(State.mainAssist, 'pc') then
        Log.info('Main Assist is back resuming action.')
        self.waitMA = false
        return
    end
    if not mounted() and not T.bool(function() return mq.TLO.Me.Sitting() end) and not navOrStick()
        and (pct('Mana') < 90 or pct('Endurance') < 90 or hp() < 90) then
        self:sit(false)
    end
end

-- ------------------------------------------------------------- WaitForMedders
--- The main assist's role, asked over DanNet once a minute (the Lua MA answers MuleAssist.Role, the macro Role).
function M:refreshMARole()
    local ma = State.mainAssist
    if ma == '' or lower(ma) == lower(T.myName()) then return end
    if Timers.running('med:marole') and self.maRole.cacheFor == ma then return end
    Timers.set('med:marole', 60000)
    self.maRole = { cacheFor = ma, role = nil }
    if not Comms.danNet() or not Comms.isPeer(ma) then return end
    for _, q in ipairs({ 'Role', 'MuleAssist.Role' }) do
        mq.cmdf('/dquery %s -q %s', ma, q)
        mq.delay(300, function() return T.num(function() return mq.TLO.DanNet(ma).Q(q).Received() end) > 0 end)
        local v = T.str(function() return mq.TLO.DanNet(ma).Q(q)() end)
        if v ~= '' and v:upper() ~= 'NULL' then self.maRole.role = v return end
    end
end

--- How many group members sit to med, and the first one (CountMedders).
function M:countMedders()
    local c = self.cfg
    local skipMA = false
    if (c.WaitForMeddersSkipMA or 1) == 2 then skipMA = true
    elseif (c.WaitForMeddersSkipMA or 1) == 1 then
        self:refreshMARole()
        local r = self.maRole.role
        skipMA = r == nil or PULL_ROLES[lower(r)] == true
    end
    local count, first = 0, nil
    for i = 1, 5 do
        local m = T.groupMember(i)
        local id = T.num(function() return m.ID() end)
        if id > 0 and T.bool(function() return m.Present() end) and not T.bool(function() return m.Mercenary() end)
            and not T.bool(function() return m.Dead() end) and T.str(function() return m.Type() end) ~= 'Corpse' then
            local cls = T.str(function() return m.Class.ShortName() end):upper()
            local name = T.str(function() return m.CleanName() end)
            if cls ~= 'BRD' and not (skipMA and lower(name) == lower(State.mainAssist)) and T.bool(function() return m.Sitting() end) then
                local stat = END_CLASSES[cls] and 'Endurance' or 'Mana'
                if memberStat(m, stat) < 100 then
                    count = count + 1
                    first = first or name
                end
            end
        end
    end
    return count, first
end

function M:wfmStart()
    local c = self.cfg
    if (c.WaitForMedders or 0) == 0 or lower(State.role) == 'manual' then return end
    if Timers.running('med:wfmcooldown') then return end
    if T.bool(function() return mq.TLO.Me.Hovering() end) or T.aggroTargetId() > 0 then return end
    if moving() or mounted() then return end
    local count, first = self:countMedders()
    if count == 0 then return end
    local msg = 'Waiting for ' .. tostring(first)
    if count > 1 then msg = msg .. string.format(' (+%d others)', count - 1) end
    State.pulling = false
    setMedding(true)
    self.wfm = { first = first, capped = (c.WaitForMeddersMax or 0) > 0 }
    if self.wfm.capped then Timers.set('med:wfmcap', c.WaitForMeddersMax * 1000) end
    if pullRole() then Comms.say('t', 'WAITFORMEDDERS-> %s to finish medding.', msg) else Log.info('WAITFORMEDDERS-> %s to finish medding.', msg) end
end

function M:wfmTick()
    local c = self.cfg
    if ((c.ReturnToCamp or 0) ~= 0 and self:campDistance() > (c.ReturnToCampAccuracy or 10)) or State.chaseAssist then Cast.hooks.doWeMove('WaitForMedders') end
    if T.aggroTargetId() > 0 then
        self.wfm = nil
        setMedding(false)
        return
    end
    if not mounted() and not T.bool(function() return mq.TLO.Me.Sitting() end) and not moving() and T.num(function() return mq.TLO.Me.Casting.ID() end) == 0 then
        self:sit(true)
    end
    local count, first = self:countMedders()
    local done = count == 0
    if not done and self.wfm.capped and Timers.expired('med:wfmcap') then
        Timers.set('med:wfmcooldown', (c.WaitForMeddersMax or 0) * 1000)
        local msg = string.format('WAITFORMEDDERS-> Gave up after %ds, %s still sitting.', c.WaitForMeddersMax or 0, tostring(first or self.wfm.first))
        if pullRole() then Comms.say('t', '%s', msg) else Log.info('%s', msg) end
        done = true
    end
    if done then
        if count == 0 then
            if pullRole() then Comms.say('t', 'WAITFORMEDDERS-> Medders are up, resuming.') else Log.info('WAITFORMEDDERS-> Medders are up, resuming.') end
        end
        self.wfm = nil
        stand()
        setMedding(false)
    end
end

-- ------------------------------------------------------------- the tick
function M:GiveTime(ctx)
    self:sitToMedTick()
    if self.medding and not self.watch and not self.wfm then self:medTick() return end
    if self.watch then self:watchTick() return end
    if self.wfm then self:wfmTick() return end
    if self.waitMA then self:waitMATick() return end
    if T.inCombat() then return end
    if State.chainPull == 2 then return end
    if Timers.running('med:scan') then return end   -- the group scans (mana / sitting / class per member) once a second
    Timers.set('med:scan', 1000)
    if self:medStart() then return end
    self:groupWatchStart()
    if self.watch or self.waitMA then return end
    self:wfmStart()
end

function M:OnCombatStart()
    if self.medding then setMedding(false) end
end

M.Binds = {
    ['/medstart'] = function(self, arg)
        local v = tonumber(arg)
        if not v then Log.info('MedStart %d', self.cfg.MedStart or 20) return end
        self.cfg.MedStart = v
        Config.set('General', 'MedStart', v)
        Log.info('MedStart %d', v)
    end,
    ['/waitformedders'] = function(self, arg)
        local v = tonumber(arg)
        if arg == 'on' then v = 1 elseif arg == 'off' then v = 0 end
        if v == nil then v = (self.cfg.WaitForMedders or 0) == 0 and 1 or 0 end
        self.cfg.WaitForMedders = v
        Log.info('WaitForMedders %d', v)
    end,
    ['/waitformeddersmax'] = function(self, arg)
        local v = tonumber(arg)
        if v then self.cfg.WaitForMeddersMax = v Config.set('General', 'WaitForMeddersMax', v) Log.info('WaitForMeddersMax %d', v) end
    end,
    ['/waitformeddersskipma'] = function(self, arg)
        local v = tonumber(arg)
        if v then self.cfg.WaitForMeddersSkipMA = v Config.set('General', 'WaitForMeddersSkipMA', v) Log.info('WaitForMeddersSkipMA %d', v) end
    end,
    ['/pullernoselfmed'] = function(self, arg)
        local v = tonumber(arg)
        if v == nil then v = (self.cfg.PullerNoSelfMed or 0) == 0 and 1 or 0 end
        self.cfg.PullerNoSelfMed = v
        Log.info('PullerNoSelfMed %d', v)
    end,
    ['/groupwatchresume'] = function(self, arg)
        local v = tonumber(arg)
        if v then
            self.cfg.GroupWatchResume = v
            Config.set('General', 'GroupWatchResume', v)
            self.gw = M.parseGroupWatch(self.cfg.GroupWatchOn, v)
            Log.info('GroupWatchResume %d', self.gw.resume)
        end
    end,
}

return M
