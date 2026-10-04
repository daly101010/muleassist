-- modules/beg.lua: BegBuff. A tell or group line that contains one of a Beg entry's aliases gets that buff
-- when the sender is allowed by [Buffs] BegPermission. Chat arrives through events and is handled on the
-- next tick (event handlers never yield).
local mq = require('mq')
local T = require('core.tlo')
local Config = require('core.config')
local Spell = require('core.spell')
local Cast = require('core.cast')
local Log = require('core.log')
local State = require('core.state')
local Rules = require('core.buffrules')
local BC = require('core.buffcheck')

local M = { name = 'beg' }

M.Settings = {
    scalars = {
        { section = 'Buffs', key = 'BegOn', type = 'int', default = 0 },
        { section = 'Buffs', key = 'BegPermission', type = 'string', default = 'NULL', rank = false },
        { section = 'Buffs', key = 'BegPermissionHelp', type = 'string', default = 'Valid options are |raid|guild|fellowship|all|tell|group', rank = false },
        { section = 'Buffs', key = 'BegHelp', type = 'string', default = 'Spellname|alias1,alias2,alias3 etc', rank = false },
        { section = 'General', key = 'BuffWhileChasing', type = 'int', default = 1 },
    },
    arrays = {
        { section = 'Buffs', name = 'Beg', size = { key = 'BegSize', default = 1 } },
    },
}
M.cfg = {}
M.entries = {}
M.queue = {}

function M:LoadSettings()
    self.cfg = Config.load(self.Settings)
    self.entries = {}
    for _, raw in ipairs(self.cfg.Beg or {}) do
        local e = Rules.parseBeg(raw)
        if e then self.entries[#self.entries + 1] = e end
    end
end

function M:Init()
    -- requests queue only while begging is on, and the queue is capped so a paused box does not honour
    -- an hour of stale tells on resume
    local function push(medium, who, text)
        if (M.cfg.BegOn or 0) == 0 then return end
        if #M.queue >= 20 then table.remove(M.queue, 1) end
        M.queue[#M.queue + 1] = { medium = medium, who = who, text = text }
    end
    mq.event('ma_beg_tell', "#1# tells you, '#2#'", function(_, who, text) push('tell', who, text) end)
    mq.event('ma_beg_group', "#1# tells the group, '#2#'", function(_, who, text) push('group', who, text) end)
end

function M:Shutdown()
    pcall(mq.unevent, 'ma_beg_tell')
    pcall(mq.unevent, 'ma_beg_group')
end

local function lower(s) return tostring(s or ''):lower() end

--- Decide what to do with one chat line. Returns the entry and target id, or nil and the reason.
function M:decide(ev)
    local c = self.cfg
    if (c.BegOn or 0) == 0 then return nil, 'off' end
    if T.inCombat() and c.BegOn ~= 2 then return nil, 'in combat' end
    if T.bool(function() return mq.TLO.Me.Invis() end) or T.bool(function() return mq.TLO.Me.Hovering() end) then return nil, 'invis or dead' end
    if State.chaseAssist and (c.BuffWhileChasing or 1) == 0 then return nil, 'chasing' end
    local e = Rules.begMatch(ev.text, self.entries)
    if not e then return nil, 'no alias' end
    local sp = T.spawnByName(ev.who, 'pc')
    if not sp then return nil, 'not in zone' end
    local id = T.num(function() return sp.ID() end)
    local kind = Spell.kind(e.name)
    if not kind then return nil, 'I do not have ' .. e.name end
    local facts = Spell.facts(e.name)
    local dist = T.num(function() return sp.Distance() end)
    local reach = math.max(facts.range, facts.aerange)
    if reach > 0 and dist >= reach then return nil, 'out of range' end
    BC.cacheBuffs(id)
    local tele = T.bool(function() return mq.TLO.Spell(e.name).HasSPA(146)() end)
    if not tele and BC.stacksSpawn(e.name, id) == false then return nil, 'does not stack' end
    if kind == 'spell' and facts.mana > T.num(function() return mq.TLO.Me.CurrentMana() end) then return nil, 'not enough mana' end
    local approved = Rules.begApproved(c.BegPermission, {
        inRaid = T.num(function() return mq.TLO.Raid.Member(ev.who).ID() end) > 0,
        sameGuild = T.str(function() return sp.Guild() end) ~= '' and T.str(function() return sp.Guild() end) == T.str(function() return mq.TLO.Me.Guild() end),
        inFellowship = T.num(function() return mq.TLO.Spawn('id ' .. id .. ' fellowship').ID() end) > 0,
        medium = ev.medium,
        inGroup = T.inGroup(id),
    })
    if not approved then return nil, 'not allowed' end
    return e, id
end

function M:GiveTime()
    if #self.queue == 0 then return end
    local ev = table.remove(self.queue, 1)
    local e, idOrWhy = self:decide(ev)
    if not e then
        Log.debug('beg from %s: %s', tostring(ev.who), tostring(idOrWhy))
        return
    end
    local id = idOrWhy
    if lower(ev.text):find('selfbuff', 1, true) then
        if not BC.myHas(e.name) then Cast.cast(e.name, T.myId(), 'BuffBeg', { skipOhShit = true, nomem = false }) end
        return
    end
    Log.info('BegBuff: Going to cast %s on %s', e.name, tostring(ev.who))
    Cast.cast(e.name, id, 'BuffBeg', { skipOhShit = true, item = e.item, nomem = false })
end

return M
