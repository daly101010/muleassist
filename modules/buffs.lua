-- modules/buffs.lua: the buffs subsystem (CheckBuffs, GroupBuff, OOGBuff, CheckIniBuffs, RegenOther, BuffOnce,
-- CheckAura, CheckEndurance, SummonStuff, CastMana, CastMount, CheckPetBuffs, the PowerSource swaps, the
-- WornOff event and the buff binds). Same [Buffs] / [Pet] INI lines and tags as the macro.
--
-- Not a transliteration: a buff pass is a cursor over the lines that advances one cast per tick, so heals,
-- cures and the rest of the modules keep their turn between casts (the macro ran CheckHealth inside its
-- pass once a second for the same reason). Per-target timers (buff:<line>:<spawn id>) replace the
-- Buff<i>GM<j> timer variables and cover every target kind, not only group slots.
local mq = require('mq')
local T = require('core.tlo')
local Config = require('core.config')
local Ini = require('core.ini')
local Lines = require('core.lines')
local Timers = require('core.timers')
local Spell = require('core.spell')
local Cast = require('core.cast')
local Comms = require('core.comms')
local Log = require('core.log')
local Cond = require('core.cond')
local State = require('core.state')
local Rules = require('core.buffrules')
local BC = require('core.buffcheck')

local M = { name = 'buffs' }

M.Settings = {
    scalars = {
        { section = 'Buffs', key = 'BuffsOn', type = 'int', default = 0 },
        { section = 'Buffs', key = 'XTarBuff', type = 'int', default = 0 },
        { section = 'Buffs', key = 'DanNetBuff', type = 'int', default = 1 },
        { section = 'Buffs', key = 'RebuffOn', type = 'int', default = 1 },
        { section = 'Buffs', key = 'CheckBuffsTimer', type = 'int', default = 10 },
        { section = 'Buffs', key = 'PowerSource', type = 'string', default = 'NULL', rank = false },
        { section = 'Buffs', key = 'BuffCacheingDelay', type = 'int', default = 300 },
        { section = 'General', key = 'BuffWhileChasing', type = 'int', default = 1 },
        { section = 'Heals', key = 'XTarHeal', type = 'string', default = '0', rank = false },
        { section = 'Pet', key = 'PetBuffsOn', type = 'int', default = 0 },
        { section = 'Pet', key = 'PetShrinkOn', type = 'int', default = 0 },
        { section = 'Pet', key = 'PetShrinkSpell', type = 'string', default = 'Tiny Companion' },
    },
    arrays = {
        { section = 'Buffs', name = 'Buffs', size = { key = 'BuffsSize', default = 40 }, cond = 'BuffsCond' },
        { section = 'Pet', name = 'PetBuffs', size = { key = 'PetBuffsSize', default = 8 } },
    },
}
M.cfg = {}
M.lines, M.petLines = {}, {}
M.onceDone = {}
M.cursor, M.ctx, M.attempts = nil, nil, {}
M.wornOffQueue = {}
M.durationMod = 1

local function lower(s) return tostring(s or ''):lower() end
local function trim(s) return (tostring(s or ''):gsub('^%s+', ''):gsub('%s+$', '')) end
local function myId() return T.myId() end
local function inCombatState() return T.str(function() return mq.TLO.Me.CombatState() end) == 'COMBAT' end

-- ------------------------------------------------------------- line parsing (pure)
--- A Buffs entry -> { index, raw, name, kind?, tag, p2..p5, dual, classList, mgb, noGroup, oog = {tokens}, disabled }
function M.parseLine(raw, i)
    if not raw or raw == '' or raw:upper() == 'NULL' then return nil end
    local parts = Lines.split(raw, '|')
    local name = trim(parts[1])
    local l = { index = i or 0, raw = raw, name = name, p2 = trim(parts[2]), p3 = trim(parts[3]), p4 = trim(parts[4]), p5 = trim(parts[5]) }
    l.tag = lower(l.p2)
    if l.p2 == '0' or l.p3 == '0' then l.disabled = true end
    local ln = lower(name)
    if ln:find('^item:') then l.name = trim(name:sub(6))
    elseif ln:find('^command:') then l.kind = 'command' l.name = trim(name:sub(9))
    elseif ln:find('^summoned:') then l.name = trim(name:sub(10)) end
    if l.tag == 'dual' then
        l.dual = l.p3
        local sub = lower(l.p4)
        if sub == 'ma' then l.tag = 'dualma' elseif sub == 'melee' then l.tag = 'dualmelee' elseif sub == 'caster' then l.tag = 'dualcaster'
        elseif sub == 'class' then l.tag = 'dualclass' elseif sub == 'mgb' then l.tag = 'dualmgb' l.mgb = true end
    end
    l.isDual = l.tag:find('^dual') ~= nil
    if l.tag == 'class' then l.classList = l.p3 elseif l.tag == 'dualclass' then l.classList = l.p5 end
    if l.tag == 'mgb' then l.mgb = true end
    for _, p in ipairs({ l.p2, l.p3, l.p4, l.p5 }) do if lower(p) == 'nogroup' then l.noGroup = true end end
    local pos = raw:lower():find('oog:', 1, true)
    if pos then
        local rest = raw:sub(pos + 4)
        local colon = rest:find(':', 1, true)
        if colon then rest = rest:sub(1, colon - 1) end
        l.oog = {}
        for tok in rest:gmatch('[^,]+') do
            tok = trim(tok)
            if tok ~= '' then l.oog[#l.oog + 1] = tok end
        end
    end
    return l
end

--- A PetBuffs entry -> { name, item = bool, effect }  ('Item|Dual|Effect' or a plain name)
function M.parsePetLine(raw, i)
    if not raw or raw == '' or raw:upper() == 'NULL' then return nil end
    local parts = Lines.split(raw, '|')
    local l = { index = i, raw = raw, name = trim(parts[1]) }
    if lower(parts[2]) == 'dual' then l.effect = trim(parts[3]) end
    return l
end

-- ------------------------------------------------------------- settings
local function durationMod()
    local mod = 1
    local scr = T.num(function() return mq.TLO.Me.AltAbility('Spell Casting Reinforcement').Rank() end)
    local scrTab = { 1.15, 1.3, 1.5, 1.7, 1.9 }
    if scrTab[scr] then mod = scrTab[scr] end
    local ei = T.num(function() return mq.TLO.Me.AltAbility('Extended Ingenuity').Rank() end)
    local eiTab = { 1.15, 1.3, 1.5, 1.6, 1.7, 1.8 }
    if eiTab[ei] then mod = eiTab[ei] end
    return mod
end

function M:LoadSettings()
    local c = Config.load(self.Settings)
    c.BuffsCOn = Config.scalar({ section = 'Buffs', key = 'BuffsCOn', type = 'int', default = 0 }, Config.condFile)
    self.cfg = c
    State.buffsOn = (c.BuffsOn or 0) ~= 0
    BC.cacheDelayMs = (c.BuffCacheingDelay or 300) * 1000
    self.durationMod = durationMod()
    self.lines = {}
    for i, raw in ipairs(c.Buffs or {}) do
        local l = M.parseLine(raw, i)
        if l then
            l.cond = c.BuffsCond and c.BuffsCond[i] or 'TRUE'
            local reagent = Ini.read(Config.iniFile, 'Buffs', 'BuffsReagent' .. i)
            if reagent and reagent ~= '' and reagent:upper() ~= 'NULL' then
                local rp = Lines.split(reagent, '|')
                l.reagent, l.reagentCount = trim(rp[1]), tonumber(rp[2]) or 1
            end
            self.lines[#self.lines + 1] = l
        end
    end
    local sig = {}
    for i, raw in ipairs(c.Buffs or {}) do sig[#sig + 1] = i .. '=' .. tostring(raw) end
    Timers.resetOnChange('buffs', table.concat(sig, '|'), { 'buff:', 'buffs:unknown:' })
    self.petLines = {}
    for i, raw in ipairs(c.PetBuffs or {}) do
        local l = M.parsePetLine(raw, i)
        if l then self.petLines[#self.petLines + 1] = l end
    end
    self.onceDone = {}
    self.cursor = nil
end

-- ------------------------------------------------------------- shared helpers
--- A line's BuffsCond, with ${Buffee} / ${BuffeeLevel} replaced by the target (the macro set those outers).
function M:condOk(line, buffeeId)
    if (self.cfg.BuffsCOn or 0) == 0 then return true end
    local cond = line.cond
    if cond == nil or cond == '' or cond == 'TRUE' or cond == 'NULL' then return true end
    local lvl = 0
    if buffeeId and buffeeId > 0 then
        local sp = T.spawn(buffeeId)
        if sp then lvl = T.num(function() return sp.Level() end) end
    end
    cond = cond:gsub('%${Buffee}', tostring(buffeeId or 0)):gsub('%${BuffeeLevel}', tostring(lvl))
    return Cond.ok(cond)
end

--- The heal tank (the |MA lines follow /raidtank), falling back to the MainAssist.
local function tankSpawn()
    local name = State.healTank ~= '' and State.healTank or State.mainAssist
    if name == '' then return nil end
    local kind = lower(State.healTank ~= '' and State.healTankType or State.mainAssistType)
    return T.spawnByName(name, kind ~= '' and kind or 'pc')
end
local function tankId() local sp = tankSpawn() return sp and T.num(function() return sp.ID() end) or 0 end

--- What a line's buff lands on for the MA path: the merc's owner for a group spell on a merc tank, my pet
--- for the pet-tank roles, else the heal tank.
local function maTargetId(facts)
    local role = lower(State.role)
    if role == 'hunterpettank' or role == 'pettank' or role == 'pullerpettank' then
        return T.num(function() return mq.TLO.Me.Pet.ID() end)
    end
    local sp = tankSpawn()
    if not sp then return 0 end
    if T.str(function() return sp.Type() end) == 'Mercenary' and lower(facts.targetType):find('group v') then
        return T.num(function() return sp.Owner.ID() end)
    end
    return T.num(function() return sp.ID() end)
end

--- What kind of thing a Buffs name is, in the macro's precedence: an inventory item wins, then an AA, a
--- combat ability, a book spell, a spell the game knows.
local function kindOf(name)
    if T.num(function() return mq.TLO.FindItem('=' .. name).ID() end) > 0 then return 'item' end
    if T.num(function() return mq.TLO.Me.AltAbility(name).Rank() end) > 0 then return 'aa' end
    if T.num(function() return mq.TLO.Me.CombatAbility(name)() end) > 0 then return 'disc' end
    if T.num(function() return mq.TLO.Me.Book(name)() end) > 0 then return 'spell' end
    if T.num(function() return mq.TLO.Spell(name).ID() end) > 0 then return 'spell' end
    return nil
end

local function ready(kind, name)
    if kind == 'aa' then return T.bool(function() return mq.TLO.Me.AltAbilityReady(name)() end) end
    if kind == 'item' then return T.bool(function() return mq.TLO.Me.ItemReady(name)() end) end
    if kind == 'disc' then return T.bool(function() return mq.TLO.Me.CombatAbilityReady(name)() end) end
    if kind == 'spell' then
        if Spell.memmed(name) and not T.bool(function() return mq.TLO.Me.SpellReady(name)() end) then return false end
        return true
    end
    return true
end

--- The spell's reach for target selection: the AE range of a group spell, else its range, else 100.
local function spellRange(facts)
    if lower(facts.targetType):find('group v') and facts.aerange > 0 then return facts.aerange end
    if facts.range > 0 then return facts.range end
    return 100
end

local function timerKey(line, id) return 'buff:' .. line.index .. ':' .. tostring(id) end

--- After a cast: arm the per-target timer (the spell's duration x DurationMod; 60 s for a skipped buff).
function M:armed(line, id, res, facts)
    if res == 'CAST_SUCCESS' then
        local dur = (facts.durationSec or 0) * self.durationMod
        if line.isDual and line.dual then dur = (Spell.facts(line.dual).durationSec or 0) * self.durationMod end
        Timers.set(timerKey(line, id), math.max(dur, 30) * 1000)
        pcall(mq.flushevents, 'ma_wornoff')
        Timers.clear('buffs:write')
        return true
    elseif res == 'CAST_SKIPPED' then
        Timers.set(timerKey(line, id), 60000)
        return true
    end
    return false
end

local function castOn(name, id, from, opts)
    opts = opts or {}
    if opts.nomem == nil then opts.nomem = true end
    return Cast.cast(name, id, from, opts)
end

-- ------------------------------------------------------------- the pass
--- Build what a pass needs once: the XTarBuff slots, the DanNet peers out of my group, the raid rosters.
function M:buildCtx()
    local c = self.cfg
    local ctx = { xtar = {}, dannet = {}, raidTanks = {}, raidHealers = {} }
    if (c.XTarBuff or 0) ~= 0 and tostring(c.XTarHeal or '0') ~= '0' then
        for slot in tostring(c.XTarHeal):gmatch('[^|]+') do
            local n = tonumber(slot)
            if n then
                local id = T.num(function() return mq.TLO.Me.XTarget(n).ID() end)
                if id > 0 then ctx.xtar[#ctx.xtar + 1] = id end
            end
        end
    end
    if (c.DanNetBuff or 0) ~= 0 and Comms.danNet() then
        for _, peer in ipairs(Comms.peers()) do
            local sp = T.spawnByName(peer, 'pc')
            if sp then
                local id = T.num(function() return sp.ID() end)
                if id ~= myId() and not T.inGroup(id) then ctx.dannet[#ctx.dannet + 1] = peer end
            end
        end
    end
    local wantRaid = false
    for _, l in ipairs(self.lines) do
        for _, tok in ipairs(l.oog or {}) do
            local lt = lower(tok)
            if lt == 'raidtanks' or lt == 'raidhealers' then wantRaid = true end
        end
    end
    if wantRaid and T.num(function() return mq.TLO.Raid.Members() end) > 0 then
        for b = 1, T.num(function() return mq.TLO.Raid.Members() end) do
            local m = mq.TLO.Raid.Member(b)
            local name = T.str(function() return m.Name() end)
            local sp = name ~= '' and T.spawnByName(name, 'pc') or nil
            if sp then
                local id = T.num(function() return sp.ID() end)
                if id ~= myId() and not T.inGroup(id) then
                    local cls = T.str(function() return m.Class.ShortName() end):upper()
                    if cls == 'WAR' or cls == 'SHD' or cls == 'PAL' then ctx.raidTanks[#ctx.raidTanks + 1] = name
                    elseif cls == 'CLR' or cls == 'SHM' or cls == 'DRU' then ctx.raidHealers[#ctx.raidHealers + 1] = name end
                end
            end
        end
    end
    return ctx
end

function M:startPass()
    self.ctx = self:buildCtx()
    self.cursor = 1
    self.attempts = {}
end

function M:endPass()
    self.cursor = nil
    self:powerSourceEquip()
    if T.aggroTargetId() == 0 then Timers.set('buffs:pass', (self.cfg.CheckBuffsTimer or 10) * 1000) end
    if T.num(function() return mq.TLO.Macro.RunTime() end) > 120 or T.now() > 120000 then
        if Timers.expired('buffs:ininext') then Timers.set('buffs:ininext', 30000) end
    end
    Cast.rememMiscGem(false)
end

function M:GiveTime(ctx)
    self:manaTick()
    self:petTick()
    if (self.cfg.BuffsOn or 0) == 0 then return end
    if T.bool(function() return mq.TLO.Me.Hovering() end) or State.zombieMode then return end
    if T.hostiles() > 0 and not State.buffMode then self.cursor = nil return end
    if State.iAmDead then return end
    if T.bool(function() return mq.TLO.Me.Invis() end) and T.myClass() ~= 'ROG' then return end
    if State.chaseAssist and (self.cfg.BuffWhileChasing or 1) == 0 then return end
    if Cast.hooks.chaseLagging() then return end
    self:powerSourceCheck()
    self:mountTick()
    if not self.cursor then
        if Timers.running('buffs:pass') then return end
        self:startPass()
    end
    local budget = 12
    while self.cursor and budget > 0 do
        budget = budget - 1
        if (inCombatState() or T.aggroTargetId() > 0) and not State.buffMode then self.cursor = nil return end
        if State.iAmDead then self.cursor = nil return end
        if T.bool(function() return mq.TLO.Group.AnyoneMissing() end) and T.num(function() return mq.TLO.Raid.Members() end) == 0 then self.cursor = nil return end
        local line = self.lines[self.cursor]
        if not line then self:endPass() return end
        local r = self:processLine(line)
        if r == 'abort' then self.cursor = nil return end
        if r == 'cast' then
            -- stay on the line: the next tick looks for another target (group members, OOG entries)
            self.attempts[line.index] = (self.attempts[line.index] or 0) + 1
            if self.attempts[line.index] >= 8 then self.cursor = self.cursor + 1 end
            return
        end
        self.cursor = self.cursor + 1
    end
end

-- ------------------------------------------------------------- one line
--- 'done' (next line), 'cast' (a cast happened, look at this line again next tick), 'abort' (hostiles).
function M:processLine(line)
    if line.disabled or self.onceDone[line.index] then return 'done' end
    local name = line.name
    local kind = line.kind or kindOf(name)
    if kind then line.kind = kind end   -- resolved once; an unknown name is looked up again (a later scribe shows up)
    if not kind then
        if Timers.expired('buffs:unknown:' .. line.index) then
            Timers.set('buffs:unknown:' .. line.index, 300000)
            Log.warn('Buffs%d: I do not have "%s" (spell, AA, disc or item)', line.index, name)
        end
        return 'done'
    end
    if not ready(kind, name) then return 'done' end
    if line.reagent and T.num(function() return mq.TLO.FindItemCount('=' .. line.reagent)() end) < line.reagentCount then return 'done' end
    local facts = kind ~= 'command' and Spell.facts(name) or { targetType = '', range = 0, aerange = 0, durationSec = 0, beneficial = true }
    if kind == 'spell' then
        local sp = mq.TLO.Spell(name)
        local reagent = T.num(function() return sp.ReagentID(1)() end)
        if reagent > 0 and T.num(function() return mq.TLO.FindItemCount(reagent)() end) < T.num(function() return sp.ReagentCount(1)() end) then return 'done' end
        local noExpend = T.num(function() return sp.NoExpendReagentID(1)() end)
        if noExpend > 0 and T.num(function() return mq.TLO.FindItemCount(noExpend)() end) == 0 then return 'done' end
    end
    local range = spellRange(facts)
    local tt = lower(facts.targetType)
    local tag = line.tag

    -- the tag branches that never reach the group / self paths
    if kind == 'command' then
        if self:condOk(line, myId()) then Cast.cast('command:' .. name, myId(), 'Buffs', { kind = 'command', skipOhShit = true }) end
        return 'done'
    end
    if line.noGroup then return self:skipBuff(line, kind, facts, range) end
    if tag == 'endgroup' or tag == 'managroup' then
        if T.groupCount() > 0 and self:condOk(line, myId()) then
            local stat = tag == 'endgroup' and 'endurance' or 'mana'
            local classes = lower(line.p4) == 'class' and line.p5 or (tag == 'managroup' and line.p4 or '0')
            self:regenOther(name, stat, line.p3, classes)
        end
        return 'done'
    end
    if tag == 'mana' or tag == 'mount' then return 'done' end
    if tag == 'remove' then
        if BC.myHas(name) then mq.cmdf('/removebuff "%s"', name) end
        return 'done'
    end
    if tag == 'aura' then
        if self:condOk(line, myId()) then self:checkAura(name) end
        return 'done'
    end
    if tag == 'once' then
        if self:condOk(line, myId()) and self:buffOnce(name) then
            self.onceDone[line.index] = true
            Log.info('Buffing Once with %s.', line.raw)
        end
        return 'done'
    end
    if tag == 'end' then
        if T.num(function() return mq.TLO.Me.PctEndurance() end) <= (tonumber(line.p3) or 0) and self:condOk(line, myId()) then
            local sp = mq.TLO.Spell(name)
            if kind == 'disc' and T.num(function() return mq.TLO.Me.ActiveDisc.ID() end) > 0 and T.num(function() return sp.Duration() end) > 0
                and not T.bool(function() return sp.StacksWithDiscs() end) then return 'done' end
            self:checkEndurance(name)
        end
        return 'done'
    end
    if tag == 'summon' then
        if self:condOk(line, myId()) and T.num(function() return mq.TLO.FindItemCount('=' .. line.p3)() end) < (tonumber(line.p4) or 0) then
            self:summon(name, line.p3, tonumber(line.p4) or 0)
        end
        return 'done'
    end

    -- the MA / heal tank
    if tag == 'ma' or tag == 'dualma' then
        local r = self:maPath(line, kind, facts, range)
        if r == 'cast' then return 'cast' end
        return self:skipBuff(line, kind, facts, range)
    end
    -- the pet
    local second = (name:match('^%S+%s+(%S+)') or ''):lower()
    if tag == 'pet' or tt:find('pet') or second == 'symbiosis' or second == 'siphon' or second == 'simulacrum' then
        local r = self:petPath(line, name)
        if r == 'cast' then return 'cast' end
        return 'done'
    end
    -- an item I click on myself
    if kind == 'item' then
        self:itemPath(line, name, facts)
        return self:skipBuff(line, kind, facts, range)
    end

    local landing = line.isDual and line.dual or name
    -- a Dual line whose landing buff I carry, or that would not stack on me, is done
    if line.isDual and tt ~= 'self' then
        if BC.myHas(landing) or BC.mySong(landing) then return self:skipBuff(line, kind, facts, range) end
        local meTag = false
        for _, p in ipairs({ line.p2, line.p3, line.p4, line.p5 }) do if lower(p) == 'me' then meTag = true end end
        if meTag and BC.stacksOnMe(landing) == false then return self:skipBuff(line, kind, facts, range) end
    end
    -- grouped and not a self spell: the group path (Single lines go member by member, Group v once)
    if tag ~= 'me' and T.groupCount() > 0 and tt ~= 'self' then
        local r = self:groupBuff(line, name, landing, facts, range)
        if r == 'abort' then return 'abort' end
        if r == 'cast' then return 'cast' end
        return self:skipBuff(line, kind, facts, range)
    end
    -- ungrouped (or a Me line, or a self spell)
    if tag == '!me' then return 'done' end
    if tag ~= 'me' and tt ~= 'self' and T.groupCount() == 0 then
        -- an ungrouped buffer still buffs its tank
        local id = maTargetId(facts)
        if id > 0 and id ~= myId() and Timers.expired(timerKey(line, id)) then
            local sp = T.spawn(id)
            if sp and T.num(function() return sp.Distance() end) <= range then
                BC.cacheBuffs(id)
                if BC.cachedSeconds(id, landing) <= 180 and BC.stacksSpawn(landing, id) ~= false and self:condOk(line, id) then
                    local res = castOn(name, id, 'Buffs')
                    if self:armed(line, id, res, facts) then return 'cast' end
                end
            end
        end
    end
    -- myself
    if BC.myHas(landing) or BC.mySong(landing) then return self:skipBuff(line, kind, facts, range) end
    if BC.myFresh(landing, 30) then return self:skipBuff(line, kind, facts, range) end
    if BC.stacksOnMe(landing) == false then return self:skipBuff(line, kind, facts, range) end
    if tt:find('single') and tag == 'caster' and not Rules.CASTERS[T.myClass()] then return self:skipBuff(line, kind, facts, range) end
    if tt:find('single') and tag == 'melee' and not Rules.MELEE[T.myClass()] then return 'done' end
    if tt:find('single') and tag == 'ma' and lower(T.myName()) ~= lower(State.healTank) then return 'done' end
    if Timers.running(timerKey(line, myId())) then return self:skipBuff(line, kind, facts, range) end
    if self:condOk(line, myId()) then
        if line.mgb and T.bool(function() return mq.TLO.Me.AltAbilityReady('Tranquil Blessings')() end) then
            Log.info('Activating Tranquil Blessings')
            mq.cmdf('/alt act %d', T.num(function() return mq.TLO.Me.AltAbility('Tranquil Blessings').ID() end))
            mq.delay(2000, function() return not T.bool(function() return mq.TLO.Me.AltAbilityReady('Tranquil Blessings')() end) end)
        end
        local res = castOn(name, myId(), 'Buffs')
        if res == 'CAST_COMPONENTS' then Log.warn('Buff%d You are missing components.', line.index) end
        self:armed(line, myId(), res, facts)
    end
    return self:skipBuff(line, kind, facts, range)
end

--- The MA path: the tank in range, no fresh timer or the tank lacks the buff, not blocked, stacking, not
--- present with > 180 s, the condition, then the cast on the real recipient (merc owner / my pet / the tank).
function M:maPath(line, kind, facts, range)
    local tsp = tankSpawn()
    if not tsp then return 'done' end
    local tid = T.num(function() return tsp.ID() end)
    if T.num(function() return tsp.Distance() end) > range then return 'done' end
    local landing = line.isDual and line.dual or line.name
    if Timers.running(timerKey(line, tid)) and BC.cachedHas(tid, landing) then return 'done' end
    if BC.toonBlocked(tid)[lower(line.name)] or BC.toonBlocked(tid)[lower(landing)] then return 'done' end
    local id = maTargetId(facts)
    if id == 0 then return 'done' end
    BC.cacheBuffs(id)
    if BC.stacksSpawn(line.name, id) == false and BC.stacksSpawn(landing, id) == false then return 'done' end
    if BC.cachedSeconds(id, landing) > 180 or BC.cachedSeconds(id, line.name) > 180 then return 'done' end
    if not self:condOk(line, id) then return 'done' end
    local res = castOn(line.name, id, 'Buffs')
    if self:armed(line, id, res, facts) then
        Timers.set(timerKey(line, tid), Timers.left(timerKey(line, id)))
        return 'cast'
    end
    return 'done'
end

--- GroupBuff: the first group member (me included, slot 0) who needs the buff gets it; one cast per call.
function M:groupBuff(line, name, landing, facts, range)
    local n = T.groupCount()
    local tag = line.tag
    local tidTank = tankId()
    for j = 0, n do
        if T.hostiles() > 0 and not State.buffMode then return 'abort' end
        if T.aggroTargetId() > 0 and not State.buffMode then return 'abort' end
        local m = T.groupMember(j)
        local id = T.num(function() return m.ID() end)
        local ok = id > 0
        local isMe = id == myId()
        local cls = ok and T.str(function() return m.Class.ShortName() end):upper() or ''
        if ok and T.num(function() return m.Distance() end) > range and not isMe then ok = false end
        if ok and Timers.running(timerKey(line, id)) then
            if isMe then ok = not BC.myFresh(landing, 30) else ok = BC.cachedSeconds(id, landing) <= 30 end
        end
        if ok and not self:condOk(line, id) then ok = false end
        if ok and tag == 'me' and not isMe then ok = false end
        if ok and (tag == 'class' or tag == 'dualclass') and not Rules.inList(line.classList, cls) then ok = false end
        if ok and (tag == 'caster' or tag == 'dualcaster') and not Rules.CASTERS[cls] then ok = false end
        if ok and (tag == 'melee' or tag == 'dualmelee') and not Rules.MELEE[cls] then ok = false end
        if ok and facts.mana > T.num(function() return mq.TLO.Me.CurrentMana() end) then ok = false end
        if ok and tag == '!ma' and id == tidTank then ok = false end
        if ok and tag == '!me' and isMe then ok = false end
        if ok then
            if isMe then
                if BC.mySong(landing) or BC.myFresh(landing, 30) or BC.stacksOnMe(landing) == false then ok = false end
            else
                BC.cacheBuffs(id)
                if BC.cachedSeconds(id, landing) > 30 or BC.stacksSpawn(landing, id) == false then ok = false end
            end
        end
        if ok then
            -- cast on this member
            if State.chaseAssist and (self.cfg.BuffWhileChasing or 1) == 0 then return 'done' end
            if Cast.hooks.chaseLagging() then return 'done' end
            local dist = T.num(function() return m.Distance() end)
            if not isMe and ((facts.range > 0 and dist > facts.range) or (facts.aerange > 0 and facts.range == 0 and dist > facts.aerange)) then
                ok = false
            else
                if not isMe and T.num(function() return mq.TLO.Target.ID() end) ~= id then
                    mq.cmdf('/squelch /target id %d', id)
                    mq.delay(1000, function() return T.num(function() return mq.TLO.Target.ID() end) == id end)
                    BC.targetBuffWait()
                    if BC.targetFresh(landing, 30) then
                        Timers.set(timerKey(line, id), 60000)
                        ok = false
                    end
                end
                if ok then
                    mq.delay(3000, function() return not T.bool(function() return mq.TLO.Me.SpellInCooldown() end) end)
                    if line.mgb and T.bool(function() return mq.TLO.Me.AltAbilityReady('Mass Group Buff')() end) then
                        mq.cmdf('/alt act %d', T.num(function() return mq.TLO.Me.AltAbility('Mass Group Buff').ID() end))
                        mq.delay(2000, function() return not T.bool(function() return mq.TLO.Me.AltAbilityReady('Mass Group Buff')() end) end)
                    end
                    local res = castOn(name, id, 'Buffs')
                    if self:armed(line, id, res, facts) then
                        if lower(facts.targetType):find('group v') then
                            -- one cast covers the group
                            for k = 0, n do
                                local mid = T.num(function() return T.groupMember(k).ID() end)
                                if mid > 0 then Timers.set(timerKey(line, mid), Timers.left(timerKey(line, id))) end
                            end
                            return 'done'
                        end
                        return 'cast'
                    end
                end
            end
        end
    end
    return 'done'
end

--- An item clicked on myself (Call of the Wild and the like).
function M:itemPath(line, name, facts)
    local it = mq.TLO.FindItem('=' .. name)
    local spellName = T.str(function() return it.Spell.Name() end)
    if spellName == '' then return end
    if line.isDual and (BC.myHas(line.dual) or BC.mySong(line.dual)) and lower(T.str(function() return mq.TLO.Spell(line.dual).TargetType() end)) == 'self' then return end
    if BC.stacksOnMe(name) == false then return end
    local st = lower(T.str(function() return it.Spell.SpellType() end))
    if st ~= 'beneficial' and st ~= 'beneficial(group)' then return end
    if BC.myHas(spellName) then return end
    if T.num(function() return it.Timer() end) ~= 0 then return end
    if line.tag == 'aura' or line.tag == 'mount' or line.tag == 'mana' then return end
    if Timers.running(timerKey(line, myId())) then return end
    if not self:condOk(line, myId()) then return end
    local res = castOn(name, myId(), 'Buffs', { nomem = false })
    self:armed(line, myId(), res, facts)
end

--- The pet: PetBuffs-style single cast of a Buffs line tagged pet / with a pet target type.
function M:petPath(line, name)
    local petId = T.num(function() return mq.TLO.Me.Pet.ID() end)
    if petId == 0 then return 'done' end
    if BC.petHas(name) then return 'done' end
    if not T.bool(function() return mq.TLO.Spell(name).StacksPet() end) then return 'done' end
    if Timers.running(timerKey(line, petId)) then return 'done' end
    if not self:condOk(line, petId) then return 'done' end
    local res = castOn(name, petId, 'Buffs', { nomem = false })
    if self:armed(line, petId, res, Spell.facts(name)) then return 'cast' end
    return 'done'
end

-- ------------------------------------------------------------- :SkipBuff - the other toons (ini) and OOG
function M:skipBuff(line, kind, facts, range)
    local tag = line.tag
    local tt = lower(facts.targetType)
    local selfish = tag == 'mana' or tag == 'aura' or tag == 'mount' or tag == 'me' or tag == 'summon' or tag == 'end'
        or tt:find('self') ~= nil or tt:find('pet') ~= nil
    if not selfish then
        if Timers.expired('buffs:ininext') and not State.combatStart then
            if self:iniBuffs(line, kind, facts, range) == 'cast' then return 'cast' end
        end
    end
    return self:oogWalk(line, kind, facts, range)
end

--- CheckIniBuffs: buff the toons that publish their buff lists in the shared file and lack this buff.
function M:iniBuffs(line, kind, facts, range)
    local tag = line.tag
    local tidTank = tankId()
    local myCls = T.myClass()
    local buffName = line.name
    if line.isDual then
        if lower(T.str(function() return mq.TLO.Spell(line.dual).TargetType() end)) == 'self' then return 'done' end
        buffName = line.dual
    end
    local bare = buffName:gsub(' Rk%. I+$', '')
    for _, id in ipairs(BC.toonIds()) do
        if T.aggroTargetId() > 0 then return 'done' end
        local sp = T.spawn(id)
        local ty = sp and T.str(function() return sp.Type() end) or ''
        if sp and id ~= myId() and (ty == 'PC' or ty == 'Pet' or ty == 'Mercenary') then
            local cname = T.str(function() return sp.CleanName() end)
            local cls = T.str(function() return sp.Class.ShortName() end):upper()
            local ok = true
            if tag == 'ma' and id ~= tidTank then ok = false end
            if tag == '!ma' and id == tidTank then ok = false end
            if tag == 'me' then ok = false end
            if (tag == 'caster' or tag == 'dualcaster') and not Rules.CASTERS[cls] then ok = false end
            if (tag == 'melee' or tag == 'dualmelee') and not Rules.MELEE[cls] then ok = false end
            if ok and Timers.running('inibuff:' .. id .. ':' .. line.index) then ok = false end
            if ok and T.num(function() return sp.Distance() end) > range then ok = false end
            if ok then
                local blocked = BC.toonBlocked(id)
                local have = BC.toonBuffs(id)
                if blocked[lower(bare)] or blocked[lower(buffName)] or have[lower(bare)] or have[lower(buffName)] then ok = false end
                if ok then
                    for theirs in pairs(have) do
                        if not (theirs:find('group perfected levitation', 1, true) and not lower(buffName):find('group perfected levitation', 1, true)) then
                            local ws = T.str(function() return mq.TLO.Spell(theirs).WillStack(buffName)() end)
                            if ws:upper() == 'FALSE' or ws == '' then ok = false break end
                        end
                    end
                end
            end
            if ok then
                BC.cacheBuffs(id)
                if BC.cachedSeconds(id, buffName) > 180 then ok = false end
            end
            if ok and not self:condOk(line, id) then ok = false end
            if ok then
                local castName = line.isDual and line.name or buffName
                local res = castOn(castName, id, 'Buffs', { nomem = false })
                if res == 'CAST_SUCCESS' then
                    Log.info('Buffed >> %s << on %s', buffName, cname)
                    Timers.set('inibuff:' .. id .. ':' .. line.index, 60000)
                    Timers.clear('buffs:ininext')
                    pcall(mq.flushevents, 'ma_wornoff')
                    BC.writeMine(true)
                    self:armed(line, id, res, facts)
                    return 'cast'
                elseif res == 'CAST_SKIPPED' then
                    Timers.set('inibuff:' .. id .. ':' .. line.index, 60000)
                end
            end
        end
    end
    return 'done'
end

--- The OOG entries of a line: explicit OOG: tokens (names, xtargetN, raid, fellowship, range<N>, raidtanks,
--- raidhealers) plus the synthesised XTarBuff / DanNetBuff lists for Single and Group v2 spells.
function M:oogEntries(line, facts)
    local c = self.cfg
    local ctx = self.ctx or { xtar = {}, dannet = {}, raidTanks = {}, raidHealers = {} }
    local entries = {}
    if line.oog then
        for _, tok in ipairs(line.oog) do
            local lt = lower(tok)
            if lt == 'raidtanks' then for _, n in ipairs(ctx.raidTanks) do entries[#entries + 1] = { name = n } end
            elseif lt == 'raidhealers' then for _, n in ipairs(ctx.raidHealers) do entries[#entries + 1] = { name = n } end
            elseif lt == 'raid' or lt == 'fellowship' then entries[#entries + 1] = { pass = lt }
            elseif lt:sub(1, 5) == 'range' then entries[#entries + 1] = { pass = 'range', radius = tonumber(lt:sub(6)) or 0 }
            elseif lt:find('^xtarget') then
                local n = tonumber(lt:sub(8))
                local id = n and T.num(function() return mq.TLO.Me.XTarget(n).ID() end) or 0
                if id > 0 then entries[#entries + 1] = { id = id, xtar = true } end
            else entries[#entries + 1] = { name = tok } end
        end
        return entries
    end
    local tag = line.tag
    local tagged = not (tag == 'ma' or tag == 'me' or tag == 'dualma')
    local xtarLine = (c.XTarBuff or 0) ~= 0 and #ctx.xtar > 0 and tagged
    local dnLine = (c.DanNetBuff or 0) ~= 0 and #ctx.dannet > 0 and tagged and ((c.DanNetBuff or 0) >= 2 or tag == 'caster' or tag == 'melee' or tag == 'class')
    if not (xtarLine or dnLine) then return entries end
    local tt = facts.targetType
    if tt ~= 'Single' and tt ~= 'Group v2' then return entries end
    if xtarLine then for _, id in ipairs(ctx.xtar) do entries[#entries + 1] = { id = id, xtar = true } end end
    if dnLine then for _, n in ipairs(ctx.dannet) do entries[#entries + 1] = { name = n } end end
    return entries
end

local function classTagSkip(line, cls)
    return Rules.classTagSkip(line.p2, line.p3, line.p4, line.p5, cls)
end

function M:oogWalk(line, kind, facts, range)
    local entries = self:oogEntries(line, facts)
    if #entries == 0 then return 'done' end
    local landing = line.isDual and line.dual or line.name
    for _, e in ipairs(entries) do
        if State.chaseAssist and (self.cfg.BuffWhileChasing or 1) == 0 then return 'done' end
        if Cast.hooks.chaseLagging() then return 'done' end
        if T.hostiles() > 0 and not State.buffMode then return 'abort' end
        if e.pass then
            if self:oogPass(e, line, landing, facts) == 'cast' then return 'cast' end
        else
            local id = e.id or 0
            if e.name then
                local sp = T.spawnByName(e.name, 'pc') or T.spawnByName(e.name, 'pet')
                if sp then id = T.num(function() return sp.ID() end) end
            end
            local sp = id > 0 and T.spawn(id) or nil
            if sp and id ~= myId() and not Timers.running(timerKey(line, id)) then
                local ty = T.str(function() return sp.Type() end)
                local ok = (ty == 'PC' or ty == 'Pet') and T.num(function() return sp.Distance() end) <= range
                if ok and T.inGroup(id) and not e.xtar then ok = false end
                if ok and (BC.cachedSeconds(id, landing) > 180 or BC.cachedSeconds(id, line.name) > 180) then ok = false end
                if ok and classTagSkip(line, T.str(function() return sp.Class.ShortName() end)) then ok = false end
                if ok then
                    mq.cmdf('/squelch /target id %d', id)
                    mq.delay(1000, function() return T.num(function() return mq.TLO.Target.ID() end) == id end)
                    mq.delay(2000, function() return T.num(function() return sp.CachedBuffCount() end) >= 0 end)
                    if self:condOk(line, id) and BC.stacksSpawn(line.name, id) ~= false then
                        local res = castOn(line.name, id, 'OOGBuffs')
                        if self:armed(line, id, res, facts) then return 'cast' end
                    end
                end
            end
        end
    end
    return 'done'
end

--- OOGBuff: one buff line over the raid / my fellowship / every PC in a radius, skipping my own group.
function M:oogPass(e, line, landing, facts)
    local targets = {}
    local range = facts.range > 0 and facts.range or 100
    if e.pass == 'raid' then
        for b = 1, T.num(function() return mq.TLO.Raid.Members() end) do
            local m = mq.TLO.Raid.Member(b)
            local id = T.num(function() return m.ID() end)
            local dist = T.num(function() return m.Distance() end)
            if id > 0 and id ~= myId() and (dist < range or (facts.aerange > 0 and dist < facts.aerange)) then targets[#targets + 1] = id end
        end
    elseif e.pass == 'fellowship' then
        for b = 1, T.num(function() return mq.TLO.Me.Fellowship.Members() end) do
            local name = T.str(function() return mq.TLO.Me.Fellowship.Member(b)() end)
            local sp = name ~= '' and T.spawnByName(name, 'pc') or nil
            if sp and T.num(function() return sp.Distance() end) < range then targets[#targets + 1] = T.num(function() return sp.ID() end) end
        end
    else
        if not State.buffMode then return 'done' end
        local radius = e.radius or 0
        local q = 'pc radius ' .. radius
        for b = 1, T.num(function() return mq.TLO.SpawnCount(q)() end) do
            local id = T.num(function() return mq.TLO.NearestSpawn(b, q).ID() end)
            if id > 0 and id ~= myId() then targets[#targets + 1] = id end
        end
    end
    local zone = T.str(function() return mq.TLO.Zone.ShortName() end):lower()
    for _, id in ipairs(targets) do
        if T.hostiles() > 0 and not State.buffMode then return 'done' end
        if T.inGroup(id) or Timers.running(timerKey(line, id)) then goto continue end
        do
            local sp = T.spawn(id)
            if not sp then goto continue end
            local cls = T.str(function() return sp.Class.ShortName() end)
            if classTagSkip(line, cls) then goto continue end
            local stacks = BC.stacksSpawn(landing, id)
            if stacks == false and not Rules.STACKS_BROKEN_ZONES[zone] then goto continue end
            if BC.cachedSeconds(id, landing) > 180 then goto continue end
            BC.cacheBuffs(id)
            if BC.cachedSeconds(id, landing) > 180 then goto continue end
            if not self:condOk(line, id) then goto continue end
            if e.pass == 'range' then
                local cname = T.str(function() return sp.CleanName() end)
                local row = Ini.read('MuleAssistOOGBuffs.ini', landing, cname)
                local skip, count = Rules.oogRecast(row, id, T.num(function() return mq.TLO.Time.SecondsSinceMidnight() end), Spell.facts(landing).durationSec, zone)
                if skip then goto continue end
                local res = castOn(line.name, id, 'OOGBuffs')
                if res == 'CAST_SUCCESS' then
                    Ini.write('MuleAssistOOGBuffs.ini', landing, cname, string.format('%d|%d|%d', id, T.num(function() return mq.TLO.Time.SecondsSinceMidnight() end), (count or 0) + 1))
                end
                if self:armed(line, id, res, facts) then return 'cast' end
            else
                local res = castOn(line.name, id, 'OOGBuffs')
                if self:armed(line, id, res, facts) then return 'cast' end
            end
        end
        ::continue::
    end
    return 'done'
end

-- ------------------------------------------------------------- the small helpers behind the tags
--- RegenOther: cast a group mana / endurance regen on the first group member whose stat is low.
function M:regenOther(name, stat, threshold, classes)
    if T.bool(function() return mq.TLO.Me.Invis() end) or T.aggroTargetId() > 0 then return false end
    local members = {}
    for i = 1, 5 do
        local m = T.groupMember(i)
        local id = T.num(function() return m.ID() end)
        local pct = stat == 'endurance' and T.num(function() return m.PctEndurance() end) or T.num(function() return m.PctMana() end)
        members[i] = { id = id, class = T.str(function() return m.Class.ShortName() end), pct = pct }
    end
    local pick = Rules.regenPick(members, stat, threshold, classes)
    if not pick then return false end
    local res = castOn(name, pick.id, 'Regenother', { nomem = false })
    if res == 'CAST_SUCCESS' then
        Log.info('Casting %s on %s for %s.', name, T.str(function() return T.spawn(pick.id).CleanName() end), stat)
        return true
    end
    return false
end

--- BuffOnce: cast once per session; true when done (cast, or it does not stack on me).
function M:buffOnce(name)
    if T.bool(function() return mq.TLO.Me.Invis() end) or T.bool(function() return mq.TLO.Me.Hovering() end) then return false end
    if BC.stacksOnMe(name) == false then
        Log.info('%s DOES NOT stack on ME, I will skip it.', name)
        return true
    end
    return castOn(name, myId(), 'CheckEndurance', { nomem = false }) == 'CAST_SUCCESS'
end

--- CheckEndurance: an endurance regen disc / AA on myself.
function M:checkEndurance(name)
    if T.bool(function() return mq.TLO.Me.Invis() end) or T.bool(function() return mq.TLO.Me.Hovering() end) then return false end
    local res = castOn(name, myId(), 'CheckEndurance', { nomem = false })
    if res == 'CAST_SUCCESS' then Log.info('Casting >> %s << for endurance', name) return true end
    return false
end

--- The aura window name for an aura spell (CheckAura's rank strip and the odd names).
function M.auraName(spell)
    local n = spell:gsub(' Rk%. III$', ''):gsub(' Rk%. II$', ''):gsub(' Rk%.II$', '')
    local f = spell:lower()
    if f:find("disciple's aura", 1, true) then n = 'Disciples Aura' end
    if f:find('reverent', 1, true) then n = 'Reverent Aura' end
    if f:find('mana reverberation', 1, true) or f:find('mana repercussion', 1, true) or f:find('mana reiteration', 1, true) then n = 'Mana Recursion Aura' end
    if f:find('mana reiterate', 1, true) then n = 'Mana Reiterate Aura' end
    if f:find('mana reverberation', 1, true) then n = 'Mana Rev.' end
    if f:find('mana resurgence', 1, true) then n = 'Mana Resurgence Aura' end
    if f:find('mana repercussion aura', 1, true) then n = 'Mana Rep. Aura' end
    if f:find('runic radiance aura', 1, true) then n = 'Runic Rad. Aura' end
    if f:find('arcane distillect', 1, true) then n = 'Arcane Distillect' end
    if f:find('earthen strength', 1, true) then n = 'Earthen Strength' end
    if f:find("rathe's strength", 1, true) then n = "Rathe's Strength" end
    return n
end

local function auraUp(auraName)
    local want = auraName:lower()
    local variants = { want, (want:gsub('`', '')), (want:gsub("'", '')) }
    for slot = 1, 2 do
        local have = T.str(function() return mq.TLO.Me.Aura(slot).Name() end):lower()
        if have ~= '' then
            for _, v in ipairs(variants) do if have:find(v, 1, true) then return true end end
        end
    end
    return false
end

function M:checkAura(spell)
    if T.bool(function() return mq.TLO.Me.Invis() end) or T.bool(function() return mq.TLO.Me.Hovering() end) then return false end
    if auraUp(M.auraName(spell)) then return false end
    local cls = T.myClass()
    if (cls == 'BER' or cls == 'MNK' or cls == 'ROG' or cls == 'WAR') and T.num(function() return mq.TLO.Me.CurrentEndurance() end) > 500 then
        return castOn(spell, myId(), 'CheckAura', { kind = 'disc', nomem = false }) == 'CAST_SUCCESS'
    end
    return castOn(spell, myId(), 'CheckAura', { nomem = false }) == 'CAST_SUCCESS'
end

--- SummonStuff: fill the inventory up to `num` of `item` with `spell`, up to five summons per call.
function M:summon(spell, item, num)
    if T.bool(function() return mq.TLO.Me.Invis() end) or T.bool(function() return mq.TLO.Me.Hovering() end) then return end
    local function count() return T.num(function() return mq.TLO.FindItemCount('=' .. item)() end) end
    if count() >= num then return end
    local passes = 0
    while count() < num and passes < 5 and not inCombatState() do
        passes = passes + 1
        local before = count()
        if T.num(function() return mq.TLO.Me.FreeInventory() end) == 0 then
            Log.warn('No room in inventory skipping summoning >> %s <<.', item)
            break
        end
        if T.num(function() return mq.TLO.Cursor.ID() end) > 0 then mq.cmd('/autoinventory') mq.delay(500) end
        local res
        if T.myClass() == 'BER' and spell:lower():find('axe', 1, true) then
            if not T.bool(function() return mq.TLO.Me.CombatAbilityReady(spell)() end) then break end
            res = castOn(spell, myId(), 'SummonStuff', { kind = 'disc', nomem = false })
        else
            if T.num(function() return mq.TLO.FindItemCount('=' .. spell)() end) > 0 and T.num(function() return mq.TLO.FindItem('=' .. spell).Timer() end) ~= 0 then return end
            res = castOn(spell, myId(), 'SummonStuff')
        end
        if res == 'CAST_COMPONENTS' then Log.warn('You are missing components. Turning Off %s.', item) return end
        if res ~= 'CAST_SUCCESS' then break end
        Cast.tickDelay(15000, function() return T.num(function() return mq.TLO.Cursor.ID() end) > 0 or count() > before end)
        if T.num(function() return mq.TLO.Cursor.ID() end) > 0 then
            Log.info('Summoned  >> %s <<', item)
            mq.cmd('/autoinventory')
            mq.delay(2000, function() return T.num(function() return mq.TLO.Cursor.ID() end) == 0 end)
        end
        if count() == 0 then
            Log.warn('Summoning >> %s << Failed - Check reagents, timer, etc', item)
            break
        end
        if count() <= before then break end
    end
    if count() > 0 then Log.info('I now have %d/%d of >> %s <<', count(), num, item) end
end

-- ------------------------------------------------------------- CastMana (the [Buffs] Mana / Managroup lines)
function M:manaTick()
    if not Timers.expired('buffs:mana') then return end
    Timers.set('buffs:mana', 1000)
    if T.bool(function() return mq.TLO.Me.Invis() end) then return end
    for _, line in ipairs(self.lines) do
        if not line.disabled and (line.tag == 'mana' or line.tag == 'managroup' or line.tag == 'endgroup') and self:condOk(line, myId()) then
            if line.tag == 'mana' and T.num(function() return mq.TLO.Me.Buff('Revival Sickness').ID() end) == 0 and Timers.expired('zone:justzoned') then
                if T.num(function() return mq.TLO.Me.PctMana() end) <= (tonumber(line.p3) or 0) and T.num(function() return mq.TLO.Me.PctHPs() end) > (tonumber(line.p4) or 0) then
                    if T.num(function() return mq.TLO.Cursor.ID() end) > 0 then mq.cmd('/autoinventory') end
                    local res = castOn(line.name, myId(), 'Buffs', { nomem = false })
                    if res == 'CAST_SUCCESS' then Log.info('Casting >> %s << for mana', line.name) return end
                end
            elseif line.tag == 'managroup' and not State.medding then
                if self:regenOther(line.name, 'mana', line.p3, line.p5) then return end
            end
        end
    end
end

-- ------------------------------------------------------------- CheckPetBuffs (every 60 s)
function M:petTick()
    local petId = T.num(function() return mq.TLO.Me.Pet.ID() end)
    if petId == 0 or (self.cfg.PetBuffsOn or 0) == 0 then return end
    if State.combatStart or State.pulling then return end
    if not Timers.expired('pet:buffcheck') then return end
    if T.bool(function() return mq.TLO.Me.Invis() end) then return end
    if State.chaseAssist and (self.cfg.BuffWhileChasing or 1) == 0 then return end
    if Cast.hooks.chaseLagging() then return end
    Timers.set('pet:buffcheck', 60000)
    for _, l in ipairs(self.petLines) do
        if T.aggroTargetId() > 0 then return end
        if Cast.hooks.chaseLagging() then return end
        local name = l.name
        if l.effect then
            if T.num(function() return mq.TLO.FindItem('=' .. name).ID() end) > 0 and not BC.petHas(l.effect) then
                local res = castOn(name, petId, 'Pet', { nomem = false })
                if res == 'CAST_SUCCESS' then Log.info('Buffing %s, my pet, with %s (%s)', T.str(function() return mq.TLO.Me.Pet.CleanName() end), name, l.effect) end
            end
        elseif T.num(function() return mq.TLO.Me.Book(name)() end) > 0 or T.bool(function() return mq.TLO.Me.AltAbilityReady(name)() end) then
            local bare = name:gsub(' Rk%. I+$', '')
            if not BC.petHas(bare) then
                local res = castOn(name, petId, 'Pet')
                if res == 'CAST_SUCCESS' then Log.info('Buffing %s, my pet, with %s', T.str(function() return mq.TLO.Me.Pet.CleanName() end), name) end
            end
        elseif T.num(function() return mq.TLO.FindItem('=' .. name).ID() end) > 0 then
            local itemSpell = T.str(function() return mq.TLO.FindItem('=' .. name).Spell.Name() end)
            if itemSpell == '' or not BC.petHas(itemSpell) then castOn(name, petId, 'Pet', { nomem = false }) end
        end
    end
    if (self.cfg.PetShrinkOn or 0) ~= 0 and T.num(function() return mq.TLO.Me.Pet.Height() end) > 1.35 then
        castOn(self.cfg.PetShrinkSpell, petId, 'Pet', { nomem = false })
    end
    if T.num(function() return mq.TLO.Target.ID() end) == petId then mq.cmd('/squelch /target clear') end
end

-- ------------------------------------------------------------- CastMount
function M:mountTick()
    if not Timers.expired('buffs:mount') then return end
    Timers.set('buffs:mount', 2000)
    if not State.mountOn then return end
    if not T.bool(function() return mq.TLO.Me.CanMount() end) or T.bool(function() return mq.TLO.Zone.Indoor() end) then return end
    if T.num(function() return mq.TLO.Me.Mount.ID() end) > 0 or T.bool(function() return mq.TLO.Me.Invis() end) then return end
    if State.healsOn and T.aggroTargetId() > 0 then return end
    if inCombatState() or State.chaseAssist or State.attacking or T.bool(function() return mq.TLO.Me.FeetWet() end) then return end
    for _, line in ipairs(self.lines) do
        if line.tag == 'mount' and not line.disabled and self:condOk(line, myId()) then
            castOn(line.name, myId(), 'CastMount', { nomem = false })
            return
        end
    end
end

-- ------------------------------------------------------------- PowerSource
function M:powerSourceCheck()
    local ps = self.cfg.PowerSource
    if not ps or ps == '' or ps == 'NULL' then return end
    if Timers.running('buffs:powersource') then return end
    Timers.set('buffs:powersource', 5000)
    local worn = T.str(function() return mq.TLO.Me.Inventory('powersource').Name() end)
    if worn ~= '' and T.num(function() return mq.TLO.Me.Inventory('powersource').Power() end) == 0 then
        if T.num(function() return mq.TLO.Cursor.ID() end) > 0 then mq.cmd('/autoinventory') mq.delay(500) end
        mq.cmdf('/nomodkey /itemnotify "%s" leftmouseup', ps)
        Cast.tickDelay(5000, function() return T.num(function() return mq.TLO.Cursor.ID() end) > 0 end)
        if T.str(function() return mq.TLO.Cursor.Name() end) == ps then mq.cmd('/destroy') end
        Cast.tickDelay(5000, function() return T.num(function() return mq.TLO.Cursor.ID() end) == 0 end)
    end
end
function M:powerSourceEquip()
    local ps = self.cfg.PowerSource
    if not ps or ps == '' or ps == 'NULL' then return end
    local worn = T.str(function() return mq.TLO.Me.Inventory('powersource').Name() end)
    if worn == '' and T.num(function() return mq.TLO.FindItemCount('=' .. ps)() end) > 0 then
        mq.cmdf('/nomodkey /itemnotify "%s" leftmouseup', ps)
        Cast.tickDelay(5000, function() return T.num(function() return mq.TLO.Cursor.ID() end) > 0 end)
        mq.cmd('/autoinventory')
    end
end

-- ------------------------------------------------------------- WornOff
function M:Init()
    mq.event('ma_wornoff', 'Your #1# spell has worn off of #2#.', function(_, spell, wearer)
        M.wornOffQueue[#M.wornOffQueue + 1] = { spell = spell, wearer = wearer }
    end)
end

--- Drain the worn-off queue: forget the per-target timers of that spell on that wearer and run a pass soon.
function M:Tick()
    if #self.wornOffQueue == 0 then return end
    local q = self.wornOffQueue
    self.wornOffQueue = {}
    if (self.cfg.RebuffOn or 0) == 0 then return end
    for _, ev in ipairs(q) do
        local spell, wearer = ev.spell or '', ev.wearer or ''
        if lower(wearer) ~= lower(T.myName()) and not lower(spell):find('promised', 1, true) then
            local sp = T.spawnByName(wearer, 'pc') or T.spawnByName(wearer, 'pet')
            local detrimental = lower(T.str(function() return mq.TLO.Spell(spell).SpellType() end)) == 'detrimental'
            if sp and not detrimental then
                local id = T.num(function() return sp.ID() end)
                local hit = false
                for _, line in ipairs(self.lines) do
                    if lower(line.raw):find(lower(spell), 1, true) then
                        Timers.clear(timerKey(line, id))
                        hit = true
                    end
                end
                if hit then
                    Log.info('%s needs %s because it wore off.', wearer, spell)
                    Timers.clear('buffs:pass')
                    Timers.clear('buffs:ininext')
                end
            end
        end
    end
end

function M:OnZone()
    Timers.set('zone:justzoned', 20000)
    self.cursor = nil
end

function M:Shutdown()
    pcall(mq.unevent, 'ma_wornoff')
end

-- ------------------------------------------------------------- binds
local function toggle(self, key, arg, label)
    local v = tonumber(arg)
    if arg == 'on' then v = 1 elseif arg == 'off' then v = 0 end
    if v == nil then v = (self.cfg[key] or 0) == 0 and 1 or 0 end
    self.cfg[key] = v
    Config.set('Buffs', key, v)
    Log.info('%s %d', label or key, v)
    return v
end

M.Binds = {
    ['/buffson'] = function(self, arg)
        local v = toggle(self, 'BuffsOn', arg, 'BuffsOn')
        State.buffsOn = v ~= 0
        if v ~= 0 then Timers.clear('buffs:pass') end
    end,
    ['/xtarbuff'] = function(self, arg) toggle(self, 'XTarBuff', arg, 'XTarBuff') end,
    ['/dannetbuff'] = function(self, arg) toggle(self, 'DanNetBuff', arg, 'DanNetBuff') end,
    ['/rebuffon'] = function(self, arg) toggle(self, 'RebuffOn', arg, 'RebuffOn') end,
    ['/buffwhilechase'] = function(self, arg)
        local v = tonumber(arg)
        if v == nil then v = (self.cfg.BuffWhileChasing or 1) == 0 and 1 or 0 end
        self.cfg.BuffWhileChasing = v
        Config.set('General', 'BuffWhileChasing', v)
        Log.info('BuffWhileChasing %d', v)
    end,
    ['/buffmode'] = function(self, arg)
        arg = lower(arg)
        if arg:find('on', 1, true) or (not State.buffMode and not arg:find('off', 1, true)) then
            State.buffMode = true
            Timers.clear('buffs:pass')
        else
            State.buffMode = false
        end
        Log.info('BuffMode is now set to %s', State.buffMode and 'TRUE' or 'FALSE')
    end,
    ['/buffgroup'] = function(self, arg)
        if not arg or arg == '' then Comms.group('/buffgroup 1') end
        if (self.cfg.BuffsOn or 0) ~= 0 then
            Timers.clear('buffs:pass')
            Timers.clear('buffs:ininext')
            self.cursor = nil
        end
    end,
}

return M
