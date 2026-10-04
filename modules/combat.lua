-- modules/combat.lua: roles (CheckRoles), the kill-target pick (Assist, ValidateTarget, StuckKillTarget,
-- MobRadar, HomogenizeMainTarget), the fight (CheckForCombat + Combat as one pass per tick), CombatReset,
-- the [Aggro] list (AggroCheck), TankAllMobs, Mash / Weave, [Bandolier], the rogue opener and backstab
-- swap, the heal-tank sync, the TANKING / TooFar / CantSee / GotHit / ImDead events and the combat binds.
--
-- Not a transliteration: the macro sat inside :Attack for the whole fight; here every tick runs one pass
-- of the loop so heals, cures, buffs and movement keep their turn. Subsystems not ported yet (DPS, AE,
-- debuffs, mez, burn, ohshit, charm, pull, kill order, mark assist, manual, get away, healer aggro) are
-- hooks in M.hooks with no-op defaults.
local mq = require('mq')
local T = require('core.tlo')
local Config = require('core.config')
local Timers = require('core.timers')
local Spell = require('core.spell')
local Cast = require('core.cast')
local Comms = require('core.comms')
local Observe = require('core.observe')
local Log = require('core.log')
local Cond = require('core.cond')
local State = require('core.state')
local Rules = require('core.buffrules')
local Lines = require('core.lines')

local M = { name = 'combat' }

M.Settings = {
    scalars = {
        { section = 'General', key = 'MainAssist', type = 'string', default = 'NULL', rank = false },
        { section = 'General', key = 'SwitchWithMA', type = 'int', default = 0 },
        { section = 'General', key = 'MezzedEngageRange', type = 'int', default = 100 },
        { section = 'General', key = 'MobZRadius', type = 'int', default = 50 },
        { section = 'General', key = 'CampZRadius', type = 'int', default = 0 },
        { section = 'General', key = 'CampRadius', type = 'int', default = 30 },
        { section = 'General', key = 'HealerDownHold', type = 'int', default = 1 },
        { section = 'General', key = 'MoveCloserIfNoLOS', type = 'int', default = 0 },
        { section = 'Melee', key = 'MeleeOn', type = 'int', default = 0 },
        { section = 'Melee', key = 'AssistAt', type = 'int', default = 95 },
        { section = 'Melee', key = 'FaceMobOn', type = 'int', default = 1 },
        { section = 'Melee', key = 'MeleeDistance', type = 'int', default = 30 },
        { section = 'Melee', key = 'AssistRange', type = 'int', default = 200 },
        { section = 'Melee', key = 'StickHow', type = 'string', default = 'snaproll rear', rank = false },
        { section = 'Melee', key = 'AutoFireOn', type = 'int', default = 0 },
        { section = 'Melee', key = 'DismountDuringFights', type = 'int', default = 0 },
        { section = 'Melee', key = 'BeforeCombat', type = 'string', default = 'Cast Before Melee Disc', rank = false },
        { section = 'Melee', key = 'TankAllMobs', type = 'int', default = 0 },
        { section = 'Melee', key = 'KillOrderMaxDist', type = 'int', default = 300 },
        { section = 'DPS', key = 'DPSOn', type = 'int', default = 0 },
        { section = 'DPS', key = 'StayAwayToCast', type = 'int', default = 0 },
        { section = 'Aggro', key = 'AggroOn', type = 'int', default = 0 },
        { section = 'Aggro', key = 'AggroCOn', type = 'int', default = 0 },
        { section = 'Bandolier', key = 'BandolierOn', type = 'int', default = 0 },
        { section = 'Pull', key = 'MaxRadius', type = 'int', default = 350 },
        { section = 'Pull', key = 'ChainPull', type = 'int', default = 0 },
        { section = 'Pull', key = 'ChainPullHP', type = 'int', default = 90 },
        { section = 'Melee', key = 'AutoHide', type = 'int', default = 1 },
        { section = 'Melee', key = 'RogueTimerEight', type = 'string', default = 'Daggerslice', rank = false },
        { section = 'Rogue', key = 'BackstabSwapOn', type = 'int', default = 0 },
        { section = 'Rogue', key = 'BackstabSwapSync', type = 'int', default = 0 },
        { section = 'Rogue', key = 'BackstabWeapon', type = 'string', default = 'NULL', rank = false },
    },
    arrays = {
        { section = 'Aggro', name = 'Aggro', size = { key = 'AggroSize', default = 10 }, cond = 'AggroCond' },
        { section = 'Bandolier', name = 'Bandolier', size = { key = 'BandolierSize', default = 2 }, cond = 'BandolierCond' },
        { section = 'DPS', name = 'DPS', size = { key = 'DPSSize', default = 40 }, cond = 'DPSCond' },
    },
}
M.cfg = {}
M.hooks = {
    killOrderPick = function() end,       -- kill order (step 6)
    markAssistPick = function() end,      -- mark assist (step 6)
    manualTick = function() end,          -- manual mode (step 6)
    manualFollowTick = function() end,    -- manual follow (step 6)
    healerDown = function() return false end,
    healerAggroSwitch = function() return 0 end,
    mez = function() end,                 -- DoMezStuff (step 5)
    ae = function() end,                  -- AECheck (step 5)
    debuff = function(targetId) end,      -- DoDebuffStuff (step 5)
    dps = function(targetId) end,         -- CombatCast (step 5)
    burnNamed = function(targetId) end,   -- NamedWatch (step 5)
    ohShit = function(from) end,          -- OhShitStuff (step 4)
    charmMaintenance = function() end,    -- (step 5)
    checkForAdds = function() end,
    onReset = function(from) end,         -- DPS timers, TTD, mez arrays, pull reset (later steps)
    custom = function() end,
    gotHit = function(mob) end,           -- healeraggro: HealerHitCheck
    ranger = function() end,              -- dps: RangerStuff (AutoFire / StayAwayToCast positioning)
    chainProbe = function(id) return false end,   -- pull: the chain-pull probe from the fight (true = leave the fight)
    aggroOffMs = function() return 2000 end,   -- healeraggro: the aggro-off hold for a feigning healer
    onDeath = function() end,             -- rez: Event_ImDead's extras
}
M.resetHooks = {}
--- Other modules register their CombatReset parts here (DPS timers, the mez table, charm pets ...).
function M.addResetHook(name, fn) M.resetHooks[name] = fn end
M.mash, M.weave = {}, {}
M.aggroLines, M.bandolier = {}, {}
M.tankAllGiveUp = {}
M.walk = nil
M.rogue = { origWeapon = '', piercerOffhand = false, swingVerb = nil, swingSeen = false, syncWarned = false }

local function lower(s) return tostring(s or ''):lower() end
local function role() return lower(State.role) end
local TANK_ROLES = { tank = true, pullertank = true, pettank = true, pullerpettank = true }
local PET_TANK_ROLES = { pettank = true, pullerpettank = true, hunterpettank = true }
local PULL_ROLES = { puller = true, pullertank = true, pullerpettank = true }
local MEZ_ANIM = { [26] = true, [32] = true, [71] = true, [72] = true, [17] = true, [111] = true, [129] = true }
local function tankRole(r) return TANK_ROLES[r or role()] == true end
local function targetId() return T.num(function() return mq.TLO.Target.ID() end) end
local function meCombat() return T.bool(function() return mq.TLO.Me.Combat() end) end
local function iAmMA() return State.mainAssist ~= '' and lower(State.mainAssist) == lower(T.myName()) end
local function maSpawn()
    if State.mainAssist == '' then return nil end
    if (State.mainAssistId or 0) > 0 then
        local s = T.spawn(State.mainAssistId)
        if s and lower(T.str(function() return s.CleanName() end)) == lower(State.mainAssist) then return s end
    end
    local kind = lower(State.mainAssistType)
    return T.spawnByName(State.mainAssist, kind ~= '' and kind or 'pc')
end
local function stand()
    if T.bool(function() return mq.TLO.Me.Standing() end) then return true end
    mq.cmd('/stand')
    mq.delay(1000, function() return T.bool(function() return mq.TLO.Me.Standing() end) end)
    return T.bool(function() return mq.TLO.Me.Standing() end)
end
local function targetSpawn(id, wait)
    if id <= 0 or targetId() == id then return targetId() == id end
    mq.cmdf('/squelch /target id %d', id)
    mq.delay(wait or 1000, function() return targetId() == id end)
    return targetId() == id
end
local function wet() return T.bool(function() return mq.TLO.Me.FeetWet() end) end
local function stickTarget() return T.num(function() return mq.TLO.Stick.StickTarget() end) end
local function stickActive() return T.bool(function() return mq.TLO.Stick.Active() end) end
local function stuckTo(id) return stickTarget() == id and T.str(function() return mq.TLO.Stick.Status() end):upper() ~= 'OFF' end
local function setTarget(id, name)
    State.myTargetId = id or 0
    State.myTargetName = name or (id and id > 0 and T.str(function() return T.spawn(id).CleanName() end) or '')
end
local Mv = nil
local function movement() if not Mv then Mv = require('modules.movement') end return Mv end
local Pet = nil
local function pet() if not Pet then Pet = require('modules.pet') end return Pet end

--- The spell / ability behind a mash or weave name is ready?
local function abilityReady(name)
    return T.bool(function() return mq.TLO.Me.AltAbilityReady(name)() end) or T.bool(function() return mq.TLO.Me.ItemReady(name)() end)
        or T.bool(function() return mq.TLO.Me.CombatAbilityReady(name)() end) or T.bool(function() return mq.TLO.Me.AbilityReady(name)() end)
        or T.bool(function() return mq.TLO.Me.SpellReady(name)() end)
end

-- ------------------------------------------------------------- settings and roles
function M:LoadSettings()
    local c = Config.load(self.Settings)
    self.cfg = c
    State.meleeOn = (c.MeleeOn or 0) ~= 0
    State.dpsOn = (c.DPSOn or 0) ~= 0
    State.chainPull = c.ChainPull or 0
    if c.MainAssist and c.MainAssist ~= '' and c.MainAssist:upper() ~= 'NULL' then State.mainAssist = c.MainAssist end
    if State.launchMainAssist then State.mainAssist = State.launchMainAssist end   -- /lua run muleassist <role> <MA>
    self:applyRole()
    -- [Aggro] Spell|PCT|<or>|Target
    self.aggroLines = {}
    for i, raw in ipairs(c.Aggro or {}) do
        local p = Lines.split(raw, '|')
        if p[1] and p[1] ~= '' and p[1]:upper() ~= 'NULL' then
            self.aggroLines[#self.aggroLines + 1] = { name = p[1], pct = tonumber(p[2]) or 0, op = p[3] or '<', target = lower(p[4] or 'mob'), cond = c.AggroCond and c.AggroCond[i] or 'TRUE' }
        end
    end
    -- [Bandolier] set names with conditions
    self.bandolier = {}
    for i, raw in ipairs(c.Bandolier or {}) do
        if raw and raw ~= '' and raw:upper() ~= 'NULL' then self.bandolier[#self.bandolier + 1] = { set = raw, cond = c.BandolierCond and c.BandolierCond[i] or 'NULL' } end
    end
    -- the |mash and |weave lines of [DPS]
    self.mash, self.weave = {}, {}
    for i, raw in ipairs(c.DPS or {}) do
        local l = lower(raw)
        local p = Lines.split(raw, '|')
        if p[1] and p[1]:upper() ~= 'NULL' and (tonumber(p[2]) or 0) ~= 0 then
            if l:find('|weave', 1, true) then self.weave[#self.weave + 1] = { name = p[1], pct = tonumber(p[2]) or 100, cond = c.DPSCond and c.DPSCond[i] or 'TRUE' }
            elseif l:find('|mash', 1, true) then self.mash[#self.mash + 1] = { name = p[1], cond = c.DPSCond and c.DPSCond[i] or 'TRUE' } end
        end
    end
    if State.mainAssist == '' then
        -- the target at start (the macro's /changema on launch), tank roles use themselves
        local tgt = mq.TLO.Target
        local ty = T.str(function() return tgt.Type() end)
        if ty == 'PC' or ty == 'Mercenary' or ty == 'Pet' then
            State.mainAssist, State.mainAssistType = T.str(function() return tgt.CleanName() end), ty
        end
    end
    if State.chaseName == '' then State.chaseName = State.mainAssist end
    self:healTankSync()
end

--- CheckRoles: what each role forces.
function M:applyRole()
    local r = role()
    local c = self.cfg
    local me = T.myName()
    local rd = { returnToCamp = nil, chaseAssist = nil, campRadiusExceed = nil }
    if r == 'tank' and State.mainAssist == '' then State.mainAssist = me State.mainAssistType = 'PC' end
    if r == 'pullertank' or r == 'hunter' or r == 'hunterpettank' or r == 'pettank' or r == 'pullerpettank' then State.mainAssist = me State.mainAssistType = 'PC' end
    if r == 'tank' or r == 'pullertank' or r == 'hunter' or r == 'hunterpettank' or r == 'pettank' or r == 'pullerpettank' then c.AssistAt = 100 end
    if r == 'puller' or r == 'pullertank' or r == 'pullerpettank' then rd.returnToCamp = true rd.chaseAssist = false rd.campRadiusExceed = (c.MaxRadius or 350) + 200 end
    if r == 'hunter' then c.StickHow = '12' rd.campRadiusExceed = (c.MaxRadius or 350) + 200 rd.returnToCamp = false end
    if r == 'hunterpettank' then rd.returnToCamp = false rd.chaseAssist = false State.mountOn = false State.petAttackRange = 115 end
    if r == 'pettank' then State.mountOn = false State.petAttackRange = 115 rd.campRadiusExceed = (c.MaxRadius or 350) + 200 end
    if r == 'pullerpettank' then c.MeleeOn = 0 State.meleeOn = false State.mountOn = false State.petAttackRange = 115 end
    if r == 'petassist' or r == 'manual' then c.MeleeOn = 0 State.meleeOn = false mq.cmd('/assist off') end
    if r == 'manual' then rd.returnToCamp = false rd.chaseAssist = false c.DPSOn = 0 State.dpsOn = false end
    if (c.AutoFireOn or 0) ~= 0 or (c.StayAwayToCast or 0) ~= 0 then
        if (c.MeleeOn or 0) ~= 0 then Log.warn('You have AutoFire and Melee on. Turning off Melee') c.MeleeOn = 0 State.meleeOn = false end
        if lower(c.StickHow) ~= 'off' then Log.warn('You have StickHow set with AutoFire. Changing it to "off"') c.StickHow = 'off' end
    end
    State.roleDefaults = rd
    State.assistAt = c.AssistAt
end

-- ------------------------------------------------------------- the heal tank (HealTankSync, 1 s)
function M:healTankSync()
    local name, kind = State.mainAssist, State.mainAssistType ~= '' and State.mainAssistType or 'PC'
    local want = nil
    local mode = lower(State.healTankMode or 'off')
    if mode == 'auto' then
        if T.num(function() return mq.TLO.Raid.Members() end) > 0 then want = T.str(function() return mq.TLO.Raid.MainAssist(1)() end) end
    elseif mode ~= 'off' and mode ~= '' then want = State.healTankMode end
    if want and want ~= '' then
        local sp = T.spawnByName(want, 'pc')
        if sp then name, kind = T.str(function() return sp.CleanName() end), 'PC'
        elseif Timers.expired('combat:healtankwarn') then
            Timers.set('combat:healtankwarn', 60000)
            Log.info('[HealTank] %s is not a PC in this zone - healing the MainAssist %s for now', want, State.mainAssist)
        end
    end
    if name ~= State.healTank or kind ~= State.healTankType then
        State.healTank, State.healTankType = name, kind
        if name ~= '' then Log.info('[HealTank] %s%s', name, lower(name) == lower(State.mainAssist) and ' (the MainAssist)' or '') end
    end
    local sp = name ~= '' and T.spawnByName(name, lower(kind)) or nil
    State.healTankId = sp and T.num(function() return sp.ID() end) or 0
end

-- ------------------------------------------------------------- MobRadar
--- MobCount: targetable NPCs with line of sight within `radius` (0.3 s cache), or 1 when a hater is on XTarget.
function M:mobRadar(radius)
    radius = radius or self.cfg.MeleeDistance or 30
    local key = 'combat:radar:' .. radius
    if Timers.running(key) then return State.mobCount end
    Timers.set(key, 300)
    local q = string.format('npc targetable los radius %d zradius %d noalert 3', radius, self.cfg.MobZRadius or 50)
    local n = T.num(function() return mq.TLO.SpawnCount(q)() end)
    if n == 0 and T.hostiles() > 0 then n = 1 end
    State.mobCount = n
    return n
end

-- ------------------------------------------------------------- ValidateTarget
local BAD_TYPES = { AURA = true, BANNER = true, CAMPFIRE = true, CORPSE = true, CHEST = true, ITEM = true, TRIGGER = true, TRAP = true, TIMER = true, MOUNT = true, MERCENARY = true }

--- Can this spawn be my kill target? Returns valid, reason.
function M:validateTarget(id)
    if State.buffMode or State.zombieMode then return false, 'BuffMode' end
    local sp = T.spawn(id)
    if not sp then return false, 'NoTarget' end
    local ty = T.str(function() return sp.Type() end)
    if BAD_TYPES[ty:upper()] then return false, 'BadTargetType' end
    if pet().isProtected(id) then return false, 'MobProtected' end
    local name = lower(T.str(function() return sp.CleanName() end))
    local onXTarget = T.onXTarget(id)
    for _, n in ipairs(State.mobsToIgnore or {}) do
        if name:find(lower(n), 1, true) and not onXTarget then return false, 'MobOnIgnoreList' end
    end
    local masterPC = T.str(function() return sp.Master.Type() end) == 'PC'
    if ty == 'Pet' and masterPC then return false, 'MobIsFriendlyPet' end
    local r = role()
    local ko = State.killOrderOn and (State.killOrderTarget or 0) == id
    local ma = maSpawn()
    local maInGroup = ma ~= nil and T.inGroup(T.num(function() return ma.ID() end))
    if r == 'tank' and not ko and State.mobCount <= 13 and maInGroup and not onXTarget then return false, 'NotOnXTarget' end
    local dist = T.num(function() return sp.Distance() end)
    local md = self.cfg.MeleeDistance or 30
    local zr = self.cfg.CampZRadius or 0
    local zRef = State.returnToCamp and State.campZ or T.num(function() return mq.TLO.Me.Z() end)
    local zBad = zr > 0 and math.abs(T.num(function() return sp.Z() end) - zRef) > zr
    if (dist > md or zBad) and not State.pulling and tankRole(r) and not ko then
        local still = T.num(function() return sp.Speed() end) == 0
        local reach = (T.num(function() return sp.MaxRangeTo() end) + T.num(function() return T.spawnByName(T.str(function() return sp.AssistName() end), 'pc') and T.spawnByName(T.str(function() return sp.AssistName() end), 'pc').Distance() or 0 end)) * 1.3
        local parked = still and ty == 'NPC' and dist <= (self.cfg.MezzedEngageRange or 100) and (MEZ_ANIM[T.num(function() return sp.Animation() end)] or T.num(function() return sp.CachedBuff('^Mezzed').Duration() end) > 0)
        if not ((still and dist <= reach) or parked) then return false, 'OutofCampRadius' end
    end
    if name:find('eye of ', 1, true) then
        local who = name:match('eye of (.+)$')
        if who and T.spawnByName(who, 'pc') then return false, 'Spell-Eye-PC' end
    end
    if ty == 'Pet' and masterPC then return false, 'PET-PC' end
    if ty == 'PC' then return false, 'PC' end
    return true, 'ok'
end

-- ------------------------------------------------------------- StuckKillTarget
--- The committed target stayed beyond MeleeDistance for 10 s while an unclaimed hater is already in camp.
function M:stuckKillTarget()
    local id = State.myTargetId or 0
    local sp = id > 0 and T.spawn(id) or nil
    local md = self.cfg.MeleeDistance or 30
    if not sp or T.str(function() return sp.Type() end) == 'Corpse' or T.num(function() return sp.Distance3D() end) <= md then
        self.stuckId = nil
        return false
    end
    if self.stuckId ~= id then self.stuckId = id Timers.set('combat:stuck', 10000) return false end
    if Timers.running('combat:stuck') then return false end
    for i = 1, 13 do
        local xt = mq.TLO.Me.XTarget(i)
        local xid = T.num(function() return xt.ID() end)
        if xid > 0 and xid ~= id and T.str(function() return xt.TargetType() end) == 'Auto Hater' then
            local s = T.spawn(xid)
            if s and T.str(function() return s.Type() end) == 'NPC' and T.num(function() return s.Master.ID() end) == 0
                and not (State.charmPetIds or {})[xid] and not Timers.running('mezclaim:' .. xid) and T.num(function() return s.Distance3D() end) <= md then
                Comms.say('y', "SWITCHING >> %s (%d away) isn't coming - %s is already in camp", T.str(function() return sp.CleanName() end), T.num(function() return sp.Distance3D() end), T.str(function() return s.CleanName() end))
                setTarget(0, '')
                State.pulled = false
                self.stuckId = nil
                if targetId() == id then mq.cmd('/squelch /target clear') end
                return true
            end
        end
    end
    Timers.set('combat:stuck', 10000)
    return false
end

-- ------------------------------------------------------------- Assist (the pick)
--- The haters on XTarget as a list of { id, slot, named, level, hp }.
local function haters()
    local out = {}
    for _, h in ipairs(T.haters()) do out[#out + 1] = { id = h.id, slot = h.slot, named = h.named } end
    return out
end

--- Rank the haters the way the MA does: named in range first, mez-immune in range, then the closest to camp
--- with the highest-level and most-hurt overrides. Pure given the candidate facts.
function M.rankCandidates(cands, meleeDistance, campRadius)
    for _, c in ipairs(cands) do
        if c.named and c.dist3d <= meleeDistance then return c.id, 'named' end
    end
    for _, c in ipairs(cands) do
        if c.mezImmune and c.dist3d <= meleeDistance then return c.id, 'mezimmune' end
    end
    local highest, highestId, hurt, hurtId, closest = 0, 0, 500, 0, nil
    for _, c in ipairs(cands) do
        if highest < c.level or c.named then highest, highestId = c.level, c.id end
        if hurt > c.hp then hurt, hurtId = c.hp, c.id end
        if not closest or closest.distToCamp >= c.distToCamp then closest = c end
    end
    if not closest then return 0, 'none' end
    local pick = closest
    local byId = {}
    for _, c in ipairs(cands) do byId[c.id] = c end
    if highestId > 0 and highest > closest.level and byId[highestId].dist <= campRadius and hurt <= closest.hp then
        pick = byId[highestId]
    elseif hurtId > 0 and hurt < closest.hp and closest.dist <= campRadius and byId[hurtId].inCamp then
        pick = byId[hurtId]
    end
    return pick.id, 'ranked'
end

function M:assist()
    local c = self.cfg
    if State.buffMode or State.zombieMode or T.bool(function() return mq.TLO.Me.Hovering() end) then return end
    if not State.meleeOn and not State.dpsOn and not State.mezOn and T.num(function() return mq.TLO.Me.Pet.ID() end) == 0 then return end
    if State.dpsPaused then return end
    if State.markAssistOn then self.hooks.markAssistPick() return end
    if State.manualOn or State.manualMAOn then return end
    if State.pulled and (State.myTargetId or 0) > 0 and iAmMA() and not State.killOrderOn then
        local sp = T.spawn(State.myTargetId)
        if not sp or T.str(function() return sp.Type() end) == 'Corpse' then
            State.pulled = false
            setTarget(0, '')
        elseif not self:stuckKillTarget() then
            return
        end
    end
    local hdNow = (c.HealerDownHold or 0) ~= 0 and self.hooks.healerDown() or false
    if self.hooks.healerAggroSwitch() ~= 0 then return end
    self:mobRadar()
    local aggro = T.aggroTargetId()
    local md = c.MeleeDistance or 30
    local cr = c.CampRadius or 30
    -- the MA's live target settles for 2 s before a follower adopts it (unless SwitchWithMA or no target)
    local maLive = T.num(function() return mq.TLO.Me.GroupAssistTarget.ID() end)
    if maLive ~= (self.maLiveId or 0) then self.maLiveId = maLive Timers.set('combat:malive', 2000) end
    local mine = T.spawn(State.myTargetId or 0)
    local settled = (c.SwitchWithMA or 0) ~= 0 or Timers.expired('combat:malive') or maLive == State.myTargetId or not mine or T.str(function() return mine.Type() end) == 'Corpse'

    local pickId = 0
    if not iAmMA() and not tankRole() then
        -- a follower copies the MA's target
        local ma = maSpawn()
        if State.mobCount > 0 or aggro > 0 then
            if ma and T.num(function() return ma.Distance() end) < 200 then
                local t = maLive
                if t == 0 then
                    mq.cmdf('/assist %s', State.mainAssist)
                    mq.delay(1000, function() return targetId() > 0 end)
                    t = targetId()
                end
                local ts = t > 0 and T.spawn(t) or nil
                local ty = ts and T.str(function() return ts.Type() end) or ''
                if ts and (ty == 'NPC' or (ty == 'Pet' and T.str(function() return ts.Master.Type() end) ~= 'PC')) and settled then pickId = t end
                if pickId == 0 and (State.myTargetId or 0) > 0 then pickId = State.myTargetId end
            elseif not ma and aggro > 0 and T.num(function() return T.spawn(aggro).Distance() end) <= cr then
                pickId = aggro
            end
        end
        if pickId == 0 then pickId = targetId() end
    else
        if State.killOrderOn then
            if (State.killOrderTarget or 0) == 0 then return end
            pickId = State.killOrderTarget
        else
            self:stuckKillTarget()
            if targetId() == T.myId() and aggro > 0 then mq.cmd('/squelch /target clear') end
            local list = haters()
            if State.mobCount == 1 and #list <= 1 and aggro > 0 then
                if hdNow and T.num(function() return T.spawn(aggro).Distance() end) > md then
                    if Timers.expired('combat:healerdown') then Timers.set('combat:healerdown', 30000) Log.pm('healer down: holding in camp, not engaging %s at %d.', T.str(function() return T.spawn(aggro).CleanName() end), T.num(function() return T.spawn(aggro).Distance() end)) end
                    return
                end
                pickId = aggro
            elseif (State.mobCount >= 2 or #list >= 2) and aggro > 0 then
                local cands = {}
                local mezFirst = nil
                for _, h in ipairs(list) do
                    local s = T.spawn(h.id)
                    if s then
                        local ty = T.str(function() return s.Type() end)
                        local dist = T.num(function() return s.Distance() end)
                        local skip = (ty == 'Pet' and T.str(function() return s.Master.Type() end) == 'PC') or (hdNow and dist > md)
                        local mez = Timers.running('mezclaim:' .. h.id) or MEZ_ANIM[T.num(function() return s.Animation() end)] == true
                        if mez and not skip then mezFirst = mezFirst or h.id skip = true end
                        if not skip then
                            cands[#cands + 1] = { id = h.id, named = h.named, level = T.num(function() return s.Level() end), hp = T.num(function() return s.PctHPs() end),
                                dist = dist, dist3d = T.num(function() return s.Distance3D() end), distToCamp = movement().distToCamp(h.id), inCamp = movement().inCamp(h.id),
                                mezImmune = (State.mezImmuneNames or {})[lower(T.str(function() return s.CleanName() end))] == true }
                        end
                    end
                end
                if #cands == 0 then pickId = mezFirst or 0 else pickId = M.rankCandidates(cands, md, cr) end
            else
                pickId = targetId()
            end
        end
    end
    -- validate
    if pickId == 0 then return end
    local ok, reason = self:validateTarget(pickId)
    if not ok then
        local cur = State.myTargetId or 0
        local curSp = cur > 0 and T.spawn(cur) or nil
        if cur > 0 and cur ~= pickId and (meCombat() or stickActive()) and curSp and T.str(function() return curSp.Type() end) ~= 'Corpse' then targetSpawn(cur) return end
        if reason == 'OutofCampRadius' and cur == pickId and (meCombat() or stickActive()) and curSp and T.str(function() return curSp.Type() end) == 'NPC'
            and T.num(function() return curSp.Distance() end) <= md * 3 then return end
        if State.combatStart or State.attacking or meCombat() or stickActive() then
            Log.info('Engaged target %s invalidated (%s) - dropping attack', T.str(function() return T.spawn(pickId) and T.spawn(pickId).CleanName() end), reason)
            self:combatReset('Invalid:' .. reason)
        else
            setTarget(0, '')
        end
        return
    end
    targetSpawn(pickId)
    setTarget(pickId)
end

--- HomogenizeMainTarget: a follower adopts the MA's kill target over DanNet (1 s throttle).
function M:homogenize()
    if not Comms.danNet() or (self.cfg.SwitchWithMA or 0) ~= 0 or State.manualMAOn or State.markAssistOn then return end
    if not Timers.expired('combat:hmt') then return end
    Timers.set('combat:hmt', 1000)
    local ma = State.mainAssist
    if ma == '' or not Comms.isPeer(ma) then return end
    -- an observer on the MA's kill target: no query, no delay (the macro's /dquery + /delay 2 stalled the loop)
    Observe.want('hmt', 'MuleAssist.Target', { ma }, 60000)
    local id = tonumber(Observe.value(ma, 'MuleAssist.Target')) or 0
    if id == 0 or id == State.myTargetId then return end
    local sp = T.spawn(id)
    if not sp or T.str(function() return sp.Type() end) ~= 'NPC' or T.num(function() return sp.Distance() end) > 200 then return end
    if MEZ_ANIM[T.num(function() return sp.Animation() end)] or (State.charmPetIds or {})[id] or pet().isProtected(id) then return end
    setTarget(id)
end

-- ------------------------------------------------------------- CANSTARTCOMBAT (pure)
--- The macro's CANSTARTCOMBAT define over plain facts.
function M.canStartCombat(f)
    if not f.targetId or f.targetId == 0 or (f.targetType ~= 'NPC' and f.targetType ~= 'Pet') then return false end
    if f.manualOn and f.meCombat then return true end
    if f.manualMAOn and f.manualMAAttack and f.targetId == f.manualMATarget then return true end
    if f.killOrderTarget and f.killOrderTarget == f.targetId and f.dist < f.meleeDistance then return true end
    if f.hp <= f.assistAt then
        if f.dist < f.meleeDistance then return true end
        if f.distToMA and f.distToMA <= f.campRadius and not f.maIsPuller then return true end
        if f.still and f.dist <= f.reach * 1.3 then return true end
    end
    return false
end

function M:canStart(id)
    local sp = T.spawn(id)
    if not sp then return false end
    local c = self.cfg
    local ma = maSpawn()
    local distToMA = nil
    if ma then
        local dx = T.num(function() return sp.X() end) - T.num(function() return ma.X() end)
        local dy = T.num(function() return sp.Y() end) - T.num(function() return ma.Y() end)
        distToMA = math.sqrt(dx * dx + dy * dy)
    end
    local helper = T.spawnByName(T.str(function() return sp.AssistName() end), 'pc')
    return M.canStartCombat({
        targetId = id, targetType = T.str(function() return sp.Type() end), hp = T.num(function() return sp.PctHPs() end),
        dist = T.num(function() return sp.Distance() end), meleeDistance = c.MeleeDistance or 30, assistAt = c.AssistAt or 95,
        campRadius = c.CampRadius or 30, distToMA = distToMA, maIsPuller = lower(State.mainAssist) == lower(T.str(function() return mq.TLO.Group.Puller.Name() end)),
        still = T.num(function() return sp.Speed() end) == 0, reach = T.num(function() return sp.MaxRangeTo() end) + (helper and T.num(function() return helper.Distance() end) or 0),
        manualOn = State.manualOn, meCombat = meCombat(), manualMAOn = State.manualMAOn, manualMAAttack = State.manualMAAttack, manualMATarget = State.manualMATarget,
        killOrderTarget = State.killOrderOn and State.killOrderTarget or nil,
    })
end

-- ------------------------------------------------------------- stick helpers
function M:stickTo(id, extra)
    local how = self.cfg.StickHow or 'snaproll rear'
    if lower(how) == 'off' or how == '0' then return end
    if wet() then
        if T.bool(function() return mq.TLO.Navigation.Active() end) then mq.cmd('/nav stop') end
        mq.cmdf('/stick %suw %s id %d', extra or '', how, id)
    else
        mq.cmdf('/stick %s%s id %d', extra or '', how, id)
    end
end

-- ------------------------------------------------------------- CombatReset
function M:combatReset(from)
    self.hooks.onReset(from)
    for _, fn in pairs(self.resetHooks) do local ok, err = pcall(fn, from) if not ok then Log.error('reset hook: %s', tostring(err)) end end
    pet().onCombatReset()
    State.combatStart = false
    State.attacking = false
    State.meleeHit = false
    self.walk = nil
    local mt = State.myTargetId or 0
    if (State.assistId or 0) == mt or not T.spawn(State.assistId or 0) then State.assistId = 0 end
    if State.returnToCamp and movement().distToCampLoc() > 10 then movement().doWeMove('CombatReset') end
    self:mobRadar()
    State.aggroTargetId2 = 0
    setTarget(0, '')
    State.pulled = false
    State.namedCheck = false
    if State.manualOn then
        if meCombat() then Log.pm('manual: combat reset from %s - keeping attack on', from) end
    else
        if meCombat() then Log.pm('combat reset from %s - attack off (xtar %d, mobs %d, aggro %d)', from, T.num(function() return mq.TLO.Me.XTarget() end), State.mobCount, T.aggroTargetId()) end
        mq.cmd('/squelch /attack off')
        mq.cmd('/squelch /target clear')
    end
    Timers.set('combat:tanktimer', 30000)
    if stickActive() and not State.chaseAssist then mq.cmd('/stick off') end
    if T.myClass() == 'ROG' then self:rogueStuff() end
end

-- ------------------------------------------------------------- [Aggro] (AggroCheck)
function M:aggroCheck(addId)
    if State.buffMode or State.zombieMode or State.aggroPaused or State.getAwayOn then return end
    if T.num(function() return mq.TLO.Me.Level() end) < 20 then return end
    if T.str(function() return mq.TLO.Target.Type() end) == 'Corpse' then return end
    local myAggro = T.num(function() return mq.TLO.Me.PctAggro() end)
    local mt = State.myTargetId or 0
    local md = self.cfg.MeleeDistance or 30
    local lastTid = 0
    for i, l in ipairs(self.aggroLines) do
        if State.getAwayOn then return end   -- taken during the previous line's cast
        if addId and i == 1 then Cast.cast(l.name, addId, 'Aggro') end
        local fire = (l.op == '<' and myAggro < l.pct) or (l.op == '>' and myAggro > l.pct)
        local condOk = false
        if fire and abilityReady(l.name) then
            -- the macro gates a line on its condition only with [Aggro] AggroCOn on
            if (self.cfg.AggroCOn or 0) == 0 then condOk = true
            elseif l.cond == nil or l.cond == 'TRUE' or l.cond == '' then condOk = true
            elseif l.cond == 'NULL' then condOk = false   -- as before: ${If[NULL,1,0]} was 0
            else condOk = Cond.ok(l.cond) end
        end
        if condOk then
            if true then
                local tid = lastTid
                local targetFar = mt > 0 and T.spawn(mt) and T.num(function() return T.spawn(mt).Distance() end) > md
                if l.target == 'null' or l.target == 'mob' or (l.target == 'inc' and not targetFar) then tid = addId or mt
                elseif l.target == 'me' then tid = T.myId()
                elseif l.target == 'ma' then local ma = maSpawn() tid = ma and T.num(function() return ma.ID() end) or 0
                elseif l.target == 'pet' then tid = T.num(function() return mq.TLO.Me.Pet.ID() end) end
                lastTid = tid
                if not (l.target == 'inc' and not targetFar) and tid > 0 then
                    local res = Cast.cast(l.name, tid, 'Aggro')
                    if res == 'CAST_SUCCESS' then
                        if l.op == '>' and Timers.expired('combat:aggrooff') and (T.bool(function() return mq.TLO.Me.Feigning() end) or T.bool(function() return mq.TLO.Me.Invis() end)) then
                            Timers.set('combat:aggrooff', self.hooks.aggroOffMs())
                        end
                        return
                    end
                end
            end
        end
    end
end

-- ------------------------------------------------------------- TankAllMobs (one add per tick)
function M:tankAllMobs()
    local r = role()
    if r ~= 'tank' and r ~= 'pullertank' and r ~= 'hunter' then return end
    if State.manualOn or State.markAssistOn then return end
    if (self.cfg.HealerDownHold or 0) ~= 0 and self.hooks.healerDown() then
        if Timers.expired('combat:healerdown') then Timers.set('combat:healerdown', 30000) Log.pm('healer down: not collecting adds (%d haters).', T.hostiles()) end
        return
    end
    local cr2 = (self.cfg.CampRadius or 30) * 2
    local me = lower(T.myName())
    for _, h in ipairs(haters()) do
        local s = T.spawn(h.id)
        if s and T.str(function() return s.Type() end) == 'NPC' and T.num(function() return s.Distance() end) <= cr2 then
            local assistName = lower(T.str(function() return s.AssistName() end))
            local helper = assistName ~= '' and T.spawnByName(assistName, 'pc') or nil
            if (State.charmPetIds or {})[h.id] then
                if assistName ~= me and T.bool(function() return mq.TLO.Me.AbilityReady('Taunt')() end) and not State.aggroPaused and T.num(function() return s.Distance() end) <= 15 then
                    targetSpawn(h.id, 500)
                    mq.cmd('/doability taunt')
                end
            elseif assistName ~= me and helper and h.id ~= (State.myTargetId or 0) and not Timers.running('combat:tankallhold:' .. h.id)
                and (T.inGroup(T.num(function() return helper.ID() end)) or T.num(function() return mq.TLO.Raid.Member(assistName).ID() end) > 0)
                and not MEZ_ANIM[T.num(function() return s.Animation() end)] and not pet().isProtected(h.id) then
                targetSpawn(h.id, 2000)
                if targetId() == h.id and T.num(function() return mq.TLO.Target.Mezzed.ID() end) == 0 and T.num(function() return mq.TLO.Target.Rooted.ID() end) == 0 then
                    if meCombat() then mq.cmd('/attack off') end
                    mq.cmd('/attack on')
                    local dist = T.num(function() return s.Distance() end)
                    if dist > 13 and dist < cr2 and T.bool(function() return mq.TLO.Navigation.MeshLoaded() end) then
                        mq.cmd('/stick off')
                        mq.cmd('/nav target')
                        mq.delay(700, function() return T.num(function() return s.Distance() end) < 12 end)
                        if T.bool(function() return mq.TLO.Navigation.Active() end) then mq.cmd('/nav stop') end
                        mq.cmdf('/stick %s', self.cfg.StickHow or 'snaproll rear')
                    end
                    mq.cmd('/face fast')
                    if T.bool(function() return mq.TLO.Me.AbilityReady('Taunt')() end) and not State.aggroPaused then mq.cmd('/doability taunt') end
                    self:aggroCheck(h.id)
                    mq.delay(1000, function() return lower(T.str(function() return s.AssistName() end)) == me or not T.spawn(h.id) end)
                    if T.spawn(h.id) and lower(T.str(function() return s.AssistName() end)) ~= me then
                        Timers.set('combat:tankallhold:' .. h.id, 15000)
                        Log.pm('tankall: gave up peeling %s (%d) off %s - one try per call for 15s', T.str(function() return s.CleanName() end), h.id, assistName)
                    end
                    mq.cmd('/stick unpause')
                    if not meCombat() then mq.cmd('/attack on') end
                    return
                end
            end
        end
    end
end

-- ------------------------------------------------------------- Mash / Weave / Bandolier
local function condTrue(cond)
    if cond == nil or cond == '' or cond == 'TRUE' or cond == 'NULL' then return true end
    return Cond.ok(cond)
end

--- WeaveStuff: the first ready weave entry whose HP gate passes is cast (returns true when one qualified).
function M:weaveStuff(tid)
    if State.buffMode or State.zombieMode or State.getAwayOn then return false end
    local sp = T.spawn(tid)
    if not sp then return false end
    for _, w in ipairs(self.weave) do
        if condTrue(w.cond) and abilityReady(w.name) and T.num(function() return sp.PctHPs() end) <= w.pct then
            local res = Cast.cast(w.name, tid, 'WeaveStuff')
            if res == 'CAST_SUCCESS' then Log.info('-- Weaved: %s', w.name) end
            return true
        end
    end
    return false
end

--- MashButtons: every ready mash entry (item, AA, disc, skill) in order.
function M:mashButtons(from)
    if State.buffMode or State.zombieMode or State.getAwayOn then return end
    self:doBandolier()
    if from ~= 'ohshit' then self.hooks.ohShit('MashButtons') end
    for _, m in ipairs(self.mash) do
        if State.getAwayOn then return end   -- taken during the previous button
        if condTrue(m.cond) then
            local name = m.name
            if T.num(function() return mq.TLO.FindItem('=' .. name).ID() end) > 0 and T.bool(function() return mq.TLO.Me.ItemReady(name)() end) then
                Cast.cast(name, targetId(), 'Mash', { kind = 'item', skipOhShit = true })
            elseif T.num(function() return mq.TLO.Me.AltAbility(name).ID() end) > 0 then
                if T.bool(function() return mq.TLO.Me.AltAbilityReady(name)() end) and lower(name) ~= 'twincast' then
                    mq.cmdf('/alt act %d', T.num(function() return mq.TLO.Me.AltAbility(name).ID() end))
                    mq.delay(200)
                end
            elseif T.num(function() return mq.TLO.Me.CombatAbility(name)() end) > 0 then
                if T.bool(function() return mq.TLO.Me.CombatAbilityReady(name)() end) then
                    local sp = mq.TLO.Spell(name)
                    local range = T.num(function() return sp.Range() end)
                    if lower(T.str(function() return sp.TargetType() end)) == 'single' and range > 0 and T.num(function() return mq.TLO.Target.Distance3D() end) >= range then
                        Log.info("I would mash >> %s << but target is out of range (%d) so I can't.", name, T.num(function() return mq.TLO.Target.Distance3D() end))
                    else
                        Cast.cast(name, targetId(), 'Mash', { kind = 'disc', skipOhShit = true })
                    end
                end
            elseif T.bool(function() return mq.TLO.Me.AbilityReady(name)() end) then
                if not Timers.running('mash:' .. name) and T.bool(function() return mq.TLO.Target.LineOfSight() end) and not T.bool(function() return mq.TLO.Me.Stunned() end) then
                    if lower(name) == 'backstab' then self:backstabSwap('in') end
                    self.tooFarAbility = false
                    mq.cmdf('/doability "%s"', name)
                    mq.delay(100)
                    mq.doevents()
                    if lower(name) == 'backstab' then self:backstabSwap('out') end
                    if self.tooFarAbility then Timers.set('mash:' .. name, 2000) end
                end
            end
        end
    end
end

--- DoBandolier: activate the first [Bandolier] set whose condition is true.
function M:doBandolier()
    if (self.cfg.BandolierOn or 0) == 0 then return end
    if Timers.running('combat:bando') then return end   -- the tick, the mash and the attack pass all call this
    Timers.set('combat:bando', 1000)
    for _, b in ipairs(self.bandolier) do
        if b.cond ~= 'NULL' and b.cond ~= '' and condTrue(b.cond) then
            local set = mq.TLO.Me.Bandolier(b.set)
            if not T.bool(function() return set.Active() end) then
                mq.cmdf('/invoke ${Me.Bandolier[%s].Activate}', b.set)
                mq.delay(1000, function() return T.bool(function() return mq.TLO.Me.Bandolier(b.set).Active() end) end)
            end
            return
        end
    end
end

-- ------------------------------------------------------------- rogue
function M:rogueStuff()
    if T.myClass() ~= 'ROG' then return end
    self:backstabSwap('out')
    if not meCombat() and (self.cfg.AutoHide or 1) ~= 0 and T.bool(function() return mq.TLO.Me.AbilityReady('Hide')() end) and T.bool(function() return mq.TLO.Me.AbilityReady('Sneak')() end) then
        if not T.bool(function() return mq.TLO.Me.Sneaking() end) then mq.cmd('/doability sneak') end
        if not T.bool(function() return mq.TLO.Me.Invis() end) then mq.cmd('/doability hide') end
    end
end

--- AssassinAttack: hide + sneak + backstab with the big disc when everything is ready.
function M:assassinAttack()
    local disc = Spell.rank(self.cfg.RogueTimerEight or 'Daggerslice')
    if not (T.bool(function() return mq.TLO.Me.AbilityReady('Hide')() end) and T.bool(function() return mq.TLO.Me.AbilityReady('Sneak')() end) and T.bool(function() return mq.TLO.Me.AbilityReady('Backstab')() end)) then return end
    if not T.bool(function() return mq.TLO.Me.CombatAbilityReady(disc)() end) then return end
    if T.num(function() return mq.TLO.Spell(disc).EnduranceCost() end) >= T.num(function() return mq.TLO.Me.CurrentEndurance() end) then return end
    local id = State.myTargetId or 0
    if id == 0 then return end
    Log.info('Im going to %s %s!', disc, T.str(function() return mq.TLO.Target.CleanName() end))
    if T.num(function() return mq.TLO.Me.ActiveDisc.ID() end) > 0 then mq.cmd('/stopdisc') end
    mq.cmd('/attack off')
    targetSpawn(id)
    mq.cmdf('/stick 5 id %d behind', id)
    mq.delay(1000, function() return T.num(function() return mq.TLO.Target.Distance() end) < 15 end)
    if not T.bool(function() return mq.TLO.Me.Sneaking() end) then mq.cmd('/doability sneak') end
    if not T.bool(function() return mq.TLO.Me.Invis() end) then mq.cmd('/doability hide') end
    mq.delay(1000)
    Cast.cast(disc, id, 'Combat', { kind = 'disc', skipOhShit = true })
    self:backstabSwap('in')
    mq.cmd('/doability backstab')
    mq.delay(300)
    self:backstabSwap('out')
end

--- RogWeaponVerb: an item Type ("1H Slashing", "Piercing" ...) to the verb EQ prints in my own hit / miss lines.
function M.weaponVerb(itemType)
    local t = tostring(itemType or '')
    if t:find('Slash') then return 'slash' end
    if t:find('Blunt') then return 'crush' end
    if t:find('Pierc') then return 'pierce' end
    if t:find('Hand to Hand') then return 'punch' end
    return nil
end

M.SWING_EVENTS = { 'ma_bsswing_slash', 'ma_bsswing_crush', 'ma_bsswing_pierce', 'ma_bsswing_punch', 'ma_bsswing_try' }

--- RogWaitPrimarySwing ([Rogue] BackstabSwapSync): hold the swap-in until the next primary swing round lands
--- (a hit or miss line with the primary weapon's verb), so a swing timer reset on the weapon change costs only
--- the swap round trip. Double / triple attacks arrive as one burst: the first line is the round. Needs a
--- different damage type in the offhand, otherwise its lines look the same and the swap runs unsynced (warned
--- once). Gives up after the weapon delay + 0.5 s, or when combat or the target ends.
function M:waitPrimarySwing()
    local r = self.rogue
    if not T.bool(function() return mq.TLO.Me.Combat() end) then return end
    local delay = T.num(function() return mq.TLO.InvSlot('mainhand').Item.ItemDelay() end)
    if delay <= 0 then return end
    local verb = M.weaponVerb(T.str(function() return mq.TLO.InvSlot('mainhand').Item.Type() end))
    if not verb then return end
    local offVerb = M.weaponVerb(T.str(function() return mq.TLO.InvSlot('offhand').Item.Type() end))
    if verb == offVerb then
        if not r.syncWarned then Log.info('BackstabSwap: sync needs a different damage type in the offhand (both %s), swapping unsynced.', verb) end
        r.syncWarned = true
        return
    end
    for _, ev in ipairs(M.SWING_EVENTS) do mq.flushevents(ev) end
    r.swingVerb, r.swingSeen = verb, false
    local deadline = T.now() + (delay + 5) * 100   -- ItemDelay is tenths of a second; +0.5 s covers message latency
    while T.now() < deadline do
        for _, ev in ipairs(M.SWING_EVENTS) do mq.doevents(ev) end
        if r.swingSeen then Log.debug('BackstabSwap: primary swing seen, swapping now') break end
        local tid = State.myTargetId or 0
        local t = tid > 0 and T.spawn(tid) or nil
        if not T.bool(function() return mq.TLO.Me.Combat() end) or not t or T.str(function() return t.Type() end) == 'Corpse' then break end
        Cast.tickDelay(100)
    end
    r.swingVerb = nil
end

--- The 1HP piercer swap around a macro-fired backstab ([Rogue] BackstabSwapOn / BackstabWeapon).
function M:backstabSwap(dir)
    local c = self.cfg
    if dir == 'in' then
        if (c.BackstabSwapOn or 0) == 0 or not c.BackstabWeapon or c.BackstabWeapon == '' or lower(c.BackstabWeapon) == 'null' then return end
        local piercer = c.BackstabWeapon
        if T.num(function() return mq.TLO.FindItem('=' .. piercer).ID() end) == 0 then return end
        local main = T.str(function() return mq.TLO.InvSlot('mainhand').Item.Name() end)
        if main == piercer then return end
        if T.num(function() return mq.TLO.Cursor.ID() end) > 0 then mq.cmd('/autoinventory') mq.delay(300) end
        if (c.BackstabSwapSync or 0) ~= 0 then self:waitPrimarySwing() end
        self.rogue.origWeapon = main
        if T.str(function() return mq.TLO.InvSlot('offhand').Item.Name() end) == piercer then
            self.rogue.piercerOffhand = true
            self:swapHands()
        else
            self:bagToMainhand(piercer, false)
        end
        if T.str(function() return mq.TLO.InvSlot('mainhand').Item.Name() end) ~= piercer then Log.warn('BackstabSwap: %s did not reach mainhand in time.', piercer) end
    else
        if self.rogue.origWeapon == '' then return end
        mq.delay(500, function() return not T.bool(function() return mq.TLO.Me.AbilityReady('Backstab')() end) end)
        local orig = self.rogue.origWeapon
        if T.str(function() return mq.TLO.InvSlot('mainhand').Item.Name() end) ~= orig and T.num(function() return mq.TLO.FindItem('=' .. orig).ID() end) > 0 then
            if T.str(function() return mq.TLO.InvSlot('offhand').Item.Name() end) == orig then self:swapHands() else self:bagToMainhand(orig, self.rogue.piercerOffhand) end
        end
        self.rogue.origWeapon = ''
        self.rogue.piercerOffhand = false
    end
end

--- Trade mainhand and offhand with cursor clicks (/exchange refuses a worn item).
function M:swapHands()
    local offId = T.num(function() return mq.TLO.InvSlot('offhand').ID() end)
    mq.cmd('/nomodkey /itemnotify offhand leftmouseup')
    mq.delay(1000, function() return T.num(function() return mq.TLO.Cursor.ID() end) > 0 end)
    if T.num(function() return mq.TLO.Cursor.ID() end) == 0 then Log.warn('BackstabSwap: could not pick up the offhand weapon.') return end
    mq.cmd('/nomodkey /itemnotify mainhand leftmouseup')
    mq.delay(1000, function() return T.num(function() return mq.TLO.Cursor.ID() end) > 0 end)
    mq.cmd('/nomodkey /itemnotify offhand leftmouseup')
    mq.delay(1000, function() return T.num(function() return mq.TLO.Cursor.ID() end) == 0 end)
    if T.num(function() return mq.TLO.Cursor.ID() end) > 0 then mq.cmd('/autoinventory') end
end

--- Bag -> mainhand with clicks; the displaced weapon goes to the offhand when asked, else back to the bag.
function M:bagToMainhand(name, displacedToOffhand)
    local it = mq.TLO.FindItem('=' .. name)
    if T.str(function() return mq.TLO.Cursor.Name() end) ~= name then
        if T.num(function() return mq.TLO.Cursor.ID() end) > 0 then mq.cmd('/autoinventory') mq.delay(300) end
        local slot = T.num(function() return it.ItemSlot() end)
        if slot < 23 then Log.warn('BackstabSwap: %s is not in a bag or on the cursor, leaving it where it is.', name) return end
        local sub = T.num(function() return it.ItemSlot2() end)
        if sub >= 0 then mq.cmdf('/nomodkey /itemnotify in pack%d %d leftmouseup', slot - 22, sub + 1) else mq.cmdf('/nomodkey /itemnotify pack%d leftmouseup', slot - 22) end
        mq.delay(1000, function() return T.str(function() return mq.TLO.Cursor.Name() end) == name end)
        if T.str(function() return mq.TLO.Cursor.Name() end) ~= name then Log.warn('BackstabSwap: could not pick up %s.', name) return end
    end
    mq.cmd('/nomodkey /itemnotify mainhand leftmouseup')
    mq.delay(1000, function() return T.str(function() return mq.TLO.InvSlot('mainhand').Item.Name() end) == name end)
    if T.num(function() return mq.TLO.Cursor.ID() end) > 0 then
        if displacedToOffhand and T.num(function() return mq.TLO.InvSlot('offhand').ID() end) == 0 then mq.cmd('/nomodkey /itemnotify offhand leftmouseup') else mq.cmd('/autoinventory') end
        mq.delay(500, function() return T.num(function() return mq.TLO.Cursor.ID() end) == 0 end)
    end
end

-- ------------------------------------------------------------- the fight
local function targetFacts(id)
    local sp = T.spawn(id)
    if not sp then return nil end
    return sp, T.str(function() return sp.Type() end), T.num(function() return sp.Distance() end), T.num(function() return sp.PctHPs() end)
end

--- A non-blocking walk toward a spawn (WalkToSpawn): issues the move once and watches it for 15 s.
function M:walkTo(id, stop, needLos)
    local sp = T.spawn(id)
    if not sp then self.walk = nil return 'gone' end
    local dist = T.num(function() return sp.Distance() end)
    local los = T.bool(function() return sp.LineOfSight() end)
    if dist <= stop and (not needLos or los) then
        if T.bool(function() return mq.TLO.Navigation.Active() end) then mq.cmd('/nav stop') end
        if T.bool(function() return mq.TLO.MoveTo.Moving() end) then mq.cmd('/moveto off') end
        self.walk = nil
        return 'arrived'
    end
    if not self.walk or self.walk.id ~= id then
        self.walk = { id = id }
        Timers.set('combat:walk', 15000)
        if T.bool(function() return mq.TLO.MoveTo.Moving() end) then mq.cmd('/moveto off') end
        if stickActive() then mq.cmd('/squelch /stick off') end
        if T.bool(function() return mq.TLO.Navigation.MeshLoaded() end) and T.bool(function() return mq.TLO.Navigation.PathExists('id ' .. id)() end) then
            mq.cmdf('/nav id %d', id)
        else
            mq.cmdf('/moveto id %d mdist 10', id)
        end
        return 'walking'
    end
    if Timers.expired('combat:walk') then
        if T.bool(function() return mq.TLO.Navigation.Active() end) then mq.cmd('/nav stop') end
        if T.bool(function() return mq.TLO.MoveTo.Moving() end) then mq.cmd('/moveto off') end
        self.walk = nil
        return 'timeout'
    end
    return 'walking'
end

--- One pass of Combat on MyTargetID. Returns true while the fight continues.
function M:combatPass()
    local c = self.cfg
    local r = role()
    if State.buffMode or State.zombieMode or State.getAwayOn then return false end
    local md = c.MeleeDistance or 30
    local cr = c.CampRadius or 30
    if PULL_ROLES[r] and movement().distToCampLoc() >= cr and State.pulling then return false end
    local id = State.myTargetId or 0
    if id == 0 then return false end
    local sp, ty, dist, hp = targetFacts(id)
    if not sp then return false end
    -- the kill-order walk-out
    if State.killOrderOn and (State.killOrderTarget or 0) == id and (State.meleeOn or ((c.AutoFireOn or 0) == 0 and (c.StayAwayToCast or 0) == 0) or hp == 100) then
        local los = T.bool(function() return sp.LineOfSight() end)
        if dist > math.floor(md * 0.8) or not los then
            local w = self:walkTo(id, math.floor(md * 0.8), true)
            if w == 'walking' then return true end
            if w == 'timeout' or w == 'gone' then
                Timers.set('kounreach:' .. id, 10000)
                Log.pm("killorder: can't reach %s (%d) - skipping it for 10s", T.str(function() return sp.CleanName() end), id)
                if State.combatStart or State.attacking then self:combatReset('KillOrderUnreach') end
                State.killOrderTarget = 0
                setTarget(0, '')
                return false
            end
        end
    end
    if State.getAwayOn then return false end   -- taken during the kill-order walk-out
    -- no line of sight
    if not T.bool(function() return sp.LineOfSight() end) then
        if not State.manualOn and (r == 'tank' or r == 'pullertank' or r == 'pullerpettank') and (c.MoveCloserIfNoLOS or 0) ~= 0 and dist < cr and dist < md
            and T.bool(function() return mq.TLO.Navigation.PathExists('id ' .. id)() end) then
            mq.cmdf('/nav id %d', id)
        elseif ((c.StayAwayToCast or 0) ~= 0 or (c.AutoFireOn or 0) ~= 0) and self:canStart(id) then
            Log.info("I'm autopositioning but I can't see the mob. Getting to main assist.")
            local ma = maSpawn()
            if ma then mq.cmdf('/nav id %d', T.num(function() return ma.ID() end)) end
        else
            return true
        end
    end
    if State.dpsPaused then return true end
    if T.num(function() return mq.TLO.Me.XTarget() end) == 0 and not (State.killOrderOn and State.killOrderTarget == id) and not State.manualOn and not (State.manualMAOn and State.manualMATarget == id) then
        if T.num(function() return mq.TLO.Target.Mezzed.ID() end) == 0 then return true end
    end
    local groupMA = T.num(function() return mq.TLO.Group.MainAssist.ID() end)
    if groupMA > 0 and groupMA ~= T.myId() and targetId() == id and T.num(function() return mq.TLO.Target.Mezzed.ID() end) > 0 and State.meleeOn then return true end
    if PET_TANK_ROLES[r] and dist < (State.petAttackRange or 0) then pet():combatPet(id) end
    if (c.AggroOn or 0) ~= 0 and not iAmMA() and r == 'tank' and dist > md then self:aggroCheck() end
    if (c.TankAllMobs or 0) ~= 0 and not iAmMA() and r == 'tank' then self:tankAllMobs() end
    if not (r == 'tank' or r == 'pullertank' or r == 'pullerpettank' or r == 'hunter') then self:homogenize() end
    -- a parked mezzed mob: walk to it
    if tankRole(r) and State.meleeOn and ty == 'NPC' and T.num(function() return sp.Speed() end) == 0 and dist > md and dist <= (c.MezzedEngageRange or 100)
        and (MEZ_ANIM[T.num(function() return sp.Animation() end)] or T.num(function() return sp.CachedBuff('^Mezzed').Duration() end) > 0) then
        if self:walkTo(id, 12, false) == 'walking' then return true end
    end
    if State.manualOn and not meCombat() then return true end
    if not self:canStart(id) then
        -- the pet still goes in at PetAssistAt when the mob is close enough
        if pet():wantsAttack(id) and (dist < md or movement().inCamp(id)) then pet():combatPet(id) end
        return true
    end
    if (c.DismountDuringFights or 0) == 1 and T.num(function() return mq.TLO.Me.Mount.ID() end) > 0 then mq.cmd('/dismount') end
    local name = T.str(function() return sp.CleanName() end)
    if not State.combatStart then
        if T.num(function() return mq.TLO.Cursor.ID() end) > 0 then mq.cmd('/autoinventory') end
        State.combatStart = true
        Log.info(' ATTACKING -> %s <- ', name)
        if State.returnToCamp and dist >= md and movement().distToCampLoc() > 10 then movement().doWeMove('Combat 2') end
        local charm = (State.charmPetIds or {})[id]
        if (r == 'tank' or r == 'pullertank' or r == 'hunter' or (r == 'manual' and groupMA == T.myId())) and not charm then
            Comms.say('y', 'TANKING-> %s <- ID:%d', name, id)
        elseif PET_TANK_ROLES[r] then
            Comms.say('y', '%s is TANKING-> %s <- ID:%d', T.str(function() return mq.TLO.Me.Pet.CleanName() end), name, id)
        end
        if (r == 'pettank' or r == 'pullerpettank') and not State.attacking and dist < cr then
            pet().attackSafe(id)
            mq.cmd('/pet swarm')
            State.attacking = true
        end
    end
    if (c.FaceMobOn or 1) ~= 0 and targetId() == id and (T.bool(function() return mq.TLO.Me.Standing() end) or T.num(function() return mq.TLO.Me.Mount.ID() end) > 0) then
        mq.cmd('/face fast nolook')
    end
    -- the melee opener
    if State.getAwayOn then return false end
    if State.meleeOn and not State.attacking and not State.manualOn then
        State.attacking = true
        if not stand() then return true end
        if State.getAwayOn then return false end
        targetSpawn(id)
        if dist <= md and not meCombat() then
            mq.cmd('/attack on')
            if T.bool(function() return mq.TLO.Navigation.Active() end) then mq.cmd('/nav stop') end
        end
        if (c.AutoFireOn or 0) == 0 then
            if r == 'tank' or r == 'pullertank' or r == 'hunter' then
                if T.bool(function() return mq.TLO.Me.AbilityReady('Taunt')() end) and not State.aggroPaused then mq.cmd('/doability Taunt') end
                if not meCombat() then mq.cmd('/attack on') end
            end
            local bc = c.BeforeCombat or ''
            if bc ~= '' and not lower(bc):find('disc', 1, true) and T.bool(function() return mq.TLO.Me.CombatAbilityReady(Spell.rank(bc))() end) then
                local res = Cast.cast(bc, id, 'Combat', { kind = 'disc' })
                if res == 'CAST_SUCCESS' then Log.info('** %s on >> %s', bc, name) end
            end
            if dist > 13 then mq.cmdf('/moveto id %d', id) end
            self:stickTo(id)
            mq.cmd('/attack on')
        end
    end
    if tankRole(r) then State.mezMobFlag = true end
    return self:attackPass(id)
end

--- One pass of the :Attack loop.
function M:attackPass(id)
    local c = self.cfg
    local r = role()
    local sp, ty, dist, hp = targetFacts(id)
    local md = c.MeleeDistance or 30
    local function fightOver()
        if not sp or ty == 'Corpse' then return true end
        if T.num(function() return mq.TLO.Me.XTarget() end) == 0 and not (State.killOrderOn and State.killOrderTarget == id) and not State.manualOn and not (State.manualMAOn and State.manualMATarget == id) then return true end
        if targetId() == id and T.num(function() return mq.TLO.Target.Charmed.ID() end) > 0 and not (State.markAssistOn and State.markId == id) then return true end
        return false
    end
    if fightOver() then self:combatReset('Combat') return false end
    if State.getAwayOn then return false end
    local noStick = lower(c.StickHow) == 'off' or c.StickHow == '0'
    if not State.manualOn and State.meleeOn and (c.AutoFireOn or 0) == 0 and (c.StayAwayToCast or 0) == 0 and not noStick
        and T.num(function() return mq.TLO.Navigation.Velocity() end) == 0 and not stuckTo(id) and movement().inCamp(id) then
        self:stickTo(id)
    end
    if T.myClass() == 'ROG' then self:assassinAttack() end
    if State.getAwayOn then return false end
    if State.combatStart and ((c.AutoFireOn or 0) ~= 0 or (c.StayAwayToCast or 0) ~= 0) and targetId() == id and T.num(function() return mq.TLO.Target.Mezzed.ID() end) == 0 then self.hooks.ranger() end
    if State.getAwayOn then return false end
    if not State.manualOn and dist > 13 and State.meleeOn and not stuckTo(id) and not meCombat() then mq.cmd('/attack on') end
    self:doBandolier()
    self.hooks.healerAggroSwitch()
    self.hooks.mez()
    self.hooks.ae()
    if (c.AggroOn or 0) ~= 0 then self:aggroCheck() end
    if (c.TankAllMobs or 0) ~= 0 then self:tankAllMobs() end
    if not (r == 'tank' or r == 'pullertank' or r == 'pullerpettank' or r == 'hunter') then self:homogenize() end
    if pet():wantsAttack(id) then pet():combatPet(id) end
    if State.getAwayOn then return false end
    if targetId() ~= id and State.meleeOn and not State.manualOn then targetSpawn(id) end
    if not State.namedCheck then
        self.hooks.burnNamed(id)
        if T.bool(function() return sp.Named() end) then State.namedCheck = true end
    end
    local chainPuller = role() == 'puller' and State.chainPull ~= 0
    if not chainPuller then self.hooks.debuff(id) end
    if State.getAwayOn then return false end   -- a /getaway taken during the debuff pass
    if fightOver() or State.dpsPaused then self:combatReset('Combat1') return false end
    if State.dpsOn and not chainPuller then
        self.hooks.dps(id)
        if State.getAwayOn then return false end
        if #self.weave > 0 and T.bool(function() return mq.TLO.Me.SpellInCooldown() end) then self:weaveStuff(id) end
        if #self.mash > 0 then self:mashButtons() end
    end
    self:combatTargetCheck()
    id = State.myTargetId or 0
    if id == 0 then return false end
    sp, ty, dist, hp = targetFacts(id)
    if not sp then return false end
    -- the attack gate
    local gate = State.attacking and State.meleeOn and (hp <= (c.AssistAt or 95) - 5 or tankRole(r) or r == 'hunter' or r == 'hunterpettank' or iAmMA()) and dist < md and (c.AutoFireOn or 0) == 0
    if gate then
        if not meCombat() then
            if not stand() then return true end
            if ty == 'NPC' then
                self:stickTo(id)
                mq.cmd('/attack on')
            end
            if not noStick and not stickActive() and dist > 13 then self:stickTo(id) end
        end
        if fightOver() then self:combatReset('Combat') return false end
        self.hooks.ohShit('Combat')
        self.hooks.charmMaintenance()
        if chainPuller then
            if self.hooks.chainProbe(id) then return false end
            self.hooks.debuff(id)
            if State.dpsOn and not State.getAwayOn then self.hooks.dps(id) end
        end
    else
        if pet():wantsAttack(id) and (dist < md or movement().inCamp(id)) then pet():combatPet(id) end
    end
    return true
end

--- CombatTargetCheck: keep Target on MyTargetID, adopt the MA's switch (SwitchWithMA), the kill order repick.
function M:combatTargetCheck()
    local c = self.cfg
    if State.markAssistOn then self.hooks.markAssistPick() end
    if State.manualOn then self.hooks.manualTick() return end
    if State.killOrderOn and Timers.expired('combat:korepick') then
        Timers.set('combat:korepick', 1000)
        self.hooks.killOrderPick()
        local ko = State.killOrderTarget or 0
        if ko > 0 and ko ~= State.myTargetId then
            local s = T.spawn(ko)
            if s and (T.num(function() return s.Distance() end) >= (c.MeleeDistance or 30) or not T.bool(function() return s.LineOfSight() end)) then
                Log.info('[KillOrder] next target %s (%d) is out of reach - leaving this fight to go get it', T.str(function() return s.CleanName() end), ko)
                if meCombat() then mq.cmd('/attack off') end
                if stickActive() then mq.cmd('/squelch /stick off') end
                Comms.zone(string.format('/maswitch %s %d clear', T.myName(), T.zoneId()))
                setTarget(0, '')
                State.attacking = false
                return
            elseif s then
                Log.info('[KillOrder] switching to %s (%d)', T.str(function() return s.CleanName() end), ko)
                M.Binds['/switchnow'](self, tostring(ko))
                return
            end
        end
    end
    local id = State.myTargetId or 0
    local sp = T.spawn(id)
    if not sp or T.str(function() return sp.Type() end) == 'Corpse' or State.dpsPaused then return end
    local groupMA = T.num(function() return mq.TLO.Group.MainAssist.ID() end)
    local ma = maSpawn()
    local gat = T.num(function() return mq.TLO.Me.GroupAssistTarget.ID() end)
    if ma and groupMA == T.num(function() return ma.ID() end) and groupMA ~= T.myId() and targetId() ~= gat and gat > 0 and id ~= gat then
        local g = T.spawn(gat)
        if g and T.str(function() return g.Type() end) == 'NPC' and targetId() ~= (State.assistId or 0) and (c.SwitchWithMA or 0) ~= 0 and not pet().isProtected(gat) then
            Log.info("My target does not match MA's. Switching to new target.")
            setTarget(gat)
            id = gat
        end
    end
    if targetId() ~= id and T.spawn(id) then targetSpawn(id) end
end

-- ------------------------------------------------------------- CheckForCombat (one pass per tick)
function M:tick()
    local c = self.cfg
    if State.buffMode then self.hooks.ohShit('BuffMode') return end
    if State.zombieMode or State.getAwayOn then return end
    local aid = State.assistId or 0
    if aid > 0 then
        local a = T.spawn(aid)
        if not a or T.str(function() return a.Type() end) == 'PC' or T.str(function() return a.Master.Type() end) == 'PC' or T.str(function() return a.Type() end) == 'Corpse' then State.assistId = 0 end
    end
    self.hooks.custom()
    self:doBandolier()
    self:mobRadar()
    local aggro = T.aggroTargetId()
    if State.killOrderOn then
        self.hooks.killOrderPick()
        if (State.killOrderTarget or 0) == 0 then
            if State.combatStart or State.pulled then self:combatReset('KillOrderIdle') end
            return
        end
    end
    local cfcManual = (State.manualOn and meCombat() and (State.myTargetId or 0) > 0) or (State.manualMAOn and State.manualMAAttack and (State.myTargetId or 0) > 0 and State.myTargetId == State.manualMATarget)
    local aggroSp = aggro > 0 and T.spawn(aggro) or nil
    local petHater = aggroSp and State.mobCount == 0 and (State.killOrderTarget or 0) == 0 and T.num(function() return aggroSp.Master.ID() end) > 0 and T.str(function() return aggroSp.Master.Type() end) == 'PC'
    local fightRoles = State.dpsOn or State.meleeOn
    if T.bool(function() return mq.TLO.Me.Hovering() end) or (State.iAmDead and aggro == 0) or (State.mobCount == 0 and aggro == 0 and (State.killOrderTarget or 0) == 0 and not cfcManual) or petHater then
        if State.combatStart or State.pulled then self:combatReset('CFC1') end
        return
    end
    self:assist()
    if State.getAwayOn then setTarget(0, '') return end
    if State.markAssistOn and (State.myTargetId or 0) == 0 then
        if State.combatStart then self:combatReset('MarkNone') end
        return
    end
    if fightRoles then
        self:combatPass()
    elseif aggro > 0 then
        if pet():wantsAttack(State.myTargetId or aggro) then pet():combatPet(State.myTargetId or aggro) end
    end
    if State.chainPull == 2 then
        if State.combatStart then self:combatReset('CheckForCombat') end
        return
    end
    -- the support block
    local r = role()
    self.hooks.mez()
    self.hooks.ohShit('CheckForCombat1')
    self.hooks.charmMaintenance()
    self.hooks.checkForAdds()
    if (r == 'tank' or r == 'pullertank') and not iAmMA() and State.chaseAssist then movement().doWeMove('CheckForCombat 1') end
    if (r == 'tank' or r == 'pullertank') and State.returnToCamp then
        local d = movement().distToCampLoc()
        if (State.mobCount == 0 and d > 5) or (State.mobCount == 1 and aggro > 0 and d > 75) then movement().doWeMove('CheckForCombat 2') end
    end
end

function M:GiveTime(ctx)
    local r = role()
    if Timers.expired('combat:healtank') then Timers.set('combat:healtank', 1000) self:healTankSync() end
    if State.chainPull == 2 or State.getAwayFollow then return end
    if meCombat() and not State.manualOn and not State.combatStart and not State.attacking then mq.cmd('/attack off') end
    self:tick()
    -- refresh the main assist id
    local ma = maSpawn()
    State.mainAssistId = ma and T.num(function() return ma.ID() end) or 0
end

-- ------------------------------------------------------------- events
function M:Init()
    local function tankTarget(_, tanker, id)
        id = tonumber(id) or 0
        if id == 0 then State.assistId = 0 return end
        if lower(tanker) == lower(State.mainAssist) then State.assistId = id end
    end
    mq.event('ma_tanktarget1', '<#1#>#*#TANKING-> #3# <- ID:#2#', tankTarget)
    -- BSSwing ([Rogue] BackstabSwapSync): my own hit / miss lines; only read while a swap-in waits for the swing
    if T.myClass() == 'ROG' then
        local function swing(line)
            local r = M.rogue
            if r.swingVerb and tostring(line or ''):find(r.swingVerb, 1, true) then r.swingSeen = true end
        end
        for i, v in ipairs({ 'slash', 'crush', 'pierce', 'punch' }) do mq.event(M.SWING_EVENTS[i], 'You ' .. v .. ' #*#', swing) end
        mq.event('ma_bsswing_try', 'You try to #*#', swing)
    end
    mq.event('ma_tanktarget2', '[ #1# (#*#) ]#*#TANKING-> #3# <- ID:#2#', tankTarget)
    mq.event('ma_tanktarget3', '#*# #1# is TANKING-> #3# <- ID:#2#', tankTarget)
    mq.event('ma_toofar', 'Your target is #*#, get closer!', function() M.queueEvent = M.queueEvent or {} M.queueEvent[#M.queueEvent + 1] = 'toofar' end)
    mq.event('ma_cantsee', 'You cannot see your target.', function() M.queueEvent = M.queueEvent or {} M.queueEvent[#M.queueEvent + 1] = 'cantsee' end)
    mq.event('ma_toofarability', '#*#You are too far away#*#', function() M.tooFarAbility = true end)
    local verbs = { 'bashes', 'crushes', 'hits', 'kicks', 'mauls', 'pierces', 'punches', 'slashes', 'bites', 'claws', 'stings', 'gores', 'smashes', 'backstabs', 'strikes', 'frenzies on', 'rampages' }
    for i, v in ipairs(verbs) do
        mq.event('ma_gothit' .. i, '#1# ' .. v .. ' YOU for #*# points of damage.#*#', function(_, mob) State.meleeHit = true M.hitBy = mob M.hooks.gotHit(mob) end)
    end
    mq.event('ma_gothit_miss', '#1# tries to #*# YOU, but #*#', function(_, mob) State.meleeHit = true M.hitBy = mob M.hooks.gotHit(mob) end)
    for i, p in ipairs({ 'Returning to Bind Location#*#', 'You died.#*#', 'You have been slain by#*#' }) do
        mq.event('ma_imdead' .. i, p, function() M.queueEvent = M.queueEvent or {} M.queueEvent[#M.queueEvent + 1] = 'dead' end)
    end
end

function M:Tick()
    local q = self.queueEvent
    if not q or #q == 0 then return end
    self.queueEvent = {}
    local id = State.myTargetId or 0
    for _, ev in ipairs(q) do
        if ev == 'toofar' and id > 0 and State.meleeOn and State.combatStart and movement().inCamp(id) then
            self:stickTo(id, '50% ')
        elseif ev == 'cantsee' and State.attacking and id > 0 then
            stand()
            mq.cmd('/squelch /face fast nolook')
            if lower(self.cfg.StickHow) == 'off' or self.cfg.StickHow == '0' then
                mq.cmdf('/stick %spin id %d', wet() and 'uw ' or '', id)
            else
                self:stickTo(id)
            end
        elseif ev == 'dead' and not State.iAmDead then
            Log.pm('I died%s', self.hitBy and (' - last hit by ' .. tostring(self.hitBy)) or '')
            State.iAmDead = true
            State.killOrderTarget = 0
            self.hooks.onDeath()
            self:combatReset('ImDead')
        end
    end
end

function M:Shutdown()
    for _, e in ipairs({ 'ma_tanktarget1', 'ma_tanktarget2', 'ma_tanktarget3', 'ma_toofar', 'ma_cantsee', 'ma_toofarability', 'ma_gothit_miss' }) do pcall(mq.unevent, e) end
    for i = 1, 17 do pcall(mq.unevent, 'ma_gothit' .. i) end
    for i = 1, 3 do pcall(mq.unevent, 'ma_imdead' .. i) end
end

function M:OnZone()
    State.assistId = 0
    if State.combatStart or State.attacking then self:combatReset('zoned') end
    if State.iAmDead and State.campZone == T.zoneId() then State.iAmDead = false end
end

-- ------------------------------------------------------------- binds
M.Binds = {
    ['/switchnow'] = function(self, arg)
        if State.manualOn then Log.info('[Manual] /switchnow is off in manual mode - click the mob') return end
        if State.markAssistOn then Log.info('[Mark] /switchnow is off in mark assist - move the mark') return end
        local new = tonumber(arg) or 0
        local tgt = targetId()
        if new == 0 and T.str(function() return mq.TLO.Target.Type() end) == 'NPC' and tgt ~= State.myTargetId then new = tgt end
        if State.mainAssistId ~= T.myId() then
            if new > 0 then Comms.exec(State.mainAssist, '/switchnow ' .. new) end
            return
        end
        if new == 0 then
            local x1, x2 = T.num(function() return mq.TLO.Me.XTarget(1).ID() end), T.num(function() return mq.TLO.Me.XTarget(2).ID() end)
            if tgt == x1 and x2 > 0 then new = x2 elseif tgt == x2 and x1 > 0 then new = x1 end
            if new == 0 then Log.info('No other hater in XTarget 1 or 2 to switch to. Not changing my target - target the mob and /switchnow.') return end
        end
        local s = T.spawn(new)
        if not s then Log.info('No valid ID. Not changing my target.') return end
        Log.info('Switching my target to %d %s', new, T.str(function() return s.CleanName() end))
        targetSpawn(new)
        setTarget(new)
        State.assistId = new
        Comms.zone(string.format('/maswitch %s %d backoff', T.myName(), T.zoneId()))
        mq.delay(300)
        self.hooks.onReset('SwitchBind')
        for _, fn in pairs(self.resetHooks) do pcall(fn, 'SwitchBind') end
        Comms.zone(string.format('/maswitch %s %d clear', T.myName(), T.zoneId()))
        mq.delay(300)
        Comms.zone(string.format('/maswitch %s %d resume', T.myName(), T.zoneId()))
        local r = role()
        if r == 'hunter' or r == 'tank' or r == 'pullertank' or r == 'pullerpettank' or r == 'hunterpettank' or r == 'pettank' then
            Comms.say('y', 'TANKING-> %s <- ID:%d', T.str(function() return s.CleanName() end), new)
        end
    end,
    ['/maswitch'] = function(self, from, zone, what)
        if State.markAssistOn or State.mainAssist == '' then return end
        if iAmMA() or lower(from) ~= lower(State.mainAssist) or (tonumber(zone) or 0) ~= T.zoneId() then return end
        what = lower(what)
        if what == 'backoff' then
            State.dpsPaused = true
            Timers.set('combat:backoff', 3000)
            State.combatStart = false
            mq.cmd('/squelch /attack off')
            if stickActive() then mq.cmd('/stick off') end
            self:combatReset('BackOff')
        elseif what == 'clear' then setTarget(0, '')
        elseif what == 'resume' then State.dpsPaused = false Timers.clear('combat:backoff') end
    end,
    ['/backoff'] = function(self, arg)
        arg = lower(arg)
        if arg == 'off' then State.dpsPaused = false Timers.clear('combat:backoff') Log.info('BackOff off') return end
        State.dpsPaused = true
        if arg == 'temp' then Timers.set('combat:backoff', 3000) else Timers.clear('combat:backoff') end
        State.combatStart = false
        mq.cmd('/squelch /attack off')
        if stickActive() then mq.cmd('/stick off') end
        self:combatReset('BackOff')
        Log.info('BackOff%s', arg == 'temp' and ' (3s)' or '')
    end,
    ['/aggrotaunt'] = function(self, arg)
        arg = lower(arg)
        if arg == 'off' then State.aggroPaused = true elseif arg == 'on' then State.aggroPaused = false else State.aggroPaused = not State.aggroPaused end
        Log.info('Aggro and taunts %s', State.aggroPaused and 'paused' or 'on')
    end,
    ['/stickhow'] = function(self, ...)
        local args = { ... }
        local all, save, words = false, false, {}
        for _, a in ipairs(args) do
            local l = lower(a)
            if l == 'all' then all = true elseif l == 'save' then save = true elseif a ~= '' then words[#words + 1] = a end
        end
        local new = table.concat(words, ' ')
        if new == '' then Log.info('[StickHow] %s (MeleeOn %d) - /stickhow [all] <args>|off [save]', self.cfg.StickHow, self.cfg.MeleeOn or 0) return end
        if all then
            Comms.zone('/stickhow ' .. new .. (save and ' save' or ''))
            for _, p in ipairs(Comms.peersInZone(function(sp) return T.str(function() return sp.Class.ShortName() end) == 'BRD' end)) do
                Comms.exec(p, '/mdstick ' .. new .. (save and ' save' or ''))
            end
        end
        if ((self.cfg.AutoFireOn or 0) ~= 0 or (self.cfg.StayAwayToCast or 0) ~= 0) and lower(new) ~= 'off' then Log.info('[StickHow] AutoFire / StayAwayToCast box keeps StickHow off (asked: %s)', new) return end
        if (role() == 'hunter' or role() == 'hunterpettank') and new ~= '12' then Log.info('[StickHow] hunter role keeps its own StickHow 12 (asked: %s)', new) return end
        self.cfg.StickHow = new
        Log.info('[StickHow] now "%s"%s', new, save and ' (saved)' or '')
        if save then Config.set('Melee', 'StickHow', new) end
        if State.meleeOn and stickActive() and (State.myTargetId or 0) > 0 and stickTarget() == State.myTargetId and not State.getAwayOn then mq.cmd('/squelch /stick off') end
    end,
    ['/assistat'] = function(self, arg) local v = tonumber(arg) if v then self.cfg.AssistAt = v State.assistAt = v Config.set('Melee', 'AssistAt', v) Log.info('AssistAt %d', v) end end,
    ['/meleedistance'] = function(self, arg) local v = tonumber(arg) if v then self.cfg.MeleeDistance = v Config.set('Melee', 'MeleeDistance', v) Log.info('MeleeDistance %d', v) end end,
    ['/meleeon'] = function(self, arg)
        local v = tonumber(arg)
        if arg == 'on' then v = 1 elseif arg == 'off' then v = 0 end
        if v == nil then v = (self.cfg.MeleeOn or 0) == 0 and 1 or 0 end
        self.cfg.MeleeOn = v
        State.meleeOn = v ~= 0
        if v == 0 then mq.cmd('/assist off') if stickActive() and not State.chaseAssist then mq.cmd('/squelch /stick off') end end
        Log.info('MeleeOn %d', v)
    end,
    ['/autofireon'] = function(self, arg)
        local v = tonumber(arg)
        if v == nil then v = (self.cfg.AutoFireOn or 0) == 0 and 1 or 0 end
        self.cfg.AutoFireOn = v
        Log.info('AutoFireOn %d', v)
    end,
}

return M
