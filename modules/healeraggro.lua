-- modules/healeraggro.lua: the healer-protection switch. The healer side (HealerHitCheck from the GotHit
-- lines, HealerAggroCheck from XTarget) broadcasts HEALERAGGRO-> <mob> <- ID:<id>; the tank side
-- (Event_HealerAggro, HealerAggroSwitch, HealerAggroBurst) spends the [HealerAggro] tools on that mob one per
-- HealerAggroDelay, temp-targeted or with a full switch. Also FreshAddCheck (the fresh-add heal hold),
-- CheckHealer / HealerDown, the feign machinery (the aggro-off hold, FeignStandOK, the stand on expiry)
-- and InvulnSafeToDrop, with the same [HealerAggro] keys as the macro.
local mq = require('mq')
local T = require('core.tlo')
local Config = require('core.config')
local Timers = require('core.timers')
local Cast = require('core.cast')
local Comms = require('core.comms')
local Log = require('core.log')
local Cond = require('core.cond')
local State = require('core.state')

local M = { name = 'healeraggro' }

M.Settings = {
    scalars = {
        { section = 'HealerAggro', key = 'HealerAggroOn', type = 'int', default = 1 },
        { section = 'HealerAggro', key = 'HealerAggroCOn', type = 'int', default = 0 },
        { section = 'HealerAggro', key = 'HealerAggroDelay', type = 'int', default = 3 },
        { section = 'HealerAggro', key = 'HealerAggroClasses', type = 'string', default = 'CLR,DRU,SHM', rank = false },
        { section = 'HealerAggro', key = 'HealerAggroSwitchTarget', type = 'int', default = 0 },
        { section = 'HealerAggro', key = 'HealerAggroNoDamage', type = 'int', default = 1 },
        { section = 'HealerAggro', key = 'HealerEscape', type = 'string', default = 'NULL' },
        { section = 'HealerAggro', key = 'HealerEscapeHold', type = 'int', default = 5 },
        { section = 'HealerAggro', key = 'FeignStandRadius', type = 'int', default = 40 },
        { section = 'HealerAggro', key = 'HealerEscapeHP', type = 'int', default = 100 },
        { section = 'Heals', key = 'FreshAddHoldSec', type = 'int', default = 6 },
        { section = 'Heals', key = 'FreshAddRange', type = 'int', default = 60 },
        { section = 'General', key = 'CampRadius', type = 'int', default = 30 },
        { section = 'General', key = 'MobZRadius', type = 'int', default = 50 },
        { section = 'Melee', key = 'MeleeDistance', type = 'int', default = 30 },
    },
    arrays = {
        { section = 'HealerAggro', name = 'HealerAggro', size = { key = 'HealerAggroSize', default = 5 }, cond = 'HealerAggroCond' },
    },
}
M.cfg = {}
M.tools = {}
M.aggroId = 0          -- the mob the healer reported (HealerAggroID)
M.mezzedAddsNear = 0
M.freshSeen = {}
M.lastPM = 0
M.hooks = { ccHeldByOther = function(id) return nil end }   -- mez (step 5)

local MEZ_ANIM = { [26] = true, [32] = true, [71] = true, [72] = true, [17] = true, [111] = true, [129] = true }
local TANK_ROLES = { tank = true, pullertank = true, pettank = true, pullerpettank = true }
local function lower(s) return tostring(s or ''):lower() end
local function role() return lower(State.role) end
local function iAmMA() return State.mainAssist ~= '' and lower(State.mainAssist) == lower(T.myName()) end
local function healerClass(cls)
    cls = cls or T.myClass()
    for c in tostring(M.cfg.HealerAggroClasses or ''):gmatch('[^,]+') do if lower(c):gsub('%s+', '') == lower(cls) then return true end end
    return false
end
local function targetId() return T.num(function() return mq.TLO.Target.ID() end) end
local function tankSpawn()
    if State.healTank == '' then return nil end
    return T.spawnByName(State.healTank, lower(State.healTankType ~= '' and State.healTankType or 'pc'))
end
local function toolReady(name)
    return T.bool(function() return mq.TLO.Me.SpellReady(name)() end) or T.bool(function() return mq.TLO.Me.AbilityReady(name)() end)
        or T.bool(function() return mq.TLO.Me.AltAbilityReady(name)() end) or T.bool(function() return mq.TLO.Me.ItemReady('=' .. name)() end)
        or (T.bool(function() return mq.TLO.Me.CombatAbilityReady(name)() end) and T.num(function() return mq.TLO.Me.ActiveDisc.ID() end) == 0)
end

function M:LoadSettings()
    local c = Config.load(self.Settings)
    self.cfg = c
    self.tools = {}
    for i, raw in ipairs(c.HealerAggro or {}) do
        local name, target = tostring(raw):match('^([^|]*)|?([^|]*)')
        name = (name or ''):gsub('^%s+', ''):gsub('%s+$', '')
        if name ~= '' and name:upper() ~= 'NULL' then
            self.tools[#self.tools + 1] = { name = name, target = lower((target or ''):gsub('%s+', '')), cond = c.HealerAggroCond and c.HealerAggroCond[i] or 'TRUE' }
        end
    end
end

-- ------------------------------------------------------------- the healer side
local function report(sp)
    Comms.say('r', 'HEALERAGGRO-> %s <- ID:%d', T.str(function() return sp.CleanName() end), T.num(function() return sp.ID() end))
    Timers.set('ha:send', 2000)
end

--- HealerHitCheck: a melee line hit me (the combat module relays its GotHit events here).
function M:hitCheck(attacker)
    local c = self.cfg
    if (c.HealerAggroOn or 0) == 0 or not State.healsOn or Timers.running('ha:send') or T.bool(function() return mq.TLO.Me.Hovering() end) then return end
    if not healerClass() then return end
    local sp = mq.TLO.NearestSpawn('npc "' .. tostring(attacker) .. '"')
    local id = T.num(function() return sp.ID() end)
    if id == 0 or T.num(function() return sp.Distance() end) > 30 then return end
    Log.pm('healer hit: %s (%d) pctaggro %s haters %d', T.str(function() return sp.CleanName() end), id, tostring(T.num(function() return sp.PctAggro() end)), T.num(function() return mq.TLO.Me.XTarget() end))
    report(sp)
    local esc = c.HealerEscape or 'NULL'
    if esc ~= '' and esc:upper() ~= 'NULL' and Timers.expired('ha:escape') and not T.bool(function() return mq.TLO.Me.Feigning() end)
        and T.num(function() return mq.TLO.Me.PctHPs() end) <= (c.HealerEscapeHP or 100) and toolReady(esc) then
        Log.pm('healer escape: %s - %s is on me at %d%%, holding %ds', esc, T.str(function() return sp.CleanName() end), T.num(function() return mq.TLO.Me.PctHPs() end), c.HealerEscapeHold or 5)
        if T.num(function() return mq.TLO.Me.Casting.ID() end) > 0 then mq.cmd('/stopcast') end
        Cast.cast(esc, T.myId(), 'OhShitStuff', { skipOhShit = true })
        Timers.set('ha:escape', 30000)
        if T.bool(function() return mq.TLO.Me.Feigning() end) then Timers.set('combat:aggrooff', (c.HealerEscapeHold or 5) * 1000) end
    end
end

--- HealerAggroCheck: a hater on XTarget with 100% aggro on me (once per 2 s).
function M:aggroCheck()
    local c = self.cfg
    if (c.HealerAggroOn or 0) == 0 or not State.healsOn or not healerClass() then return end
    if Timers.running('ha:send') or T.hostiles() == 0 or T.bool(function() return mq.TLO.Me.Hovering() end) then return end
    for i = 1, 13 do
        local xt = mq.TLO.Me.XTarget(i)
        local id = T.num(function() return xt.ID() end)
        if id > 0 and T.str(function() return xt.TargetType() end) == 'Auto Hater' and T.num(function() return xt.PctAggro() end) >= 100 then
            local sp = T.spawn(id)
            if sp and T.str(function() return sp.Type() end) == 'NPC' and T.num(function() return sp.Distance() end) < 60 then report(sp) return end
        end
    end
end

--- The aggro-off hold for a healer class feigning after an [Aggro] drop (the combat module asks).
function M.aggroOffMs()
    if T.bool(function() return mq.TLO.Me.Feigning() end) and healerClass() then return (M.cfg.HealerEscapeHold or 5) * 1000 end
    return 2000
end

-- ------------------------------------------------------------- the tank side
function M:onReport(healer, id)
    if (self.cfg.HealerAggroOn or 0) == 0 or lower(healer) == lower(T.myName()) then return end
    if not TANK_ROLES[role()] and not iAmMA() then return end
    id = tonumber(id) or 0
    if id == 0 then return end
    self.aggroId = id
    Timers.set('ha:timer', 3500)
    if id ~= self.lastPM then
        self.lastPM = id
        local sp = T.spawn(id)
        Log.pm('healer aggro: %s reports %s (%d) dist %d; my target %s (%d) my aggro %d%%', healer, sp and T.str(function() return sp.CleanName() end) or '?', id,
            sp and T.num(function() return sp.Distance() end) or 0, State.myTargetName or '', State.myTargetId or 0, T.num(function() return mq.TLO.Me.PctAggro() end))
    end
end

function M:onTaunted(name)
    if not Timers.running('ha:timer') or self.aggroId == 0 then return end
    local sp = T.spawn(self.aggroId)
    if sp and lower(T.str(function() return sp.CleanName() end)) == lower(name) then
        Log.pm('healer aggro: taunt landed on %s - holding the rest of the list.', name)
        Timers.clear('ha:timer')
        Timers.set('ha:burst', (self.cfg.HealerAggroDelay or 3) * 1000)
    end
end

local function damaging(name)
    local sp = mq.TLO.Spell(name)
    if T.num(function() return sp.ID() end) > 0 then return T.bool(function() return sp.HasSPA(0)() end) or T.bool(function() return sp.HasSPA(79)() end) end
    local it = mq.TLO.FindItem('=' .. name)
    if T.num(function() return it.ID() end) > 0 then return T.bool(function() return it.Spell.HasSPA(0)() end) or T.bool(function() return it.Spell.HasSPA(79)() end) end
    return lower(name) ~= 'taunt'
end
local function toolRange(name)
    local sp = mq.TLO.Spell(name)
    if T.num(function() return sp.ID() end) > 0 then
        local r = T.num(function() return sp.MyRange() end)
        return r > 0 and r or T.num(function() return sp.AERange() end), r > 0
    end
    local aa = mq.TLO.Me.AltAbility(name).Spell
    if T.num(function() return aa.ID() end) > 0 then
        local r = T.num(function() return aa.MyRange() end)
        return r > 0 and r or T.num(function() return aa.AERange() end), false
    end
    return M.cfg.MeleeDistance or 30, false
end

--- HealerAggroBurst: one tool per HealerAggroDelay on the reported mob.
function M:burst()
    local c = self.cfg
    if State.aggroPaused or State.manualOn or State.markAssistOn then return end
    if (c.HealerAggroOn or 0) == 0 or not Timers.running('ha:timer') or self.aggroId == 0 or #self.tools == 0 then return end
    if Timers.running('ha:burst') or T.num(function() return mq.TLO.Me.Casting.ID() end) > 0 then return end
    local mob = T.spawn(self.aggroId)
    if not mob or T.str(function() return mob.Type() end) ~= 'NPC' then return end
    local switchMode = (c.HealerAggroSwitchTarget or 0) ~= 0 and not State.killOrderOn and not State.manualMAOn
    if switchMode and targetId() ~= self.aggroId then return end
    local prev = targetId()
    local wasCombat = T.bool(function() return mq.TLO.Me.Combat() end)
    local myAggro, mezzedNear = 0, 0
    for i = 1, 13 do
        local xt = mq.TLO.Me.XTarget(i)
        local id = T.num(function() return xt.ID() end)
        if id == self.aggroId then myAggro = T.num(function() return xt.PctAggro() end)
        elseif id > 0 and T.str(function() return xt.TargetType() end) == 'Auto Hater' and T.num(function() return xt.Distance() end) <= 50 then
            local s = T.spawn(id)
            if Timers.running('mezclaim:' .. id) or (s and MEZ_ANIM[T.num(function() return s.Animation() end)]) then mezzedNear = mezzedNear + 1 end
        end
    end
    self.mezzedAddsNear = mezzedNear
    if myAggro >= 100 then return end
    local held = self.hooks.ccHeldByOther(self.aggroId)
    local mezzed = MEZ_ANIM[T.num(function() return mob.Animation() end)] == true
    for _, tool in ipairs(self.tools) do
        local condOk = (c.HealerAggroCOn or 0) == 0 or tool.cond == 'TRUE' or tool.cond == '' or tool.cond == 'NULL'
        if not condOk then condOk = Cond.ok(tool.cond) end
        if condOk then
            local dmg = damaging(tool.name)
            if not (dmg and ((c.HealerAggroNoDamage or 1) ~= 0 or held or mezzed)) then
                local range, needLos = toolRange(tool.name)
                local dist = T.num(function() return mob.Distance3D() end)
                if dist <= range and not (needLos and not T.bool(function() return mob.LineOfSight() end)) and toolReady(tool.name) then
                    local tid = tool.target == 'me' and T.myId() or self.aggroId
                    Log.pm('healer aggro: %s on %s at %d (range %d, its aggro %d%%, mezzed adds near %d, held by %s, kill target stays %s)', tool.name,
                        T.str(function() return mob.CleanName() end), dist, range, myAggro, mezzedNear, held or 'nobody', State.myTargetName or '')
                    if not switchMode then
                        if wasCombat then mq.cmd('/squelch /attack off') end
                        if targetId() ~= self.aggroId then mq.cmdf('/squelch /target id %d', self.aggroId) mq.delay(500, function() return targetId() == self.aggroId end) end
                    end
                    local res = Cast.cast(tool.name, tid, 'Aggro')
                    mq.doevents()
                    if not switchMode then
                        if prev > 0 and prev ~= targetId() and T.spawn(prev) then mq.cmdf('/squelch /target id %d', prev) mq.delay(500, function() return targetId() == prev end) end
                        if wasCombat and not T.bool(function() return mq.TLO.Me.Combat() end) and targetId() > 0 and T.str(function() return mq.TLO.Target.Type() end) == 'NPC' then mq.cmd('/attack on') end
                    end
                    if res == 'CAST_SUCCESS' then Timers.set('ha:burst', (c.HealerAggroDelay or 3) * 1000) return end
                end
            end
        end
    end
end

--- HealerAggroSwitch: 0 = nothing / tools fired on the side, 2 = the kill target switched.
function M:switch()
    local c = self.cfg
    if (c.HealerAggroOn or 0) == 0 or not Timers.running('ha:timer') or self.aggroId == 0 then return 0 end
    if require('modules.pet').isProtected(self.aggroId) then return 0 end
    if State.aggroPaused or State.manualOn or State.markAssistOn then return 0 end
    local mob = T.spawn(self.aggroId)
    if not mob or T.str(function() return mob.Type() end) ~= 'NPC' or T.num(function() return mob.Distance() end) >= (c.CampRadius or 30) * 3 then return 0 end
    if not iAmMA() and not TANK_ROLES[role()] then return 0 end
    if (c.HealerAggroSwitchTarget or 0) == 0 or State.killOrderOn or State.manualMAOn then self:burst() return 0 end
    local result = 1
    if State.myTargetId ~= self.aggroId then
        local name = T.str(function() return mob.CleanName() end)
        Log.pm('healer aggro: switching to %s (%d) - switching to it!', name, self.aggroId)
        if T.bool(function() return mq.TLO.Stick.Active() end) then mq.cmd('/squelch /stick off') end
        State.myTargetId, State.myTargetName = self.aggroId, name
        if iAmMA() then Comms.say('g', 'TANKING-> %s <- ID:%d', name, self.aggroId) end
        result = 2
    end
    if targetId() ~= self.aggroId then mq.cmdf('/squelch /target id %d', self.aggroId) mq.delay(500, function() return targetId() == self.aggroId end) end
    self:burst()
    return result
end

-- ------------------------------------------------------------- the fresh add, the healer down
--- FreshAddCheck: an unclaimed hater not yet on the tank, seen for at most FreshAddHoldSec. Returns its id or 0.
function M:freshAdd()
    local c = self.cfg
    local now = T.now()
    if self.freshAt and now - self.freshAt < 100 then return self.freshLast or 0 end
    self.freshAt = now
    self.freshLast = self:freshAddScan()
    return self.freshLast
end
function M:freshAddScan()
    local c = self.cfg
    if T.hostiles() == 0 then return 0 end
    local tank = tankSpawn()
    if not tank then return 0 end
    local tx, ty = T.num(function() return tank.X() end), T.num(function() return tank.Y() end)
    for i = 1, 13 do
        local xt = mq.TLO.Me.XTarget(i)
        local id = T.num(function() return xt.ID() end)
        if id > 0 and T.str(function() return xt.TargetType() end) == 'Auto Hater' then
            local sp = T.spawn(id)
            if sp and T.str(function() return sp.Type() end) == 'NPC' and id ~= (State.assistId or 0) and T.num(function() return sp.Distance() end) <= (c.FreshAddRange or 60)
                and not Timers.running('mezclaim:' .. id) and not MEZ_ANIM[T.num(function() return sp.Animation() end)] then
                local dx, dy = T.num(function() return sp.X() end) - tx, T.num(function() return sp.Y() end) - ty
                if math.sqrt(dx * dx + dy * dy) > (c.MeleeDistance or 30) then
                    if not self.freshSeen[id] then self.freshSeen[id] = true Timers.set('ha:fresh:' .. id, (c.FreshAddHoldSec or 6) * 1000) end
                    if Timers.running('ha:fresh:' .. id) then return id end
                end
            end
        end
    end
    return 0
end

--- CheckHealer: any group member dead, hovering or out of zone (the pull hold).
function M.anyMemberDown()
    for i = 0, T.groupCount() do
        local m = T.groupMember(i)
        if T.num(function() return m.ID() end) == 0 or not T.bool(function() return m.Present() end) or T.bool(function() return m.Hovering() end) or T.bool(function() return m.Dead() end) then return true end
    end
    return false
end

--- HealerDown: a CLR / DRU / SHM in the group is dead, hovering or out of zone.
function M.healerDown()
    for i = 0, T.groupCount() do
        local m = T.groupMember(i)
        local cls = T.str(function() return m.Class.ShortName() end)
        if cls == 'CLR' or cls == 'DRU' or cls == 'SHM' then
            if T.num(function() return m.ID() end) == 0 or not T.bool(function() return m.Present() end) or T.bool(function() return m.Hovering() end) or T.bool(function() return m.Dead() end) then return true end
        end
    end
    return false
end

-- ------------------------------------------------------------- feign
--- InvulnSafeToDrop: above 50% and nothing on XTarget is on me.
function M.invulnSafeToDrop()
    if T.num(function() return mq.TLO.Me.PctHPs() end) > 50 then return true end
    local me = lower(T.myName())
    for i = 1, 13 do
        local xt = mq.TLO.Me.XTarget(i)
        local id = T.num(function() return xt.ID() end)
        if id > 0 and T.str(function() return xt.TargetType() end) == 'Auto Hater' then
            local sp = T.spawn(id)
            if sp and T.str(function() return sp.Type() end) == 'NPC' and lower(T.str(function() return sp.AssistName() end)) == me then return false end
        end
    end
    return true
end

--- FeignStandOK: a tank is up, or only tanks are down, or nothing unmezzed is near.
function M:feignStandOK()
    local c = self.cfg
    local tankUp, anyDown, otherDown = false, false, false
    local function tankClass(cls) return cls == 'WAR' or cls == 'PAL' or cls == 'SHD' end
    if T.num(function() return mq.TLO.Raid.Members() end) > 0 then
        for i = 1, T.num(function() return mq.TLO.Raid.Members() end) do
            local r = mq.TLO.Raid.Member(i)
            local name = T.str(function() return r.Name() end)
            if name ~= '' and lower(name) ~= lower(T.myName()) then
                local sp = T.spawnByName(name, 'pc')
                local cls = T.str(function() return r.Class.ShortName() end)
                if sp and not T.bool(function() return sp.Dead() end) then
                    if tankClass(cls) then tankUp = true end
                elseif T.spawnByName(name, 'pccorpse') then
                    anyDown = true
                    if not tankClass(cls) then otherDown = true end
                end
            end
        end
    else
        for i = 1, T.groupCount() do
            local m = T.groupMember(i)
            local cls = T.str(function() return m.Class.ShortName() end)
            local alive = T.bool(function() return m.Present() end) and not T.bool(function() return m.Dead() end) and not T.bool(function() return m.Hovering() end)
            if alive then
                if tankClass(cls) then tankUp = true end
            elseif T.bool(function() return m.Dead() end) or T.bool(function() return m.Hovering() end) or T.spawnByName(T.str(function() return m.CleanName() end), 'pccorpse') then
                anyDown = true
                if not tankClass(cls) then otherDown = true end
            end
        end
    end
    if tankUp then return true end
    if anyDown and not otherDown then return true end
    if (c.FeignStandRadius or 40) <= 0 then return true end
    local q = string.format('npc nopet radius %d zradius %d', c.FeignStandRadius or 40, c.MobZRadius or 50)
    local near = T.num(function() return mq.TLO.SpawnCount(q)() end)
    local mezzed = 0
    for i = 1, near do
        local sp = mq.TLO.NearestSpawn(i, q)
        if MEZ_ANIM[T.num(function() return sp.Animation() end)] or T.num(function() return sp.CachedBuff('^Mezzed').Duration() end) > 0 then mezzed = mezzed + 1 end
    end
    if mezzed > 0 and near >= mezzed then near = near - mezzed end
    return near == 0
end

--- The aggro-off hold ended (Event_Timer): stand from the feign when it is safe, else hold 5 s more.
function M:feignTick()
    local running = Timers.running('combat:aggrooff')
    if running then self.wasHolding = true return end
    if not self.wasHolding then return end
    self.wasHolding = false
    if T.bool(function() return mq.TLO.Me.Feigning() end) then
        if M.healerDown() then
            Log.info('Holding feign - healer is down.')
            Timers.set('combat:aggrooff', 5000)
        elseif not self:feignStandOK() then
            if Timers.expired('ha:feignecho') then
                Timers.set('ha:feignecho', 15000)
                Log.pm('feign: holding - no tank up, more than the tank down, mob(s) within %d', self.cfg.FeignStandRadius or 40)
            end
            Timers.set('combat:aggrooff', 5000)
        else
            Log.info('stand feign2')
            mq.cmd('/stand')
        end
    end
    if T.bool(function() return mq.TLO.Me.Invis() end) then mq.cmd('/makemevisible') end
end

--- The cast hold: a feigning healer class during the aggro-off hold (CastWhat's Feigned).
function M.feignHold()
    return T.bool(function() return mq.TLO.Me.Feigning() end) and Timers.running('combat:aggrooff') and healerClass()
end

-- ------------------------------------------------------------- module hooks
function M:Init()
    local function onAggro(_, healer, id) M:onReport(healer, id) end
    mq.event('ma_healeraggro1', '[ #1# (#*#) ]#*#HEALERAGGRO-> #*# <- ID:#2#', onAggro)
    mq.event('ma_healeraggro2', '<#1#>#*#HEALERAGGRO-> #*# <- ID:#2#', onAggro)
    mq.event('ma_healeraggro_taunt', "You capture #1#'s attention!", function(_, name) M:onTaunted(name) end)
    Cast.hooks.feignHold = M.feignHold
    local Combat = require('modules.combat')
    Combat.hooks.healerDown = M.healerDown
    Combat.hooks.healerAggroSwitch = function() return M:switch() end
    Combat.hooks.gotHit = function(mob) M:hitCheck(mob) end
    Combat.hooks.aggroOffMs = M.aggroOffMs
    local Heals = require('modules.heals')
    Heals.hooks.healerAggroCheck = function() M:aggroCheck() end
    Heals.hooks.freshAdd = function() return M:freshAdd() end
    Heals.hooks.invulnSafeToDrop = M.invulnSafeToDrop
    local Rez = require('modules.rez')
    Rez.hooks.invulnSafeToDrop = M.invulnSafeToDrop
    Rez.hooks.xtarSlots = function() return Heals:xtarSlots() end
    Rez.hooks.ladderCombat = function() return Heals.rezCombat end
    Rez.hooks.ladderOOC = function() return Heals.rezOOC end
end

function M:Shutdown()
    for _, e in ipairs({ 'ma_healeraggro1', 'ma_healeraggro2', 'ma_healeraggro_taunt' }) do pcall(mq.unevent, e) end
end

function M:GiveTime(ctx)
    self:feignTick()
    if State.chainPull == 2 or State.getAwayFollow then return end
    -- the tank side's burst between fights (the combat loop calls switch() during one)
    if not State.combatStart and Timers.running('ha:timer') then self:switch() end
end

function M:OnZone()
    self.aggroId = 0
    self.freshSeen = {}
    Timers.clear('ha:timer')
end

return M
