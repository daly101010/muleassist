-- modules/rez.lua: RezCheck (the battle rez per group member with RezPolicy and the REZCLAIM hold, my own
-- corpse, the out-of-combat rez of guild / fellowship / XTarget / DanNet-peer / raid corpses, the far
-- peer-corpse notice), PickRezAbility, the rez claim events, the death flags (IAmDead / the corpse cleared
-- after a rez) and the rogue corpse drag, with the same [Heals] rez keys as the macro.
--
-- Not a transliteration: RezCheck runs once per heal pass (the heals module calls it) plus once a second
-- otherwise; the macro called it up to five times per CheckHealth.
local mq = require('mq')
local T = require('core.tlo')
local Config = require('core.config')
local Timers = require('core.timers')
local Spell = require('core.spell')
local Cast = require('core.cast')
local Comms = require('core.comms')
local Log = require('core.log')
local State = require('core.state')

local M = { name = 'rez' }

local REZ_CLASSES = { CLR = true, NEC = true, SHM = true, DRU = true, PAL = true }
M.Settings = {
    scalars = {
        { section = 'Heals', key = 'RezInCombatMA', type = 'int', default = 1 },
        { section = 'Heals', key = 'RezEncMobsAt', type = 'int', default = 3 },
        { section = 'Heals', key = 'RezClaimHold', type = 'int', default = 20 },
        { section = 'General', key = 'RezAcceptOn', type = 'string', default = '0|96', rank = false },
        { section = 'General', key = 'CampRadius', type = 'int', default = 30 },
        { section = 'AFKTools', key = 'CampOnDeath', type = 'int', default = 0 },
        { section = 'AFKTools', key = 'ClickBacktoCamp', type = 'int', default = 0 },
    },
}
M.cfg = {}
M.RADIUS = 150
M.hooks = {
    ladderCombat = function() return {} end,     -- heals: the |rez / |rezcombat lines
    ladderOOC = function() return {} end,        -- heals: the |rez / |rezooc lines
    invulnSafeToDrop = function() return true end,
    onDeath = function() end,                    -- kill order clear, manual off, charm pet (later steps)
}
M.claims = {}      -- corpse id -> { by = name, pri = n } while 'rez:claim:<id>' runs

local function lower(s) return tostring(s or ''):lower() end
local function targetId() return T.num(function() return mq.TLO.Target.ID() end) end
local function ready(name)
    return T.bool(function() return mq.TLO.Me.SpellReady(name)() end) or T.bool(function() return mq.TLO.Me.AltAbilityReady(name)() end)
        or T.bool(function() return mq.TLO.Me.ItemReady('=' .. name)() end)
end

function M:LoadSettings()
    local c = Config.load(self.Settings)
    if REZ_CLASSES[T.myClass()] then
        c.AutoRezOn = Config.scalar({ section = 'Heals', key = 'AutoRezOn', type = 'int', default = 0 })
        c.AutoRezWith = Config.scalar({ section = 'Heals', key = 'AutoRezWith', type = 'string', default = 'Your Rez Item/AA/Spell', rank = false })
        c.RezDanNetPeers = Config.scalar({ section = 'Heals', key = 'RezDanNetPeers', type = 'int', default = 1 })
    else
        c.AutoRezOn, c.AutoRezWith, c.RezDanNetPeers = 0, 'NULL', 0
    end
    if T.myClass() == 'ROG' then
        c.RogCorpseRetrieval = Config.scalar({ section = 'Rogue', key = 'RogCorpseRetrieval', type = 'int', default = 0 })
        c.RogCorpseRadius = Config.scalar({ section = 'Rogue', key = 'RogCorpseRadius', type = 'int', default = 500 })
    else
        c.RogCorpseRetrieval, c.RogCorpseRadius = 0, 0
    end
    self.cfg = c
    State.autoRezOn = (c.AutoRezOn or 0) ~= 0
    -- MQ2Rez: accept on with the pct
    local acc, pct = tostring(c.RezAcceptOn or '0|96'):match('^([^|]*)|?(.*)$')
    if acc == '1' then
        mq.cmd('/squelch /rez accept on')
        mq.cmd('/squelch /rez loot off')
        if (tonumber(pct) or 0) > 0 then mq.cmdf('/rez pct %s', pct) end
    end
end

-- ------------------------------------------------------------- the ladder and the policy
--- PickRezAbility: the first READY entry of the combat / OOC ladder, then AutoRezWith.
function M:pickAbility(combat)
    local list = combat and self.hooks.ladderCombat() or self.hooks.ladderOOC()
    for i = 1, math.min(#list, 9) do
        if ready(list[i]) then return list[i] end
    end
    local w = self.cfg.AutoRezWith or 'NULL'
    if w ~= '' and w:upper() ~= 'NULL' and ready(w) then return w end
    return nil
end

--- RezPolicy: may I battle-rez this group member now?
function M:policy(name)
    if T.aggroTargetId() == 0 then return true end
    local m = mq.TLO.Group.Member(name)
    local cls = T.str(function() return m.Class.ShortName() end)
    if lower(name) == lower(State.mainAssist) or cls == 'WAR' or cls == 'PAL' or cls == 'SHD' then return (self.cfg.RezInCombatMA or 0) ~= 0 end
    if cls == 'ENC' and (self.cfg.RezEncMobsAt or 0) > 0 and T.num(function() return mq.TLO.SpawnCount('npc xtarhater radius 60')() end) >= self.cfg.RezEncMobsAt then return true end
    return false
end

--- The peer holding a claim on this corpse, or nil.
function M.claimHolder(id)
    if Timers.running('rez:claim:' .. id) and M.claims[id] then return M.claims[id].by end
    return nil
end

-- ------------------------------------------------------------- RezCheck
local function castRez(ability, corpseId, from)
    mq.cmdf('/squelch /target id %d', corpseId)
    mq.delay(1000, function() return targetId() == corpseId end)
    if targetId() ~= corpseId then return 'CAST_NOTARGET' end
    return Cast.cast(ability, corpseId, from or 'Rez')
end

function M:battleRez()
    for i = 1, T.groupCount() do
        local m = T.groupMember(i)
        local name = T.str(function() return m.CleanName() end)
        local corpse = name ~= '' and T.spawnByName(name, 'pccorpse') or nil
        if corpse then
            local present = T.bool(function() return m.Present() end) and not T.bool(function() return m.Dead() end) and not T.bool(function() return m.Hovering() end)
            local cid = T.num(function() return corpse.ID() end)
            if not (T.aggroTargetId() > 0 and present) and self:policy(name) then
                local holder = M.claimHolder(cid)
                if holder and lower(holder) ~= lower(T.myName()) then
                    if Timers.expired('rez:holderecho') then Timers.set('rez:holderecho', 10000) Log.pm('rez: %s is rezzing %s - I keep healing.', holder, name) end
                else
                    local ability = self:pickAbility(true)
                    local otherZone = T.bool(function() return m.OtherZone() end)
                    if ability and not (lower(ability):find('call of', 1, true) and not otherZone) then
                        local dist = T.num(function() return corpse.Distance() end)
                        if Timers.expired('rez:battle:' .. i) and dist < self.RADIUS then
                            local mana = Spell.facts(ability).mana or 0
                            if dist < 100 and T.num(function() return mq.TLO.Me.CurrentMana() end) > mana then
                                mq.cmdf('/squelch /target id %d', cid)
                                mq.delay(1000, function() return targetId() == cid end)
                                mq.cmd('/corpse')
                                mq.delay(200)
                                local ok = true
                                if T.num(function() return mq.TLO.Me.Invulnerable.ID() end) > 0 then
                                    if self.hooks.invulnSafeToDrop() then
                                        Comms.say('o', "I'M INVULNERABLE !!!")
                                        mq.cmdf('/removebuff %s', T.str(function() return mq.TLO.Me.Invulnerable() end))
                                        mq.delay(500, function() return T.num(function() return mq.TLO.Me.Invulnerable.ID() end) == 0 end)
                                    else ok = false end
                                end
                                if ok then
                                    local res = castRez(ability, cid, 'Rez')
                                    if res == 'CAST_SUCCESS' then
                                        Comms.say('o', 'BATTLE REZZED =>> %s <<= with %s', name, ability)
                                        Timers.set('rez:battle:' .. i, lower(ability):find('call of', 1, true) and 360000 or 180000)
                                        mq.cmd('/squelch /target clear')
                                    elseif lower(name) ~= lower(State.mainAssist) then
                                        Timers.set('rez:battle:' .. i, 60000)
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
end

function M:myCorpse()
    local id = T.num(function() return mq.TLO.Spawn(string.format('corpse %s radius %d zradius 50', T.myName(), self.RADIUS)).ID() end)
    if id == 0 then return end
    local ability = self:pickAbility(T.aggroTargetId() > 0)
    if Timers.running('rez:ooc:' .. id) or not ability then return end
    mq.cmdf('/target id %d', id)
    mq.delay(1000, function() return targetId() == id end)
    if T.num(function() return mq.TLO.Target.Distance() end) > (self.cfg.CampRadius or 30) then mq.cmd('/corpse') end
    local res = Cast.cast(ability, id, 'Rez')
    if res == 'CAST_SUCCESS' then Timers.set('rez:ooc:' .. id, 180000) end
end

function M:oocRez()
    if State.combatStart then return end
    local n = T.num(function() return mq.TLO.SpawnCount(string.format('pccorpse radius %d zradius 50', self.RADIUS))() end)
    for j = 1, n do
        local sp = mq.TLO.NearestSpawn(j, string.format('pccorpse radius %d zradius 50', self.RADIUS))
        local id = T.num(function() return sp.ID() end)
        local ability = self:pickAbility(false)
        if id > 0 and ability then
            local f = Spell.facts(ability)
            local manaOk = not (Spell.kind(ability) == 'spell' and f.mana >= T.num(function() return mq.TLO.Me.CurrentMana() end))
            if manaOk and Timers.expired('rez:ooc:' .. id) then
                local cname = T.str(function() return sp.CleanName() end)
                local pcName = cname:gsub("'s corpse%d*$", '')
                local xtarRez = false
                for _, slot in ipairs(self.hooks.xtarSlots and self.hooks.xtarSlots() or {}) do
                    if T.num(function() return mq.TLO.Me.XTarget(slot).ID() end) == id then xtarRez = true end
                end
                local peerRez = (self.cfg.RezDanNetPeers or 0) ~= 0 and Comms.isPeer(pcName)
                local myGuild = T.str(function() return mq.TLO.Me.Guild() end)
                local guildOk = myGuild ~= '' and T.str(function() return sp.Guild() end) == myGuild
                local fellow = T.num(function() return mq.TLO.Me.Fellowship.Member(pcName).ID() end) > 0
                local raid = T.num(function() return mq.TLO.Raid.Member(pcName).Level() end) > 0
                if guildOk or fellow or xtarRez or peerRez or raid then
                    local inZone = T.spawnByName(pcName, 'pc') ~= nil
                    if not (lower(ability):find('call of', 1, true) and inZone) and T.num(function() return sp.Distance() end) <= self.RADIUS then
                        local res = castRez(ability, id, 'Rez')
                        if res == 'CAST_SUCCESS' then
                            Comms.say('o', 'Rezzing =>> %s <<=', cname)
                            Timers.set('rez:ooc:' .. id, 300000)
                            mq.delay(3000, function() return T.num(function() return mq.TLO.Me.Casting.ID() end) == 0 end)
                            mq.cmd('/squelch /target clear')
                        end
                    end
                end
            end
        end
    end
end

function M:peerCorpseNotice()
    if (self.cfg.RezDanNetPeers or 0) == 0 or not Log.pmOn or State.combatStart or Timers.running('rez:peerecho') or not Comms.danNet() then return end
    for _, peer in ipairs(Comms.peers()) do
        local corpse = T.spawnByName(peer, 'pccorpse')
        if corpse and T.num(function() return corpse.Distance() end) > self.RADIUS then
            Log.pm('rez: peer %s has a corpse %d away - beyond RezRadius %d, not rezzing it from here.', peer, T.num(function() return corpse.Distance() end), self.RADIUS)
            Timers.set('rez:peerecho', 60000)
        end
    end
end

--- RezCheck: every part, gated as the macro.
function M:rezCheck()
    if State.buffMode or State.zombieMode or not State.autoRezOn then return end
    if T.bool(function() return mq.TLO.Me.Hovering() end) then return end
    if T.bool(function() return mq.TLO.Me.Invis() end) and T.aggroTargetId() == 0 then return end
    if self.cfg.AutoRezOn == 2 and T.aggroTargetId() > 0 then return end
    self.ranAt = T.now()
    self:battleRez()
    self:myCorpse()
    self:oocRez()
    self:peerCorpseNotice()
end

-- ------------------------------------------------------------- death and corpses
--- The dead flag clears once I am back in the camp zone with rez sickness or no corpse left (DoMiscStuff).
function M:deadTick()
    if State.combatStart or T.aggroTargetId() > 0 then return end
    if State.iAmDead and State.campZone == T.zoneId() then
        if T.num(function() return mq.TLO.Me.Buff('Resurrection Sickness').ID() end) > 0 or T.num(function() return mq.TLO.SpawnCount('pccorpse ' .. T.myName())() end) == 0 then
            State.iAmDead = false
        end
    end
end

--- ClearCorpse: loot my corpse after a rez on a pre-CotF server (corpses hold items there).
function M:clearCorpse()
    if T.bool(function() return mq.TLO.Me.HaveExpansion('Call of the Forsaken')() end) then return end
    if T.num(function() return mq.TLO.Me.Buff('Resurrection Sickness').ID() end) == 0 then return end
    local corpse = T.spawnByName(T.myName(), 'pccorpse')
    if not corpse or T.num(function() return corpse.Distance() end) >= 15 then return end
    if Timers.running('rez:clearcorpse') then return end
    Timers.set('rez:clearcorpse', 30000)
    Log.info('Trying to clear my corpse after rez')
    local id = T.num(function() return corpse.ID() end)
    mq.cmdf('/squelch /target id %d', id)
    mq.delay(1000, function() return targetId() == id end)
    mq.cmdf('/moveto id %d', id)
    mq.delay(1000, function() return T.num(function() return mq.TLO.Target.Distance() end) < 10 end)
    mq.cmd('/loot')
    mq.delay(1000, function() return T.bool(function() return mq.TLO.Window('LootWnd').Open() end) end)
    mq.cmd('/keypress esc')
    mq.delay(200)
end

--- RogDragging: a rogue drags the group's corpses back to camp under sneak/hide.
function M:rogDragging()
    local c = self.cfg
    if T.myClass() ~= 'ROG' or (c.RogCorpseRetrieval or 0) == 0 or not State.returnToCamp then return end
    if T.num(function() return mq.TLO.Spawn(string.format('group corpse radius %d', c.RogCorpseRadius or 500)).ID() end) == 0 then return end
    local total = T.num(function() return mq.TLO.SpawnCount('group corpse')() end)
    if total == T.num(function() return mq.TLO.SpawnCount(string.format('group corpse radius %d', c.CampRadius or 30))() end) then return end
    Log.info('Gonna try to retrieve group corpses back to camp')
    local until_ = T.now() + 10000
    while not T.bool(function() return mq.TLO.Me.Invis(4)() end) and T.now() < until_ do
        if not T.bool(function() return mq.TLO.Me.Sneaking() end) then mq.cmd('/doability sneak') end
        mq.cmd('/doability hide')
        mq.delay(1000, function() return T.bool(function() return mq.TLO.Me.Invis(4)() end) end)
    end
    if not T.bool(function() return mq.TLO.Me.Invis(4)() end) then Log.info("Couldn't sneak/hide") return end
    local ids = {}
    for j = 1, total do ids[#ids + 1] = T.num(function() return mq.TLO.NearestSpawn(j, 'group corpse').ID() end) end
    for j, id in ipairs(ids) do
        local sp = T.spawn(id)
        if sp then
            mq.cmdf('/nav id %d', id)
            mq.cmdf('/squelch /target id %d', id)
            mq.delay(1000, function() return T.num(function() return mq.TLO.Navigation.Velocity() end) > 0 end)
            if not T.bool(function() return mq.TLO.Navigation.PathExists('id ' .. id)() end) then return end
            Cast.tickDelay(30000, function() return not T.spawn(id) or T.num(function() return T.spawn(id).Distance() end) <= 100 end)
            mq.cmd('/nav stop')
            mq.delay(200)
            mq.cmd('/corpsedrag')
            mq.delay(800)
            local second = ids[j + 1]
            if second and T.spawn(second) and T.num(function() return T.spawn(second).Distance() end) <= 100 then
                mq.cmdf('/squelch /target id %d', second)
                mq.delay(1000)
                mq.cmd('/corpsedrag')
                mq.delay(500)
            else second = nil end
            Cast.hooks.doWeMove('RogDrag')
            Cast.tickDelay(60000, function() return require('modules.movement').distToCampLoc() <= (c.CampRadius or 30) end)
            mq.cmdf('/squelch /target id %d', id)
            mq.delay(1000)
            mq.cmd('/corpsedrop')
            mq.delay(700)
            if second then mq.cmdf('/squelch /target id %d', second) mq.delay(1000) mq.cmd('/corpsedrop') mq.delay(700) end
        end
    end
end

-- ------------------------------------------------------------- events
function M:Init()
    local function claim(_, sender, corpseName, corpseId, claimant, pri)
        local id = tonumber(corpseId) or 0
        pri = tonumber(pri) or 0
        if id == 0 or lower(claimant) == lower(T.myName()) then return end
        local mine = M.claims[id]
        if Timers.running('rez:claim:' .. id) and mine and lower(mine.by) == lower(T.myName()) then
            if pri < mine.pri or (pri == mine.pri and claimant > T.myName()) then return end
            Log.pm('rez: yielding %s to %s (emeralds %d vs mine %d)', corpseName, claimant, pri, mine.pri)
        end
        M.claims[id] = { by = claimant, pri = pri }
        Timers.set('rez:claim:' .. id, (M.cfg.RezClaimHold or 20) * 1000)
        Log.pm('rez: %s claims %s (%d, emeralds %d) - holding my rez for %ds', claimant, corpseName, id, pri, M.cfg.RezClaimHold or 20)
    end
    mq.event('ma_rezclaim1', '[ #1# (#*#) ]#*#REZCLAIM-> #2# <- ID:#3# BY:#4# PRI:#5#', claim)
    mq.event('ma_rezclaim2', '<#1#>#*#REZCLAIM-> #2# <- ID:#3# BY:#4# PRI:#5#', claim)
    local function done(_, sender, corpseName, corpseId)
        local id = tonumber(corpseId) or 0
        if id == 0 or not M.claims[id] then return end
        Timers.clear('rez:claim:' .. id)
        Log.pm('rez: %s rezzed %s (%d)', sender, corpseName, id)
    end
    mq.event('ma_rezdone1', '[ #1# (#*#) ]#*#REZDONE-> #2# <- ID:#3#', done)
    mq.event('ma_rezdone2', '<#1#>#*#REZDONE-> #2# <- ID:#3#', done)
    require('modules.combat').hooks.onDeath = function() M:onDeath() end
    require('modules.heals').hooks.rezCheck = function()
        if not State.autoRezOn or (M.ranAt and T.now() - M.ranAt < 1000) then return end
        if T.num(function() return mq.TLO.SpawnCount(string.format('pccorpse radius %d zradius 50', M.RADIUS))() end) == 0 then M.ranAt = T.now() return end
        M:rezCheck()
    end
end

function M:Shutdown()
    for _, e in ipairs({ 'ma_rezclaim1', 'ma_rezclaim2', 'ma_rezdone1', 'ma_rezdone2' }) do pcall(mq.unevent, e) end
end

--- Event_ImDead's extras (the combat module flags the death and resets the fight).
function M:onDeath()
    Log.info('I have died and the Angels wept.')
    self.hooks.onDeath()
end

function M:GiveTime(ctx)
    if State.chainPull == 2 or State.getAwayFollow then return end
    self:deadTick()
    if T.bool(function() return mq.TLO.Me.Hovering() end) then return end
    if State.autoRezOn and (not self.ranAt or T.now() - self.ranAt >= 1000) then self:rezCheck() end
    if Timers.expired('rez:misc') then
        Timers.set('rez:misc', 5000)
        self:clearCorpse()
        self:rogDragging()
    end
end

M.Binds = {
    ['/autorezon'] = function(self, arg)
        local v = tonumber(arg)
        if arg == 'on' then v = 1 elseif arg == 'off' then v = 0 end
        if v == nil then v = (self.cfg.AutoRezOn or 0) == 0 and 1 or 0 end
        self.cfg.AutoRezOn = v
        State.autoRezOn = v ~= 0
        Log.info('AutoRezOn %d', v)
    end,
}

return M
