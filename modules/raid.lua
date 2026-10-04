-- modules/raid.lua: raid control. /changema with the out-of-group XTarHeal seating, the group-window MA tag
-- (AssignGroupRole), AggroRaidTick (WAR/SHD/PAL pause their aggro tools in a raid), XTarTanks (CLR/SHM/DRU
-- pin the raid's WAR/SHD/PAL outside their group to free XTarget slots and heal them) and /raidmode (mark
-- assist + XTarTanks + aggro paused + AE off, restored by /raidmode off), with the same keys as the macro.
local mq = require('mq')
local T = require('core.tlo')
local Config = require('core.config')
local Timers = require('core.timers')
local Comms = require('core.comms')
local Log = require('core.log')
local State = require('core.state')

local M = { name = 'raid' }

M.Settings = {
    scalars = {
        { section = 'Heals', key = 'XTarHeal', type = 'string', default = '0', rank = false },
        { section = 'Heals', key = 'XTarTanks', type = 'int', default = 0 },
    },
}
M.cfg = {}
M.pins = {}             -- XTarTanks pins: { slot = n, name = s, kind = 'E' | 'A' } (XTarTankOwned)
M.aggroRaid = { seen = false, auto = false, armed = false }
M.saved = nil           -- /raidmode snapshot { mark, markNum, xtarTanks, aggroPaused, aeOn }
M.hooks = { markAssist = function(onOff, n) end, xtarHealSet = function(list) end }

local HEALERS = { CLR = true, SHM = true, DRU = true }
local TANKS = { WAR = true, PAL = true, SHD = true }
local function lower(s) return tostring(s or ''):lower() end
local function iAmMA() return State.mainAssist ~= '' and lower(State.mainAssist) == lower(T.myName()) end
local function raidMembers() return T.num(function() return mq.TLO.Raid.Members() end) end
local function slotList(s)
    local out = {}
    if tonumber(s) == 0 then return out end
    for n in tostring(s or ''):gmatch('[^|]+') do local v = tonumber(n) if v then out[#out + 1] = v end end
    return out
end
local function pinsString()
    local out = {}
    for _, p in ipairs(M.pins) do out[#out + 1] = string.format('%d:%s:%s', p.slot, p.name, p.kind) end
    return table.concat(out, '|')
end

function M:LoadSettings()
    self.cfg = Config.load(self.Settings)
    self.base = slotList(self.cfg.XTarHeal)
    State.xtarTanks = (self.cfg.XTarTanks or 0) ~= 0
end

-- ------------------------------------------------------------- /changema
--- Bind_AssignMainAssist: the new MA from a name or the target, the OOG seating in a free XTarHeal slot.
function M:changeMA(arg)
    local name, ty = nil, nil
    if arg and arg ~= '' then
        local sp = T.spawnByName(arg, 'pc') or T.spawnByName(arg, 'pet') or T.spawnByName(arg)
        if not sp then Log.warn('/changema: no spawn named %s in this zone', arg) return end
        name, ty = T.str(function() return sp.CleanName() end), T.str(function() return sp.Type() end)
    else
        local t = mq.TLO.Target
        local tt = T.str(function() return t.Type() end)
        if tt == 'PC' or tt == 'Mercenary' or tt == 'Pet' then name, ty = T.str(function() return t.CleanName() end), tt end
    end
    if not name then Log.warn('/changema: target a PC, mercenary or pet, or give a name') return end
    local prev = State.mainAssist
    Log.info('Changing MA to %s', name)
    State.mainAssist, State.mainAssistType = name, ty
    State.chaseName = name
    local sp = T.spawnByName(name, lower(ty))
    State.mainAssistId = sp and T.num(function() return sp.ID() end) or 0
    -- an out-of-group MA takes a free XTarHeal seat (never a pin)
    if State.mainAssistId > 0 and State.mainAssistId ~= T.myId() and not T.inGroup(State.mainAssistId) and #self.base > 0 then
        local seated = false
        for _, s in ipairs(slotList(State.xtarHealLive or self.cfg.XTarHeal)) do
            if T.num(function() return mq.TLO.Me.XTarget(s).ID() end) == State.mainAssistId then seated = true end
        end
        if not seated then
            local pick = 0
            for _, s in ipairs(self.base) do
                local xt = mq.TLO.Me.XTarget(s)
                if T.num(function() return xt.ID() end) == State.mainAssistId then pick = -1 break end
                local tt = T.str(function() return xt.TargetType() end)
                if pick == 0 and T.num(function() return xt.ID() end) == 0 and tt ~= 'Specific PC' then pick = s end
                if prev ~= '' and prev ~= name and tt == 'Specific PC' and lower(T.str(function() return xt.Name() end)) == lower(prev) then pick = s break end
            end
            if pick > 0 then mq.cmdf('/xtarget set %d %s', pick, name)
            elseif pick == 0 then Log.info('No free XTarHeal slot (%s) for out-of-group MA %s - clear one and /changema to seat them.', self.cfg.XTarHeal, name) end
        end
    end
    require('modules.combat'):healTankSync()
end

--- The group-window MA tag when I lead the group (AssignGroupRole).
function M:tagGroupMA()
    if T.groupCount() == 0 or State.mainAssist == '' then return end
    local leader = T.str(function() return mq.TLO.Group.Leader() end)
    if lower(leader) ~= lower(T.myName()) then return end
    local ma = T.spawnByName(State.mainAssist, lower(State.mainAssistType ~= '' and State.mainAssistType or 'pc'))
    local tagged = T.str(function() return mq.TLO.Group.MainAssist.Name() end)
    local inGroup = ma and T.inGroup(T.num(function() return ma.ID() end))
    local who = State.mainAssist
    if ma and T.str(function() return ma.Type() end) == 'Pet' then
        local master = T.str(function() return ma.Master.CleanName() end)
        if master ~= '' and T.inGroup(T.num(function() return ma.Master.ID() end)) then inGroup, who = true, master end
    end
    if inGroup then
        if tagged ~= '' and lower(tagged) ~= lower(who) then mq.cmdf('/grouproles unset "%s" 2', tagged) end
        if tagged == '' or lower(tagged) ~= lower(who) then
            Comms.say('r', 'Assigning %s as Main Assist in Group Window', who)
            mq.cmdf('/grouproles set "%s" 2', who)
        end
    elseif tagged ~= '' and lower(tagged) ~= lower(who) then
        mq.cmdf('/grouproles unset "%s" 2', tagged)
    end
end

-- ------------------------------------------------------------- AggroRaidTick
function M:aggroRaidTick()
    if not TANKS[T.myClass()] then return end
    local a = self.aggroRaid
    if raidMembers() > 0 then
        a.armed = false
        if a.seen then return end
        a.seen = true
        if not State.aggroPaused then
            State.aggroPaused, a.auto = true, true
            Log.info('[Aggro] in a raid - [Aggro], [HealerAggro] and Taunt paused. /aggrotaunt on to use them')
        end
        return
    end
    if not a.seen then return end
    if not a.armed then a.armed = true Timers.set('raid:gone', 10000) return end
    if Timers.running('raid:gone') then return end
    a.seen, a.armed = false, false
    if a.auto and State.aggroPaused then
        State.aggroPaused = false
        Log.info('[Aggro] left the raid - [Aggro], [HealerAggro] and Taunt back on')
    end
    a.auto = false
end

-- ------------------------------------------------------------- XTarTanks
local function wanted(name)
    if raidMembers() == 0 or name == '' or lower(name) == lower(T.myName()) then return false end
    local cls = T.str(function() return mq.TLO.Raid.Member(name).Class.ShortName() end)
    if not TANKS[cls] then return false end
    if T.num(function() return mq.TLO.Group.Member(name).ID() end) > 0 then return false end
    return true
end
local function unpin(p)
    local xt = mq.TLO.Me.XTarget(p.slot)
    if p.slot == 0 or T.str(function() return xt.TargetType() end) ~= 'Specific PC' then return end
    local n = T.str(function() return xt.Name() end)
    if n ~= '' and lower(n) ~= lower(p.name) then return end
    Log.info('[XTarTanks] slot %d released (%s)%s', p.slot, p.name, p.kind == 'A' and ' - back to Auto Hater' or '')
    if p.kind == 'A' then mq.cmdf('/xtarget set %d autohater', p.slot) else mq.cmdf('/xtarget remove %d', p.slot) end
end
local function inBase(slot) for _, s in ipairs(M.base) do if s == slot then return true end end return false end

function M:applyHealList(list)
    local s = #list > 0 and table.concat(list, '|') or '0'
    if s ~= (State.xtarHealLive or table.concat(self.base, '|')) and not (s == '0' and #self.base == 0 and State.xtarHealLive == nil) then
        State.xtarHealLive = s
        self.hooks.xtarHealSet(s)
        Log.info('[XTarTanks] healing XTarget slots %s', s)
    end
end

function M:release()
    for _, p in ipairs(self.pins) do unpin(p) end
    if #self.pins > 0 then Log.info('[XTarTanks] released slots (%s)', pinsString()) end
    self.pins = {}
    State.xtarTankOwned = ''
    local base = #self.base > 0 and table.concat(self.base, '|') or '0'
    if State.xtarHealLive and State.xtarHealLive ~= base then
        State.xtarHealLive = base
        self.hooks.xtarHealSet(base)
        Log.info('[XTarTanks] healing XTarget slots %s', base)
    end
end

function M:xtarTanksTick()
    if Timers.running('raid:xtartanks') then return end
    Timers.set('raid:xtartanks', 10000)
    if not State.xtarTanks or raidMembers() == 0 or not HEALERS[T.myClass()] then
        if #self.pins > 0 or (State.xtarHealLive and State.xtarHealLive ~= (#self.base > 0 and table.concat(self.base, '|') or '0')) then self:release() end
        return
    end
    local keep, free, used, adopt = {}, {}, {}, {}
    -- step 1: my existing pins
    for _, p in ipairs(self.pins) do
        local xt = mq.TLO.Me.XTarget(p.slot)
        if p.slot > 0 and T.str(function() return xt.TargetType() end) == 'Specific PC' then
            local n = T.str(function() return xt.Name() end)
            if n == '' or lower(n) == lower(p.name) then
                if wanted(p.name) and T.spawnByName(p.name, 'pc') then keep[#keep + 1] = p else free[#free + 1] = p end
                used[p.slot] = true
            end
        end
    end
    -- step 2: seat wanted tanks, WAR then PAL then SHD
    local total = T.num(function() return mq.TLO.Me.XTargetSlots() end)
    if total == 0 then total = 13 end
    for _, cls in ipairs({ 'WAR', 'PAL', 'SHD' }) do
        for i = 1, raidMembers() do
            local r = mq.TLO.Raid.Member(i)
            local name = T.str(function() return r.Name() end)
            if name ~= '' and wanted(name) and T.str(function() return r.Class.ShortName() end) == cls and T.spawnByName(name, 'pc') then
                local seatedAt = 0
                for s = 1, total do
                    local xt = mq.TLO.Me.XTarget(s)
                    if T.str(function() return xt.TargetType() end) == 'Specific PC' and lower(T.str(function() return xt.Name() end)) == lower(name) then seatedAt = s end
                end
                local already = false
                for _, p in ipairs(keep) do if lower(p.name) == lower(name) then already = true end end
                if seatedAt > 0 then
                    if not already and not inBase(seatedAt) and not used[seatedAt] then adopt[#adopt + 1] = seatedAt used[seatedAt] = true end
                elseif not already then
                    local slot, kind = 0, 'E'
                    if #free > 0 then local f = table.remove(free, 1) slot, kind = f.slot, f.kind
                    else
                        for s = 1, total do
                            if slot == 0 and T.str(function() return mq.TLO.Me.XTarget(s).TargetType() end) == 'Empty Target' and not inBase(s) and not used[s] then slot, kind = s, 'E' end
                        end
                        if slot == 0 then
                            for s = total, 1, -1 do
                                local xt = mq.TLO.Me.XTarget(s)
                                if slot == 0 and T.str(function() return xt.TargetType() end) == 'Auto Hater' and T.num(function() return xt.ID() end) == 0 and not inBase(s) and not used[s] then slot, kind = s, 'A' end
                            end
                        end
                    end
                    if slot == 0 then
                        if Timers.expired('raid:xtwarn') then Timers.set('raid:xtwarn', 60000) Log.info('[XTarTanks] no free XTarget slot for %s (no Empty Target or empty Auto Hater slot)', name) end
                    else
                        mq.cmdf('/xtarget set %d %s', slot, name)
                        Log.info('[XTarTanks] slot %d <- %s (%s)', slot, name, cls)
                        keep[#keep + 1] = { slot = slot, name = name, kind = kind }
                        used[slot] = true
                    end
                end
            end
        end
    end
    for _, p in ipairs(free) do unpin(p) end
    self.pins = keep
    State.xtarTankOwned = pinsString()
    local list = {}
    for _, s in ipairs(self.base) do list[#list + 1] = s end
    for _, p in ipairs(keep) do list[#list + 1] = p.slot end
    for _, s in ipairs(adopt) do list[#list + 1] = s end
    self:applyHealList(list)
end

-- ------------------------------------------------------------- /raidmode
function M:raidMode(a, b, c)
    a, b = lower(a), lower(b)
    local cls = T.myClass()
    if a == '' then
        Log.info('[Raid] %s - mark %s, XTarTanks %s, aggro %s, AE %s', State.raidModeOn and 'on' or 'off', State.markAssistOn and ('on (RaidMark ' .. (State.raidMarkNum or 1) .. ')') or 'off',
            State.xtarTanks and 'on' or 'off', State.aggroPaused and 'paused' or 'on', State.aeOn and 'on' or 'off')
        return
    end
    if a == 'all' then
        if b ~= 'on' and b ~= 'off' then Log.info('[Raid] usage: /raidmode [on [1-3] | off | all on [1-3] | all off]') return end
        local n = tonumber(c)
        if c and c ~= '' and (not n or n < 1 or n > 3) then Log.info('[Raid] usage: /raidmode [on [1-3] | off | all on [1-3] | all off]') return end
        self:raidMode(b, c or '')
        if not Comms.danNet() then Log.info('[Raid] DanNet is off - applied here only') return end
        for _, peer in ipairs(Comms.peersInZone(function(sp) return T.str(function() return sp.Class.ShortName() end) ~= 'BRD' end)) do
            Comms.exec(peer, string.format('/raidmode %s %s', b, c or ''))
        end
        Log.info('[Raid] sent /raidmode %s to the muleassist boxes in %s', b, T.str(function() return mq.TLO.Zone.ShortName() end))
        return
    end
    if a == 'off' then
        if not State.raidModeOn then Log.info('[Raid] already off') return end
        State.raidModeOn = false
        local s = self.saved or {}
        if s.mark then
            if not State.markAssistOn or State.raidMarkNum ~= s.markNum then self.hooks.markAssist('on', s.markNum) end
        elseif State.markAssistOn then self.hooks.markAssist('off') end
        if HEALERS[cls] then
            if s.xtarTanks and not State.xtarTanks then self.Binds['/xtartanks'](self, 'on')
            elseif not s.xtarTanks and State.xtarTanks then self.Binds['/xtartanks'](self, 'off') end
        end
        if raidMembers() > 0 and TANKS[cls] then State.aggroPaused, self.aggroRaid.auto = true, true else State.aggroPaused = s.aggroPaused or false end
        State.aeOn = s.aeOn or false
        Log.info('[Raid] off - mark %s, XTarTanks %s, aggro %s, AE %s', State.markAssistOn and 'on' or 'off', State.xtarTanks and 'on' or 'off', State.aggroPaused and 'paused' or 'on', State.aeOn and 'on' or 'off')
        return
    end
    if a ~= 'on' then Log.info('[Raid] usage: /raidmode [on [1-3] | off | all on [1-3] | all off]') return end
    local n = 1
    if b ~= '' then
        n = tonumber(b)
        if not n or n < 1 or n > 3 then Log.info('[Raid] usage: /raidmode [on [1-3] | off | all on [1-3] | all off]') return end
    elseif State.markAssistOn then n = State.raidMarkNum or 1 end
    if not State.raidModeOn then
        self.saved = { mark = State.markAssistOn, markNum = State.raidMarkNum or 1, xtarTanks = State.xtarTanks, aggroPaused = (not self.aggroRaid.auto) and State.aggroPaused or false, aeOn = State.aeOn }
    end
    State.raidModeOn = true
    self.hooks.markAssist('on', n)
    if HEALERS[cls] and not State.xtarTanks then self.Binds['/xtartanks'](self, 'on') end
    if TANKS[cls] then
        if not State.aggroPaused then self.aggroRaid.auto = true end
        State.aggroPaused = true
    end
    State.aeOn = false
    if raidMembers() == 0 then Log.info('[Raid] not in a raid yet - mark assist waits for a mark, XTarTanks for the raid') end
    Log.info('[Raid] on - RaidMark %d%s%s + AE off. /raidmode off restores', n, HEALERS[cls] and ' + XTarTanks' or '', TANKS[cls] and ' + aggro paused' or '')
end

-- ------------------------------------------------------------- module hooks
function M:Init()
    self.hooks.xtarHealSet = function(s) require('modules.heals').xtarOverride = s end
    self.hooks.markAssist = function(onOff, n) local Modes = require('modules.modes') Modes.Binds['/markassist'](Modes, onOff, n and tostring(n) or '') end
end

function M:GiveTime(ctx)
    self:xtarTanksTick()
    self:aggroRaidTick()
    if Timers.expired('raid:tag') then Timers.set('raid:tag', 30000) self:tagGroupMA() end
end

function M:Shutdown()
    if #self.pins > 0 then self:release() end
end

M.Binds = {
    ['/changema'] = function(self, arg) self:changeMA(arg) end,
    ['/xtartanks'] = function(self, arg)
        arg = lower(arg)
        if not HEALERS[T.myClass()] then Log.info('[XTarTanks] clerics, shamans and druids only') return end
        if arg == '' then Log.info('[XTarTanks] %s - pins: %s - healing XTarget slots %s', State.xtarTanks and 'on' or 'off', #self.pins > 0 and pinsString() or 'none', State.xtarHealLive or self.cfg.XTarHeal or '0') return end
        if arg == 'on' then
            State.xtarTanks = true
            Timers.clear('raid:xtartanks')
            Log.info('[XTarTanks] on - raid WAR/SHD/PAL outside my group get an XTarget slot (Empty Target, else an empty Auto Hater slot) and heals')
            self:xtarTanksTick()
        elseif arg == 'off' then
            State.xtarTanks = false
            self:release()
            Log.info('[XTarTanks] off')
        else Log.info('[XTarTanks] usage: /xtartanks [on | off]') end
    end,
    ['/raidmode'] = function(self, a, b, c) self:raidMode(a or '', b or '', c or '') end,
    ['/raidtank'] = function(self, a, b)
        local arg = lower(a)
        if arg == 'all' then
            arg = lower(b)
            if arg == '' then Log.info('[HealTank] usage: /raidtank [<name> | auto | off | all <name>|auto|off]') return end
            self.Binds['/raidtank'](self, b)
            if not Comms.danNet() then Log.info('[HealTank] DanNet is off - applied here only') return end
            for _, peer in ipairs(Comms.peersInZone(function(sp) return T.str(function() return sp.Class.ShortName() end) ~= 'BRD' end)) do Comms.exec(peer, '/raidtank ' .. b) end
            Log.info('[HealTank] sent /raidtank %s to the muleassist boxes in %s', b, T.str(function() return mq.TLO.Zone.ShortName() end))
            return
        end
        if arg == '' then Log.info('[HealTank] mode %s - healing %s%s', State.healTankMode, State.healTank, lower(State.healTank) == lower(State.mainAssist) and ' (the MainAssist)' or '') return end
        if arg == 'off' or arg == 'auto' then
            State.healTankMode = arg
            if arg == 'auto' and raidMembers() == 0 then Log.info('[HealTank] auto - not in a raid yet, healing the MainAssist until there is a raid Main Assist') end
        else
            local sp = T.spawnByName(a, 'pc')
            if not sp then Log.info('[HealTank] %s is not a PC in this zone', a) return end
            State.healTankMode = T.str(function() return sp.CleanName() end)
        end
        require('modules.combat'):healTankSync()
        Log.info('[HealTank] mode %s - healing %s', State.healTankMode, State.healTank)
    end,
}

return M
