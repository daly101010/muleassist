-- modules/ohshit.lua: OhShitStuff - the [OhShit] emergency list (OhShitN=<spell|AA|item|skill>|<target>
-- or OhShitN=command:/<cmd> <args>|<target>) checked before every cast, every heal pass and every combat
-- pass; every entry whose condition is TRUE fires in list order. Also the pet-on-a-PC guard and the mash
-- call the macro folded into it.
--
-- Not a transliteration: a command entry's target is the pipe field after the command (the macro read the
-- wrong field); OhShitCOn gates the conditions as every other *COn does (the macro ignored it), and it
-- defaults to 1 so an INI without the key keeps its OhShitCond entries live.
local mq = require('mq')
local T = require('core.tlo')
local Config = require('core.config')
local Timers = require('core.timers')
local Cast = require('core.cast')
local Log = require('core.log')
local Cond = require('core.cond')
local State = require('core.state')

local M = { name = 'ohshit' }

M.Settings = {
    scalars = {
        { section = 'OhShit', key = 'OhShitOn', type = 'int', default = 0 },
        { section = 'OhShit', key = 'OhShitCOn', type = 'int', default = 1 },
        { section = 'Melee', key = 'FaceMobOn', type = 'int', default = 1 },
    },
    arrays = {
        { section = 'OhShit', name = 'OhShit', size = { key = 'OhShitSize', default = 10 }, cond = 'OhShitCond' },
    },
}
M.cfg = {}
M.entries = {}
M.hooks = { mash = function() end, pullOnce = function() end }
M.busy = false

local function lower(s) return tostring(s or ''):lower() end
local function targetId() return T.num(function() return mq.TLO.Target.ID() end) end

--- Parse one entry: { command = '/cmd args' | nil, name = spell, target = 'Me' | id | name | '' , cond }.
function M.parseEntry(raw, cond)
    raw = tostring(raw or ''):gsub('^%s+', ''):gsub('%s+$', '')
    if raw == '' or raw:upper() == 'NULL' then return nil end
    local first, rest = raw:match('^([^|]*)|?(.*)$')
    local e = { cond = cond or 'TRUE', target = (rest or ''):match('^([^|]*)') or '' }
    e.target = e.target:gsub('^%s+', ''):gsub('%s+$', '')
    if lower(first):find('^command:') then
        e.command = first:gsub('^[Cc][Oo][Mm][Mm][Aa][Nn][Dd]:', '')
        e.name = e.command:match('^%S+%s*(%S*)') or ''
    else
        e.name = first:gsub('%s+$', '')
    end
    return e
end

function M:LoadSettings()
    local c = Config.load(self.Settings)
    self.cfg = c
    self.entries = {}
    for i, raw in ipairs(c.OhShit or {}) do
        local e = M.parseEntry(raw, c.OhShitCond and c.OhShitCond[i] or 'TRUE')
        if e then e.index = i self.entries[#self.entries + 1] = e end
    end
    State.ohShitOn = (c.OhShitOn or 0) ~= 0
end

local function resolveTarget(t)
    if t == '' then return 0 end
    if lower(t) == 'me' then return T.myId() end
    local n = tonumber(t)
    if n then return T.spawn(n) and n or 0 end
    local sp = T.spawnByName(t, 'pc') or T.spawnByName(t)   -- an exact name first, never a bare substring
    return sp and T.num(function() return sp.ID() end) or 0
end

local function condOk(e)
    if (M.cfg.OhShitCOn or 0) == 0 then return e.cond == 'TRUE' or e.cond == '' or e.cond == 'NULL' end
    if e.cond == 'TRUE' or e.cond == '' or e.cond == 'NULL' then return true end
    return Cond.ok(e.cond)
end

--- OhShitStuff(from).
function M:check(from)
    if self.busy or not State.ohShitOn then return end
    if T.bool(function() return mq.TLO.Me.Hovering() end) then return end
    self.busy = true
    local ok, err = pcall(function()
        -- the pet is on a PC: call it back
        local pet = mq.TLO.Me.Pet
        if T.num(function() return pet.ID() end) > 0 and T.bool(function() return pet.Combat() end) and Timers.expired('ohshit:petback') then
            local an = T.str(function() return pet.AssistName() end)
            if an ~= '' and (T.inGroup(T.num(function() return mq.TLO.Group.Member(an).ID() end)) or T.spawnByName(an, 'pc')) then
                local hold = require('modules.pet').petHold
                if hold ~= '' then mq.cmdf('/pet %s on', hold) end
                mq.cmd('/pet back')
                Log.info('Pet is attacking a PC (%s)', an)
                Timers.set('ohshit:petback', 3000)
            end
        end
        if T.str(function() return mq.TLO.Target.Type() end) == 'NPC' and T.inCombat() and not T.bool(function() return mq.TLO.Me.Invis() end) then self.hooks.mash() end
        self.hooks.pullOnce()
        if State.zombieMode then return end
        for _, e in ipairs(self.entries) do
            local skip = false
            if not e.command and T.num(function() return mq.TLO.Me.Spell(e.name).ID() end) > 0 and not T.bool(function() return mq.TLO.Me.SpellReady(e.name)() end) then skip = true end
            if not skip and condOk(e) and (not State.buffMode or e.command) then
                if T.num(function() return mq.TLO.Me.Casting.ID() end) > 0 then mq.cmd('/stopcast') end
                local tid = resolveTarget(e.target)
                if tid > 0 and targetId() ~= tid then
                    mq.cmdf('/squelch /target id %d', tid)
                    mq.delay(1000, function() return targetId() == tid end)
                end
                if (self.cfg.FaceMobOn or 1) ~= 0 and tid > 0 and targetId() == tid and T.str(function() return mq.TLO.Target.Type() end) == 'NPC' then mq.cmdf('/squelch /face fast id %d', tid) end
                if e.command then
                    mq.cmdf('/docommand %s', e.command)
                    mq.delay(200)
                else
                    Cast.cast(e.name, tid, 'OhShitStuff', { skipOhShit = true })
                end
            end
        end
    end)
    self.busy = false
    if not ok then Log.error('ohshit: %s', tostring(err)) end
end

function M:Init()
    Cast.hooks.ohShit = function(from) M:check(from) end
    local Combat = require('modules.combat')
    Combat.hooks.ohShit = function(from) M:check(from) end
    M.hooks.mash = function() if #Combat.mash > 0 then Combat:mashButtons('ohshit') end end
end

function M:GiveTime(ctx)
    if State.ohShitOn and not ctx.inCombat then self:check('MainLoop') end
end

return M
