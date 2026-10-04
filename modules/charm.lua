-- modules/charm.lua: charm pets. CharmMaintenance (the 5 s ping, the watchdog sweep, adopt, assist-tash,
-- the auto pick, the recharm), CharmWatchSweep / CharmRelease, AutoCharmPick (the MobDPS score),
-- CharmStuff (stun, short mez, retash, charm, 3 tries), CharmAESafe, CharmAdoptCheck, CharmAssistTash,
-- CharmPetHeal, the /charmthis /charmadd /charmping /charmdel /charmsync /autocharm /charmhold binds and
-- the Charmed / CannotCharm events, with the same [Charm] keys as the macro. The group-wide protect list
-- is State.charmPetIds (a set) that the combat and pet modules read.
local mq = require('mq')
local T = require('core.tlo')
local Config = require('core.config')
local Timers = require('core.timers')
local Spell = require('core.spell')
local Cast = require('core.cast')
local Comms = require('core.comms')
local Log = require('core.log')
local State = require('core.state')
local Ini = require('core.ini')

local M = { name = 'charm' }

local CHARM_CLASSES = { ENC = true, DRU = true, NEC = true }
M.Settings = {
    scalars = {
        { section = 'Charm', key = 'CharmAutoOn', type = 'int', default = 0 },
        { section = 'Charm', key = 'CharmStunOn', type = 'int', default = 1 },
        { section = 'Charm', key = 'CharmWatchSec', type = 'int', default = 15 },
        { section = 'Charm', key = 'CharmRetashOn', type = 'int', default = 1 },
        { section = 'Charm', key = 'CharmDoNotList', type = 'string', default = 'NULL', rank = false },
        { section = 'Charm', key = 'CharmDoNotClass', type = 'string', default = 'NULL', rank = false },
        { section = 'Charm', key = 'CharmOnlyList', type = 'string', default = 'NULL', rank = false },
        { section = 'Heals', key = 'CharmHealOn', type = 'int', default = 0 },
        { section = 'Heals', key = 'CharmHealCombat', type = 'string', default = 'NULL', rank = false },
        { section = 'Heals', key = 'CharmHealOOC', type = 'string', default = 'NULL', rank = false },
    },
}
M.cfg = {}
M.petId = 0            -- my charm pet (CharmPetID)
M.hold = false         -- /charmhold
M.liveIds = {}         -- ids pinged this window
M.ownerMap = {}        -- id -> owner name (newest ping wins)
M.hideCorpse = false
M.hooks = { skipIds = function() return {} end, skipAdd = function(id) end, zoneImmune = function(name) return false end, anyPCNeedsHeal = function() return false end }

local function lower(s) return tostring(s or ''):lower() end
local function targetId() return T.num(function() return mq.TLO.Target.ID() end) end
local function petId() return T.num(function() return mq.TLO.Me.Pet.ID() end) end
local function charmClass() return CHARM_CLASSES[T.myClass()] == true end
local function listTokens(s)
    local out = {}
    s = tostring(s or '')
    if s == '' or s:upper() == 'NULL' then return out end
    for t in s:gmatch('[^|]+') do out[#out + 1] = t end
    return out
end
local function groupPCs()
    local out = {}
    for i = 1, T.groupCount() do
        local m = T.groupMember(i)
        if T.str(function() return m.Type() end) == 'PC' then out[#out + 1] = T.str(function() return m.CleanName() end) end
    end
    return out
end
local function fanOut(cmd) for _, n in ipairs(groupPCs()) do Comms.exec(n, cmd) end end
local function charmGems()
    local out = {}
    for g = 1, 13 do
        local sp = mq.TLO.Me.Gem(g)
        if T.num(function() return sp.ID() end) > 0 and T.bool(function() return sp.HasSPA(22)() end) then out[#out + 1] = { gem = g, name = T.str(function() return sp.Name() end), node = sp } end
    end
    return out
end
local function bodyOk(spellNode, sp)
    local tt = T.str(function() return spellNode.TargetType() end)
    if tt == 'Undead' or tt == 'Animal' or tt == 'Summoned' then return T.str(function() return sp.Body.Name() end) == tt end
    return true
end

function M:LoadSettings()
    self.cfg = Config.load(self.Settings)
    State.charmPetIds = State.charmPetIds or {}
    if (self.cfg.CharmWatchSec or 0) > 0 then Timers.set('charm:watch', self.cfg.CharmWatchSec * 1000) end
end

-- ------------------------------------------------------------- the protect list
function M:add(id)
    id = tonumber(id) or 0
    if id == 0 then return end
    if not State.charmPetIds[id] then
        State.charmPetIds[id] = true
        local sp = T.spawn(id)
        Log.info('Protecting charm pet %s (%d).', sp and T.str(function() return sp.CleanName() end) or '?', id)
    end
end
function M:del(arg)
    local a = lower(arg)
    if a == 'all' or a == 'clear' or a == 'clearall' then
        State.charmPetIds, self.liveIds, self.ownerMap = {}, {}, {}
        self.petId = 0
        Log.info('Cleared the charm protect list.')
        return
    end
    local id = tonumber(arg) or 0
    if id == 0 then Log.info('/charmdel needs a spawn ID (or "all"). Got: %s', tostring(arg)) return end
    State.charmPetIds[id] = nil
    if self.petId == id then self.petId = 0 end
end
function M:release(id, why)
    local sp = T.spawn(id)
    Comms.say('r', 'Releasing charm pet %s (%d) - %s. Kill it!', sp and T.str(function() return sp.CleanName() end) or '?', id, why)
    fanOut('/charmdel ' .. id)
    self:del(tostring(id))
end
function M:clearMine()
    if self.petId > 0 then
        fanOut('/charmdel ' .. self.petId)
        self:del(tostring(self.petId))
    end
    self.petId = 0
    local ids = {}
    for id in pairs(State.charmPetIds) do ids[#ids + 1] = tostring(id) end
    Log.info('Cleared my charm pet. Protect list is now: %s', table.concat(ids, '|'))
end

--- /charmthis <id|clear|clearall> [Box] [autocharm|adopt|event]
function M:charmThis(arg, turing, from)
    local a = lower(arg)
    if a == '' and (from == 'event' or from == 'adopt') then Log.info('Probably some other charmer charmed a pet. Not gonna change anything.') return end
    if a == 'clear' then self:clearMine() return end
    if a == 'clearall' then fanOut('/charmdel all') self:del('all') Log.info("Reset everyone's charm data.") return end
    local id = tonumber(arg) or 0
    if a == '' then
        local tt = T.str(function() return mq.TLO.Target.Type() end)
        if tt ~= 'NPC' and tt ~= 'Pet' then Log.info('No valid ID or NPC/pet target. Keeping CharmPetID %d.', self.petId) return end
        id = targetId()
    elseif id == 0 then Log.info('/charmthis needs a spawn ID (or no arg with an NPC targeted), "clear", or "clearall". Got: %s', tostring(arg)) return end
    if lower(turing) ~= 'box' then fanOut(string.format('/charmthis %d Box', id)) end
    self:add(id)
    if not charmClass() then return end
    local sp = T.spawn(id)
    local name = sp and T.str(function() return sp.CleanName() end) or '?'
    if self.hold then Log.info('Charm is on hold (/charmhold off to resume) - %s is protected, not adopted.', name) return end
    if self.petId > 0 and petId() == self.petId then Log.info('Keeping my current charm pet %d. %d is on the protect list.', self.petId, id) return end
    if sp then
        local master = T.num(function() return sp.Master.ID() end)
        if master > 0 and master ~= T.myId() then Log.info("%s is %s's pet. Protecting it but not adopting it.", name, T.str(function() return sp.Master.CleanName() end)) return end
    end
    self.petId = id
    Log.info('My CharmPetID is set to %d (%s)', id, name)
end

-- ------------------------------------------------------------- the watchdog
function M:watchSweep()
    local c = self.cfg
    if (c.CharmWatchSec or 0) == 0 then return end
    if next(State.charmPetIds) == nil then Timers.set('charm:watch', c.CharmWatchSec * 1000) return end
    local silence = Timers.expired('charm:watch')
    for id in pairs(State.charmPetIds) do
        local sp = T.spawn(id)
        if id ~= self.petId and sp and T.str(function() return sp.Type() end) == 'NPC' and T.num(function() return sp.Master.ID() end) == 0 then
            local owner = self.ownerMap[id]
            if owner then
                local os = T.spawnByName(owner, 'pc')
                if not os or T.bool(function() return os.Linkdead() end) or T.bool(function() return os.Dead() end) then self:release(id, string.format('its charmer %s is dead, linkdead or gone', owner)) end
            elseif silence and not self.liveIds[id] then
                self:release(id, 'no heartbeat from its charmer all window')
            end
        end
    end
    if silence then self.liveIds = {} Timers.set('charm:watch', c.CharmWatchSec * 1000) end
end

-- ------------------------------------------------------------- AutoCharmPick
function M:autoPick()
    local c = self.cfg
    Timers.set('charm:auto', 3000)
    local gems = charmGems()
    local pick = nil
    for _, g in ipairs(gems) do if T.num(function() return mq.TLO.Me.GemTimer(g.gem)() end) == 0 then pick = g break end end
    if not pick then return end
    if T.num(function() return pick.node.Mana() end) * 2 > T.num(function() return mq.TLO.Me.CurrentMana() end) then return end
    local maxLevel = T.num(function() return pick.node.MaxLevel() end)
    local skip = self.hooks.skipIds()
    local best, bestScore = nil, -1
    local server = T.str(function() return mq.TLO.EverQuest.Server() end)
    local zone = T.str(function() return mq.TLO.Zone.ShortName() end)
    for i = 1, 13 do
        local xt = mq.TLO.Me.XTarget(i)
        local id = T.num(function() return xt.ID() end)
        local sp = id > 0 and T.spawn(id) or nil
        if sp and T.str(function() return xt.TargetType() end) == 'Auto Hater' and T.str(function() return sp.Type() end) == 'NPC' and id ~= (State.myTargetId or 0)
            and not State.charmPetIds[id] and not skip[id] and T.num(function() return sp.Master.ID() end) == 0
            and T.num(function() return sp.Level() end) <= maxLevel and T.num(function() return sp.Distance() end) < 100 and T.bool(function() return sp.LineOfSight() end) then
            local name = T.str(function() return sp.CleanName() end)
            local ok = bodyOk(pick.node, sp)
            local cls = T.str(function() return sp.Class.ShortName() end)
            if ok and cls ~= '' and lower(c.CharmDoNotClass):find(lower(cls), 1, true) then ok = false end
            if ok then for _, t in ipairs(listTokens(c.CharmDoNotList)) do if lower(name):find(lower(t), 1, true) then ok = false end end end
            if ok and self.hooks.zoneImmune(name) then ok = false end
            local only = listTokens(c.CharmOnlyList)
            if ok and #only > 0 then
                ok = false
                for _, t in ipairs(only) do if lower(name):find(lower(t), 1, true) then ok = true end end
            end
            if ok then
                local dps = tonumber(Ini.read(string.format('MobDPS_%s_%s.ini', server, State.mainAssist), zone, name)) or 0
                local score = dps * 1000 + T.num(function() return sp.Level() end) * 10 - T.num(function() return sp.Distance() end) / 100
                if score > bestScore then best, bestScore = { id = id, name = name, dps = dps }, score end
            end
        end
    end
    if best then
        Log.pm('charm: acquiring %s (%d) with %s - score %d (dps %s).', best.name, best.id, pick.name, bestScore, best.dps > 0 and tostring(best.dps) or 'none')
        self:charmThis(tostring(best.id), 'autocharm', 'autocharm')
    end
end

-- ------------------------------------------------------------- CharmStuff
function M:aeSafe(gemNode)
    local range = T.num(function() return gemNode.AERange() end)
    local loc = string.format('loc %d %d radius %d', T.num(function() return mq.TLO.Me.X() end), T.num(function() return mq.TLO.Me.Y() end), range)
    local haters = T.num(function() return mq.TLO.SpawnCount('npc xtarhater ' .. loc)() end)
    local all = T.num(function() return mq.TLO.SpawnCount('npc ' .. loc)() end)
    local mt = State.myTargetId or 0
    if mt > 0 then
        local pinned = true
        for i = 1, 13 do if T.num(function() return mq.TLO.Me.XTarget(i).ID() end) == mt and T.str(function() return mq.TLO.Me.XTarget(i).TargetType() end) == 'Auto Hater' then pinned = false end end
        local ms = T.spawn(mt)
        if pinned and ms and T.num(function() return ms.Distance() end) <= range then haters = haters + 1 end
    end
    if haters < all then Log.info('Skipping PB AE %s - %d non-aggro NPC(s) within %d would join the fight.', T.str(function() return gemNode.Name() end), all - haters, range) return false end
    return true
end

function M:charmStuff()
    local c = self.cfg
    if not self.hideCorpse and T.num(function() return mq.TLO.SpawnCount('npc corpse radius 20')() end) > 0 then mq.cmd('/hidec alwaysnpc') self.hideCorpse = true end
    if not charmClass() or petId() > 0 then return end
    local sp = T.spawn(self.petId)
    if not sp then return end
    local level = T.num(function() return sp.Level() end)
    local gems = charmGems()
    local mana = T.num(function() return mq.TLO.Me.CurrentMana() end)
    local charm = nil
    for _, g in ipairs(gems) do
        if mana > T.num(function() return g.node.Mana() end) then
            charm = charm or g
            if T.num(function() return g.node.MaxLevel() end) >= level and bodyOk(g.node, sp) then charm = g break end
        end
    end
    local name = T.str(function() return sp.CleanName() end)
    for try = 1, 3 do
        sp = T.spawn(self.petId)
        if not sp or petId() > 0 or T.num(function() return sp.Master.ID() end) > 0 or T.num(function() return sp.Distance() end) >= 200 or T.str(function() return sp.Type() end) == 'Corpse' then return end
        if not charm then
            for i = 1, T.groupCount() do
                local m = T.groupMember(i)
                local cls = T.str(function() return m.Class.ShortName() end)
                if CHARM_CLASSES[cls] and T.num(function() return m.ID() end) ~= T.myId() and T.num(function() return m.Distance() end) < 100 then return end
            end
            Log.info('I have no spell to charm with! Just kill the Smooshers :(. ')
            self:clearMine()
            return
        end
        local cf = Spell.facts(charm.name)
        if cf.mana > T.num(function() return mq.TLO.Me.CurrentMana() end) then
            Comms.say('r', "I don't have mana to charm my pet. Just kill the Smooshers")
            self.hooks.skipAdd(self.petId)
            self:clearMine()
            return
        end
        if not bodyOk(charm.node, sp) then
            Log.info('%s only charms %s targets and %s is %s. Clearing my charm pet.', charm.name, T.str(function() return charm.node.TargetType() end), name, T.str(function() return sp.Body.Name() end))
            self.hooks.skipAdd(self.petId)
            self:clearMine()
            return
        end
        if not T.bool(function() return mq.TLO.Me.Standing() end) then
            mq.cmd('/stand')
            mq.delay(1000, function() return T.bool(function() return mq.TLO.Me.Standing() end) end)
            if not T.bool(function() return mq.TLO.Me.Standing() end) then Log.info("Can't charm! I'm not standing!") return end
        end
        -- a PB AE stun, then a PB AE short mez, to get the mob under control
        for _, want in ipairs({ { spa = 21, what = 'a stun' }, { spa = 31, what = 'a short duration Mez' } }) do
            if petId() > 0 then break end
            for g = 1, 13 do
                local gn = mq.TLO.Me.Gem(g)
                if T.num(function() return gn.ID() end) > 0 and ((want.spa == 21 and (c.CharmStunOn or 1) ~= 0) or want.spa == 31) and T.bool(function() return gn.HasSPA(want.spa)() end)
                    and level <= T.num(function() return gn.MaxLevel() end) and T.str(function() return gn.TargetType() end):find('PB AE', 1, true) and T.num(function() return mq.TLO.Me.GemTimer(g)() end) == 0
                    and (want.spa ~= 31 or T.num(function() return gn.Duration() end) <= 3) then
                    if T.num(function() return gn.Mana() end) + cf.mana > T.num(function() return mq.TLO.Me.CurrentMana() end) then break end
                    if not self:aeSafe(gn) then break end
                    Log.info('%s is either %s. Gonna cast it real quick to get the mob under control.', T.str(function() return gn.Name() end), want.what)
                    Cast.cast(T.str(function() return gn.Name() end), self.petId, 'CharmStuff', { skipOhShit = true, dontRecast = true })
                    break
                end
            end
        end
        -- retash
        if (c.CharmRetashOn or 1) ~= 0 and petId() == 0 then
            for _, g in ipairs(gems) do end
            for g = 1, 13 do
                local gn = mq.TLO.Me.Gem(g)
                local gname = T.str(function() return gn.Name() end)
                if gname:find('Tash', 1, true) and T.num(function() return mq.TLO.Me.GemTimer(g)() end) == 0 and targetId() == self.petId
                    and T.num(function() return mq.TLO.Target.Tashed.ID() end) == 0 and T.num(function() return mq.TLO.Target.Buff(gname).ID() end) == 0 then
                    if T.num(function() return gn.Mana() end) + cf.mana <= T.num(function() return mq.TLO.Me.CurrentMana() end) then
                        Log.info('%s is a form of Tash. Gonna cast it on our pet.', gname)
                        Cast.cast(gname, self.petId, 'CharmStuff', { skipOhShit = true, dontRecast = true })
                    end
                    break
                end
            end
        end
        if petId() == 0 then
            if level <= T.num(function() return charm.node.MaxLevel() end) then
                local res = Cast.cast(charm.name, self.petId, 'CharmStuff', { skipOhShit = true, dontRecast = true })
                if res == 'NoLOS' then
                    if Timers.expired('charm:pm') then Timers.set('charm:pm', 10000) Log.pm('charm: no line of sight to %s (%d) - retrying the recharm next pass', name, self.petId) end
                    return
                end
            else
                Log.info("Can't charm %s because %s only affects creatures up to level %d and it is level %d", name, charm.name, T.num(function() return charm.node.MaxLevel() end), level)
                self.hooks.skipAdd(self.petId)
                self:clearMine()
                return
            end
        end
        mq.doevents()
        if petId() > 0 or self.petId == 0 then return end
        if try == 3 and Timers.expired('charm:pm') then
            Timers.set('charm:pm', 10000)
            Log.pm('charm: %s (%d) still not charmed after 3 tries - back to the main loop, retrying next pass', name, self.petId)
        end
    end
end

-- ------------------------------------------------------------- adopt, assist tash, the pet heal
function M:adoptCheck()
    local pid = petId()
    if pid == 0 or pid == self.petId or pid == self.adoptChecked then return end
    self.adoptChecked = pid
    for _, g in ipairs(charmGems()) do
        if T.num(function() return mq.TLO.Me.PetBuff(g.name)() end) > 0 then
            Log.info('Detected my charm %s on %s - registering it as my charm pet.', g.name, T.str(function() return mq.TLO.Me.Pet.CleanName() end))
            self:charmThis(tostring(pid), 'adopt', 'adopt')
            return
        end
    end
end

function M:assistTash()
    if next(State.charmPetIds) == nil then return end
    Timers.set('charm:assisttash', 5000)
    local tash = nil
    for g = 1, 13 do
        local gn = mq.TLO.Me.Gem(g)
        local gname = T.str(function() return gn.Name() end)
        if gname:find('Tash', 1, true) and T.num(function() return mq.TLO.Me.GemTimer(g)() end) == 0 and T.num(function() return gn.Mana() end) <= T.num(function() return mq.TLO.Me.CurrentMana() end) then tash = gname break end
    end
    if not tash then return end
    for id in pairs(State.charmPetIds) do
        local sp = T.spawn(id)
        if sp and id ~= self.petId and T.str(function() return sp.Type() end) == 'NPC' and T.num(function() return sp.Master.ID() end) == 0 and T.num(function() return sp.Distance() end) < 200 and T.bool(function() return sp.LineOfSight() end) then
            Timers.set('charm:assisttash', 5000)
            if targetId() ~= id then mq.cmdf('/squelch /target id %d', id) mq.delay(1000, function() return targetId() == id end) require('core.buffcheck').targetBuffWait() end
            if targetId() == id and Timers.expired('tashat:' .. id) and T.num(function() return mq.TLO.Target.Tashed.ID() end) == 0 and T.num(function() return mq.TLO.Target.Buff(tash).ID() end) == 0 then
                Log.info('Tashing broken charm pet %s with %s so it can be recharmed.', T.str(function() return sp.CleanName() end), tash)
                if Cast.cast(tash, id, 'CharmStuff', { skipOhShit = true, dontRecast = true }) == 'CAST_SUCCESS' then
                    local d = Spell.facts(tash).durationSec
                    Timers.set('tashat:' .. id, (d > 0 and d or 60) * 1000)
                end
            end
            return
        end
    end
end

function M:petHeal()
    local c = self.cfg
    if (c.CharmHealOn or 0) == 0 or next(State.charmPetIds) == nil then return end
    if self.hooks.anyPCNeedsHeal() then return end
    if T.bool(function() return mq.TLO.Me.Hovering() end) or T.bool(function() return mq.TLO.Me.Moving() end) then return end
    if T.bool(function() return mq.TLO.Me.Invis() end) and T.aggroTargetId() == 0 then return end
    local entry = T.aggroTargetId() > 0 and c.CharmHealCombat or c.CharmHealOOC
    if not entry or entry == '' or entry:upper() == 'NULL' then return end
    local spell, pct = entry:match('^([^|]*)|?(.*)$')
    pct = tonumber(pct) or 80
    local range = Spell.facts(spell).range
    if range == 0 then range = 100 end
    local low, lowId = 100, 0
    for id in pairs(State.charmPetIds) do
        local sp = T.spawn(id)
        if sp and T.str(function() return sp.Type() end) ~= 'Corpse' and T.num(function() return sp.Distance3D() end) < range then
            local hp = T.num(function() return sp.PctHPs() end)
            if hp < low then low, lowId = hp, id end
        end
    end
    if lowId == 0 or low >= pct then return end
    if Cast.cast(spell, lowId, 'CharmHeal') == 'CAST_SUCCESS' then
        Comms.say('o', 'CHARM PET HEAL >> %s << with %s (was %d%%)', T.str(function() return T.spawn(lowId).CleanName() end), spell, low)
        require('modules.heals').healAgain = true
    end
end

-- ------------------------------------------------------------- CharmMaintenance
function M:maintenance()
    if self.charmedPending and T.num(function() return mq.TLO.Me.Casting.ID() end) == 0 then local n = self.charmedPending self.charmedPending = nil self:onCharmed(n) end
    local c = self.cfg
    if (c.CharmWatchSec or 0) > 0 and self.petId > 0 and Timers.expired('charm:ping') then
        Timers.set('charm:ping', 5000)
        Comms.group(string.format('/charmping %d %s', self.petId, T.myName()))
    end
    self:watchSweep()
    if self.hold then return end
    if charmClass() and petId() > 0 and petId() ~= self.petId then self:adoptCheck() end
    if T.myClass() == 'ENC' and Timers.expired('charm:assisttash') then self:assistTash() end
    if (c.CharmAutoOn or 0) ~= 0 and petId() == 0 and self.petId == 0 and charmClass() and Timers.expired('charm:auto') then self:autoPick() end
    if self.petId > 0 then
        local sp = T.spawn(self.petId)
        if sp and T.str(function() return sp.Type() end) ~= 'Corpse' then self:charmStuff() end
    end
end

--- CombatReset's charm part: drop dead pets, notice a lost charm pet.
function M:onReset()
    for id in pairs(State.charmPetIds) do
        local sp = T.spawn(id)
        if not sp or T.str(function() return sp.Type() end) == 'Corpse' then State.charmPetIds[id] = nil end
    end
    if self.petId > 0 then
        local sp = T.spawn(self.petId)
        if not sp or T.str(function() return sp.Type() end) == 'Corpse' then Log.info('We lost my charm pet. RIP Smooshers.') self.petId = 0 end
    end
    self.hideCorpse = false
end

function M:onDeath()
    if self.petId > 0 then
        local sp = T.spawn(self.petId)
        Comms.say('r', 'I died - kill my charm pet %s (%d).', sp and T.str(function() return sp.CleanName() end) or '?', self.petId)
        self.hooks.skipAdd(self.petId)
        self:clearMine()
    end
end

function M:Init()
    mq.event('ma_charmed1', '#1# has been charmed.', function(_, name) M:onCharmed(name) end)
    mq.event('ma_charmed2', '#1# moans.', function(_, name) M:onCharmed(name) end)
    mq.event('ma_cannotcharm', 'This NPC cannot be charmed.', function()
        local t = targetId()
        Log.info('%s cannot be charmed', T.str(function() return mq.TLO.Target.CleanName() end))
        M.hooks.skipAdd(t)
        require('modules.mez'):zonePersist('charm', t)
        M:clearMine()
    end)
    local Combat = require('modules.combat')
    Combat.hooks.charmMaintenance = function() M:maintenance() end
    Combat.addResetHook('charm', function() M:onReset() end)
    local Mez = require('modules.mez')
    self.hooks.skipIds = function() return Mez.charmSkipIds end
    self.hooks.skipAdd = function(id) Mez:charmSkipAdd(id) end
    self.hooks.zoneImmune = function(name) return Mez:zoneHas('charm', name) end
    local Heals = require('modules.heals')
    Heals.hooks.charmPetHeal = function() M:petHeal() end
    self.hooks.anyPCNeedsHeal = function() return Heals:anyPCNeedsHeal() end
    local Rez = require('modules.rez')
    local prev = Rez.hooks.onDeath
    Rez.hooks.onDeath = function() prev() M:onDeath() end
end

function M:onCharmed(name)
    if not charmClass() then return end
    if T.num(function() return mq.TLO.Me.Casting.ID() end) > 0 then self.charmedPending = name return end   -- fired from Cast.wait's doevents
    self.charmedPending = nil
    local same = self.petId > 0 and T.spawn(self.petId) and lower(T.str(function() return T.spawn(self.petId).CleanName() end)) == lower(name)
    local pid = petId()
    local sp = T.spawnByName(name)
    if pid > 0 and sp and T.str(function() return sp.Type() end) == 'Pet' and T.num(function() return sp.Distance() end) < 100 and T.num(function() return sp.ID() end) == pid then
        Comms.say('g', '%s is my new pet and his ID is %d', name, pid)
        self.petId = pid
        Log.info('My new charm pet is %s (%d)', name, pid)
        if not same then self:charmThis(tostring(pid), 'event', 'event') end
        require('modules.combat'):combatReset('Charmed')
    end
end

function M:Shutdown()
    for _, e in ipairs({ 'ma_charmed1', 'ma_charmed2', 'ma_cannotcharm' }) do pcall(mq.unevent, e) end
end

function M:OnZone()
    if self.petId > 0 then
        Comms.say('y', 'I zoned away - kill my old charm pet (%d).', self.petId)
        self:clearMine()
    end
    self.petId = 0
end

function M:GiveTime(ctx)
    if State.getAwayFollow then return end
    if not ctx.inCombat then self:maintenance() end
end

M.Binds = {
    ['/charmthis'] = function(self, arg, turing, from) self:charmThis(arg or '', turing or '', lower(from or '')) end,
    ['/charmadd'] = function(self, arg) local id = tonumber(arg) if not id then if arg ~= '' and lower(arg) ~= 'null' and arg ~= '0' then Log.info('/charmadd needs a spawn ID. Got: %s', tostring(arg)) end return end self:add(id) end,
    ['/charmping'] = function(self, arg, owner)
        local id = tonumber(arg) or 0
        if id == 0 then return end
        self.liveIds[id] = true
        if owner and owner ~= '' then
            for oid, o in pairs(self.ownerMap) do if lower(o) == lower(owner) then self.ownerMap[oid] = nil end end
            self.ownerMap[id] = owner
        end
    end,
    ['/charmdel'] = function(self, arg) if arg and arg ~= '' then self:del(arg) end end,
    ['/charmsync'] = function(self, mode)
        if lower(mode) ~= 'respond' then fanOut('/charmsync respond') return end
        for id in pairs(State.charmPetIds) do
            local sp = T.spawn(id)
            if sp and T.str(function() return sp.Type() end) ~= 'Corpse' then fanOut('/charmadd ' .. id) end
        end
    end,
    ['/autocharm'] = function(self)
        local v = (self.cfg.CharmAutoOn or 0) == 0 and 1 or 0
        self.cfg.CharmAutoOn = v
        Config.set('Charm', 'CharmAutoOn', v)
        Log.info('AutoCharm is now %s', v == 1 and 'ON' or 'OFF')
    end,
    ['/charmhold'] = function(self, arg)
        local a = lower(arg)
        if a == 'off' or a == '0' or a == 'resume' or (a == '' and self.hold) then
            self.hold = false
            Log.info('Charm hold OFF - charming resumes (AutoCharm %s).', (self.cfg.CharmAutoOn or 0) ~= 0 and 'ON' or 'OFF')
        elseif a == 'on' or a == '1' or a == '' then
            self.hold = true
            if self.petId > 0 then
                Log.info('Charm hold ON - clearing my charm pet %s (%d); the invis breaks the charm, kill it.', T.str(function() return T.spawn(self.petId) and T.spawn(self.petId).CleanName() end), self.petId)
                self:clearMine()
            end
            Log.info('Charm hold ON - no charming until /charmhold off.')
        else
            Log.info('/charmhold needs on or off (no arg toggles). Got: %s', tostring(arg))
        end
    end,
}

return M
