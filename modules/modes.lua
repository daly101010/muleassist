-- modules/modes.lua: the target modes. Kill order (/killorder on the MA, forwarded by followers), mark assist
-- (the group / raid mark is the kill target), get away (the MA disengages and followers near the mob run to
-- the MA), manual mode (the MA's own target and auto-attack lead, sent to followers as /manualma every 2 s)
-- and the zone lists (MobsToProtect / MobsToIgnore / MobsToPull in KissAssist_Info.ini with /addprotect
-- /addignore /addpull, ProtectWatch), with the same commands and broadcasts as the macro.
-- Precedence as coded: get away > mark assist > manual / manual follow > kill order > the normal pick.
local mq = require('mq')
local T = require('core.tlo')
local Config = require('core.config')
local Timers = require('core.timers')
local Comms = require('core.comms')
local Log = require('core.log')
local State = require('core.state')
local Ini = require('core.ini')
local Buffcheck = require('core.buffcheck')

local M = { name = 'modes' }

M.INFO_FILE = 'KissAssist_Info.ini'
M.Settings = {
    scalars = {
        { section = 'Melee', key = 'KillOrderMaxDist', type = 'int', default = 300 },
        { section = 'Melee', key = 'MeleeDistance', type = 'int', default = 30 },
        { section = 'Melee', key = 'AssistRange', type = 'int', default = 200 },
        { section = 'Melee', key = 'StickHow', type = 'string', default = 'snaproll rear', rank = false },
        { section = 'General', key = 'CampRadius', type = 'int', default = 30 },
    },
}
M.cfg = {}
M.ko = { list = {} }        -- kill order entries { id = n } or { name = s }, in order
M.manualState = { sig = '' }
M.getAway = { src = '', leader = '', seenOff = false, mob = 0, bards = {} }
M.lists = { protect = {}, ignore = {}, pull = {}, pullSecondary = {} }
M.hooks = { isProtected = function(id) return false end, inCamp = function(id) return true end, distToCampLoc = function() return 0 end, resetDPS = function(from) end }

local MEZ_ANIM = { [26] = true, [32] = true, [71] = true, [72] = true, [17] = true, [111] = true, [129] = true }
local TANK_ROLES = { tank = true, pullertank = true, pettank = true, pullerpettank = true }
local function lower(s) return tostring(s or ''):lower() end
local function role() return lower(State.role) end
local function targetId() return T.num(function() return mq.TLO.Target.ID() end) end
local function iAmMA() return State.mainAssist ~= '' and lower(State.mainAssist) == lower(T.myName()) end
local function meCombat() return T.bool(function() return mq.TLO.Me.Combat() end) end
local function setTarget(id)
    State.myTargetId = id
    local sp = id > 0 and T.spawn(id) or nil
    State.myTargetName = sp and T.str(function() return sp.CleanName() end) or ''
end
local function disengage()
    if meCombat() then mq.cmd('/attack off') end
    if T.bool(function() return mq.TLO.Stick.Active() end) then mq.cmd('/squelch /stick off') end
end
local function isPCPet(sp) return T.str(function() return sp.Type() end) == 'Pet' and T.str(function() return sp.Master.Type() end) == 'PC' end
local function mezzedLook(sp) return MEZ_ANIM[T.num(function() return sp.Animation() end)] == true or T.num(function() return sp.CachedBuff('^Mezzed').Duration.TotalSeconds() end) > 0 end

function M:LoadSettings()
    self.cfg = Config.load(self.Settings)
    self:zoneLists()
end

-- ------------------------------------------------------------- the zone lists
local function csv(s)
    local out = {}
    s = tostring(s or '')
    local l = lower(s)
    if s == '' or l == 'null' or l:find('list up to', 1, true) or l:find('escort/quest', 1, true) then return out end
    for n in s:gmatch('[^,]+') do n = n:gsub('^%s+', ''):gsub('%s+$', '') if n ~= '' then out[#out + 1] = n end end
    return out
end
--- The zone's lists under the short zone name (the long name as a fallback), plus the global [Protect].
function M:zoneLists()
    local short = T.str(function() return mq.TLO.Zone.ShortName() end)
    local long = T.str(function() return mq.TLO.Zone.Name() end)
    local function read(key)
        local v = Ini.read(self.INFO_FILE, short, key)
        if (v == nil or v == '' or lower(v) == 'null') and long ~= '' and not long:find('[,\']') then v = Ini.read(self.INFO_FILE, long, key) end
        return csv(v)
    end
    self.lists.protect = read('MobsToProtect')
    for _, n in ipairs(csv(Ini.read(self.INFO_FILE, 'Protect', 'MobsToProtect'))) do self.lists.protect[#self.lists.protect + 1] = n end
    self.lists.ignore = read('MobsToIgnore')
    self.lists.pull = read('MobsToPull')
    self.lists.pullSecondary = read('MobsToPullSecondary')
    State.mobsToProtect, State.mobsToIgnore, State.mobsToPull, State.mobsToPullSecondary = self.lists.protect, self.lists.ignore, self.lists.pull, self.lists.pullSecondary
    mq.cmd('/squelch /alert clear 5')
    for _, n in ipairs(self.lists.protect) do mq.cmdf('/squelch /alert add 5 "=%s"', n) end
    mq.cmd('/squelch /alert clear 3')
    for _, n in ipairs(self.lists.ignore) do mq.cmdf('/squelch /alert add 3 "=%s"', n) end
    for _, n in ipairs(self.lists.protect) do mq.cmdf('/squelch /alert add 3 "=%s"', n) end
    if #self.lists.protect > 0 then Log.pm('protect: never attacking [%s] in %s', table.concat(self.lists.protect, ','), short) end
end

local function addToList(self, key, listName, arg, label)
    local id = tonumber(arg) or (arg == '' and targetId() or 0)
    local sp = id > 0 and T.spawn(id) or (arg ~= '' and T.spawnByName(arg, 'npc')) or nil
    if not sp or T.str(function() return sp.Type() end) ~= 'NPC' then Log.info('No NPC named (%s) detected. Nothing added to %s.', tostring(arg), key) return end
    local name = T.str(function() return sp.CleanName() end):gsub("'s corpse%d*$", '')
    local list = self.lists[listName]
    for _, n in ipairs(list) do if lower(n) == lower(name) then Log.info('>> %s << already on %s.', name, label) return end end
    list[#list + 1] = name
    local zone = T.str(function() return mq.TLO.Zone.ShortName() end)
    Ini.write(self.INFO_FILE, zone, key, table.concat(list, ','))
    return name
end

--- ProtectWatch (1 s): drop a protected kill target, attack off on a protected target.
function M:protectWatch()
    if #self.lists.protect == 0 or Timers.running('modes:protect') then return end
    Timers.set('modes:protect', 1000)
    local mt = State.myTargetId or 0
    if mt > 0 and self.hooks.isProtected(mt) then
        Log.pm('protect: %s is on MobsToProtect - dropping it', State.myTargetName or '')
        disengage()
        if targetId() == mt then mq.cmd('/squelch /target clear') end
        setTarget(0)
    end
    local tid = targetId()
    if meCombat() and tid > 0 and T.str(function() return mq.TLO.Target.Type() end) == 'NPC' and self.hooks.isProtected(tid) then
        Log.pm('protect: auto-attack was on %s - attack off', T.str(function() return mq.TLO.Target.CleanName() end))
        mq.cmd('/attack off')
        mq.cmd('/squelch /target clear')
    end
end

-- ------------------------------------------------------------- kill order
local function koFind(key)
    for i, e in ipairs(M.ko.list) do
        if (key.id and e.id == key.id) or (key.name and e.name and lower(e.name) == lower(key.name)) then return i end
    end
    return nil
end
function M:koClear() self.ko.list = {} State.killOrderOn = false State.killOrderTarget = 0 end
function M:koPrune()
    local kept = {}
    for _, e in ipairs(self.ko.list) do
        if e.name then kept[#kept + 1] = e
        else local sp = T.spawn(e.id) if sp and T.str(function() return sp.Type() end) == 'NPC' then kept[#kept + 1] = e end end
    end
    self.ko.list = kept
    if State.killOrderOn and #kept == 0 then
        State.killOrderOn, State.killOrderTarget = false, 0
        Comms.say('y', 'KILLORDER-> done, back to normal')
    end
end
--- KillOrderPick: resolve waiting names, then the first reachable live NPC in order.
function M:koPick()
    self:koPrune()
    State.killOrderTarget = 0
    if not State.killOrderOn or #self.ko.list == 0 then return 0 end
    local maxd = self.cfg.KillOrderMaxDist or 300
    for i, e in ipairs(self.ko.list) do
        if e.name then
            for k = 1, 5 do
                local sp = mq.TLO.NearestSpawn(k, string.format('npc radius %d =%s', maxd, e.name))
                local id = T.num(function() return sp.ID() end)
                if id == 0 then break end
                if T.str(function() return sp.Type() end) == 'NPC' and not koFind({ id = id }) then
                    self.ko.list[i] = { id = id }
                    Log.info('[KillOrder] %s is up - #%d is now %s (%d) at %d', e.name, i, T.str(function() return sp.CleanName() end), id, T.num(function() return sp.Distance() end))
                    break
                end
            end
        end
    end
    for _, e in ipairs(self.ko.list) do
        if e.id then
            local sp = T.spawn(e.id)
            if sp and T.str(function() return sp.Type() end) == 'NPC' and not isPCPet(sp) and T.num(function() return sp.Distance() end) <= maxd and not Timers.running('kounreach:' .. e.id) then
                State.killOrderTarget = e.id
                break
            end
        end
    end
    return State.killOrderTarget
end

function M:killOrder(verb, arg, ...)
    verb = lower(verb)
    if verb == '' then verb = 'list' end
    local id = tonumber(arg) or 0
    local name = nil
    if arg and arg ~= '' and id == 0 then
        local words = { arg, ... }
        local parts = {}
        for _, w in ipairs(words) do if w and w ~= '' then parts[#parts + 1] = w end end
        name = table.concat(parts, ' '):gsub('^~', '')
        if name == '' then name = nil end
    end
    if verb == 'add' and id == 0 and not name and T.str(function() return mq.TLO.Target.Type() end) == 'NPC' then id = targetId() end
    local key = name and ('~' .. name) or (id > 0 and tostring(id) or '')
    if not iAmMA() then
        Log.info('[KillOrder] %s is not the MA (MainAssist=%s) - sending "%s" to %s', T.myName(), State.mainAssist, verb, State.mainAssist)
        Comms.exec(State.mainAssist, ('/killorder ' .. verb .. ' ' .. key):gsub('%s+$', ''))
        return
    end
    local list = self.ko.list
    if verb == 'add' then
        if name then
            if koFind({ name = name }) then Log.info('[KillOrder] %s is already queued (waiting to spawn)', name) return end
            if #list >= 20 then Log.info('[KillOrder] queue is full (20)') return end
            list[#list + 1] = { name = name }
            Log.info('[KillOrder] #%d %s (waiting to spawn - picked when a live "%s" is within %d)', #list, name, name, self.cfg.KillOrderMaxDist or 300)
        else
            local sp = id > 0 and T.spawn(id) or nil
            if not sp or T.str(function() return sp.Type() end) ~= 'NPC' or isPCPet(sp) then Log.info('[KillOrder] add refused: %d is not a live NPC', id) return end
            local cname = T.str(function() return sp.CleanName() end)
            if koFind({ id = id }) then Log.info('[KillOrder] %s (%d) is already queued', cname, id) return end
            if #list >= 20 then Log.info('[KillOrder] queue is full (20)') return end
            list[#list + 1] = { id = id }
            Log.info('[KillOrder] #%d %s (%d)', #list, cname, id)
        end
    elseif verb == 'del' then
        local i = koFind(name and { name = name } or { id = id })
        if not i then return end
        table.remove(list, i)
        if State.killOrderTarget == id then State.killOrderTarget = 0 end
        Log.info('[KillOrder] removed %s', key)
    elseif verb == 'up' or verb == 'down' then
        local i = koFind(name and { name = name } or { id = id })
        if not i or #list < 2 then return end
        local j = verb == 'up' and i - 1 or i + 1
        if j < 1 or j > #list then return end
        list[i], list[j] = list[j], list[i]
    elseif verb == 'clear' then
        self:koClear()
        Log.info('[KillOrder] cleared')
    elseif verb == 'on' then
        if State.manualOn then Log.info('[KillOrder] manual mode is on - /manual off first') return end
        if State.markAssistOn then Log.info('[KillOrder] mark assist is on - /markassist off first') return end
        self:koPrune()
        if #list == 0 then Log.info('[KillOrder] nothing queued - not turning on') return end
        State.killOrderOn = true
        Comms.say('y', 'KILLORDER-> on (%d mobs)', #list)
    elseif verb == 'off' then
        State.killOrderOn, State.killOrderTarget = false, 0
        Comms.say('y', 'KILLORDER-> off')
    elseif verb == 'list' then
        Log.info('[KillOrder] %s - working %d - max dist %d', State.killOrderOn and 'ON' or 'OFF', State.killOrderTarget or 0, self.cfg.KillOrderMaxDist or 300)
        if #list == 0 then Log.info('[KillOrder] queue is empty') end
        for i, e in ipairs(list) do
            if e.name then Log.info('[KillOrder] #%d %s (waiting to spawn)', i, e.name)
            else
                local sp = T.spawn(e.id)
                Log.info('[KillOrder] #%d %s (%d) %s unreach=%s', i, sp and T.str(function() return sp.CleanName() end) or '?', e.id, sp and (T.num(function() return sp.Distance() end) .. 'ft') or 'dead', tostring(Timers.running('kounreach:' .. e.id)))
            end
        end
    else
        Log.info('[KillOrder] usage: /killorder add|del|up|down <id>, /killorder clear|on|off|list')
    end
end

-- ------------------------------------------------------------- mark assist
function M:markTargetId()
    local function live(id)
        if id == 0 then return 0 end
        local sp = T.spawn(id)
        if not sp or T.str(function() return sp.Type() end) == 'Corpse' then return 0 end
        return id
    end
    local id = live(T.num(function() return mq.TLO.Me.GroupMarkNPC(1).ID() end))
    if id == 0 then id = live(T.num(function() return mq.TLO.Me.RaidMarkNPC(State.raidMarkNum or 1).ID() end)) end
    if id == 0 then id = live(T.num(function() return mq.TLO.Me.RaidMarkNPC(1).ID() end)) end
    State.markId = id
    return id
end

function M:markValid(id)
    local sp = T.spawn(id)
    if not sp then return 'NoTarget' end
    local name = lower(T.str(function() return sp.CleanName() end))
    local onXT = false
    for i = 1, 13 do if T.num(function() return mq.TLO.Me.XTarget(i).ID() end) == id then onXT = true end end
    for _, n in ipairs(self.lists.ignore) do if name:find(lower(n), 1, true) and not onXT then return 'MobOnIgnoreList' end end
    if targetId() == id and T.num(function() return mq.TLO.Target.Charmed.ID() end) > 0 then return 'Charmed' end
    if isPCPet(sp) then return 'PlayerPet' end
    local who = name:match('^eye of (.+)$')
    if who and T.spawnByName(who, 'pc') then return 'PlayerEye' end
    local r = role()
    local ma = State.mainAssist ~= '' and T.spawnByName(State.mainAssist, lower(State.mainAssistType ~= '' and State.mainAssistType or 'pc')) or nil
    if (r == 'tank' or r == 'pullertank') and State.mobCount <= 13 and ma and T.inGroup(T.num(function() return ma.ID() end)) and not onXT then return 'NotOnXTarget' end
    local range = math.max(self.cfg.MeleeDistance or 30, T.num(function() return sp.MaxRangeTo() end) + 5)
    if State.returnToCamp and not State.pulling and TANK_ROLES[r] and require('modules.movement').distToCamp(id) > range then return 'OutofCampRange' end
    return 'VALID'
end

--- MarkAssistPick: the mark is the kill target; a mark on a player starts a get away.
function M:markAssistPick()
    local old = State.myTargetId or 0
    local mark = self:markTargetId()
    local Pet = require('modules.pet')
    if mark > 0 and T.str(function() return T.spawn(mark).Type() end) == 'PC' then
        if not State.getAwayOn and (State.mobCount > 0 or T.aggroTargetId() > 0 or old > 0) then
            self:getAwayStart('mark', T.str(function() return T.spawn(mark).CleanName() end))
        end
        return 0
    end
    if State.getAwayOn then return 0 end
    local why = 'VALID'
    local fight = State.mobCount > 0 or T.aggroTargetId() > 0
    if mark > 0 and fight then
        if targetId() ~= mark then mq.cmdf('/squelch /target id %d', mark) mq.delay(1000, function() return targetId() == mark end) Buffcheck.targetBuffWait() end
        why = self:markValid(mark)
        if why ~= 'VALID' and (self.markWarnId ~= mark or Timers.expired('modes:markwarn')) then
            self.markWarnId = mark
            Timers.set('modes:markwarn', 10000)
            Log.info('[Mark] not attacking %s (%d): %s', T.str(function() return T.spawn(mark).CleanName() end), mark, why)
        end
    end
    if mark == 0 or not fight or why ~= 'VALID' then
        if T.bool(function() return mq.TLO.Me.Pet.Combat() end) and Timers.expired('modes:petoff') then Timers.set('modes:petoff', 2000) mq.cmd('/pet back off') end
        if old == 0 and not meCombat() then return 0 end
        disengage()
        if old > 0 then setTarget(0) State.attacking = false end
        if T.str(function() return mq.TLO.Target.Type() end) == 'NPC' then mq.cmd('/squelch /target clear') end
        return 0
    end
    if old ~= mark then
        local name = T.str(function() return T.spawn(mark).CleanName() end)
        Log.info('[Mark] now %s (%d)', name, mark)
        if T.bool(function() return mq.TLO.Stick.Active() end) then mq.cmd('/squelch /stick off') end
        setTarget(mark)
        State.attacking = false
        self.hooks.resetDPS('Mark')
        if T.bool(function() return mq.TLO.Me.Pet.Combat() end) and T.num(function() return mq.TLO.Me.Pet.Target.ID() end) ~= mark then Pet.attackSafe(mark) end
        if old > 0 and not (State.charmPetIds or {})[mark] then
            local r = role()
            if r == 'tank' or r == 'pullertank' or r == 'hunter' then Comms.say('y', 'TANKING-> %s <- ID:%d', name, mark)
            elseif r == 'pettank' or r == 'pullerpettank' or r == 'hunterpettank' then Comms.say('y', '%s is TANKING-> %s <- ID:%d', T.str(function() return mq.TLO.Me.Pet.CleanName() end), name, mark) end
        end
    end
    if targetId() ~= mark then mq.cmdf('/squelch /target id %d', mark) mq.delay(1000, function() return targetId() == mark end) end
    return mark
end

-- ------------------------------------------------------------- get away
function M:getAwayStart(src, leader)
    if State.getAwayOn then return end
    local g = self.getAway
    State.getAwayOn, g.src, g.leader, g.seenOff, State.getAwayFollow = true, src, leader, false, false
    local mt = State.myTargetId or 0
    if lower(leader) ~= lower(T.myName()) and mt > 0 and T.spawn(mt) and T.num(function() return T.spawn(mt).Distance() end) <= (self.cfg.MeleeDistance or 30) * 2 then State.getAwayFollow = true end
    disengage()
    if not (lower(leader) == lower(T.myName()) and src == 'cmd') then
        if T.bool(function() return mq.TLO.Navigation.Active() end) then mq.cmd('/nav stop') end
        mq.cmd('/moveto off')
        if T.bool(function() return mq.TLO.AdvPath.Following() end) then mq.cmd('/afollow off') end
    end
    if T.num(function() return mq.TLO.Me.Casting.ID() end) > 0 and (State.getAwayFollow or not require('core.spell').facts(T.str(function() return mq.TLO.Me.Casting.Name() end)).beneficial) then mq.cmd('/stopcast') end
    if T.bool(function() return mq.TLO.Me.Pet.Combat() end) then mq.cmd('/pet back off') end
    if State.combatStart or State.attacking then require('modules.combat'):combatReset('GetAway') end
    setTarget(0)
    State.attacking = false
    if lower(leader) == lower(T.myName()) and src == 'cmd' then Log.info('[GetAway] on - disengage; re-engage by attacking (or /getaway)')
    elseif State.getAwayFollow then Log.info('[GetAway] following %s', leader)
    else Log.info('[GetAway] staying put') end
end

function M:getAwayEnd(why)
    if not State.getAwayOn then return end
    local g = self.getAway
    if g.src == 'cmd' and lower(g.leader) == lower(T.myName()) then self:getAwaySend('end') end
    if State.getAwayFollow then if T.bool(function() return mq.TLO.Navigation.Active() end) then mq.cmd('/nav stop') end mq.cmd('/moveto off') end
    State.getAwayOn, State.getAwayFollow = false, false
    g.src, g.leader, g.seenOff, g.mob = '', '', false, 0
    Log.info('[GetAway] off (%s)', why)
end

local function peersNoBards() return Comms.peersInZone(function(sp) return T.str(function() return sp.Class.ShortName() end) ~= 'BRD' end) end
--- Near-mob bards in my group / raid group back off with medley's own /mdgetaway (medley decides follow/stay
--- and never rewrites its chase settings). A mark on a player needs nothing from here: medley reads marks itself.
function M:bardsGo(leader, mobId)
    local out = {}
    if not Comms.danNet() or mobId == 0 or not T.spawn(mobId) then return out end
    local mob = T.spawn(mobId)
    local inRaid = T.num(function() return mq.TLO.Raid.Members() end) > 0
    local myRaidGroup = inRaid and T.num(function() return mq.TLO.Raid.Member(T.myName()).Group() end) or 0
    for _, peer in ipairs(Comms.peersInZone(function(sp) return T.str(function() return sp.Class.ShortName() end) == 'BRD' end)) do
        local sp = T.spawnByName(peer, 'pc')
        local ok = T.inGroup(T.num(function() return sp.ID() end)) or (inRaid and T.num(function() return mq.TLO.Raid.Member(peer).Group() end) == myRaidGroup)
        if ok then
            local dx, dy = T.num(function() return sp.X() end) - T.num(function() return mob.X() end), T.num(function() return sp.Y() end) - T.num(function() return mob.Y() end)
            if math.sqrt(dx * dx + dy * dy) <= (self.cfg.MeleeDistance or 30) * 2 then
                Comms.exec(peer, '/mdgetaway go ' .. leader)
                out[#out + 1] = peer
            end
        end
    end
    return out
end
function M:bardsEnd(list) for _, b in ipairs(list) do Comms.exec(b, '/mdgetaway end ' .. T.myName()) end end

function M:getAwaySend(verb)
    if not Comms.danNet() then return end
    for _, peer in ipairs(peersNoBards()) do Comms.exec(peer, string.format('/getaway %s %s %d', verb, T.myName(), T.zoneId())) end
    if verb == 'go' then self.getAway.bards = self:bardsGo(T.myName(), self.getAway.mob)
    else self:bardsEnd(self.getAway.bards) self.getAway.bards = {} end
end

function M:getAwayTick()
    if not State.getAwayOn then return end
    local g = self.getAway
    if g.src == 'cmd' and lower(g.leader) == lower(T.myName()) then
        local off = not meCombat() and not T.bool(function() return mq.TLO.Me.AutoFire() end)
        if off then g.seenOff = true elseif g.seenOff then self:getAwayEnd('attack') end
        return
    end
    if g.src == 'mark' then
        local mark = self:markTargetId()
        if not State.markAssistOn or mark == 0 or T.str(function() return T.spawn(mark).Type() end) ~= 'PC' then self:getAwayEnd('mark moved') return end
        local pc = T.str(function() return T.spawn(mark).CleanName() end)
        if lower(pc) ~= lower(g.leader) then
            g.leader = pc
            if lower(pc) == lower(T.myName()) then
                if State.getAwayFollow then if T.bool(function() return mq.TLO.Navigation.Active() end) then mq.cmd('/nav stop') end mq.cmd('/moveto off') end
                State.getAwayFollow = false
            end
        end
    elseif g.src == 'cmd' then
        if lower(g.leader) ~= lower(State.mainAssist) or not T.spawnByName(g.leader, 'pc') then self:getAwayEnd('MA gone') return end
    end
    disengage()
    if T.bool(function() return mq.TLO.Me.Pet.Combat() end) then mq.cmd('/pet back off') end
    if State.getAwayFollow then self:followStep() end
end

function M:followStep()
    local sp = T.spawnByName(self.getAway.leader, 'pc')
    local id = sp and T.num(function() return sp.ID() end) or 0
    if id == 0 or id == T.myId() then return end
    if T.num(function() return sp.Distance() end) <= 15 then
        if T.bool(function() return mq.TLO.Navigation.Active() end) then mq.cmd('/nav stop') end
        mq.cmd('/moveto off')
        return
    end
    if Timers.running('modes:ganav') then return end
    Timers.set('modes:ganav', 1000)
    if T.bool(function() return mq.TLO.Navigation.MeshLoaded() end) and T.bool(function() return mq.TLO.Navigation.PathExists('id ' .. id)() end) then mq.cmdf('/squelch /nav id %d distance=15', id)
    else mq.cmdf('/squelch /moveto id %d mdist 15', id) end
end

-- ------------------------------------------------------------- manual mode (the MA) and manual follow
function M:manualSend(on, target, atk)
    if not Comms.danNet() then return end
    for _, peer in ipairs(peersNoBards()) do Comms.exec(peer, string.format('/manualma %s %d %d %s %d', on and 'on' or 'off', target, atk and 1 or 0, T.myName(), T.zoneId())) end
end

function M:manualTick()
    if not State.manualOn or State.getAwayOn then return end
    if not iAmMA() then
        State.manualOn, self.manualState.sig = false, ''
        self:manualSend(false, 0, false)
        Log.info('[Manual] off - %s is no longer the MA (MainAssist=%s)', T.myName(), State.mainAssist)
        return
    end
    local tid = targetId()
    local mt = State.myTargetId or 0
    if tid > 0 and tid ~= mt then
        local sp = T.spawn(tid)
        if sp and T.str(function() return sp.Type() end) == 'NPC' and not isPCPet(sp) and not self.hooks.isProtected(tid) then
            setTarget(tid)
            mt = tid
            self.hooks.resetDPS('Manual')
            Log.info('[Manual] now %s (%d)', State.myTargetName, tid)
        end
    end
    if mt > 0 then local sp = T.spawn(mt) if not sp or T.str(function() return sp.Type() end) == 'Corpse' then setTarget(0) mt = 0 end end
    local atk = mt > 0 and meCombat()
    if atk and State.meleeOn and tid == mt then
        local st = T.num(function() return mq.TLO.Stick.StickTarget() end)
        if st ~= mt or T.str(function() return mq.TLO.Stick.Status() end):upper() == 'OFF' then
            mq.cmdf('/stick %s%s id %d', T.bool(function() return mq.TLO.Me.FeetWet() end) and 'uw ' or '', self.cfg.StickHow or 'snaproll rear', mt)
        end
    elseif not atk and T.bool(function() return mq.TLO.Stick.Active() end) then mq.cmd('/squelch /stick off') end
    local sig = string.format('1|%d|%s', mt, atk and '1' or '0')
    if sig ~= self.manualState.sig or Timers.expired('modes:manualbeat') then
        self:manualSend(true, mt, atk)
        self.manualState.sig = sig
        Timers.set('modes:manualbeat', 2000)
    end
end

function M:manual(arg)
    arg = lower(arg)
    if not iAmMA() then
        Log.info('[Manual] %s is not the MA (MainAssist=%s) - sending "%s" to %s', T.myName(), State.mainAssist, arg, State.mainAssist)
        Comms.exec(State.mainAssist, ('/manual ' .. arg):gsub('%s+$', ''))
        return
    end
    if arg == '' then arg = State.manualOn and 'off' or 'on' end
    if arg == 'on' then
        if State.markAssistOn then Log.info('[Manual] mark assist is on - /markassist off first') return end
        if State.manualOn then
            local mt = State.myTargetId or 0
            Log.info('[Manual] already on - holding %s', mt > 0 and string.format('%s (%d)', State.myTargetName or '', mt) or 'nothing yet')
            return
        end
        if State.killOrderOn then State.killOrderOn, State.killOrderTarget = false, 0 Log.info('[Manual] kill order turned off (queue kept)') end
        State.manualOn = true
        local tid = targetId()
        local sp = tid > 0 and T.spawn(tid) or nil
        if sp and T.str(function() return sp.Type() end) == 'NPC' and not isPCPet(sp) and not self.hooks.isProtected(tid) then
            setTarget(tid)
            Log.info('[Manual] on - holding %s (%d)', State.myTargetName, tid)
        else
            setTarget(0)
            Log.info('[Manual] on - no NPC targeted; the next NPC you target is the kill target')
        end
        self.hooks.resetDPS('Manual')
        self.manualState.sig = ''
        Timers.clear('modes:manualbeat')
        self:manualTick()
    elseif arg == 'off' then
        if not State.manualOn then return end
        State.manualOn, self.manualState.sig = false, ''
        self:manualSend(false, 0, false)
        Log.info('[Manual] off - auto targeting resumes')
    else Log.info('[Manual] usage: /manual [on|off]') end
end

function M:followClear() State.manualMAOn, State.manualMATarget, State.manualMAAttack = false, 0, false Timers.clear('modes:manualexpire') end
function M:followDrop()
    if (State.myTargetId or 0) == 0 and not meCombat() then return end
    disengage()
    setTarget(0)
    State.attacking = false
end
function M:manualTargetValid(id)
    local sp = id > 0 and T.spawn(id) or nil
    if not sp or T.str(function() return sp.Type() end) ~= 'NPC' or isPCPet(sp) then return false end
    if T.num(function() return sp.Distance() end) > (self.cfg.AssistRange or 200) then return false end
    if (State.charmPetIds or {})[id] then return false end
    if mezzedLook(sp) then return false end
    return true
end
function M:manualMA(on, target, attack, from, zone)
    if State.markAssistOn or iAmMA() then return end
    if lower(from) ~= lower(State.mainAssist) or (tonumber(zone) or 0) ~= T.zoneId() then return end
    if lower(on) == 'on' then
        if not State.manualMAOn then Log.info('[Manual] following %s manual mode', from) end
        State.manualMAOn, State.manualMATarget, State.manualMAAttack = true, tonumber(target) or 0, (tonumber(attack) or 0) ~= 0
        Timers.set('modes:manualexpire', 5000)
        return
    end
    if State.manualMAOn then Log.info('[Manual] %s left manual mode', from) self:followDrop() end
    self:followClear()
end
function M:followTick()
    if not State.manualMAOn then return end
    if iAmMA() then Log.info('[Manual] %s is the MA now - manual follow cleared, normal assist', T.myName()) self:followClear() return end
    if Timers.expired('modes:manualexpire') then Log.info('[Manual] lost %s heartbeat - normal assist', State.mainAssist) self:followClear() return end
    local valid = self:manualTargetValid(State.manualMATarget) and not self.hooks.isProtected(State.manualMATarget)
    if State.manualMAAttack and valid then
        if State.myTargetId ~= State.manualMATarget then setTarget(State.manualMATarget) State.attacking = false self.hooks.resetDPS('ManualFollow') end
        if targetId() ~= State.manualMATarget then mq.cmdf('/squelch /target id %d', State.manualMATarget) mq.delay(1000, function() return targetId() == State.manualMATarget end) end
        return
    end
    self:followDrop()
end

-- ------------------------------------------------------------- module hooks
function M:Init()
    local Combat = require('modules.combat')
    Combat.hooks.killOrderPick = function() return M:koPick() end
    Combat.hooks.markAssistPick = function() return M:markAssistPick() end
    Combat.hooks.manualTick = function() M:manualTick() end
    Combat.hooks.manualFollowTick = function() M:followTick() end
    self.hooks.isProtected = require('modules.pet').isProtected
    -- the macro's DPSTimerReset: the DPS timers only, never the pull / mez / charm resets
    self.hooks.resetDPS = function(from) local fn = Combat.resetHooks.dps if fn then pcall(fn, from) end end
    local Rez = require('modules.rez')
    local prev = Rez.hooks.onDeath
    Rez.hooks.onDeath = function()
        prev()
        M:koClear()
        if State.manualOn then M:manual('off') end
        M:followClear()
    end
end

function M:GiveTime(ctx)
    self:manualTick()
    self:followTick()
    self:protectWatch()
    self:getAwayTick()
end

function M:OnZone()
    self:koClear()
    if State.manualOn then self:manual('off') end
    self:followClear()
    self:zoneLists()
end

function M:Shutdown()
    local g = self.getAway
    if State.getAwayOn and g.src == 'cmd' and lower(g.leader) == lower(T.myName()) then self:getAwaySend('end') end
end

M.Binds = {
    ['/killorder'] = function(self, verb, arg, ...) self:killOrder(verb or '', arg or '', ...) end,
    ['/killordermaxdist'] = function(self, arg) local v = tonumber(arg) if v then self.cfg.KillOrderMaxDist = v Config.set('Melee', 'KillOrderMaxDist', v) Log.info('KillOrderMaxDist %d', v) end end,
    ['/markassist'] = function(self, arg, num)
        arg = lower(arg)
        if arg == '' then
            if State.markAssistOn then Log.info('[Mark] on - GroupMark 1 > RaidMark %d > RaidMark 1', State.raidMarkNum or 1) else Log.info('[Mark] off') end
            return
        end
        if arg == 'off' then
            if not State.markAssistOn then return end
            State.markAssistOn, State.markId = false, 0
            Log.info('[Mark] off - normal assist')
            return
        end
        if arg ~= 'on' then Log.info('[Mark] usage: /markassist [on [1-3] | off]') return end
        local n = 1
        if num and num ~= '' then
            n = tonumber(num)
            if not n or n < 1 or n > 3 then Log.info('[Mark] usage: /markassist [on [1-3] | off]') return end
        end
        State.raidMarkNum = n
        if State.manualOn then State.manualOn, self.manualState.sig = false, '' self:manualSend(false, 0, false) Log.info('[Mark] manual mode turned off') end
        self:followClear()
        if State.killOrderOn then State.killOrderOn, State.killOrderTarget = false, 0 Log.info('[Mark] kill order turned off (queue kept)') end
        State.markAssistOn = true
        Log.info('[Mark] on - GroupMark 1 > RaidMark %d > RaidMark 1', n)
    end,
    ['/getaway'] = function(self, verb, from, zone)
        verb = lower(verb)
        if verb == 'go' or verb == 'end' then
            if iAmMA() or lower(from) ~= lower(State.mainAssist) or (tonumber(zone) or 0) ~= T.zoneId() then return end
            if verb == 'go' then self:getAwayStart('cmd', from) elseif self.getAway.src == 'cmd' then self:getAwayEnd('released by ' .. from) end
            return
        end
        if not iAmMA() then Log.info('[GetAway] sending /getaway to %s', State.mainAssist) Comms.exec(State.mainAssist, '/getaway') return end
        if (verb == 'off') and not State.getAwayOn then return end
        if verb == 'on' and State.getAwayOn then return end
        if verb ~= '' and verb ~= 'on' and verb ~= 'off' then Log.info('[GetAway] usage: /getaway [on|off]') return end
        if State.getAwayOn then
            if self.getAway.src == 'mark' then Log.info('[GetAway] a mark on %s started this - move the mark off the player to end it', self.getAway.leader) return end
            self:getAwayEnd('/getaway')
            return
        end
        local mob = State.myTargetId or 0
        if mob == 0 and T.str(function() return mq.TLO.Target.Type() end) == 'NPC' then mob = targetId() end
        self.getAway.mob = mob
        self:getAwayStart('cmd', T.myName())
        self:getAwaySend('go')
    end,
    ['/manualma'] = function(self, on, target, attack, from, zone) self:manualMA(on or '', target, attack, from or '', zone) end,
    ['/manual'] = function(self, arg) self:manual(arg or '') end,
    ['/addprotect'] = function(self, arg)
        local name = addToList(self, 'MobsToProtect', 'protect', arg or '', 'MobsToProtect')
        if name then
            State.mobsToProtect = self.lists.protect
            mq.cmdf('/squelch /alert add 5 "=%s"', name)
            mq.cmdf('/squelch /alert add 3 "=%s"', name)
            Log.info('AddToProtect -> %s <- never attacking it in %s (other boxes: /dgge /addprotect <id>)', name, T.str(function() return mq.TLO.Zone.ShortName() end))
        end
    end,
    ['/addignore'] = function(self, arg)
        local name = addToList(self, 'MobsToIgnore', 'ignore', arg or '', 'Ignore List')
        if name then State.mobsToIgnore = self.lists.ignore mq.cmdf('/squelch /alert add 3 "=%s"', name) Log.info('AddToIgnore -> %s <- Adding to Ignore list.', name) end
    end,
    ['/addpull'] = function(self, arg)
        if not arg or arg == '' then Log.info('No NPCs detected. Nothing added to list.') return end
        local name = addToList(self, 'MobsToPull', 'pull', arg, 'Pull List')
        if name then State.mobsToPull = self.lists.pull Log.info('AddToPull-> %s <- Adding to Pull list.', name) end
    end,
}

return M
