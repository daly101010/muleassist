-- modules/cures.lua: the first ported module. Behaviour = muleassist.mac CheckCures as of 2026-10-01:
--   * [Cures] CuresOn, CuresSize, Cures1..N ("Spell|type,type" or "Spell|type|type"; empty = any),
--     CuresCond1..N
--   * my own debuff line (poison/disease/curse/corruption counters) published for peers
--   * peers watched: me, PCs in my group, the out-of-group MA and the heal tank, the XTarHeal PC slots;
--     observers refreshed every 60 s; a real player (not a peer) is never cured
--   * a cure must really remove the type (the counter SPA on the resolved spell), else the line is skipped
--     with one warning
--   * only a ready cure reaches the cast (an unmemmed book spell out of combat is allowed)
--   * a cured target is held 3 s so the stale line is not cured twice; one cast per pass
--   * cure order: list order x watched order (me first)
-- The decision function is pure (decide()) and tested in tests/cures_test.lua.
local mq = require('mq')
local T = require('core.tlo')
local Config = require('core.config')
local Lines = require('core.lines')
local Timers = require('core.timers')
local Spell = require('core.spell')
local Cast = require('core.cast')
local Comms = require('core.comms')
local Observe = require('core.observe')
local Log = require('core.log')
local Cond = require('core.cond')
local State = require('core.state')
local Stats = require('core.stats')

local M = { name = 'cures' }

M.Settings = {
    scalars = {
        { section = 'Cures', key = 'CuresOn', type = 'int', default = 0 },
    },
    arrays = {
        { section = 'Cures', name = 'Cures', size = { key = 'CuresSize', default = 10 }, cond = 'CuresCond' },
    },
}

local SPA = { poison = 36, disease = 35, curse = 116, corruption = 369 }
local ORDER = { 'poison', 'disease', 'curse', 'corruption' }

M.cfg = {}
M.lines = {}          -- { name, types = {poison=true...}, any = bool, kind, warned }

-- ------------------------------------------------------------- pure decision logic
--- Parse a Cures entry into types. 'Spell|poison,disease' or 'Spell|poison|disease'; no types = any.
function M.parseLine(entry)
    local l = Lines.parse(entry)
    if not l then return nil end
    local types, any = {}, true
    for i = 2, #l.args do
        for tok in tostring(l.args[i]):gmatch('[^,]+') do
            tok = tok:lower():gsub('^%s+', ''):gsub('%s+$', '')
            if SPA[tok] then types[tok] = true any = false end
        end
    end
    return { name = l.name, types = types, any = any }
end

--- Parse a debuff line "N|poisonID|diseaseID|curseID|corruptionID" (the macro's MyDebuffs) into counters.
function M.parseDebuffs(line)
    local a = Lines.split(line or '0', '|')
    return { poison = (tonumber(a[2]) or 0) > 0, disease = (tonumber(a[3]) or 0) > 0,
             curse = (tonumber(a[4]) or 0) > 0, corruption = (tonumber(a[5]) or 0) > 0,
             any = (tonumber(a[1]) or 0) > 0 }
end

--- decide(line, debuffs, removes) -> true when this line should be cast for a target with these debuffs.
--- removes(type) says whether the resolved spell really removes that counter type (nil = unknown, trusted).
function M.decide(line, debuffs, removes)
    for _, ty in ipairs(ORDER) do
        if debuffs[ty] and (line.any or line.types[ty]) then
            local ok = removes and removes(ty)
            if ok == nil or ok then return true, ty end
        end
    end
    return false
end

-- ------------------------------------------------------------- game side
function M:LoadSettings()
    self.cfg = Config.load(self.Settings)
    State.curesOn = (self.cfg.CuresOn or 0) ~= 0
    self.lines = {}
    for i, e in ipairs(self.cfg.Cures or {}) do
        local l = M.parseLine(e)
        if l then
            l.index = i
            l.cond = self.cfg.CuresCond and self.cfg.CuresCond[i] or 'TRUE'
            self.lines[#self.lines + 1] = l
            -- a listed type the spell cannot remove is skipped for good: say so once (the macro's warning)
            local f = Spell.facts(l.name)
            if f.kind and f.hasSPA then
                for ty in pairs(l.types) do
                    if not f.hasSPA(SPA[ty]) then Log.warn('Cures%d: %s does not remove %s - that type is skipped for this line', i, l.name, ty) end
                end
            end
        end
    end
end

local function myDebuffLine()
    local p = T.num(function() return mq.TLO.Me.Poisoned.ID() end)
    local d = T.num(function() return mq.TLO.Me.Diseased.ID() end)
    local c = T.num(function() return mq.TLO.Me.Cursed.ID() end)
    local co = T.num(function() return mq.TLO.Me.Corrupted.ID() end)
    local n = p + d + c + co
    if n == 0 then return '0' end
    return string.format('%d|%d|%d|%d|%d', n, p, d, c, co)
end

--- The XTarHeal slots in use (XTarTanks may rewrite them): the PCs in them are cured too.
function M:xtarSlots()
    local s = State.xtarHealLive
    if s == nil then local H = package.loaded['modules.heals'] s = H and H.cfg and H.cfg.XTarHeal end
    local out = {}
    if s == nil or tonumber(s) == 0 then return out end
    for n in tostring(s):gmatch('[^|]+') do local v = tonumber(n) if v and v > 0 then out[#out + 1] = v end end
    return out
end

--- The ids and peer names to watch: me, group PCs that are peers, the MA, the heal tank, XTarHeal slots.
function M:watchList(xtarSlots)
    local ids, peers = { T.myId() }, {}
    local seen = { [T.myId()] = true }
    local function add(sp)
        local id = T.num(function() return sp.ID() end)
        if id <= 0 or seen[id] then return end
        local name = T.str(function() return sp.CleanName() end)
        if T.str(function() return sp.Type() end) ~= 'PC' then return end
        if not Comms.isPeer(name) then return end   -- a real player has nothing to read
        seen[id] = true
        ids[#ids + 1] = id
        peers[#peers + 1] = name
    end
    local n = T.num(function() return mq.TLO.Group.Members() end)
    for i = 1, n do add(mq.TLO.Group.Member(i)) end
    if State.mainAssistType == 'PC' and State.mainAssist ~= '' then
        local sp = T.spawnByName(State.mainAssist, 'pc'); if sp then add(sp) end
    end
    if State.healTankType == 'PC' and State.healTankId > 0 then
        local sp = T.spawn(State.healTankId); if sp then add(sp) end
    end
    for _, slot in ipairs(xtarSlots or {}) do
        local sp = mq.TLO.Me.XTarget(slot)
        if sp and sp() then add(sp) end
    end
    return ids, peers
end

local function removes(line)
    return function(ty)
        local f = Spell.facts(line.name)
        if not f.kind or not f.hasSPA then return nil end
        return f.hasSPA(SPA[ty])
    end
end

--- A CuresCond entry: TRUE/blank/NULL passes, anything else goes to core/cond (macro ${...} or native Lua).
local function condTrue(cond)
    if cond == nil or cond == '' or cond == 'TRUE' or cond == 'NULL' then return true end
    return Cond.ok(cond)
end

local function readyEnough(name)
    local kind = Spell.kind(name)
    if not kind then return false end
    if Spell.ready(name, kind) then return true end
    -- an unmemmed book spell out of combat: the cast engine (step 2) will memorise it
    if kind == 'spell' and not Spell.memmed(name) and T.aggroTargetId() == 0 then return true end
    return false
end

function M:GiveTime(ctx)
    if (self.cfg.CuresOn or 0) == 0 then return end
    if State.buffMode or State.zombieMode then return end
    if T.bool(function() return mq.TLO.Me.Invis() end) and T.aggroTargetId() == 0 then return end
    -- publish my own line for the peers that watch me
    State.myDebuffs = myDebuffLine()
    -- keep the observer set in sync (5 s cadence)
    if Timers.expired('cures:sync') then
        Timers.set('cures:sync', 5000)
        local ids, peers = self:watchList(self:xtarSlots())
        self.watchIds = ids
        Observe.want('cures', 'MuleAssist.Debuffs', peers, 60000)
    end
    local myId = T.myId()
    -- each watched toon's debuff line once per tick; nothing more to do while nobody is debuffed
    local debuffsById, spawnById, anyDebuffed = {}, {}, false
    for _, id in ipairs(self.watchIds or { myId }) do
        local sp = T.spawn(id)
        if sp and Timers.expired('cures:hold:' .. id) then
            local d
            if id == myId then d = M.parseDebuffs(State.myDebuffs)
            else d = M.parseDebuffs(Observe.value(T.str(function() return sp.CleanName() end), 'MuleAssist.Debuffs') or '0') end
            if d.any then debuffsById[id], spawnById[id], anyDebuffed = d, sp, true end
        end
    end
    if not anyDebuffed then return end
    for _, line in ipairs(self.lines) do
        if condTrue(line.cond) then
            line.removes = line.removes or removes(line)
            for _, id in ipairs(self.watchIds or { myId }) do
                local sp, debuffs = spawnById[id], debuffsById[id]
                if sp and debuffs then
                    local go, ty = M.decide(line, debuffs, line.removes)
                    if go and T.num(function() return sp.Distance() end) < 100 and T.str(function() return sp.Type() end) ~= 'Corpse' then
                        if not readyEnough(line.name) then
                            if Timers.expired('cures:unready') then
                                Stats.cureUnready(line.name)
                                Timers.set('cures:unready', 5000)
                            end
                        else
                            local f = Spell.facts(line.name)
                            local isGroup = (f.targetType or ''):lower():find('group') ~= nil
                            if isGroup and not T.inGroup(id) then
                                -- group cures do not land on an out-of-group toon
                            else
                                local res = Cast.cast(line.name, id, 'Cure')
                                if res == 'CAST_SUCCESS' then
                                    Stats.bump('cure')
                                    if isGroup then Stats.bump('cureGroup') end
                                    Comms.say('o', 'CURING: >> %s << (%s) with %s', T.str(function() return sp.CleanName() end), ty, line.name)
                                    if isGroup then
                                        for _, wid in ipairs(self.watchIds or {}) do Timers.set('cures:hold:' .. wid, 3000) Stats.bump('cureHeld') end
                                    else
                                        Timers.set('cures:hold:' .. id, 3000)
                                        Stats.bump('cureHeld')
                                    end
                                    return   -- one cast per pass: heals interleave
                                end
                            end
                        end
                    end
                end
            end
        end
    end
end

function M:Shutdown()
    Observe.release('cures')
end

M.Binds = {
    ['/cureson'] = function(self, arg)
        local v = tonumber(arg)
        if v == nil then v = (self.cfg.CuresOn or 0) == 0 and 1 or 0 end
        self.cfg.CuresOn = v
        State.curesOn = v ~= 0
        Config.set('Cures', 'CuresOn', v)
        Log.info('CuresOn %d', v)
    end,
}

return M
