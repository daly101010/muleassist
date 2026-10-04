-- modules/pull.lua: pulling. SetPullRange / PullVars, FindMobToPull (the scan around the camp with the nav
-- path-length sort, PullValidate, the secondary list, the FailMax / PullWait wait), Pull (the walk out by nav
-- or moveto, the stuck escape, the pull by melee / ranged / pet / cast with the calm, the aggro checks and
-- the retries), DoThePullDance, WaitForMob (the walk home and the wait for the mob), PullReset,
-- TogglePullMode, chain pulling (the Combat probe, ChainPull 2, ChainPullHold, the ChainPullPause
-- schedule), GrabTheDead, the pull arc, mass pull, /pull, and the CantHit / CantSee / TooClose / TooFar
-- flags, with the same [Pull] keys as the macro.
--
-- Not a transliteration: the mobs the macro put on alert list 1 are a Lua skip set (`pull:skip:<id>`
-- timers); the MQ2AdvPath pull path is not ported (nav or moveto only); a hunter's inline fight is left to
-- the combat module; the melee attack loop and the readiness spin are bounded by the pull timer.
local mq = require('mq')
local T = require('core.tlo')
local Config = require('core.config')
local Timers = require('core.timers')
local Spell = require('core.spell')
local Cast = require('core.cast')
local Comms = require('core.comms')
local Log = require('core.log')
local Cond = require('core.cond')
local State = require('core.state')
local Buffcheck = require('core.buffcheck')

local M = { name = 'pull' }

M.Settings = {
    scalars = {
        { section = 'Pull', key = 'PullWith', type = 'string', default = 'Melee' },
        { section = 'Pull', key = 'PullMeleeStick', type = 'int', default = 0 },
        { section = 'Pull', key = 'MaxRadius', type = 'int', default = 350 },
        { section = 'Pull', key = 'MaxZRange', type = 'int', default = 50 },
        { section = 'Pull', key = 'PullWait', type = 'int', default = 5 },
        { section = 'Pull', key = 'PullCond', type = 'string', default = 'TRUE', rank = false },
        { section = 'Pull', key = 'PrePullCond', type = 'string', default = 'TRUE', rank = false },
        { section = 'Pull', key = 'PullRoleToggle', type = 'int', default = 0 },
        { section = 'Pull', key = 'ChainPull', type = 'int', default = 0 },
        { section = 'Pull', key = 'ChainPullHP', type = 'int', default = 90 },
        { section = 'Pull', key = 'ChainPullPause', type = 'string', default = '30|2', rank = false },
        { section = 'Pull', key = 'PullLevel', type = 'string', default = '0|0', rank = false },
        { section = 'Pull', key = 'PullArcWidth', type = 'string', default = '0', rank = false },
        { section = 'Pull', key = 'PullNamedsFirst', type = 'int', default = 0 },
        { section = 'Pull', key = 'ActNatural', type = 'int', default = 1 },
        { section = 'Pull', key = 'UseCalm', type = 'int', default = 0 },
        { section = 'Pull', key = 'CalmWith', type = 'string', default = 'Harmony' },
        { section = 'Pull', key = 'CalmRadius', type = 'int', default = 50 },
        { section = 'Pull', key = 'GrabDeadGroupMembers', type = 'int', default = 1 },
        { section = 'Bandolier', key = 'BandolierOn', type = 'int', default = 0 },
        { section = 'Bandolier', key = 'BandolierPull', type = 'string', default = '1HS', rank = false },
        { section = 'Pet', key = 'PetRampPullWait', type = 'int', default = 0 },
        { section = 'General', key = 'CampRadius', type = 'int', default = 30 },
        { section = 'General', key = 'ReturnToCampAccuracy', type = 'int', default = 10 },
        { section = 'General', key = 'MedStart', type = 'int', default = 20 },
        { section = 'General', key = 'MedOn', type = 'int', default = 1 },
        { section = 'General', key = 'PullerNoSelfMed', type = 'int', default = 0 },
        { section = 'General', key = 'HealerDownHold', type = 'int', default = 1 },
        { section = 'Melee', key = 'MeleeDistance', type = 'int', default = 30 },
        { section = 'Melee', key = 'DismountDuringFights', type = 'int', default = 0 },
        { section = 'Melee', key = 'FaceMobOn', type = 'int', default = 1 },
        { section = 'Melee', key = 'StickHow', type = 'string', default = 'snaproll rear', rank = false },
    },
}
M.cfg = {}
M.pullRange, M.pullType, M.pullItem, M.pullAmmo = 0, 'Melee', '', ''
M.pullMin, M.pullMax = 1, 200
M.arc = { l = 0, r = 0 }
M.flags = { cantHit = false, cantSee = false, tooClose = false, tooFar = false }
M.failCounter = 0
M.pullOnce = false
M.massPull = nil
M.lastMobPullId = 0
M.chainTemp = 0
M.origRanged = ''
M.deadMember, M.dragging = 0, false
M.hooks = { healerDown = function() return false end, anyMemberDown = function() return false end, validateTarget = function(id) return true, 'ok' end,
    isProtected = function(id) return false end, combatPet = function(id) end, petAttackSafe = function(id) end }

local PULL_ROLES = { puller = true, pullertank = true, pullerpettank = true, hunter = true, hunterpettank = true }
local HUNTERS = { hunter = true, hunterpettank = true }
local MEZ_ANIM = { [26] = true, [32] = true, [71] = true, [72] = true, [17] = true, [111] = true, [129] = true }
local function lower(s) return tostring(s or ''):lower() end
local function role() return lower(State.role) end
local function targetId() return T.num(function() return mq.TLO.Target.ID() end) end
local function iAmMA() return State.mainAssist ~= '' and lower(State.mainAssist) == lower(T.myName()) end
local function meCombat() return T.bool(function() return mq.TLO.Me.Combat() end) end
local function navOk() return T.bool(function() return mq.TLO.Navigation.MeshLoaded() end) end
local function navActive() return T.bool(function() return mq.TLO.Navigation.Active() end) end
local function Mv() return require('modules.movement') end
local function Combat() return require('modules.combat') end
local function camp() return State.campX, State.campY end
local function distToCamp(sp)
    local cx, cy = camp()
    local dx, dy = T.num(function() return sp.X() end) - cx, T.num(function() return sp.Y() end) - cy
    return math.sqrt(dx * dx + dy * dy)
end
local function maSpawn() if State.mainAssist == '' then return nil end return T.spawnByName(State.mainAssist, lower(State.mainAssistType ~= '' and State.mainAssistType or 'pc')) end
local function dist2(a, b)
    local dx, dy = T.num(function() return a.X() end) - T.num(function() return b.X() end), T.num(function() return a.Y() end) - T.num(function() return b.Y() end)
    return math.sqrt(dx * dx + dy * dy)
end
local function xtSlot(n)
    -- the n-th Auto Hater slot's id (XTSlot / XTSlot2)
    local seen = 0
    for i = 1, 13 do
        local xt = mq.TLO.Me.XTarget(i)
        if T.str(function() return xt.TargetType() end) == 'Auto Hater' then
            seen = seen + 1
            if seen == n then return T.num(function() return xt.ID() end) end
        end
    end
    return 0
end
local function skip(id, ms) Timers.set('pull:skip:' .. id, ms or 300000) end
local function skipped(id) return Timers.running('pull:skip:' .. id) end
local function condTrue(cond)
    if cond == nil or cond == '' or cond == 'TRUE' or cond == 'NULL' then return true end
    return Cond.ok(cond)
end
local function haveAggro(beginId)
    -- the macro's "aggro appeared" test in its chain and non-chain forms
    if State.chainPull == 0 then return T.aggroTargetId() > 0 end
    local s1, s2 = xtSlot(1), xtSlot(2)
    return s2 > 0 or (s1 > 0 and s1 ~= (State.myTargetId or 0) and s1 ~= (beginId or 0))
end
local function pulledNow()
    if State.chainPull == 0 then return T.aggroTargetId() > 0 end
    return xtSlot(2) > 0 or xtSlot(1) == targetId()
end

-- ------------------------------------------------------------- settings
function M:LoadSettings()
    local c = Config.load(self.Settings)
    self.cfg = c
    State.chainPull = c.ChainPull or 0
    if role() ~= 'puller' and State.chainPull ~= 0 then State.chainPull = 0 end   -- the macro's typo keeps chain pulling for plain pullers only; kept
    State.chainPullHold = 0
    -- PullLevel
    local pl = lower(c.PullLevel or '0|0')
    self.pullMin, self.pullMax = 1, 200
    if pl:find('auto', 1, true) then
        local lvl = T.num(function() return mq.TLO.Me.Level() end)
        self.pullMin, self.pullMax = lvl - 5, lvl + 2
    elseif pl:find('|', 1, true) and pl ~= '0|0' and pl ~= 'null' then
        local a, b = pl:match('^(%d+)|(%d+)$')
        a, b = tonumber(a) or 0, tonumber(b) or 0
        if a == 0 or b == 0 or a > b then Log.warn('Invalid Pull Level Settings resetting to default.') else self.pullMin, self.pullMax = a, b end
    end
    self.origRanged = T.str(function() return mq.TLO.InvSlot('ranged').Item.Name() end)
    local width = tonumber(c.PullArcWidth) or 0
    if width > 0 and (role() == 'puller' or role() == 'pullertank') then
        self:setPullAngles(T.num(function() return mq.TLO.Me.Heading.Degrees() end), width, true)
        Log.info('Pulling an Area starting from the Left at %d degrees ending at %d degrees.', self.arc.l, self.arc.r)
    end
    if PULL_ROLES[role()] then
        if navOk() then Comms.say('r', 'PULL: The MQ2Nav mesh for %s is loaded', T.str(function() return mq.TLO.Zone.Name() end)) Comms.say('r', 'PULL: Using MQ2Nav to Pull') end
        if role() == 'puller' then mq.cmdf('/squelch /mapfilter TargetRadius %d', c.MaxRadius or 350) end
    end
end

--- SetPullRange: the pull range and type from PullWith.
function M:setPullRange(flag)
    local c = self.cfg
    local with = c.PullWith or 'Melee'
    -- recomputed only when the inputs change or every 30 s (ammo can run out): the inventory walks and
    -- the /mapfilter commands are not per-pass work
    local sig = table.concat({ tostring(with), tostring(c.MaxRadius or 350), role(), flag == 3 and '3' or '0', tostring(State.petAttackRange or 115) }, '|')
    if sig == self.rangeSig and Timers.running('pull:range') then return end
    self.rangeSig = sig
    Timers.set('pull:range', 30000)
    local function vars(range, kind, actual)
        self.pullRange, self.pullType, self.pullRangeActual = math.floor(range), kind, actual
        mq.cmdf('/squelch /mapfilter CastRadius %d', self.pullRange)
        mq.cmdf('/squelch /mapfilter PullRadius %d', c.MaxRadius or 350)
    end
    local item, ammo = with:match('^([^|]*)|?(.*)$')
    item = item or with
    local it = mq.TLO.FindItem('=' .. item)
    local itType = T.str(function() return it.Type() end)
    if (itType == 'Archery' or itType:find('^Throwing') or itType == 'ammo') and T.num(function() return mq.TLO.FindItemCount('=' .. item)() end) > 0 then
        self.pullItem = item
        local range = T.num(function() return it.Range() end)
        if range == 0 then range = 50 end
        if ammo ~= '' and T.num(function() return mq.TLO.FindItemCount('=' .. ammo)() end) > 0 then
            self.pullAmmo = ammo
            if itType == 'Archery' then range = range + T.num(function() return mq.TLO.FindItem('=' .. ammo).Range() end) end
            vars(range * 0.9, 'Ranged', range)
            return
        end
        Log.info("I can't find any ammo defaulting to Melee for PullWith")
        vars(15, 'Melee', 15)
        return
    end
    if ammo == '' and T.num(function() return mq.TLO.FindItemCount('=' .. with)() end) > 0 then
        local range = T.num(function() return mq.TLO.FindItem('=' .. with).Spell.Range() end)
        vars(range * 0.9, with, range)
        return
    end
    local kind = Spell.kind(with)
    if kind == 'spell' or kind == 'aa' or kind == 'disc' then
        local range = Spell.facts(with).range
        local r = role()
        if r == 'puller' or r == 'pullertank' or r == 'pullerpettank' or r == 'hunterpettank' or flag == 3 then vars(range / 1.11, with, range)
        elseif r == 'hunter' then vars(range / 2.75, with, range) end
        return
    end
    if lower(with) == 'pet' then
        if role() == 'hunterpettank' then vars((State.petAttackRange or 115) * 0.8, 'Pet', (State.petAttackRange or 115) * 0.8) else vars(185, 'Pet', 185) end
        return
    end
    if lower(with) == 'melee' then vars(15, 'Melee', 15) return end
end

-- ------------------------------------------------------------- the pull arc
function M:setPullAngles(dir, width, quiet)
    if width == 0 then return end
    local l, r = dir - width / 2, dir + width / 2
    if l < 0 then l = 360 - (width * 0.5 - dir) end
    if r > 360 then r = width * 0.5 + dir - 360 end
    self.arc.l, self.arc.r = l, r
    if not quiet then Log.info('Setting Pull Angles. Facing: %d Left Side: %d Right Side: %d Width: %d', dir, l, r, width) end
end
function M:mobInArc(id)
    local sp = T.spawn(id)
    if not sp then return false end
    local cx, cy = camp()
    local toCamp = T.num(function() return sp.HeadingToLoc(cy, cx).Degrees() end)
    local dir = (toCamp + 180) % 360
    local l, r = self.arc.l, self.arc.r
    if l >= r then return not (dir < l and dir > r) end
    return not (dir < l or dir > r)
end

-- ------------------------------------------------------------- PullValidate
function M:onList(name, list)
    for _, n in ipairs(list or {}) do if lower(name):find(lower(n), 1, true) then return true end end
    return false
end
function M:listIsAll()
    local list = State.mobsToPull or {}
    if #list == 0 then return true end
    for _, n in ipairs(list) do if lower(n) == 'all' or lower(n):find('all for all', 1, true) then return true end end
    return false
end
function M:pullValidate(id, flag, checkSec)
    local c = self.cfg
    local sp = T.spawn(id)
    if not sp then return false end
    local name = T.str(function() return sp.CleanName() end)
    if not self:listIsAll() then
        local ok = self:onList(name, State.mobsToPull)
        if not ok and checkSec and #(State.mobsToPullSecondary or {}) > 0 and self:onList(name, State.mobsToPullSecondary) then ok = true end
        if not ok then return false end
    end
    if distToCamp(sp) > (c.MaxRadius or 350) then return false end
    local r = role()
    if (r == 'puller' or r == 'pullertank' or r == 'pullerpettank') and not T.bool(function() return sp.LineOfSight() end) and not navOk() then return false end
    local lvl = T.num(function() return sp.Level() end)
    if lvl < self.pullMin or lvl > self.pullMax then return false end
    if (tonumber(c.PullArcWidth) or 0) > 0 and not self:mobInArc(id) then return false end
    if T.num(function() return sp.PctHPs() end) <= 99 then
        if flag ~= 0 and targetId() ~= id then
            Log.info('%s not at 100%% HPs Double checking for server lag', name)
            mq.cmdf('/squelch /target id %d', id)
            mq.delay(1000, function() return targetId() == id end)
            mq.delay(500)
            if T.num(function() return mq.TLO.Target.PctHPs() end) > 99 then return true end
        end
        return false
    end
    if T.bool(function() return sp.Named() end) and ((flag ~= 0 and State.mobCount > 0 and xtSlot(1) > 0) or flag == 0) then return false end
    if T.bool(function() return sp.Named() end) then Log.info('Found a named to pull: %s', name) end
    return true
end

--- ValidateTarget's pull branch (PrePullCond, radius, LOS, strangers, health, level, the ToT, the lists).
function M:validatePull(id, flag)
    local c = self.cfg
    local sp = T.spawn(id)
    if not sp then return false, 'NoTarget' end
    if not condTrue(c.PrePullCond) then Log.info('PrePullCond is False. Not starting pull') return false, 'PrePullCondBad' end
    if distToCamp(sp) > (c.MaxRadius or 350) then return false, 'OutofRadius' end
    local r = role()
    if (r == 'puller' or r == 'pullertank' or r == 'pullerpettank' or flag == 3) and not T.bool(function() return sp.LineOfSight() end) and not navOk() then return false, 'NoLOS' end
    if T.num(function() return sp.Distance() end) >= 16 and self:strangerNear(id, 20) then return false, 'PCNear' end
    if T.num(function() return sp.PctHPs() end) <= 99 then
        if targetId() ~= id then mq.cmdf('/squelch /target id %d', id) mq.delay(1000, function() return targetId() == id end) mq.delay(500) end
        if T.num(function() return sp.PctHPs() end) <= 99 then return false, 'PullNotFullHealth' end
        if T.num(function() return mq.TLO.Me.TargetOfTarget.ID() end) > 0 then return false, 'PCNear' end
    end
    local lvl = T.num(function() return sp.Level() end)
    if lvl < self.pullMin or lvl > self.pullMax then return false, 'BadLevel' end
    if targetId() == id then
        local tot = mq.TLO.Me.TargetOfTarget
        local totId = T.num(function() return tot.ID() end)
        local totType = T.str(function() return tot.Type() end)
        if totId > 0 and totId ~= T.myId() then
            if totType == 'PC' and not T.inGroup(totId) then return false, 'PullToTTNotPuller' end
            if totType == 'Pet' and totId ~= T.num(function() return mq.TLO.Me.Pet.ID() end) then return false, 'PullToTTNotMyPet' end
        end
    end
    if not self:listIsAll() then
        local name = T.str(function() return sp.CleanName() end)
        if not self:onList(name, State.mobsToPull) and not self:onList(name, State.mobsToPullSecondary) then return false, 'PullMobNotonList' end
    end
    return true, 'ok'
end

--- StrangerNearSpawn: a PC within `radius` of the spawn who is not me, my group, my raid or a DanNet peer.
function M:strangerNear(id, radius)
    local sp = T.spawn(id)
    if not sp then return false end
    local n = T.num(function() return mq.TLO.SpawnCount('pc')() end)
    for i = 1, n do
        local pc = mq.TLO.NearestSpawn(i, 'pc')
        local name = T.str(function() return pc.CleanName() end)
        if name ~= '' and lower(name) ~= lower(T.myName()) and dist2(pc, sp) <= radius then
            local pid = T.num(function() return pc.ID() end)
            if not T.inGroup(pid) and T.num(function() return mq.TLO.Raid.Member(name).Level() end) == 0 and not Comms.isPeer(name) then return true end
        end
    end
    return false
end

-- ------------------------------------------------------------- FindMobToPull
local function searchQ(base, radius)
    local cx, cy = camp()
    return string.format('range %d %d npc %s radius %d zradius %d targetable', M.pullMin, M.pullMax, base, radius, M.cfg.MaxZRange or 50), cx, cy
end

function M:findMobToPull(flag)
    local c = self.cfg
    if State.buffMode or State.zombieMode then return 0 end
    local r = role()
    if (c.BandolierOn or 0) ~= 0 and (c.BandolierPull or '') ~= '' then
        local set = mq.TLO.Me.Bandolier(c.BandolierPull)
        if T.num(function() return set.Index() end) > 0 and not T.bool(function() return set.Active() end) then
            mq.cmdf('/invoke ${Me.Bandolier[%s].Activate}', c.BandolierPull)
            mq.delay(1000, function() return T.bool(function() return mq.TLO.Me.Bandolier(c.BandolierPull).Active() end) end)
        end
    end
    if T.groupCount() > 0 and self.hooks.anyMemberDown() then
        if Timers.expired('pull:downecho') then Timers.set('pull:downecho', 10000) Log.info('Group Member is dead or gone, holding pulls') end
        return 0
    end
    if State.chainPull == 2 and flag ~= 0 then State.chainPull = 1 end
    local blocked = (flag ~= 0 and not PULL_ROLES[r]) or (flag == 0 and not r:find('puller', 1, true)) or State.pulled or (T.aggroTargetId() > 0 and State.chainPull == 0) or State.chainPullHold ~= 0 or State.dpsPaused
    if blocked and flag ~= 3 then return 0 end
    if flag == 3 then Log.info('We are going to pull ONCE in FindMobToPull') end
    Combat():mobRadar()
    if State.chainPull ~= 0 and (State.mobCount > 1 or xtSlot(2) > 0) then return 0 end
    if flag ~= 0 then
        if State.chainPull ~= 0 then
            if targetId() == T.myId() then mq.cmd('/squelch /target clear') mq.delay(1000, function() return targetId() == 0 end) end
            local s1 = xtSlot(1)
            local mt = State.myTargetId or 0
            if s1 > 0 and ((mt == 0 and targetId() == 0) or T.num(function() return mq.TLO.Target.PctHPs() end) >= (c.ChainPullHP or 90) or (mt > 0 and T.spawn(mt) and T.num(function() return T.spawn(mt).PctHPs() end) >= (c.ChainPullHP or 90))) then return 0 end
            local ma = maSpawn()
            if ma and distToCamp(ma) > 75 then return 0 end
        end
        if flag ~= 3 and (not PULL_ROLES[r] or T.num(function() return mq.TLO.Me.Buff('Resurrection Sickness').ID() end) > 0 or T.num(function() return mq.TLO.Me.Buff('Revival Sickness').ID() end) > 0 or State.iAmDead) then return 0 end
        local cls = T.myClass()
        if (cls == 'MAG' or cls == 'NEC' or cls == 'BST') and (c.PetRampPullWait or 0) ~= 0 and not T.inCombat() and r == 'pullerpettank' then self:checkRampPets() end
    end
    self:setPullRange(flag)
    mq.doevents()
    State.pulling = false
    if State.medding or State.chainPullHold ~= 0 then return 0 end
    local nav = navOk()
    local secondPass = false
    local md = c.MeleeDistance or 30
    for pass = 1, 2 do
        local pullMob, count = 0, 0
        local base = (r == 'hunter' or r == 'hunterpettank') and '' or (nav and string.format('loc %d %d', camp()) or string.format('los loc %d %d', camp()))
        local q = searchQ(base, c.MaxRadius or 350)
        count = T.num(function() return mq.TLO.SpawnCount(q)() end)
        local total = count
        if flag == 0 then
            if count > 0 and self.lastMobPullId > 0 and T.spawn(self.lastMobPullId) and T.num(function() return T.spawn(self.lastMobPullId).Distance() end) >= md then return 0 end
            count = count - T.num(function() return mq.TLO.SpawnCount(searchQ(base, md))() end)
        end
        if count > 0 then
            local cands = {}
            local n = math.min(total, 40)
            for i = 1, n do
                local sp = mq.TLO.NearestSpawn(i, q)
                local id = T.num(function() return sp.ID() end)
                if id > 0 and not skipped(id) then
                    local d = 100000
                    if nav then
                        local loc = string.format('locxyz %d %d %d', T.num(function() return sp.X() end), T.num(function() return sp.Y() end), T.num(function() return sp.FloorZ() end))
                        if T.bool(function() return mq.TLO.Navigation.PathExists(loc)() end) then
                            if (c.PullNamedsFirst or 0) ~= 0 and T.bool(function() return sp.Named() end) then d = 1 Log.info('Lets pull nameds first mkay...') else d = T.num(function() return mq.TLO.Navigation.PathLength(loc)() end) end
                        end
                    else d = T.num(function() return sp.Distance() end) end
                    cands[#cands + 1] = { id = id, d = d }
                end
            end
            table.sort(cands, function(a, b) return a.d < b.d end)
            for _, cand in ipairs(cands) do
                if self:pullValidate(cand.id, flag, secondPass) then pullMob = cand.id self.chainTemp = cand.id break end
            end
            if pullMob == 0 then self.chainTemp = 0 end
        else self.chainTemp = 0 end
        if pullMob > 0 then
            if flag == 0 then return count end
            local sp = T.spawn(pullMob)
            if T.num(function() return sp.Distance3D() end) < 120 and T.bool(function() return sp.LineOfSight() end) then mq.cmdf('/squelch /target id %d', pullMob) mq.delay(2000, function() return targetId() == pullMob end) end
            State.pulling = true
            local ok, why = self.hooks.validateTarget(pullMob)
            if ok then ok, why = self:validatePull(pullMob, flag) end
            if not ok or (targetId() > 0 and T.spawn(targetId()) and distToCamp(T.spawn(targetId())) > (c.MaxRadius or 350)) then
                skip(pullMob)
                Log.pm('pull: %s (%d) rejected: %s', T.str(function() return sp.CleanName() end), pullMob, tostring(why))
                mq.cmd('/squelch /target clear')
                State.pulling = false
            else
                State.myTargetId, State.myTargetName = pullMob, T.str(function() return sp.CleanName() end)
                if lower(self.pullType) == 'pet' and T.str(function() return mq.TLO.Me.Pet.Stance() end):upper() ~= 'FOLLOW' then mq.cmd('/pet follow') end
                if targetId() > 0 and targetId() ~= pullMob then if meCombat() then mq.cmd('/attack off') end mq.cmd('/squelch /target clear') end
                if not State.killOrderOn then self:pull(flag) end
                if State.chainPull ~= 0 then
                    local _, b = tostring(c.ChainPullPause or '30|2'):match('^(%d+)|(%d+)$')
                    if b then Timers.set('pull:chain2', (tonumber(b) + 1) * 60000) end
                end
                return 0
            end
        elseif flag == 0 then return 0
        elseif not secondPass and #(State.mobsToPullSecondary or {}) > 0 then
            secondPass = true
        else break end
    end
    -- nothing to pull: the scan is tried again in a second, and after FailMax dry scans the skip set is
    -- cleared and the PullWait respawn wait starts (the macro's FailCounter / PullWait)
    self.failCounter = self.failCounter + 1
    Timers.set('pull:wait', 1000)
    if self.failCounter < 3 then return 0 end
    Timers.clearPrefix('pull:skip:')
    self.failCounter = 0
    if (c.PullWait or 0) > 0 then
        Comms.say('t', 'PULLING-> Waiting %d seconds for mobs to respawn.', c.PullWait)
        Timers.set('pull:wait', math.max(c.PullWait * 1000, 1000))
        local medStart = c.MedStart or 20
        if not T.bool(function() return mq.TLO.Me.Sitting() end) and (c.PullerNoSelfMed or 0) == 0 and (c.MedOn or 1) ~= 0
            and (T.num(function() return mq.TLO.Me.PctMana() end) < medStart or T.num(function() return mq.TLO.Me.PctEndurance() end) < medStart or T.num(function() return mq.TLO.Me.PctHPs() end) < medStart) then
            require('modules.med'):sit()
        end
    end
    if HUNTERS[r] and Mv().distToCampLoc() > 15 then
        State.returnToCamp, State.chaseAssist = true, false
        Log.info('%s: There are no mobs within %d trying to return to camp.', State.role, c.MaxRadius or 350)
        Mv().doWeMove('FindMobToPull')
    end
    return 0
end

function M:checkRampPets()
    for i = 0, 20 do
        local name = string.format('%s`s_pet0%d', T.myName(), i)
        local sp = T.spawnByName(name)
        if sp then
            Log.info('+++ My rampage pet is up: (%s|%d), HOLDING . . .', name, T.num(function() return sp.ID() end))
            Cast.tickDelay(60000, function() return T.inCombat() or not T.spawnByName(name) end)
        end
    end
end

-- ------------------------------------------------------------- a spot the pet / I can reach near the mob
function M:spotNear(id, radius)
    local sp = T.spawn(id)
    if not sp then return nil end
    local mx, my = T.num(function() return sp.X() end), T.num(function() return sp.Y() end)
    local head = T.num(function() return sp.Heading.Degrees() end) - 10
    local best, bestD = nil, 10000
    local meX, meY = T.num(function() return mq.TLO.Me.X() end), T.num(function() return mq.TLO.Me.Y() end)
    for i = 1, 36 do
        local a = math.rad(head + i * 10)
        local x, y = mx + radius * math.cos(a), my + radius * math.sin(a)
        if T.bool(function() return mq.TLO.Navigation.PathExists(string.format('locyx %d %d', y, x))() end) then
            local d = math.sqrt((x - meX) ^ 2 + (y - meY) ^ 2)
            if d < bestD then best, bestD = { x = x, y = y }, d end
        end
    end
    return best
end

-- ------------------------------------------------------------- PullReset, the pull dance
function M:pullReset()
    mq.cmd('/moveto mdist 10')
    State.pulling, State.pulled = false, false
    State.myTargetId, State.myTargetName = 0, ''
    self.flags.tooClose = false
    if meCombat() then mq.cmd('/attack off') end
    if T.bool(function() return mq.TLO.MoveTo.Moving() end) then mq.cmd('/moveto off') end
    if navActive() then Log.info('PullReset stopping nav') mq.cmd('/nav stop') end
    Timers.clear('pull:waittimer')
    mq.cmd('/squelch /target clear')
end

function M:pullDance()
    local c = self.cfg
    if T.num(function() return mq.TLO.Target.Distance3D() end) <= 80 or Mv().distToCampLoc() < (c.CampRadius or 30) then return end
    local natural = (c.ActNatural or 1) ~= 0 and lower(self.pullType) ~= 'pet'
    if natural then mq.cmd('/keypress forward hold') mq.delay(200) mq.cmd('/keypress forward') end
    local heading = T.num(function() return mq.TLO.Target.HeadingTo.DegreesCCW() end)
    if math.random(2) == 1 then
        heading = heading + math.random(5, 10)
        if natural then mq.cmd('/keypress left hold') mq.delay(400) mq.cmd('/keypress left') end
    else
        heading = heading - math.random(5, 10)
        if natural then mq.cmd('/keypress right hold') mq.delay(400) mq.cmd('/keypress right') end
    end
    mq.cmdf('/face nolook heading %d', heading)
    if natural then
        local k = math.random(2) == 1 and 'back' or 'forward'
        mq.cmdf('/keypress %s hold', k) mq.delay(100) mq.cmdf('/keypress %s', k)
    end
end

-- ------------------------------------------------------------- GrabTheDead
function M:grabTheDead()
    if self.deadMember ~= 0 then return end
    local corpse = mq.TLO.Spawn('group pccorpse')
    local id = T.num(function() return corpse.ID() end)
    if id == 0 then corpse = T.spawnByName(T.myName(), 'pccorpse') id = corpse and T.num(function() return corpse.ID() end) or 0 end
    if id == 0 or T.num(function() return corpse.Distance3D() end) >= 90 then return end
    self.deadMember = id
    mq.cmdf('/squelch /target id %d', id)
    mq.delay(1000, function() return targetId() == id end)
    mq.cmdf('/popup I found %s while pulling. Better grab it.', T.str(function() return mq.TLO.Target.CleanName() end))
    mq.cmd('/corpsedrag')
    self.dragging = true
    mq.delay(1000, function() return T.num(function() return mq.TLO.Target.Distance3D() end) < 10 end)
    if T.num(function() return mq.TLO.Target.Distance3D() end) > 10 then self.deadMember = 0 end
end

-- ------------------------------------------------------------- Pull
local function abortHome(self, flag, reason)
    local mt = State.myTargetId or 0
    if mt > 0 then skip(mt) end
    if reason then Log.pm('pull: %s', reason) end
    if State.returnToCamp then Mv().doWeMove('FindMobToPull ' .. tostring(flag)) end
    self:pullReset()
end

function M:pull(flag)
    local c = self.cfg
    if State.buffMode or State.zombieMode then return end
    local r = role()
    if flag ~= 3 then
        if not PULL_ROLES[r] or not State.pulling or State.dpsPaused or State.getAwayOn then return end
    else Log.info('Forced Pull') end
    if (c.HealerDownHold or 1) ~= 0 and self.hooks.healerDown() then
        if Timers.expired('pull:healerdown') then Timers.set('pull:healerdown', 30000) Log.pm('healer down: holding pulls.') end
        return
    end
    local nav = navOk()
    local autoFireWas = (Combat().cfg.AutoFireOn or 0) ~= 0
    if autoFireWas then Combat().cfg.AutoFireOn = 0 end
    State.pulled = false
    self.flags = { cantHit = false, cantSee = false, tooClose = false, tooFar = false }
    Timers.set('pull:timer', 5000)
    local attempts, stuck = 0, 0
    local pullDist = self.pullRange
    local tempAmmo = T.str(function() return mq.TLO.InvSlot('ammo').Item.Name() end)
    local rangedSwitch, ammoSwitch = false, false
    local isPet = lower(self.pullType) == 'pet'
    local isRanged = self.pullType == 'Ranged'
    local isMelee = lower(self.pullType) == 'melee'
    local beginId = xtSlot(1)
    if flag ~= 3 and r == 'pullerpettank' and (c.PullRoleToggle or 0) ~= 0 and T.num(function() return mq.TLO.Group.Puller.ID() end) ~= T.myId() then
        local mt = T.spawn(State.myTargetId or 0)
        if mt and distToCamp(mt) > (c.CampRadius or 30) then self:togglePullMode(true) end
    end
    local function finish()
        mq.cmd('/moveto mdist 8')
        if rangedSwitch then mq.cmdf('/exchange "%s" ranged', self.origRanged) mq.delay(1000) end
        if ammoSwitch then if T.num(function() return mq.TLO.Cursor.ID() end) > 0 then mq.cmd('/autoinventory') end mq.cmdf('/exchange "%s" ammo', tempAmmo) mq.delay(1000) end
        State.pulling = false
        if autoFireWas then Combat().cfg.AutoFireOn = 1 end
    end
    local function body()
    for _ = 1, 200 do   -- :PullAgain (bounded: the pull timer ends it)
        if (c.GrabDeadGroupMembers or 1) ~= 0 then self:grabTheDead() end
        mq.doevents()
        if State.dpsPaused or State.getAwayOn then return end
        local x1, y1 = math.floor(T.num(function() return mq.TLO.Me.X() end)), math.floor(T.num(function() return mq.TLO.Me.Y() end))
        local mt = State.myTargetId or 0
        local sp = T.spawn(mt)
        -- aggro already: the pull is done
        if haveAggro(beginId) then
            State.pulled = true
            State.myTargetId = T.aggroTargetId() > 0 and T.aggroTargetId() or xtSlot(1)
            local a = T.spawn(State.myTargetId)
            State.myTargetName = a and T.str(function() return a.CleanName() end) or ''
            if navActive() then mq.cmd('/nav stop') end
            if T.bool(function() return mq.TLO.MoveTo.Moving() end) then mq.cmd('/moveto off') end
            break
        end
        if nav and sp and T.num(function() return mq.TLO.Navigation.PathLength(string.format('locxyz %d %d %d', T.num(function() return sp.X() end), T.num(function() return sp.Y() end), T.num(function() return sp.FloorZ() end)))() end) > (c.MaxRadius or 350) then
            abortHome(self, flag, 'the path is longer than MaxRadius')
            return
        end
        if Timers.expired('pull:timer') or Mv().distToCampLoc() > (c.MaxRadius or 350) or (attempts >= 7 and sp and not T.bool(function() return sp.LineOfSight() end) and not HUNTERS[r]) or not sp then
            abortHome(self, flag, 'pull timer ran out or the mob is gone')
            return
        end
        if ((T.aggroTargetId() > 0 and State.chainPull == 0) or (xtSlot(2) > 0 and State.chainPull ~= 0)) and Mv().distToCampLoc() < (c.CampRadius or 30) then
            Log.info('Looks like mobs in camp aborting pull.')
            self:pullReset()
            return
        end
        if isRanged then
            if T.num(function() return mq.TLO.Cursor.ID() end) > 0 then mq.cmd('/autoinventory') end
            if self.origRanged ~= self.pullItem and self.origRanged ~= '' then mq.cmdf('/exchange "%s" ranged', self.pullItem) rangedSwitch = true mq.delay(1000) end
            if tempAmmo ~= '' and tempAmmo ~= self.pullAmmo then mq.cmdf('/exchange "%s" ammo', self.pullAmmo) ammoSwitch = true mq.delay(1000) end
        end
        -- readiness (bounded by the pull timer)
        if State.chainPull == 0 and T.aggroTargetId() == 0 then
            local ready = true
            if not isMelee and not isPet and not isRanged then ready = Spell.ready(self.pullType) or T.bool(function() return mq.TLO.Me.ItemReady(self.pullType)() end)
            elseif isRanged then ready = T.bool(function() return mq.TLO.Me.RangedReady() end) end
            if not ready then
                Cast.tickDelay(5000, function() return Spell.ready(self.pullType) or T.bool(function() return mq.TLO.Me.RangedReady() end) or T.aggroTargetId() > 0 end)
                if not (Spell.ready(self.pullType) or T.bool(function() return mq.TLO.Me.RangedReady() end)) then abortHome(self, flag, self.pullType .. ' is not ready') return end
            end
        end
        if T.groupCount() == 1 and lower(T.str(function() return mq.TLO.Group.Puller.Name() end)) ~= lower(T.myName()) and r == 'puller' then
            local ma = maSpawn()
            if ma and T.str(function() return ma.Type() end) == 'Mercenary' then mq.cmdf('/grouproles set "%s" 3', T.myName()) mq.delay(1000) end
        end
        -- the walk out
        local dist = T.num(function() return sp.Distance() end)
        local los = T.bool(function() return sp.LineOfSight() end)
        if (dist > pullDist or not los) and distToCamp(sp) < (c.MaxRadius or 350) then
            if nav and not HUNTERS[r] then
                pullDist = self.pullRange
                if not T.bool(function() return mq.TLO.Navigation.PathExists('id ' .. mt)() end) then
                    local spot = self:spotNear(mt, isPet and 160 or 50)
                    if spot then
                        mq.cmdf('/squelch /nav locyx %d %d', spot.y, spot.x)
                        Log.info('Ok Cool, we actually CAN pull it I found a nice loc at %d %d', spot.y, spot.x)
                        mq.delay(1000, function() return navActive() end)
                        Cast.tickDelay(isPet and 20000 or 40000, function() return not navActive() end)
                    else
                        Log.info("Can't Pull %s (%d) No Path exist.", State.myTargetName, mt)
                        skip(mt)
                        self:pullReset()
                        return
                    end
                elseif isPet and dist > 150 then
                    mq.cmdf('/nav id %d distance=150', mt)
                    pullDist = 150
                elseif not isPet then
                    mq.cmdf('/nav id %d distance=10', mt)
                end
                Timers.set('pull:heading', 2000)
                for _ = 1, 600 do   -- :DistanceCheck
                    mq.delay(200)
                    if Timers.expired('pull:timer') then break end
                    if T.num(function() return sp.Speed() end) > 25 and Timers.expired('pull:heading') then mq.cmdf('/nav id %d', mt) Timers.set('pull:heading', 2000) end
                    if haveAggro(beginId) then break end
                    if Mv().distToCampLoc() > (c.MaxRadius or 350) then
                        if State.returnToCamp then Mv().doWeMove('FindMobToPull 3') end
                        if Mv().distToCampLoc() < (c.CampRadius or 30) then self:pullReset() return end
                    end
                    if not ((T.num(function() return sp.Distance() end) > pullDist or not T.bool(function() return sp.LineOfSight() end)) and not haveAggro(beginId)) then break end
                    if navActive() then Timers.set('pull:timer', math.max(Timers.left('pull:timer'), 5000)) end
                end
                if navActive() and T.bool(function() return sp.LineOfSight() end) and T.num(function() return sp.Distance() end) < pullDist - 3 then mq.cmd('/nav stop') end
            elseif los then
                mq.cmdf('/moveto id %d mdist %d', mt, math.floor(pullDist))
                mq.delay(300)
            else
                mq.cmdf('/nav id %d distance=10', mt)
                Cast.tickDelay(5000, function() return T.bool(function() return sp.LineOfSight() end) or haveAggro(beginId) or Timers.expired('pull:timer') end)
                if navActive() and T.bool(function() return sp.LineOfSight() end) and T.num(function() return sp.Distance() end) < pullDist then mq.cmd('/nav stop') end
            end
        end
        self.flags.cantSee = false
        mq.doevents()
        if Mv().distToCampLoc() > (c.MaxRadius or 350) then goto again end
        if (State.dpsPaused and flag ~= 3) or State.getAwayOn then return end
        if navActive() or T.bool(function() return mq.TLO.MoveTo.Moving() end) or (T.num(function() return sp.Speed() end) > 25 and T.num(function() return sp.Distance() end) > self.pullRange) then Timers.set('pull:timer', Timers.left('pull:timer') + 5000) end
        attempts = attempts + 1
        if attempts >= 7 then
            if T.num(function() return sp.Distance() end) <= pullDist and not T.bool(function() return sp.LineOfSight() end) then pullDist = pullDist * 0.6 end
            goto again
        elseif attempts >= 3 and T.num(function() return sp.Speed() end) > 25 then pullDist = pullDist * 0.6 goto again end
        mq.delay(200)
        if math.floor(T.num(function() return mq.TLO.Me.X() end)) == x1 and math.floor(T.num(function() return mq.TLO.Me.Y() end)) == y1 then
            stuck = stuck + 1
            if stuck >= 2 then
                if State.iAmDead or T.bool(function() return mq.TLO.Me.Hovering() end) then mq.cmd('/moveto off') mq.cmd('/nav stop') return end
                Mv().stuckEscape()
            end
            if stuck >= 7 and not haveAggro(beginId) then
                Log.info('I am stuck aborting pull')
                mq.cmd('/moveto off') mq.cmd('/nav stop')
                abortHome(self, flag, 'stuck')
                return
            end
        end
        dist = T.num(function() return sp.Distance() end)
        los = T.bool(function() return sp.LineOfSight() end)
        if (dist > self.pullRange or (not los and not isPet)) and not haveAggro(beginId) then goto again end
        if not los and not isPet and not HUNTERS[r] and Timers.running('pull:timer') then pullDist = pullDist * 0.8 goto again end
        if haveAggro(beginId) then goto again end
        -- the pull itself
        if sp and dist < self.pullRange and not haveAggro(beginId) then
            mq.cmd('/moveto off')
            if navActive() then mq.cmd('/nav stop') end
            mq.cmdf('/squelch /target id %d', mt)
            mq.delay(1000, function() return targetId() == mt end)
            Buffcheck.targetBuffWait()
            local ok, why = self.hooks.validateTarget(mt)
            if ok then ok, why = self:validatePull(mt, flag) end
            if ok and targetId() == mt then
                local tot = mq.TLO.Me.TargetOfTarget
                local totId = T.num(function() return tot.ID() end)
                local tt = T.str(function() return tot.Type() end)
                if totId > 0 and totId ~= T.myId() and not T.inGroup(totId) and (tt == 'PC' or tt == 'Pet') then
                    Log.info('Crap %s has %s engaged, not gonna pull it.', T.str(function() return tot.CleanName() end), State.myTargetName)
                    ok, why = false, 'Engaged'
                end
            end
            if not condTrue(c.PullCond) then
                Log.info('Pull Condition is False %s. Setting ValidTarget to 0', c.PullCond)
                if State.returnToCamp then Mv().doWeMove('FindMobToPull 6') end
                if Mv().distToCampLoc() < (c.CampRadius or 30) then self:pullReset() end
                return
            end
            if not ok then
                skip(mt)
                mq.cmd('/squelch /target clear')
                Log.info('Aborting Pull! Target invalid now! Reason:%s', tostring(why))
                if State.returnToCamp then Mv().doWeMove('FindMobToPull 6') end
                if Mv().distToCampLoc() < (c.CampRadius or 30) then self:pullReset() end
                return
            end
            if isMelee or self.flags.tooClose then
                if not HUNTERS[r] then
                    for _ = 1, 50 do
                        mq.cmdf('/moveto id %d mdist 5', mt)
                        if targetId() > 0 then mq.cmd('/face nolook') end
                        mq.cmd('/look 0')
                        mq.cmd('/attack on')
                        if (c.PullMeleeStick or 0) ~= 0 and T.aggroTargetId() == 0 then mq.cmdf('/stick id %d 30%%', mt) end
                        mq.delay(500)
                        if T.aggroTargetId() > 0 or T.num(function() return mq.TLO.Target.PctHPs() end) < 100 or Timers.expired('pull:timer') then break end
                    end
                    if r == 'puller' or r == 'pullertank' or r == 'pullerpettank' or r == 'hunterpettank' then
                        mq.cmd('/attack off')
                        if T.bool(function() return mq.TLO.Stick.Active() end) then mq.cmd('/stick off') end
                        mq.cmd('/squelch /target clear')
                        mq.delay(3000, function() return not meCombat() end)
                    end
                end
                State.pulled = true
                self.flags.tooClose = false
            elseif isRanged then
                for _ = 1, 50 do   -- :RangedAgain
                    mq.doevents()
                    if self.flags.tooClose then pullDist = 15 goto again end
                    if State.dpsPaused or State.getAwayOn then return end
                    if pulledNow() then State.pulled = true break end
                    if self.flags.cantHit then self.flags.cantHit = false pullDist = pullDist * 0.8 goto again end
                    if self.flags.cantSee then mq.cmd('/squelch /face nolook') mq.delay(500) self.flags.cantSee = false end
                    if meCombat() then mq.cmd('/attack off') mq.delay(2000, function() return not meCombat() end) end
                    if T.bool(function() return mq.TLO.Stick.Active() end) then mq.cmd('/stick off') end
                    mq.cmd('/squelch /face nolook')
                    mq.cmd('/look 0')
                    mq.delay(2000, function() return T.str(function() return mq.TLO.Me.Heading.ShortName() end) == T.str(function() return mq.TLO.Target.HeadingTo() end) end)
                    if targetId() == mt then mq.cmd('/range') end
                    if Mv().distToCampLoc() > (c.CampRadius or 30) then mq.delay(500) mq.cmdf('/squelch /face nolook loc %d,%d', State.campY, State.campX) end
                    Cast.tickDelay(math.floor(1 + T.num(function() return mq.TLO.Target.Distance() end) / 50) * 1000, function() return pulledNow() end)
                    if not (Timers.running('pull:timer') and not self.flags.tooFar and not pulledNow()) then break end
                end
                if pulledNow() then State.pulled = true end
            elseif isPet then
                Log.info('Pull: Pet should pull %s (%d)', State.myTargetName, mt)
                if T.str(function() return mq.TLO.Me.Pet.Stance() end):upper() ~= 'FOLLOW' then mq.cmd('/pet follow') end
                Timers.set('pull:pet', 45000)
                self.hooks.petAttackSafe(mt)
                for _ = 1, 200 do
                    mq.doevents()
                    if State.dpsPaused or State.getAwayOn then return end
                    if not pulledNow() then mq.delay(1000, function() return pulledNow() end) end
                    local alive = T.spawn(mt) and T.str(function() return T.spawn(mt).Type() end) ~= 'Corpse'
                    if not alive or pulledNow() then break end
                    if Timers.expired('pull:pet') then
                        Log.info('Timer expired we are obviously in a spot where pet cannot attack the target for some reason, lets fix that.')
                        local spot = self:spotNear(mt, 100)
                        if not spot then Log.info("Can't Pull with pet even because I can't get closer to %s No Path exist", State.myTargetName) return end
                        mq.cmdf('/squelch /nav locyx %d %d', spot.y, spot.x)
                        mq.delay(1000, function() return navActive() end)
                        Cast.tickDelay(20000, function() return not navActive() end)
                        self.hooks.petAttackSafe(mt)
                        Timers.set('pull:pet', 45000)
                    end
                end
                if pulledNow() then
                    State.pulled = true
                    local hold = require('modules.pet').petHold
                    if hold ~= '' then mq.cmdf('/pet %s on', hold) end
                    mq.cmd('/pet back off')
                end
            else
                -- a cast pull, with the calm first
                mq.delay(1000, function() return not T.bool(function() return mq.TLO.Me.Moving() end) or haveAggro(beginId) end)
                if targetId() > 0 then mq.cmd('/face nolook') end
                mq.cmd('/look 0')
                if haveAggro(beginId) then goto again end
                if T.num(function() return mq.TLO.SpawnCount('npc los id ' .. targetId())() end) == 0 then pullDist = pullDist * 0.8 goto again end
                if not T.bool(function() return mq.TLO.Me.Moving() end) then
                    if (c.UseCalm or 0) ~= 0 then self:calm(mt) end
                    local res = Cast.cast(self.pullType, targetId(), 'Pull')
                    if res == 'CAST_SUCCESS' or haveAggro(beginId) then State.pulled = true end
                end
            end
            if r == 'pullerpettank' and (c.PullRoleToggle or 0) ~= 0 and T.num(function() return mq.TLO.Group.Puller.ID() end) == T.myId() then self:togglePullMode(false) end
        elseif haveAggro(beginId) then State.pulled = true end
        if State.pulled then break end
        ::again::
    end
    return true
    end
    local done = body()
    finish()   -- on every exit: AutoFire back, the ranged / ammo swap undone, pulling off
    if not done then return end
    if HUNTERS[r] then
        -- the hunter fights where it stands: the combat module takes the target from here
        if (State.myTargetId or 0) > 0 then
            if isMelee then mq.cmdf('/moveto id %d mdist 5', State.myTargetId) mq.cmd('/face nolook') end
            Log.info('turning on attack for hunter')
            mq.cmd('/attack on')
        end
        State.pulled = false
        return
    end
    if State.returnToCamp and State.pulled then
        self:waitForMob()
        State.pulled = false
    end
end

function M:calm(mt)
    local c = self.cfg
    local old = targetId()
    local x, y = T.num(function() return mq.TLO.Target.X() end), T.num(function() return mq.TLO.Target.Y() end)
    local q = string.format('npc loc %d %d radius %d', x, y, c.CalmRadius or 50)
    if T.num(function() return mq.TLO.SpawnCount(q)() end) <= 1 then return end
    local calmId = T.num(function() return mq.TLO.NearestSpawn(2, q).ID() end)
    if calmId == 0 then return end
    local range = Spell.facts(c.CalmWith).range
    Cast.tickDelay(10000, function() return T.num(function() return T.spawn(calmId) and T.spawn(calmId).Distance3D() or 0 end) <= range end)
    Buffcheck.cacheBuffs(calmId)
    if not Buffcheck.cachedHas(calmId, c.CalmWith) then
        Log.info('time to calm down the situation... casting %s on %s', c.CalmWith, T.str(function() return T.spawn(calmId).CleanName() end))
        Cast.cast(c.CalmWith, calmId, 'Calm')
    end
    mq.cmdf('/squelch /target id %d', old)
    mq.delay(2000, function() return targetId() == old end)
end

-- ------------------------------------------------------------- WaitForMob
function M:waitForMob()
    local c = self.cfg
    local r = role()
    if HUNTERS[r] or State.dpsPaused or State.getAwayOn then return end
    Timers.set('pull:waittimer', 45000)
    Timers.set('pull:waitgrace', 1000)   -- a cast pull lands on XTarget a beat after the cast
    if not State.pulled then return end
    Mv().doWeMove('WaitForMob')
    if (c.DismountDuringFights or 0) == 1 and T.num(function() return mq.TLO.Me.Mount.ID() end) > 0 then mq.cmd('/dismount') end
    if State.chainPull ~= 0 then self.lastMobPullId = targetId() end
    local ranged = T.str(function() return mq.TLO.InvSlot('ranged').Item.Name() end)
    if self.origRanged ~= '' and ranged ~= self.origRanged then mq.cmdf('/exchange "%s" ranged', self.origRanged) end
    self.deadMember = 0
    if self.dragging then mq.cmd('/corpsedrop') mq.delay(100) self.dragging = false end
    local danced = false
    local mt = State.myTargetId or 0
    local md = c.MeleeDistance or 30
    for _ = 1, 1000 do
        if not danced and T.num(function() return mq.TLO.SpawnCount('npc radius 100')() end) == 0 and (c.FaceMobOn or 1) ~= 0 and targetId() > 0 then self:pullDance() danced = true end
        if Mv().distToCampLoc() > (c.ReturnToCampAccuracy or 10) and T.num(function() return mq.TLO.Navigation.Velocity() end) == 0 then
            if navOk() then mq.cmdf('/nav locxyz %d %d %d', State.campX, State.campY, State.campZ) else mq.cmdf('/moveto loc %d %d mdist 10', State.campY, State.campX) end
        end
        Cast.hooks.ohShit('WaitForMob')
        mq.doevents()
        if State.getAwayOn then return end
        Combat():mobRadar(c.CampRadius or 30)
        if State.mobCount >= 2 and State.chainPull == 0 then self:pullReset() return end
        if (T.aggroTargetId() == 0 and State.chainPull == 0 and Timers.expired('pull:waitgrace')) or Timers.expired('pull:waittimer') then
            if mt > 0 and T.spawn(mt) and T.str(function() return T.spawn(mt).Type() end) == 'NPC' then skip(mt) end
            self:pullReset()
            return
        end
        if (c.FaceMobOn or 1) ~= 0 and mt > 0 then mq.cmdf('/face %s id %d', (c.ActNatural or 1) ~= 0 and 'nolook' or 'fast', mt) end
        local sp = T.spawn(mt)
        local ma = maSpawn()
        local wait = false
        if r == 'pullerpettank' then
            local pet = mq.TLO.Me.Pet
            if T.num(function() return pet.ID() end) > 0 and distToCamp(pet) > (c.CampRadius or 30) and T.num(function() return pet.Distance() end) > 20 then mq.cmd('/pet back off') mq.delay(100) mq.cmd('/pet follow') end
            if sp and distToCamp(sp) >= (State.petAttackRange or 115) then wait = true else self.hooks.combatPet(mt) end
        elseif r == 'pullertank' then
            if Timers.running('pull:waittimer') and sp and distToCamp(sp) > md then wait = true end
        elseif r == 'puller' and State.chainPull == 0 then
            if sp and ma and ((distToCamp(sp) >= (c.CampRadius or 30) and dist2(sp, ma) > 20) or (State.chaseAssist and distToCamp(ma) >= (c.CampRadius or 30) and dist2(sp, ma) > 20)) then wait = true end
        elseif r == 'puller' then
            if State.mobCount >= 2 or mt == 0 or (xtSlot(1) > 0 and xtSlot(2) > 0) then self:pullReset() return end
            if sp and ma and dist2(sp, ma) > 20 and targetId() == mt and T.num(function() return mq.TLO.Me.TargetOfTarget.ID() end) == T.myId() then wait = true end
        end
        if not wait then break end
        mq.delay(200)
    end
    if T.groupCount() == 1 and r == 'puller' and lower(T.str(function() return mq.TLO.Group.Puller.Name() end)) == lower(T.myName()) then
        local ma = maSpawn()
        if ma and T.str(function() return ma.Type() end) == 'Mercenary' and T.spawn(mt) and T.num(function() return T.spawn(mt).Distance() end) <= md then mq.cmdf('/grouproles unset "%s" 3', T.myName()) end
    end
    if (mt > 0 and T.aggroTargetId() == 0 and State.chainPull == 0) or (xtSlot(2) == 0 and xtSlot(1) ~= mt and State.chainPull ~= 0) then self:pullReset() end
    Timers.clear('pull:waittimer')
end

-- ------------------------------------------------------------- TogglePullMode, the chain probe, mass pull
function M:togglePullMode(on)
    if lower(T.str(function() return mq.TLO.Group.Leader() end)) ~= lower(T.myName()) or T.num(function() return mq.TLO.SpawnCount('group mercenary')() end) == 0 then return end
    if on then
        if T.num(function() return mq.TLO.Group.Puller.ID() end) ~= T.myId() then mq.cmdf('/grouproles set %s 3', T.myName()) end
        mq.delay(1000, function() return T.num(function() return mq.TLO.Group.Puller.ID() end) == T.myId() end)
        if T.num(function() return mq.TLO.Group.Puller.ID() end) == T.myId() then Log.info('+ You have been set be group puller.') end
    else
        if T.num(function() return mq.TLO.Group.Puller.ID() end) == T.myId() then mq.cmdf('/grouproles unset %s 3', T.myName()) end
        mq.delay(1000, function() return T.num(function() return mq.TLO.Group.Puller.ID() end) ~= T.myId() end)
        if T.num(function() return mq.TLO.Group.Puller.ID() end) ~= T.myId() then Log.info('+ You are no longer group puller.') end
    end
end

--- The chain-pull probe from the fight: the next mob is scheduled when the current one is under ChainPullHP.
function M:chainProbe(mobId)
    local c = self.cfg
    if role() ~= 'puller' or State.chainPull == 0 then return false end
    local ma = maSpawn()
    if ma and distToCamp(ma) > 75 then
        if Timers.expired('pull:tankfar') then Timers.set('pull:tankfar', 30000) Comms.say('r', 'Holding Pulls. Tank to far from camp.') end
        return false
    end
    local sp = T.spawn(mobId)
    if State.chainPullHold ~= 0 or State.mobCount >= 2 or xtSlot(2) > 0 or (sp and T.bool(function() return sp.Named() end)) then return false end
    if not sp or T.num(function() return sp.PctHPs() end) >= (c.ChainPullHP or 90) then return false end
    if Timers.running('pull:chainscan') then return false end   -- the scan (nav path queries) once a second, not every pass
    Timers.set('pull:chainscan', 1000)
    local count = self:findMobToPull(0)
    local next_ = self.chainTemp > 0 and T.spawn(self.chainTemp) or nil
    if count > 0 and next_ and T.num(function() return next_.Distance() end) < self.pullRange + 400
        and lower(T.str(function() return mq.TLO.Me.TargetOfTarget.CleanName() end)) ~= lower(T.myName()) and T.num(function() return mq.TLO.Me.PctAggro() end) < 50 then
        if T.bool(function() return mq.TLO.Stick.Active() end) then mq.cmd('/squelch /stick off') end
        mq.cmd('/squelch /attack off')
        State.chainPull = 2
        State.myTargetId, State.myTargetName = 0, ''
        State.attacking = false
        return true
    end
    return false
end

function M:chainPauseTick()
    local c = self.cfg
    if State.chainPull == 0 then return end
    local a, b = tostring(c.ChainPullPause or '30|2'):match('^(%d+)|(%d+)$')
    a, b = tonumber(a) or 0, tonumber(b) or 0
    if a == 0 then return end
    -- the clock (re)starts whenever the second timer runs out while not on hold: each pull refreshes it, so a pause
    -- comes after `a` minutes of pulling and the clock resets after `b` idle minutes
    if State.chainPullHold == 0 and Timers.expired('pull:chain2') then Timers.set('pull:chain1', a * 60000) Timers.set('pull:chain2', b * 60000) end
    if Timers.expired('pull:chain1') then
        if State.chainPullHold == 0 then Log.info('Pausing Pulls for %d Minutes.', b) State.chainPullHold = 2 Timers.set('pull:chain1', b * 60000)
        elseif State.chainPullHold == 2 then Log.info('Resetting Pull Timer for %d Minutes.', a) State.chainPullHold = 0 Timers.set('pull:chain1', a * 60000) Timers.set('pull:chain2', b * 60000) end
    end
end

function M:doMassPull(spell, num, minLevel, maxLevel, maxDist)
    local q = string.format('range %d %d radius %d targetable npc', minLevel, maxLevel, maxDist)
    local n = T.num(function() return mq.TLO.SpawnCount(q)() end)
    if n == 0 then return end
    Log.info('%d mobs here we can pull', n)
    for i = 1, num do
        local sp = mq.TLO.NearestSpawn(i, q)
        local id = T.num(function() return sp.ID() end)
        if id > 0 then
            Log.info('[%d] %s %d %dft away', i, T.str(function() return sp.CleanName() end), T.num(function() return sp.Level() end), T.num(function() return sp.Distance3D() end))
            mq.cmdf('/nav id %d distance=40', id)
            mq.delay(500, function() return navActive() end)
            Cast.tickDelay(40000, function() return not navActive() end)
            mq.delay(500, function() return not T.bool(function() return mq.TLO.Me.Moving() end) end)
            mq.cmdf('/squelch /target id %d', id)
            mq.delay(1000, function() return targetId() == id end)
            Cast.cast(spell, id, 'Pull')
            mq.delay(1000)
        end
    end
    Timers.set('pull:massoverall', 300000)
    for _ = 1, 500 do
        mq.doevents()
        if Timers.expired('pull:massoverall') then Log.info('MassPull: stragglers took too long - continuing home.') break end
        mq.cmdf('/nav locxy %d %d', State.campX, State.campY)
        mq.delay(500, function() return navActive() end)
        local straggler = false
        for i = 1, T.num(function() return mq.TLO.Me.XTarget() end) do
            local xt = mq.TLO.Me.XTarget(i)
            if T.str(function() return xt.Type() end) == 'NPC' and T.num(function() return xt.Distance3D() end) > 180 then
                local xid = T.num(function() return xt.ID() end)
                local xs = T.spawn(xid)
                if xs and T.num(function() return xs.Rooted.ID() end) == 0 then
                    Log.info('%s is lagging behind, waiting for it to catch up', T.str(function() return xs.CleanName() end))
                    mq.cmd('/nav stop')
                    Cast.tickDelay(5000, function() return T.num(function() return xt.Distance3D() end) < 100 end)
                    straggler = true
                    break
                end
            end
        end
        if not straggler and not (navActive() and Mv().distToCampLoc() > 5) then break end
        mq.delay(1000)
    end
    Log.info('back at camp after masspull')
end

-- ------------------------------------------------------------- module hooks
function M:Init()
    local Combat = Combat()
    Combat.hooks.chainProbe = function(id) return M:chainProbe(id) end
    local HA = require('modules.healeraggro')
    self.hooks.healerDown = HA.healerDown
    self.hooks.anyMemberDown = HA.anyMemberDown
    self.hooks.validateTarget = function(id) return Combat:validateTarget(id) end
    local Pet = require('modules.pet')
    self.hooks.isProtected = Pet.isProtected
    self.hooks.petAttackSafe = Pet.attackSafe
    self.hooks.combatPet = function(id) Pet:combatPet(id) end
    Combat.addResetHook('pull', function() if role():find('pull', 1, true) then M:pullReset() end end)
    mq.event('ma_pull_canthit', "You can't hit them from here.", function() if State.pulling then M.flags.cantHit = true end end)
    mq.event('ma_pull_cantsee', 'You cannot see your target.', function() if State.pulling then M.flags.cantSee = true end end)
    mq.event('ma_pull_tooclose', '#*#ranged weapon!', function() if State.pulling then Log.info('Mob Too Close for %s... Switching to Melee.', M.pullType) M.flags.tooClose = true end end)
    mq.event('ma_pull_toofar', 'Your target is #*#, get closer!', function() if State.pulling and (role() == 'puller' or role() == 'pullertank' or role() == 'pullerpettank') then M.flags.tooFar = true end end)
end

function M:Shutdown()
    for _, e in ipairs({ 'ma_pull_canthit', 'ma_pull_cantsee', 'ma_pull_tooclose', 'ma_pull_toofar' }) do pcall(mq.unevent, e) end
end

function M:GiveTime(ctx)
    self:chainPauseTick()
    if self.massPull and not ctx.inCombat then local m = self.massPull self.massPull = nil self:doMassPull(m.spell, m.num, m.min, m.max, m.dist) end
    if State.getAwayOn or State.manualOn or State.killOrderOn then return end
    if self.pullOnce then self.pullOnce = false self:findMobToPull(3) return end
    if not PULL_ROLES[role()] then return end
    if Timers.running('pull:wait') then return end
    if HUNTERS[role()] and not ctx.inCombat and T.aggroTargetId() == 0 and Mv().distToCampLoc() > (self.cfg.MaxRadius or 350) * 0.95 then
        Log.info('%s: Reached edge of %d hunting radius. Trying to return to camp.', State.role, self.cfg.MaxRadius or 350)
        State.returnToCamp = true
        Mv().doWeMove('FindMobToPull 7')
    end
    self:findMobToPull(1)
end

function M:OnZone()
    self:pullReset()
    Timers.clearPrefix('pull:skip:')
end

M.Binds = {
    ['/pull'] = function(self) Log.info('Time for a onetime pull!') self.pullOnce = true end,
    ['/masspull'] = function(self, spell, num, minLevel, maxLevel, maxDist)
        if not spell or spell == '' then Log.info('/masspull <spell> <num mobs> <min level> <max level> <max dist>') return end
        self.massPull = { spell = spell, num = tonumber(num) or 1, min = tonumber(minLevel) or 1, max = tonumber(maxLevel) or 200, dist = tonumber(maxDist) or 200 }
    end,
    ['/setpullarc'] = function(self, width, dir)
        width = tonumber(width) or 0
        if width == 0 then
            if (tonumber(self.cfg.PullArcWidth) or 0) > 0 then Log.info('Turning off Directional Pulling.') end
            self.cfg.PullArcWidth = '0'
            return
        end
        self.cfg.PullArcWidth = tostring(width)
        local heading
        if not dir or dir == '' then heading = T.num(function() return mq.TLO.Me.Heading.Degrees() end)
        elseif tonumber(dir) and tonumber(dir) > 0 then heading = tonumber(dir)
        else
            local map = { n = 0, ne = 45, e = 90, se = 135, s = 180, sw = 225, w = 270, nw = 315 }
            heading = map[lower(dir)]
            if not heading then Log.info('Invalid Direction. Turning off Directional Pulling.') self.cfg.PullArcWidth = '0' return end
        end
        self:setPullAngles(heading, width, false)
    end,
    ['/maxradius'] = function(self, arg) local v = tonumber(arg) if v then self.cfg.MaxRadius = v Config.set('Pull', 'MaxRadius', v) State.roleDefaults = State.roleDefaults or {} State.roleDefaults.campRadiusExceed = v + 200 Log.info('MaxRadius %d', v) end end,
    ['/maxzrange'] = function(self, arg) local v = tonumber(arg) if v then self.cfg.MaxZRange = v Config.set('Pull', 'MaxZRange', v) Log.info('MaxZRange %d', v) end end,
}

return M
