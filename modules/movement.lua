-- modules/movement.lua: camp and chase (DoWeMove), MobInCamp / DistToCamp, ChaseLagging, MoveForCast,
-- ChaseStuckTick / Stuck, RunToTank, Campfire / CampfireBack and the camp / chase binds. Same [General]
-- keys as the macro. Installs the hooks the cast engine calls (chaseLagging, moveForCast, doWeMove).
--
-- Not a transliteration: every move is issued and then watched across ticks (a nav leg, a stick, a
-- moveto) instead of a blocking loop, so the rest of the modules keep their turn. The macro's blocking
-- return-to-camp leg for pull roles becomes the same watched leg with the same 30 s cap and the same
-- stuck escape. A return-to-camp stall no longer turns ReturnToCamp and ChaseAssist off (the macro's
-- ShakeLoose side effect); it backs up, strafes and retries.
local mq = require('mq')
local T = require('core.tlo')
local Config = require('core.config')
local Timers = require('core.timers')
local Cast = require('core.cast')
local Comms = require('core.comms')
local Log = require('core.log')
local State = require('core.state')

local M = { name = 'movement' }

M.Settings = {
    scalars = {
        { section = 'General', key = 'CampRadius', type = 'int', default = 30 },
        { section = 'General', key = 'CampRadiusExceed', type = 'int', default = 400 },
        { section = 'General', key = 'ReturnToCamp', type = 'int', default = 0 },
        { section = 'General', key = 'ReturnToCampAccuracy', type = 'int', default = 10 },
        { section = 'General', key = 'ChaseAssist', type = 'int', default = 0 },
        { section = 'General', key = 'ChaseDistance', type = 'int', default = 25 },
        { section = 'General', key = 'RunToTankOn', type = 'int', default = 0 },
        { section = 'General', key = 'MoveCloserIfNoLOS', type = 'int', default = 0 },
        { section = 'General', key = 'MoveForCastMaxDist', type = 'int', default = 150 },
        { section = 'General', key = 'MoveForLoSInCampOnly', type = 'int', default = 1 },
        { section = 'General', key = 'MezzedEngageRange', type = 'int', default = 100 },
        { section = 'General', key = 'CampZRadius', type = 'int', default = 0 },
        { section = 'General', key = 'TravelOnHorse', type = 'int', default = 0 },
        { section = 'General', key = 'CampfireOn', type = 'int', default = 0 },
        { section = 'Melee', key = 'DismountDuringFights', type = 'int', default = 0 },
        { section = 'Melee', key = 'AutoFireOn', type = 'int', default = 0 },
        { section = 'Melee', key = 'AssistRange', type = 'int', default = 200 },
        { section = 'Melee', key = 'MeleeOn', type = 'int', default = 0 },
        { section = 'DPS', key = 'StayAwayToCast', type = 'int', default = 0 },
        { section = 'Pull', key = 'MaxRadius', type = 'int', default = 350 },
        { section = 'AFKTools', key = 'ClickBacktoCamp', type = 'int', default = 0 },
    },
}
M.cfg = {}
M.stuck = { x = 0, y = 0, n = 0, tries = 0, dist = 0 }
M.rtc = { x = 0, y = 0, still = 0 }
M.chase = { lastDist = 0, jump = false }
M.oldCampfire = { x = 0, y = 0, z = 0 }

local function lower(s) return tostring(s or ''):lower() end
local PULL_ROLES = { puller = true, pullertank = true, pullerpettank = true, hunter = true, hunterpettank = true }
local function role() return lower(State.role) end
local function meX() return T.num(function() return mq.TLO.Me.X() end) end
local function meY() return T.num(function() return mq.TLO.Me.Y() end) end
local function meZ() return T.num(function() return mq.TLO.Me.Z() end) end
local function dist2(x1, y1, x2, y2) return math.sqrt((x1 - x2) ^ 2 + (y1 - y2) ^ 2) end
local function navLoaded() return T.pluginLoaded('MQ2Nav') end
local function meshLoaded() return navLoaded() and T.bool(function() return mq.TLO.Navigation.MeshLoaded() end) end
local function navActive() return T.bool(function() return mq.TLO.Navigation.Active() end) end
local function navPaused() return T.bool(function() return mq.TLO.Navigation.Paused() end) end
local function navVelocity() return T.num(function() return mq.TLO.Navigation.Velocity() end) end
local function pathExists(q) return T.bool(function() return mq.TLO.Navigation.PathExists(q)() end) end
local function stickActive() return T.bool(function() return mq.TLO.Stick.Active() end) end
local function mounted() return T.num(function() return mq.TLO.Me.Mount.ID() end) > 0 end
local function wet() return T.bool(function() return mq.TLO.Me.FeetWet() end) end
local function inCombat() return T.bool(function() return mq.TLO.Me.Combat() end) end
local function casting() return T.num(function() return mq.TLO.Me.Casting.ID() end) > 0 end
local function hovering() return T.bool(function() return mq.TLO.Me.Hovering() end) end
local function stand()
    if T.bool(function() return mq.TLO.Me.Standing() end) then return true end
    mq.cmd('/stand')
    mq.delay(1000, function() return T.bool(function() return mq.TLO.Me.Standing() end) end)
    return T.bool(function() return mq.TLO.Me.Standing() end)
end
local function navStop() if navActive() then mq.cmd('/nav stop') end end
local function stopFollows()
    navStop()
    if stickActive() then mq.cmd('/squelch /stick off') end
    if T.bool(function() return mq.TLO.MoveTo.Moving() end) then mq.cmd('/moveto off') end
end

-- ------------------------------------------------------------- settings and state
function M:LoadSettings()
    self.cfg = Config.load(self.Settings)
    -- what the role forces (CheckRoles, applied by the combat module first)
    local rd = State.roleDefaults or {}
    if rd.returnToCamp ~= nil then self.cfg.ReturnToCamp = rd.returnToCamp and 1 or 0 end
    if rd.chaseAssist ~= nil then self.cfg.ChaseAssist = rd.chaseAssist and 1 or 0 end
    if rd.campRadiusExceed ~= nil then self.cfg.CampRadiusExceed = rd.campRadiusExceed end
    State.chaseAssist = (self.cfg.ChaseAssist or 0) ~= 0
    State.returnToCamp = (self.cfg.ReturnToCamp or 0) ~= 0
    State.chaseDistance = self.cfg.ChaseDistance or 25
    State.campRadius = self.cfg.CampRadius or 30
    if State.chaseName == '' then State.chaseName = State.mainAssist end
    if State.campZone == 0 then
        State.campX, State.campY, State.campZ, State.campZone = meX(), meY(), meZ(), T.zoneId()
    end
end

--- FindvalidRangeLocation: back off to `radius` from a spawn along the line from it to me (the ranged stance).
function M.rangeLocation(id, radius)
    local sp = T.spawn(id)
    if not sp then return false end
    local sx, sy = T.num(function() return sp.X() end), T.num(function() return sp.Y() end)
    local mx, my = meX(), meY()
    local dx, dy = mx - sx, my - sy
    local d = math.sqrt(dx * dx + dy * dy)
    if d < 1 then dx, dy, d = 1, 0, 1 end
    local tx, ty = sx + dx / d * radius, sy + dy / d * radius
    if T.bool(function() return mq.TLO.Navigation.MeshLoaded() end) then
        mq.cmdf('/nav locyxz %d %d %d', ty, tx, T.num(function() return sp.Z() end))
        Cast.tickDelay(5000, function() return not T.bool(function() return mq.TLO.Navigation.Active() end) end)
    else
        mq.cmdf('/moveto loc %d %d', ty, tx)
        Cast.tickDelay(5000, function() return not T.bool(function() return mq.TLO.MoveTo.Moving() end) end)
    end
    return true
end

function M:Init()
    Cast.hooks.chaseLagging = function() return M.chaseLagging() end
    Cast.hooks.moveForCast = function(id, range, why) return M.moveForCast(id, range, why) end
    Cast.hooks.doWeMove = function(reason) return M.doWeMove(reason) end
end

--- Set the camp here (/camphere, /returntocamp on).
function M.setCampHere()
    State.campX, State.campY = meX(), meY()
    State.campZ = T.num(function() return mq.TLO.Me.FloorZ() end)
    State.campZone = T.zoneId()
end

--- My 2D distance to the camp loc.
function M.distToCampLoc()
    return dist2(meX(), meY(), State.campX, State.campY)
end

--- The camp anchor for "in camp" tests: the camp loc with ReturnToCamp, else the main assist (or me).
local function anchorSpawn()
    if State.mainAssist == '' then return mq.TLO.Me end
    if (State.mainAssistId or 0) > 0 then
        local s = T.spawn(State.mainAssistId)
        if s and lower(T.str(function() return s.CleanName() end)) == lower(State.mainAssist) then return s end
    end
    local ma = T.spawnByName(State.mainAssist, lower(State.mainAssistType) ~= '' and lower(State.mainAssistType) or 'pc')
    return ma or mq.TLO.Me
end

--- MobInCamp: a spawn within CampRadius of the camp loc (2D, with the Z radius) or of the anchor (3D).
function M.inCamp(id)
    local sp = T.spawn(id)
    if not sp then return false end
    local radius = M.cfg.CampRadius or 30
    if State.returnToCamp then
        local d = dist2(T.num(function() return sp.X() end), T.num(function() return sp.Y() end), State.campX, State.campY)
        if d > radius then return false end
        local zr = M.cfg.CampZRadius or 0
        return zr == 0 or math.abs(T.num(function() return sp.Z() end) - State.campZ) <= zr
    end
    local a = anchorSpawn()
    local dx = T.num(function() return sp.X() end) - T.num(function() return a.X() end)
    local dy = T.num(function() return sp.Y() end) - T.num(function() return a.Y() end)
    local dz = T.num(function() return sp.Z() end) - T.num(function() return a.Z() end)
    return math.sqrt(dx * dx + dy * dy + dz * dz) <= radius
end

--- DistToCamp: a spawn's 2D distance to the anchor (99999 when gone).
function M.distToCamp(id)
    local sp = T.spawn(id)
    if not sp then return 99999 end
    local x, y = T.num(function() return sp.X() end), T.num(function() return sp.Y() end)
    if State.returnToCamp then return dist2(x, y, State.campX, State.campY) end
    local a = anchorSpawn()
    return dist2(x, y, T.num(function() return a.X() end), T.num(function() return a.Y() end))
end

--- The buff leash: ChaseDistance + 15 under 15, else twice ChaseDistance.
function M.leash(chaseDistance)
    chaseDistance = tonumber(chaseDistance) or 25
    if chaseDistance < 15 then return chaseDistance + 15 end
    return chaseDistance * 2
end

local function chaseSpawn()
    if State.chaseName == '' then return nil end
    return T.spawnByName(State.chaseName, 'pc') or T.spawnByName(State.chaseName, 'pet')
end

--- ChaseLagging: the chase target is past the buff leash and buffing should yield.
function M.chaseLagging()
    if State.getAwayFollow then return true end
    if not State.chaseAssist or role() == 'manual' then return false end
    if State.chaseLeftBehind then return false end
    if State.killOrderOn and (State.killOrderTarget or 0) > 0 then return false end
    local sp = chaseSpawn()
    if not sp then return false end
    return T.num(function() return sp.Distance() end) > M.leash(M.cfg.ChaseDistance)
end

-- ------------------------------------------------------------- MoveForCast
--- Walk toward a cast target that lacks range or line of sight; true when it ends in range with LoS.
function M.moveForCast(id, range, why)
    local c = M.cfg
    if (c.MoveCloserIfNoLOS or 0) == 0 or not meshLoaded() then return false end
    if Timers.running('move:forcast') or hovering() or casting() or State.pulling then return false end
    if T.num(function() return mq.TLO.Me.Rooted.ID() end) > 0 then return false end
    local r = role()
    if r == 'tank' or r == 'pullertank' or r == 'pullerpettank' then return false end
    local sp = T.spawn(id)
    if not sp or id == T.myId() or T.str(function() return sp.Type() end) == 'Corpse' then return false end
    if T.num(function() return sp.Distance3D() end) > (c.MoveForCastMaxDist or 150) then return false end
    if (c.MoveForLoSInCampOnly or 1) ~= 0 and T.str(function() return sp.Type() end) == 'NPC' and not M.inCamp(id) then return false end
    range = tonumber(range) or 0
    if range == 0 then range = 100 end
    local stop = math.max(10, math.floor(range * 0.7))
    Timers.set('move:forcast', 3000)
    if not pathExists('id ' .. id) then return false end
    if Timers.expired('move:forcastecho') then
        Timers.set('move:forcastecho', 5000)
        Log.pm('move: %s - moving toward %s (dist %d, LoS %s) for range %d', tostring(why), T.str(function() return sp.CleanName() end),
            T.num(function() return sp.Distance3D() end), tostring(T.bool(function() return sp.LineOfSight() end)), range)
    end
    stopFollows()
    mq.cmdf('/nav id %d distance=%d', id, stop)
    mq.delay(1000, function() return navActive() end)
    Cast.tickDelay(5000, function()
        local s = T.spawn(id)
        if not navActive() or not s then return true end
        return T.bool(function() return s.LineOfSight() end) and T.num(function() return s.Distance3D() end) < range * 0.9
    end)
    navStop()
    mq.delay(300, function() return navVelocity() == 0 end)
    local s = T.spawn(id)
    return s ~= nil and T.bool(function() return s.LineOfSight() end) and T.num(function() return s.Distance3D() end) < range
end

-- ------------------------------------------------------------- Stuck
--- Back up a second and strafe a second (Sub Stuck).
function M.stuckEscape()
    if hovering() or State.iAmDead then return end
    mq.cmd('/keypress back hold') mq.delay(1000) mq.cmd('/keypress back')
    local dir = math.random(2) == 1 and 'STRAFE_LEFT' or 'STRAFE_RIGHT'
    mq.cmdf('/keypress %s hold', dir) mq.delay(1000) mq.cmdf('/keypress %s', dir)
end

--- ChaseStuckTick: a follow that has not moved three samples running (6 s) with the target still away.
function M:chaseStuckTick()
    if not State.chaseAssist or role() == 'manual' or not Timers.expired('move:chasestuck') then return end
    Timers.set('move:chasestuck', 2000)
    local s = self.stuck
    local moved = dist2(s.x, s.y, meX(), meY())
    s.x, s.y = meX(), meY()
    local sp = chaseSpawn()
    local dist, range = 0, 0
    local stickTarget = T.num(function() return mq.TLO.Stick.StickTarget() end)
    if stickActive() and stickTarget > 0 and T.spawn(stickTarget) then
        dist = T.num(function() return T.spawn(stickTarget).Distance() end)
        range = dist
    elseif sp then
        dist = T.num(function() return sp.Distance() end)
        range = T.num(function() return sp.Distance3D() end)
    end
    local following = navActive() or (stickActive() and T.str(function() return mq.TLO.Stick.StickTarget().Type() end) ~= 'NPC')
    local done = not sp or range <= (self.cfg.ChaseDistance or 25) + 10 or State.chaseLeftBehind or not following
    local hold = hovering() or casting() or navPaused() or T.bool(function() return mq.TLO.Me.Stunned() end)
        or T.num(function() return mq.TLO.Me.Rooted.ID() end) > 0 or T.bool(function() return mq.TLO.Me.Feigning() end) or inCombat()
    if done or hold or moved >= 3 then
        if s.tries > 0 and (done or dist < s.dist - 20) then
            Log.info('[Chase] moving again')
            s.tries = 0
            State.chaseStuckTries = 0
        end
        s.n = 0
        return
    end
    s.n = s.n + 1
    if s.n < 3 then return end
    s.n = 0
    s.tries = s.tries + 1
    State.chaseStuckTries = s.tries
    s.dist = dist
    Log.info('[Chase] stuck (try %d) - %s is %d away, backing up to get loose', s.tries, State.chaseName, math.floor(dist))
    stopFollows()
    M.stuckEscape()
    s.x, s.y = meX(), meY()
    Timers.set('move:chasestuck', 2000)
    if s.tries >= 3 and Timers.expired('move:chasestuckwarn') then
        Timers.set('move:chasestuckwarn', 60000)
        Comms.say('r', '[Chase] %s is stuck at %d, %d, %d - %s is %d away', T.myName(), math.floor(meY()), math.floor(meX()), math.floor(meZ()), State.chaseName, math.floor(dist))
    end
end

-- ------------------------------------------------------------- return to camp
--- One non-blocking return-to-camp step. Returns true when a move was issued or is running.
function M:returnToCamp(reason)
    local c = self.cfg
    local dist = M.distToCampLoc()
    if casting() then
        local st = lower(T.str(function() return mq.TLO.Me.Casting.SpellType() end))
        if st:find('beneficial') or T.bool(function() return mq.TLO.Me.Casting.HasSPA(31)() end) then return false end
    end
    local r = role()
    -- the camp leash: too far out, give the camp up (pullers and hunters keep it)
    if dist > (c.CampRadiusExceed or 400) and not r:find('hunter', 1, true) and not r:find('puller', 1, true) then
        State.returnToCamp = false
        self.cfg.ReturnToCamp = 0
        Log.info('Leashing exceeded distance of %d turning off ReturnToCamp', c.CampRadiusExceed or 400)
        return false
    end
    -- a tank with a live hater nearby stays out
    if T.hostiles() > 0 and (r == 'tank' or r == 'pullertank' or r == 'pettank' or r == 'pullerpettank') then
        for _, h in ipairs(T.haters()) do
            local xt = mq.TLO.Me.XTarget(h.slot)
            if T.str(function() return xt.Type() end) == 'NPC' and T.num(function() return xt.Distance() end) <= (c.MezzedEngageRange or 100) then
                if Timers.expired('move:pmecho') then
                    Timers.set('move:pmecho', 30000)
                    Log.pm('rtc: staying out - %s still up within %d', T.str(function() return xt.CleanName() end), c.MezzedEngageRange or 100)
                end
                return false
            end
        end
    end
    if dist <= 11 then return false end
    if T.num(function() return mq.TLO.Me.XTarget() end) > 0 and dist < (c.CampRadius or 30) then return false end
    if PULL_ROLES[r] and r ~= 'hunter' and r ~= 'hunterpettank' and dist <= (c.CampRadius or 30) and not State.medding then return false end
    if State.iAmDead or hovering() then if T.bool(function() return mq.TLO.MoveTo.Moving() end) then mq.cmd('/moveto off') end return false end
    if dist <= (c.ReturnToCampAccuracy or 10) then
        if T.bool(function() return mq.TLO.MoveTo.Moving() end) then mq.cmd('/moveto off') end
        if r == 'hunter' or r == 'hunterpettank' then State.returnToCamp = false self.cfg.ReturnToCamp = 0 end
        return false
    end
    if (c.DismountDuringFights or 0) ~= 0 and mounted() and (c.TravelOnHorse or 0) == 0 then
        Log.info('getting off the horse because DismountDuringFights=1')
        mq.cmd('/dismount')
    end
    if T.num(function() return mq.TLO.Me.Rooted.ID() end) > 0 then return false end
    if stickActive() and not T.bool(function() return mq.TLO.Me.Sitting() end) then mq.cmd('/squelch /stick off') end
    if meshLoaded() and not r:find('hunter', 1, true) then
        if navActive() and not navPaused() then
            -- a running leg: watch for a stall (no velocity, same spot)
            if navVelocity() == 0 and Timers.expired('move:rtc') then
                mq.cmd('/beep')
                Log.pm('rtc: I might be stuck on the way back to camp')
                if State.chaseName ~= '' then Comms.exec(State.chaseName, string.format('/popup its possible %s Stuck', T.myName())) end
                navStop()
                M.stuckEscape()
                Timers.set('move:rtc', 30000)
            end
            return true
        end
        if mounted() and (dist < 75 or ((c.TravelOnHorse or 0) == 0 or ((c.DismountDuringFights or 0) ~= 0 and T.inCombat())) and dist < 100) then
            Log.info('MQ2Nav does not work well with mounts. Dismounting.')
            mq.cmd('/dismount')
        end
        if not stand() then return false end
        if pathExists(string.format('locyxz %d %d %d', State.campY, State.campX, State.campZ)) then
            Log.info('trying to get within %d feet of the camp (%d ft)', c.ReturnToCampAccuracy or 10, math.floor(dist))
            mq.cmdf('/nav locyxz %d %d %d', State.campY, State.campX, State.campZ)
            Timers.set('move:rtc', 30000)
            mq.delay(500, function() return navActive() end)
            return true
        end
    end
    -- no mesh, no path, or a hunter: moveto
    if not T.bool(function() return mq.TLO.MoveTo.Moving() end) then
        mq.cmdf('/moveto mdist %d', c.ReturnToCampAccuracy or 10)
        mq.cmdf('/moveto loc %d %d', State.campY, State.campX)
        Timers.set('move:rtc', 30000)
        mq.delay(500, function() return T.bool(function() return mq.TLO.MoveTo.Moving() end) end)
        return true
    elseif not T.bool(function() return mq.TLO.Me.Moving() end) and Timers.expired('move:rtc') then
        mq.cmd('/moveto off')
        M.stuckEscape()
        Timers.set('move:rtc', 30000)
    end
    return true
end

-- ------------------------------------------------------------- chase
local function navTo(id)
    if mounted() and (M.cfg.TravelOnHorse or 0) == 0 then mq.cmd('/dismount') end
    mq.cmdf('/nav id %d', id)
    mq.delay(500, function() return navActive() end)
end
local function stickUw(id)
    navStop()
    stand()
    if T.num(function() return mq.TLO.Stick.StickTarget() end) ~= id or T.str(function() return mq.TLO.Stick.Status() end):upper() == 'OFF' then
        mq.cmdf('/stick uw id %d', id)
    end
end
local function stickLoose(id)
    local d = M.cfg.ChaseDistance or 25
    if wet() then navStop() mq.cmdf('/stick %d uw id %d loose', d, id) else mq.cmdf('/stick %d id %d loose', d, id) end
end

--- One chase step (the ChaseAssist branch of DoWeMove plus CanIDoStuff's chase nav).
function M:chaseStep()
    local c = self.cfg
    local sp = chaseSpawn()
    if not sp then return false end
    local id = T.num(function() return sp.ID() end)
    if id == T.myId() then return false end
    local dist = T.num(function() return sp.Distance() end)
    local exceed = c.CampRadiusExceed or 400
    -- the far test: past the leash (or on another floor with a mesh) and not just zoned
    local dz = math.abs(T.num(function() return sp.Z() end) - meZ())
    if Timers.expired('zone:justzoned') and (dist > exceed or (meshLoaded() and dz > 100)) then
        if State.chaseLeftBehind or self.chase.jump or (not meshLoaded() and dist > exceed) then
            if Timers.expired('move:leftwarn') then
                Timers.set('move:leftwarn', 60000)
                Log.info('[Chase] %s is %d away%s - waiting here, chase stays on', State.chaseName, math.floor(dist), self.chase.jump and ' (jumped)' or '')
                Comms.say('r', 'Hey! I got left behind please run me to %s', State.chaseName)
            end
            State.chaseLeftBehind = true
            if stickActive() then mq.cmd('/squelch /stick off') end
            return false
        elseif not inCombat() then
            if not navActive() and pathExists('id ' .. id) then
                if not wet() then navTo(id) else stickUw(id) end
                return true
            end
        end
    end
    -- hold position while casting on the kill target from range
    if casting() and (State.combatStart or T.aggroTargetId() > 0) and (c.MeleeOn or 0) == 0 and (State.myTargetId or 0) > 0 then
        local t = T.spawn(State.myTargetId)
        if t and T.str(function() return t.Type() end) == 'NPC' and T.bool(function() return t.LineOfSight() end)
            and T.num(function() return t.Distance3D() end) < (c.AssistRange or 200) and dist < (c.ChaseDistance or 25) * 4 then
            return false
        end
    end
    -- the follow test
    if dist > (c.ChaseDistance or 25) and dist < exceed then
        local ty = T.str(function() return sp.Type() end)
        local followId = id
        if ty == 'Pet' then followId = T.num(function() return sp.Master.ID() end) end
        if ty == 'Mercenary' then followId = T.num(function() return sp.Owner.ID() end) end
        if followId == 0 or followId == T.myId() then return false end
        if inCombat() then return false end
        if (not navActive() or navVelocity() == 0) and pathExists('id ' .. id) then
            if not wet() then navTo(id) else stickUw(id) end
            return true
        end
        if not navActive() then stand() stickLoose(followId) return true end
    end
    return false
end

--- DoWeMove: the movement decision for this tick (return to camp, or chase). Returns true when moving.
function M.doWeMove(reason)
    local self = M
    local c = self.cfg
    if State.killOrderOn and (State.killOrderTarget or 0) > 0 then return false end
    if State.getAwayOn then return false end
    if not State.returnToCamp and not State.chaseAssist then return false end
    if role() == 'manual' then return false end
    -- chase bookkeeping: a jump of 300+ in one pass past the leash, and the hysteresis back in
    self.chase.jump = false
    local sp = State.chaseAssist and chaseSpawn() or nil
    if sp then
        local d = T.num(function() return sp.Distance() end)
        if self.chase.lastDist > 0 and d > (c.CampRadiusExceed or 400) and d - self.chase.lastDist > 300 then self.chase.jump = true end
        self.chase.lastDist = d
        if State.chaseLeftBehind and Timers.expired('zone:justzoned') and d <= (c.CampRadiusExceed or 400) * 0.8 then
            State.chaseLeftBehind = false
            Log.info('[Chase] %s is back in range - following again', State.chaseName)
        end
        if (self.chase.jump or State.chaseLeftBehind) and not inCombat() and navActive() then
            Log.info('[Chase] %s %s %d away - stopping nav', State.chaseName, self.chase.jump and 'jumped to' or 'is', math.floor(d))
            mq.cmd('/nav stop')
        end
    else
        self.chase.lastDist = 0
    end
    if casting() and navPaused() then return true end
    if navPaused() and not casting() then mq.cmd('/nav pause') end
    if navActive() and T.bool(function() return mq.TLO.Me.Moving() end) and navVelocity() > 0 then return true end
    if hovering() then return false end
    if State.returnToCamp and State.chaseAssist then
        Log.info("Can't both follow and stay in camp. Setting ReturnToCamp to 0 and keeping ChaseAssist 1")
        State.returnToCamp = false
        self.cfg.ReturnToCamp = 0
    end
    if (c.MaxRadius or 0) > (c.CampRadiusExceed or 400) then self.cfg.CampRadiusExceed = c.MaxRadius end
    if State.returnToCamp then return self:returnToCamp(reason) end
    if State.chaseAssist and (not State.combatStart or ((c.AutoFireOn or 0) == 0 and (c.StayAwayToCast or 0) == 0)) then
        return self:chaseStep()
    end
    return false
end

-- ------------------------------------------------------------- RunToTank
function M:runToTank()
    local c = self.cfg
    if (c.RunToTankOn or 0) == 0 then return end
    local r = role()
    if lower(State.mainAssist) == lower(T.myName()) or r ~= 'assist' and r ~= 'petassist' then return end
    if T.aggroTargetId() == 0 or casting() then return end
    local onMe = false
    for i = 1, 13 do
        local xt = mq.TLO.Me.XTarget(i)
        if T.str(function() return xt.TargetType() end) == 'Auto Hater' and T.str(function() return xt.Type() end) == 'NPC'
            and lower(T.str(function() return xt.AssistName() end)) == lower(T.myName()) and T.num(function() return xt.Distance3D() end) < 60 then onMe = true end
    end
    if not onMe then
        if self.runToTankNav and navActive() then mq.cmd('/nav stop') end
        self.runToTankNav = false
        return
    end
    local ma = State.mainAssist ~= '' and T.spawnByName(State.mainAssist, 'pc') or nil
    if not ma or T.num(function() return ma.Distance() end) > 200 then return end
    if T.num(function() return ma.Distance() end) < 15 then
        if self.runToTankNav and navActive() then mq.cmd('/nav stop') end
        self.runToTankNav = false
        return
    end
    if navActive() or T.bool(function() return mq.TLO.MoveTo.Moving() end) then return end
    local id = T.num(function() return ma.ID() end)
    if meshLoaded() and pathExists('id ' .. id) then
        Log.info('Something is beating on me - running to %s!', State.mainAssist)
        mq.cmdf('/nav id %d distance=10', id)
    else
        Log.info('Something is beating on me - moving to %s!', State.mainAssist)
        mq.cmdf('/moveto id %d mdist 10', id)
    end
    self.runToTankNav = true
end

-- ------------------------------------------------------------- campfire
function M:campfireTick()
    local c = self.cfg
    if (c.CampfireOn or 0) == 0 or T.inCombat() or not Timers.expired('move:campfire') then return end
    if T.num(function() return mq.TLO.Me.Fellowship.CampfireZone.ID() end) > 0 then return end
    if M.distToCampLoc() > (c.CampRadius or 30) or T.aggroTargetId() > 0 or State.combatStart then return end
    local count = 0
    local members = T.num(function() return mq.TLO.Me.Fellowship.Members() end)
    for i = 1, members do
        local name = T.str(function() return mq.TLO.Me.Fellowship.Member(i)() end)
        local sp = name ~= '' and T.spawnByName(name, 'pc') or nil
        if sp and T.num(function() return sp.Distance() end) <= 50 then count = count + 1 end
    end
    if count >= 3 then
        local o = self.oldCampfire
        if o.x ~= 0 and dist2(meX(), meY(), o.x, o.y) < 200 then
            Log.info('we should drop campfire where old one was dropped.')
            mq.cmdf('/nav locyxz %d %d %d', o.y, o.x, o.z)
            mq.delay(1000, function() return navActive() end)
            Cast.tickDelay(5000, function() return not navActive() end)
        end
        M.dropCampfire()
    else
        Log.info('Not enough fellowship members trying again in 5 minutes')
        Timers.set('move:campfire', 300000)
    end
end

--- /campfire: drop (or move) the fellowship campfire through the fellowship window.
function M.dropCampfire()
    mq.cmd('/windowstate FellowshipWnd open')
    mq.delay(1000)
    mq.cmd('/nomodkey /notify FellowshipWnd FP_Subwindows tabselect 2')
    local cfZone = T.num(function() return mq.TLO.Me.Fellowship.CampfireZone.ID() end)
    if cfZone > 0 and cfZone ~= T.zoneId() then
        mq.cmd('/nomodkey /notify FellowshipWnd FP_DestroyCampsite leftmouseup')
        Cast.tickDelay(5000, function() return T.bool(function() return mq.TLO.Window('ConfirmationDialogBox').Open() end) end)
        if T.bool(function() return mq.TLO.Window('ConfirmationDialogBox').Open() end) then mq.cmd('/nomodkey /notify ConfirmationDialogBox Yes_Button leftmouseup') end
        Cast.tickDelay(5000, function() return T.num(function() return mq.TLO.Me.Fellowship.CampfireZone.ID() end) == 0 end)
    end
    mq.delay(1000)
    mq.cmd('/nomodkey /notify FellowshipWnd FP_RefreshList leftmouseup')
    mq.delay(1000)
    mq.cmd('/nomodkey /notify FellowshipWnd FP_CampsiteKitList listselect 1')
    mq.delay(1000)
    mq.cmd('/nomodkey /notify FellowshipWnd FP_CreateCampsite leftmouseup')
    Cast.tickDelay(5000, function() return T.num(function() return mq.TLO.Me.Fellowship.CampfireZone.ID() end) > 0 end)
    mq.cmd('/windowstate FellowshipWnd close')
    if T.num(function() return mq.TLO.Me.Fellowship.CampfireZone.ID() end) > 0 then
        Log.info('Campfire Dropped')
        M.oldCampfire = { x = T.num(function() return mq.TLO.Me.Fellowship.CampfireX() end), y = T.num(function() return mq.TLO.Me.Fellowship.CampfireY() end), z = T.num(function() return mq.TLO.Me.Fellowship.CampfireZ() end) }
    end
end

--- CampfireBack: dead in another zone, click the insignia once the campfire is up.
function M:campfireBackTick()
    if State.buffMode or (self.cfg.ClickBacktoCamp or 0) == 0 or not Timers.expired('move:cfclick') or hovering() then return end
    Timers.set('move:cfclick', 60000)
    if T.num(function() return mq.TLO.Me.Buff('Revival Sickness').ID() end) > 0 and State.campZone ~= T.zoneId() then State.iAmDead = true end
    if not State.iAmDead then return end
    local cfZone = T.num(function() return mq.TLO.Me.Fellowship.CampfireZone.ID() end)
    if cfZone == 0 then Log.info('There is no campfire up.') return end
    if cfZone == T.zoneId() then Log.info("I'm back in the same zone as my campfire.") State.iAmDead = false return end
    if T.num(function() return mq.TLO.FindItem('=Fellowship Registration Insignia').TimerReady() end) == 0 then
        Log.info('Time to get back to work. Clicking Fellowship Insignia in 30 seconds.')
        Cast.tickDelay(30000)
        mq.cmd('/squelch /nomodkey /itemnotify "Fellowship Registration Insignia" rightmouseup')
    end
end

-- ------------------------------------------------------------- the tick
function M:GiveTime(ctx)
    self:chaseStuckTick()
    self:campfireBackTick()
    if State.chainPull == 2 or State.getAwayFollow then return end
    if not T.inCombat() then
        M.doWeMove('MainLoop')
        self:campfireTick()
    end
    self:runToTank()
end

function M:OnZone()
    Timers.set('zone:justzoned', 20000)
    if State.returnToCamp and State.campZone ~= T.zoneId() then
        self.rememberCamp = true
        State.returnToCamp = false
    elseif self.rememberCamp and State.campZone == T.zoneId() and M.distToCampLoc() <= 100 then
        State.returnToCamp = true
        self.rememberCamp = false
    end
end

-- ------------------------------------------------------------- binds
local function setRTC(self, on)
    State.returnToCamp = on
    self.cfg.ReturnToCamp = on and 1 or 0
    if on then
        M.setCampHere()
        if State.chaseAssist then
            State.chaseAssist = false
            self.cfg.ChaseAssist = 0
            if stickActive() then mq.cmd('/squelch /stick off') end
            Log.info('>> ChaseAssist Off')
        end
        Log.info('>> New camp set %d, %d', math.floor(State.campY), math.floor(State.campX))
    end
    Log.info('>> Setting: (ReturnToCamp) to (%s)', on and 'On' or 'Off')
end

local function setChase(self, on, name)
    State.chaseAssist = on
    self.cfg.ChaseAssist = on and 1 or 0
    Config.set('General', 'ChaseAssist', on and 1 or 0)
    if on then
        if name and name ~= '' then
            if lower(name) == 'ma' or lower(name) == 'mainassist' then name = State.mainAssist end
            if T.spawnByName(name, 'pc') or T.spawnByName(name, 'pet') then
                State.chaseName = name
                Log.info('setting ChaseName to %s', name)
            end
        end
        if State.returnToCamp then State.returnToCamp = false self.cfg.ReturnToCamp = 0 end
        State.chaseLeftBehind = false
        if State.mainAssist ~= '' and T.spawnByName(State.mainAssist, 'pc') then State.campZone = T.zoneId() end
    else
        navStop()   -- a typed /chaseoff also ends the running /nav id leg
        if stickActive() then mq.cmd('/squelch /stick off') end
    end
    Log.info('>> Setting: (ChaseAssist) to (%s)', on and 'On' or 'Off')
end

M.Binds = {
    ['/camphere'] = function(self, arg)
        arg = lower(arg)
        if arg == 'off' or arg == '0' then setRTC(self, false) elseif arg == 'on' or arg == '1' then setRTC(self, true) else setRTC(self, not State.returnToCamp) end
    end,
    ['/returntocamp'] = function(self, arg) self.Binds['/camphere'](self, arg) end,
    ['/chase'] = function(self, arg)
        arg = tostring(arg or '')
        local l = lower(arg)
        if l == 'off' or l == '0' then setChase(self, false)
        elseif l == 'on' or l == '1' then setChase(self, true)
        elseif l == '' then setChase(self, not State.chaseAssist)
        else setChase(self, true, arg) end
    end,
    ['/chaseon'] = function(self, arg) setChase(self, true, arg) end,
    ['/chaseoff'] = function(self) setChase(self, false) end,
    ['/chasedistance'] = function(self, arg)
        local v = tonumber(arg)
        if v then self.cfg.ChaseDistance = v State.chaseDistance = v Config.set('General', 'ChaseDistance', v) Log.info('ChaseDistance %d', v) end
    end,
    ['/campradius'] = function(self, arg)
        local v = tonumber(arg)
        if v then self.cfg.CampRadius = v State.campRadius = v Config.set('General', 'CampRadius', v) Log.info('CampRadius %d', v) end
    end,
    ['/goback'] = function(self)
        if navActive() then Log.info('well... it looks like Navigation.Active is TRUE so we shouldnt start another') return end
        Log.info('[bind] Going back to camp...')
        mq.cmdf('/nav locxyz %d %d %d', State.campX, State.campY, State.campZ)
    end,
    ['/campfire'] = function(self) M.dropCampfire() end,
    ['/shakeloose'] = function(self, arg)
        Log.info('Stopping nav')
        navStop()
        if not lower(arg):find('keep', 1, true) and (State.chaseAssist or State.returnToCamp) then
            State.chaseAssist, State.returnToCamp = false, false
            self.cfg.ChaseAssist, self.cfg.ReturnToCamp = 0, 0
            Log.info("ShakeLoose: ChaseAssist and ReturnToCamp are now OFF - re-enable them once I'm clear.")
        end
        if stickActive() then mq.cmd('/stick off') end
        M.stuckEscape()
        local leader = T.num(function() return mq.TLO.Group.Leader.ID() end)
        if leader > 0 then mq.cmdf('/tar id %d', leader) mq.cmd('/face fast away') end
        mq.cmd('/keypress forward hold') mq.delay(300) mq.cmd('/keypress forward up')
        mq.cmd('/keypress JUMP')
    end,
}

return M
