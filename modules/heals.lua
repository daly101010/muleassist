-- modules/heals.lua: CheckHealth, SingleHeal (tap / mob / direct), DoGroupHealStuff, DoPetHealStuff,
-- AnyPCNeedsHeal, the heal-line split (FindSingleHeals / FindGroupHeals / the rez ladders), the SmartHeals
-- engine (modules/smartheal), the heal interrupt rules (WaitCast / KACheckHP) and ManaFeed, with the same [Heals] / [ManaFeed]
-- keys and line tags as the macro.
--
-- Not a transliteration: heal timers are per line AND per target spawn (`heal:<line>:<id>`) instead of the
-- Spell<i>GM<WhoNum> slots; an interrupted heal counts as interrupted, not landed; RezCheck runs once per
-- pass (the macro called it up to five times); a Tap / Mob cast that fails does not fall through into the
-- direct-heal block. Charm pet heals and the healer-aggro check are hooks filled by their own modules.
-- the SmartHeals picks come from modules/smartheal.lua (the forked engine, in-process) through M.smartSet;
-- every cast or skip is reported back through its onResult.
local mq = require('mq')
local T = require('core.tlo')
local Config = require('core.config')
local Timers = require('core.timers')
local Spell = require('core.spell')
local Cast = require('core.cast')
local Comms = require('core.comms')
local Log = require('core.log')
local Cond = require('core.cond')
local State = require('core.state')
local Stats = require('core.stats')
local Lines = require('core.lines')
local Buffcheck = require('core.buffcheck')

local M = { name = 'heals' }

M.Settings = {
    scalars = {
        { section = 'Heals', key = 'HealsOn', type = 'int', default = 0 },
        { section = 'Heals', key = 'FreshAddHoldOn', type = 'int', default = 1 },
        { section = 'Heals', key = 'FreshAddHoldPct', type = 'int', default = 50 },
        { section = 'Heals', key = 'FreshAddHoldSec', type = 'int', default = 6 },
        { section = 'Heals', key = 'FreshAddRange', type = 'int', default = 60 },
        { section = 'Heals', key = 'HealsCOn', type = 'int', default = 0 },
        { section = 'Heals', key = 'InterruptHeals', type = 'int', default = 100 },
        { section = 'Heals', key = 'XTarHeal', type = 'string', default = '0', rank = false },
        { section = 'Heals', key = 'XTarHealMode', type = 'int', default = 1 },
        { section = 'Heals', key = 'HealGroupPetsOn', type = 'int', default = 0 },
        { section = 'Heals', key = 'SmartHealsOn', type = 'int', default = 0 },
        { section = 'Heals', key = 'SmartHealDebug', type = 'int', default = 0 },
        { section = 'Heals', key = 'SmartHealFloorPct', type = 'int', default = 15 },
        { section = 'Heals', key = 'SmartHealEmergencyPct', type = 'int', default = 45 },
        { section = 'Heals', key = 'CharmHealOn', type = 'int', default = 0 },
        { section = 'General', key = 'CastingInterruptOn', type = 'int', default = 0 },
        { section = 'General', key = 'HealerDownHold', type = 'int', default = 1 },
        { section = 'General', key = 'CampRadius', type = 'int', default = 30 },
        { section = 'Melee', key = 'MeleeDistance', type = 'int', default = 30 },
        { section = 'ManaFeed', key = 'ManaFeedCOn', type = 'int', default = 0 },
        { section = 'ManaFeed', key = 'ManaFeedMinHP', type = 'int', default = 60 },
        { section = 'ManaFeed', key = 'ManaFeedStopAt', type = 'int', default = 80 },
        { section = 'ManaFeed', key = 'ManaFeedCombatStopAt', type = 'int', default = 35 },
        { section = 'ManaFeed', key = 'ManaFeedClasses', type = 'string', default = 'CLR,DRU,SHM,ENC', rank = false },
        { section = 'ManaFeed', key = 'ManaFeedAutoAt', type = 'int', default = 0 },
        { section = 'ManaFeed', key = 'ManaFeedAutoClasses', type = 'string', default = 'CLR', rank = false },
    },
    arrays = {
        { section = 'Heals', name = 'Heals', size = { key = 'HealsSize', default = 40 }, cond = 'HealsCond' },
        { section = 'ManaFeed', name = 'ManaFeed', size = { key = 'ManaFeedSize', default = 3 }, cond = 'ManaFeedCond' },
    },
}
M.cfg = {}
M.hooks = {
    healerAggroCheck = function() end,      -- healeraggro: HEALERAGGRO-> broadcast (healer side)
    freshAdd = function() return 0 end,     -- healeraggro: FreshAddCheck -> add spawn id or 0
    rezCheck = function() end,              -- rez: RezCheck
    charmPetHeal = function() end,          -- charm (step 5): CharmPetHeal
    invulnSafeToDrop = function() return true end,
}
M.single, M.group = {}, {}
M.rezCombat, M.rezOOC = {}, {}
M.singlePoint, M.singlePointMA, M.singleRange = 0, 99, 200
M.durationMod = 1
M.healAgain = false
M.curLinePct = 100
M.xtarOverride = nil             -- XTarTanks (step 6) rewrites the XTarHeal slots here
M.manaFeedOn = false
M.manaFeedOldGems = {}
M.smart = { spell = '', targetId = 0, tier = '', seq = 0, ack = 0, beat = 0, beatLast = 0, fallback = 1,
    result = '', passResult = 'IDLE', netFires = 0, warned = false }

local LEGACY_CLASSES = { BST = true, CLR = true, SHM = true, DRU = true, RNG = true, PAL = true }
local GROUP_CLASSES = { BST = true, CLR = true, SHM = true, DRU = true, PAL = true }
local SPECIAL_SINGLE = { 'aegis of superior divinity', 'harmony of the soul', 'burst of life', 'focused celestial regeneration' }
local function lower(s) return tostring(s or ''):lower() end
local function role() return lower(State.role) end
local function myHP() return T.num(function() return mq.TLO.Me.PctHPs() end) end
local function targetId() return T.num(function() return mq.TLO.Target.ID() end) end
local function spawnHP(sp) return T.num(function() return sp.PctHPs() end) end
local function tankSpawn()
    if State.healTank == '' then return nil end
    -- the combat module refreshes State.healTankId every second: an id lookup, not a name search
    if (State.healTankId or 0) > 0 then
        local s = T.spawn(State.healTankId)
        if s and lower(T.str(function() return s.CleanName() end)) == lower(State.healTank) then return s end
    end
    return T.spawnByName(State.healTank, lower(State.healTankType ~= '' and State.healTankType or 'pc'))
end
local function tankId() local s = tankSpawn() return s and T.num(function() return s.ID() end) or 0 end
local function isSpecial(name)
    local n = lower(name)
    for _, s in ipairs(SPECIAL_SINGLE) do if n:find(s, 1, true) then return true end end
    return false
end
local function condOk(cond, forOther)
    if (M.cfg.HealsCOn or 0) == 0 then return true end
    if cond == nil or cond == '' or cond == 'TRUE' or cond == 'NULL' then return true end
    if forOther and (cond:find('{Target.', 1, true) or cond:find('TLO.Target', 1, true)) then
        if Timers.expired('heals:condwarn') then
            Timers.set('heals:condwarn', 60000)
            Log.warn('Your heal condition "%s" reads the current Target, not the heal target - use ${Spawn[<id>]} / mq.TLO.Spawn(id) instead; the line is skipped', cond)
        end
        return false
    end
    return Cond.ok(cond)
end
M.condOk = condOk   -- for the tests
local function known(name)
    local kind = Spell.kind(name)
    if kind == 'spell' then return T.num(function() return mq.TLO.Me.Book(name)() end) > 0 end
    if kind == 'aa' then return T.bool(function() return mq.TLO.Me.AltAbilityReady(name)() end) end
    if kind == 'disc' then return T.bool(function() return mq.TLO.Me.CombatAbilityReady(name)() end) end
    if kind == 'item' then return T.bool(function() return mq.TLO.Me.ItemReady(name)() end) end
    return false
end
local function announced(name)
    return not T.bool(function() return mq.TLO.Me.SpellInCooldown() end) and T.bool(function() return mq.TLO.Me.SpellReady(name)() end)
end
local function durMs(name)
    local sec = Spell.facts(name).durationSec or 0
    if lower(name):find('promised', 1, true) then return 24000 end
    return math.floor(sec * M.durationMod * 1000)
end

-- ------------------------------------------------------------- settings and the line split
function M:LoadSettings()
    local c = Config.load(self.Settings)
    self.cfg = c
    State.healsOn = (c.HealsOn or 0) ~= 0
    State.smartHealsOn = (c.SmartHealsOn or 0) ~= 0
    if c.XTarHealMode ~= 1 and c.XTarHealMode ~= 2 and c.XTarHealMode ~= 3 then
        Log.warn('[Heals] XTarHealMode=%s is not 1, 2 or 3 - using 1 (the XTarget slots as their own tier)', tostring(c.XTarHealMode))
        c.XTarHealMode = 1
    end
    -- DurationMod: Spell Casting Reinforcement then Extended Ingenuity (the later rank wins, as the macro)
    self.durationMod = 1
    local scr = T.num(function() return mq.TLO.Me.AltAbility('Spell Casting Reinforcement').Rank() end)
    local scrMods = { 1.15, 1.3, 1.5, 1.7, 1.9 }
    if scr >= 1 then self.durationMod = scrMods[math.min(scr, 5)] end
    local ei = T.num(function() return mq.TLO.Me.AltAbility('Extended Ingenuity').Rank() end)
    local eiMods = { 1.15, 1.3, 1.5, 1.6, 1.7, 1.8 }
    if ei >= 1 then self.durationMod = eiMods[math.min(ei, 6)] end
    self:buildLists()
    self.manaFeedLines = {}
    for i, raw in ipairs(c.ManaFeed or {}) do
        local l = Lines.parse(raw)
        if l then l.index = i l.cond = c.ManaFeedCond and c.ManaFeedCond[i] or 'TRUE' l.gem = i self.manaFeedLines[#self.manaFeedLines + 1] = l end
    end
end

--- FindSingleHeals + FindGroupHeals + the rez ladders, from the [Heals] lines.
function M:buildLists()
    local c = self.cfg
    local cls = T.myClass()
    self.single, self.group, self.rezCombat, self.rezOOC = {}, {}, {}, {}
    self.singlePoint, self.singlePointMA, self.singleRange = 0, 0, 0
    local hasMA = false
    for i, raw in ipairs(c.Heals or {}) do
        local l = Lines.parse(raw)
        if l then
            l.index = i
            l.cond = c.HealsCond and c.HealsCond[i] or 'TRUE'
            local tagField = lower((l.args[3] or ''):gsub('^%s+', ''):gsub('%s+$', ''))
            if tagField == 'rez' or tagField == 'rezooc' or tagField == 'rezcombat' then
                if tagField ~= 'rezooc' then self.rezCombat[#self.rezCombat + 1] = l.name end
                if tagField ~= 'rezcombat' then self.rezOOC[#self.rezOOC + 1] = l.name end
                Log.info('AutoRez ladder entry: %s (%s)', l.name, tagField)
            elseif (l.pct or 0) ~= 0 then
                local f = Spell.facts(l.name)
                local tt = lower(f.targetType)
                local itemSelf = Spell.kind(l.name) == 'item' and tt:find('self') ~= nil
                local special = isSpecial(l.name)
                local classSpecial = (cls == 'DRU' or cls == 'SHM') and (lower(l.name):find('intervention', 1, true) or lower(l.name):find('survival', 1, true))
                local tagged = Lines.has(l, 'ma') or Lines.has(l, 'me') or Lines.has(l, 'pet')
                local joinSingle = special or classSpecial or tt == 'single' or tt == 'self' or itemSelf or Lines.has(l, 'tap') or Lines.has(l, 'pet')
                    or (tt:find('targeted ae') and tagged) or tt == 'free target'
                if joinSingle then
                    self.single[#self.single + 1] = l
                    if l.pct > self.singlePoint then self.singlePoint = l.pct end
                    if not (Lines.has(l, '!ma') or Lines.has(l, 'me') or Lines.has(l, 'pet') or Lines.has(l, 'tap')) and l.pct > self.singlePointMA then self.singlePointMA = l.pct end
                    if Lines.has(l, 'ma') then hasMA = true end
                    if f.range > self.singleRange then self.singleRange = f.range end
                elseif GROUP_CLASSES[cls] and not special and not classSpecial and (tt:find('group v') or (tt:find('targeted ae') and not (Lines.has(l, 'ma') or Lines.has(l, 'me')))) then
                    self.group[#self.group + 1] = l
                end
            end
        end
    end
    table.sort(self.single, function(a, b) if a.pct == b.pct then return a.index < b.index end return a.pct < b.pct end)
    table.sort(self.group, function(a, b) if a.pct == b.pct then return a.index < b.index end return a.pct < b.pct end)
    if self.singlePointMA == 0 then self.singlePointMA = self.singlePoint > 0 and self.singlePoint or 99 end
    if self.singleRange == 0 then self.singleRange = 200 end
    State.singleHealPoint, State.singleHealPointMA, State.singleHealPointRange = self.singlePoint, self.singlePointMA, self.singleRange
    local sig = {}
    for _, l in ipairs(self.single) do sig[#sig + 1] = l.name .. '@' .. tostring(l.pct) end
    sig[#sig + 1] = '#'
    for _, l in ipairs(self.group) do sig[#sig + 1] = l.name .. '@' .. tostring(l.pct) end
    Timers.resetOnChange('heals', table.concat(sig, '|'), { 'heal:', 'gheal:', 'heals:whynot:' })
    if State.healsOn then
        if #self.single == 0 and #self.group == 0 then Log.warn('WARNING: HealsOn=%d but [Heals] has no usable entries - nothing will be cast from it. Please check your ini file.', c.HealsOn or 0) end
        Log.info('Single heal point %d%%, heal tank %d%%%s, scan range %d', self.singlePoint, self.singlePointMA, hasMA and '' or ' (no |MA heal line)', self.singleRange)
    end
end

--- The XTarHeal slots as numbers ({} when off).
function M:xtarSlots()
    local s = self.xtarOverride or self.cfg.XTarHeal or '0'
    local out = {}
    if tonumber(s) == 0 then return out end
    for n in tostring(s):gmatch('[^|]+') do local v = tonumber(n) if v and v > 0 then out[#out + 1] = v end end
    return out
end

-- ------------------------------------------------------------- the small scans
--- Does any PC (me, the group, the heal tank, the XTarHeal slots) need a single heal?
function M:anyPCNeedsHeal()
    local hp = myHP()
    if hp >= 1 and hp <= self.singlePoint then return true end
    local range = self.singleRange
    for i = 0, T.groupCount() do
        local m = T.groupMember(i)
        local id = T.num(function() return m.ID() end)
        if id > 0 and T.str(function() return m.Type() end) == 'PC' then
            local mhp = spawnHP(m)
            local ber = T.str(function() return m.Class.ShortName() end) == 'BER' and T.num(function() return m.Level() end) >= 95 and mhp >= 70
            if not ber and T.num(function() return m.Distance() end) <= range and mhp >= 1 and mhp <= self.singlePoint then return true end
        end
    end
    local tank = tankSpawn()
    if tank and lower(State.healTankType) == 'pc' then
        local thp = spawnHP(tank)
        if T.num(function() return tank.Distance() end) <= range and thp >= 1 and thp <= self.singlePoint then return true end
    end
    for _, slot in ipairs(self:xtarSlots()) do
        local xt = mq.TLO.Me.XTarget(slot)
        local sp = T.spawn(T.num(function() return xt.ID() end))
        if sp and T.str(function() return sp.Type() end) == 'PC' then
            local xhp = spawnHP(sp)
            if T.num(function() return sp.Distance() end) <= range and xhp >= 1 and xhp <= self.singlePoint then return true end
        end
    end
    return false
end

--- Group members (PC / mercenary) under `pct` within `range`.
function M.countInjured(pct, range)
    local n = 0
    for i = 0, T.groupCount() do
        local m = T.groupMember(i)
        local ty = T.str(function() return m.Type() end)
        if T.num(function() return m.ID() end) > 0 and (ty == 'PC' or ty == 'Mercenary') then
            local hp = spawnHP(m)
            if hp >= 1 and hp < pct and T.num(function() return m.Distance() end) <= range then n = n + 1 end
        end
    end
    return n
end

--- The fresh-add hold: a heal on someone who is not the tank waits while a fresh add is loose (returns the add id).
function M:freshAddHold(id, hp)
    if (self.cfg.FreshAddHoldOn or 0) == 0 then return 0 end
    if id == tankId() or hp <= (self.cfg.FreshAddHoldPct or 50) then return 0 end
    return self.hooks.freshAdd() or 0
end

-- ------------------------------------------------------------- SingleHeal
--- Heal one spawn from the single-heal list. who: 'self' | 'tank' | 'group' | 'pet' | 'oog' (for the report).
--- Returns the cast result of the line that fired, or nil when no line qualified.
function M:singleHeal(id, ty, hp, who)
    if State.buffMode or State.zombieMode or not State.healsOn then return nil end
    if T.bool(function() return mq.TLO.Me.Moving() end) or T.bool(function() return mq.TLO.Me.Hovering() end) then return nil end
    id = tonumber(id) or 0
    if id == 0 then return nil end
    ty = ty or 'PC'
    if ty ~= 'PC' and ty ~= 'Pet' and ty ~= 'Mercenary' then return nil end
    if T.bool(function() return mq.TLO.Me.Invis() end) and T.aggroTargetId() == 0 then return nil end
    local sp = T.spawn(id)
    if not sp then return nil end
    local name = T.str(function() return sp.CleanName() end)
    local add = self:freshAddHold(id, hp)
    if add > 0 then
        if Timers.expired('heals:freshecho') then
            Timers.set('heals:freshecho', 5000)
            Log.pm('heal held: %s (%d%%) - fresh add %s is not on the tank yet.', name, hp, T.str(function() return T.spawn(add).CleanName() end))
        end
        return nil
    end
    local isTank = id == tankId()
    local isMe = id == T.myId()
    local c = self.cfg
    local tried = false
    local inGroup = isMe or T.inGroup(id)
    local cls = T.myClass()
    local far = not isMe and T.num(function() return sp.Distance3D() end) > 250
    for i, l in ipairs(self.single) do
        local facts = Spell.facts(l.name)
        local range = facts.range
        if lower(facts.targetType):find('group v') then range = facts.aerange end
        if range == 0 then range = 100 end
        local skip = false
        -- conditions and the buff tags
        if far then skip = true end
        if not skip and not condOk(l.cond, not isMe) then skip = true end
        if not skip and l.buff then
            if isMe then
                local has = Buffcheck.myHas(l.buff)
                if (l.buffOp == '!=' and has) or (l.buffOp == '==' and not has) then skip = true end
            else
                local key = 'heal:' .. i .. ':' .. id
                if hp > l.pct or Timers.running(key) then skip = true
                else
                    Buffcheck.cacheBuffs(id)
                    local has
                    if (Spell.facts(l.buff).durationSec or 0) > 0 then has = Buffcheck.cachedSeconds(id, l.buff) > 0 else has = Buffcheck.cachedHas(id, l.buff) end
                    if l.buffOp == '!=' and has then Timers.set(key, 60000) skip = true end
                    if l.buffOp == '==' and not has then skip = true end
                end
            end
        end
        -- the target tags
        if not skip then
            if Lines.has(l, 'me') and not isMe then skip = true end
            if Lines.has(l, 'pet') and ty ~= 'Pet' then skip = true end
            if Lines.has(l, '!pet') and ty == 'Pet' then skip = true end
            if not isTank then
                if Lines.has(l, 'pet') and ((c.HealGroupPetsOn or 0) == 0 or ty ~= 'Pet') then skip = true end
                if Lines.has(l, 'mob') and ty ~= 'NPC' then skip = true end
                if Lines.has(l, 'ma') then skip = true end
            elseif Lines.has(l, '!ma') then skip = true end
        end
        if not skip then
            local ln = lower(l.name)
            local arb = ln:find('aegis of superior divinity', 1, true) or ln:find('harmony of the soul', 1, true) or ln:find('divine arbitration', 1, true)
            if arb and (ty == 'Pet' or not inGroup) then skip = true end
            if (cls == 'DRU' or cls == 'SHM') and not inGroup and (ln:find('intervention', 1, true) or ln:find('survival', 1, true)) then skip = true end
        end
        if not skip then
            if Lines.has(l, 'tap') then
                -- 10a: a lifetap on the kill target while I am hurt
                local mt = State.myTargetId or 0
                local mob = mt > 0 and T.spawn(mt) or nil
                if not State.pulled and State.combatStart and myHP() <= l.pct and mob and T.str(function() return mob.Type() end) ~= 'Corpse'
                    and T.num(function() return mob.Distance() end) <= range and Timers.expired('heal:' .. i .. ':tap') then
                    if known(l.name) then
                        tried = true
                        self.curLinePct = l.pct
                        local res = Cast.cast(l.name, mt, 'SingleHeal', { tag = 'Tap' })
                        if res == 'CAST_SUCCESS' then
                            Comms.say('o', '%s for >> %s << 1', l.name, T.myName())
                            Stats.bump('single') Stats.bump('tap') Stats.bumpLine(l.index)
                            Timers.set('heal:' .. i .. ':tap', durMs(l.name))
                            return res
                        elseif res ~= 'CAST_INTERRUPTED_BY_ME' then Stats.fail(res, l.name) end
                        if res == 'CAST_CANCELLED' or res == 'CAST_INTERRUPTED_BY_ME' then return res end
                    end
                end
            elseif Lines.has(l, 'mob') then
                -- 10b: a nuke-heal on the kill target while the tank is hurt
                local aggro = T.aggroTargetId()
                local mt = State.myTargetId or 0
                local mob = mt > 0 and T.spawn(mt) or nil
                local tank = tankSpawn()
                if aggro > 0 and mob and tank and spawnHP(tank) <= l.pct and T.bool(function() return mob.LineOfSight() end)
                    and T.num(function() return mob.Distance() end) <= range and T.str(function() return mob.Type() end) ~= 'Corpse' then
                    if known(l.name) then
                        tried = true
                        self.curLinePct = l.pct
                        local res = Cast.cast(l.name, mt, 'SingleHeal', { tag = 'Mob' })
                        if res == 'CAST_SUCCESS' then
                            self.healAgain = true
                            Comms.say('o', '%s for >>%s << cast on %s', l.name, name, T.str(function() return mob.CleanName() end))
                            Stats.bump('single') Stats.bump('mob') Stats.bumpLine(l.index)
                            return res
                        elseif res ~= 'CAST_INTERRUPTED_BY_ME' then Stats.fail(res, l.name) end
                        if res == 'CAST_CANCELLED' or res == 'CAST_INTERRUPTED_BY_ME' then return res end
                    end
                end
            else
                -- 10c: the direct heal
                local key = 'heal:' .. i .. ':' .. id
                local dist = T.num(function() return sp.Distance() end)
                if hp <= l.pct and Timers.expired(key) and (dist > range or not T.bool(function() return sp.LineOfSight() end)) then
                    Cast.hooks.moveForCast(id, range, 'SingleHeal/' .. l.name)
                    dist = T.num(function() return sp.Distance() end)
                end
                if hp <= l.pct and dist <= range and Timers.expired(key) and known(l.name) then
                    local go = true
                    if lower(facts.targetType) == 'free target' then
                        if targetId() ~= id then mq.cmdf('/squelch /target id %d', id) mq.delay(2000, function() return targetId() == id end) end
                        if not T.bool(function() return mq.TLO.Target.CanSplashLand() end) then go = false end
                    end
                    if go and isTank and Buffcheck.myHas('Divine Barrier') and self.hooks.invulnSafeToDrop() then mq.cmd('/removebuff Divine Barrier') end
                    if go and facts.mana + 20 > T.num(function() return mq.TLO.Me.CurrentMana() end) then go = false end
                    local r = role()
                    if go and (r == 'hunter' or r == 'tank' or r == 'pullertank') and T.inCombat() and not Spell.memmed(l.name) then go = false end
                    if go then
                        if announced(l.name) then Comms.say('o', '%s on >> %s <<', l.name, name) end
                        tried = true
                        self.curLinePct = l.pct
                        local res = Cast.cast(l.name, id, 'SingleHeal', { tag = 'Heal' })
                        if res == 'CAST_SUCCESS' then
                            self.healAgain = true   -- a landed heal earns another pass (the macro's HealAgain 2)
                            local bucket = isMe and 'self' or (ty == 'Pet' and 'pet') or (isTank and 'tank') or (who == 'oog' and 'oog') or 'groupT'
                            Stats.bump('single') Stats.bump(bucket) Stats.bumpLine(l.index)
                            Timers.set(key, durMs(l.name))
                            return res
                        elseif res ~= 'CAST_INTERRUPTED_BY_ME' then Stats.fail(res, l.name) end
                        if res == 'CAST_CANCELLED' or res == 'CAST_INTERRUPTED_BY_ME' then return res end
                    end
                end
            end
        end
    end
    if not tried and hp <= math.max(self.singlePointMA, self.singlePoint) and Timers.expired('heals:whynot:' .. id) then
        Timers.set('heals:whynot:' .. id, 5000)
        Log.whyNot('SingleHeal', 'no line', name, string.format('at %d%%: every line not ready, on its timer, out of range, wrong tag or condition FALSE', hp))
    end
    return nil
end

-- ------------------------------------------------------------- group and pet heals
function M:groupHeals(avgHP)
    if State.buffMode or State.zombieMode then return end
    local tank = tankSpawn()
    if (self.cfg.FreshAddHoldOn or 0) ~= 0 and tank and spawnHP(tank) > (self.cfg.FreshAddHoldPct or 50) and (self.hooks.freshAdd() or 0) > 0 then return end
    for j, l in ipairs(self.group) do
        if condOk(l.cond, false) then
            local f = Spell.facts(l.name)
            local range = f.aerange > 0 and f.aerange or 100
            local inj = M.countInjured(l.pct, range)
            local key = 'gheal:' .. j
            local fire = inj > 1 or (inj >= 1 and avgHP <= l.pct)
            if not fire and Timers.expired(key) and Timers.expired('heals:grouprange') then
                local wide = T.num(function() return mq.TLO.Group.Injured(l.pct)() end)
                if wide > 1 or avgHP <= l.pct then Stats.bump('groupRange') Timers.set('heals:grouprange', 5000) end
            end
            if fire and Timers.expired(key) and T.groupCount() > 0 then
                local res = Cast.cast(l.name, T.myId(), 'GroupHeal')
                if res == 'CAST_SUCCESS' then
                    Comms.say('o', '%s on  >> Group <<', l.name)
                    Stats.bump('group') Stats.bumpGLine(l.index)
                    Timers.set(key, durMs(l.name))
                    self.healAgain = true
                    return
                end
            end
        end
    end
end

function M:petHeals()
    if State.buffMode or State.zombieMode then return end
    local pet = mq.TLO.Me.Pet
    local pid = T.num(function() return pet.ID() end)
    if pid == 0 then return end
    for _, l in ipairs(self.single) do
        if Lines.has(l, 'pet') then
            local php = T.num(function() return pet.PctHPs() end)
            local range = Spell.facts(l.name).range or 0
            if range == 0 then range = 100 end
            if php <= l.pct and T.num(function() return pet.Distance() end) < range then
                local res = Cast.cast(l.name, pid, 'Heal')
                if res == 'CAST_SUCCESS' then
                    Comms.say('o', '%s on  >> %s <<', l.name, T.str(function() return pet.CleanName() end))
                    self.healAgain = true
                    return   -- one pet heal per pass
                end
            end
        end
    end
end

-- ------------------------------------------------------------- SmartHeals
-- tell modules/smartheal how a pick ended (a HoT success enters the engine's HoT ledger)
local function reportSmart(seq, result)
    local sh = package.loaded['modules.smartheal']
    if sh and sh.onResult then pcall(sh.onResult, seq, result) end
end

--- modules/smartheal's current recommendation: { spell, targetId, tier, seq, beat, fallback }.
function M.smartSet(rec)
    local s = M.smart
    if rec.spell ~= nil then s.spell = tostring(rec.spell) end
    if rec.targetId ~= nil then s.targetId = tonumber(rec.targetId) or 0 end
    if rec.tier ~= nil then s.tier = tostring(rec.tier) end
    if rec.seq ~= nil then s.seq = tonumber(rec.seq) or s.seq end
    if rec.beat ~= nil then s.beat = tonumber(rec.beat) or s.beat end
    if rec.fallback ~= nil then s.fallback = tonumber(rec.fallback) or 0 end
end

function M:smartHeartbeat()
    local s = self.smart
    if not s.armed then
        -- the first look with no beat yet: the engine gets 5 s to start (a never-set timer reads as expired)
        s.armed = true
        Timers.set('heals:smartwarn', 5000)
    end
    if s.beat ~= s.beatLast then
        s.beatLast = s.beat
        Timers.set('heals:smartfresh', 1500)
        Timers.set('heals:smartwarn', 5000)
        s.warned = false
    end
    if Timers.expired('heals:smartwarn') and not s.warned then
        local sh = package.loaded['modules.smartheal']
        if sh and sh.wanted and sh:wanted() then
            Log.error('SmartHeals: engine picks stale >5s - using legacy healing until they return')
            s.warned = true
        end
    end
    if (self.cfg.SmartHealDebug or 0) ~= 0 and Timers.running('heals:smartfresh') and s.seq ~= s.ack then
        local sp = T.spawn(s.targetId)
        Log.info('SmartHeals(shadow): would cast %s on %s [%s] seq %d', s.spell, sp and T.str(function() return sp.CleanName() end) or '?', s.tier, s.seq)
        s.result = 'SHADOW'
        s.ack = s.seq
        reportSmart(s.seq, 'SHADOW')
    end
end

function M:smartActive()
    return State.smartHealsOn and (self.cfg.SmartHealDebug or 0) == 0 and Timers.running('heals:smartfresh') and self.smart.fallback == 0
end

function M:doSmartHeal()
    local s = self.smart
    local function done(res) s.result = res s.passResult = res s.ack = s.seq reportSmart(s.seq, res) return res end
    if not State.healsOn then return end
    if T.bool(function() return mq.TLO.Me.Moving() end) then return done('SKIP_MOVING') end
    if T.bool(function() return mq.TLO.Me.Hovering() end) then return end
    if s.seq == s.ack then return end
    local spell, id, seq, tier = s.spell, s.targetId, s.seq, lower(s.tier)
    self.curLinePct = self.cfg.InterruptHeals or 100
    if id == 0 or spell == '' or spell:upper() == 'NULL' then return done('SKIP_NOTARGET') end
    local sp = T.spawn(id)
    local ty = sp and T.str(function() return sp.Type() end) or ''
    if not sp or (ty ~= 'PC' and ty ~= 'Pet' and ty ~= 'Mercenary') then return done('SKIP_TYPE') end
    if ty == 'Pet' and ((self.cfg.HealGroupPetsOn or 0) == 0 or self:anyPCNeedsHeal()) then return done('SKIP_PET_PRIORITY') end
    local hp = spawnHP(sp)
    local mine = id == T.myId() or ty == 'Pet' or T.inGroup(id)
    if not tier:find('group') and (tier ~= 'emergency' or (mine and hp >= (self.cfg.SmartHealEmergencyPct or 45))) and hp > 100 - (self.cfg.SmartHealFloorPct or 15) then return done('SKIP_FLOOR') end
    local add = self:freshAddHold(id, hp)
    if add > 0 then
        if Timers.expired('heals:freshecho') then
            Timers.set('heals:freshecho', 5000)
            Log.pm('heal held: smart %s on %s (%d%%) - fresh add %s is not on the tank yet.', spell, T.str(function() return sp.CleanName() end), hp, T.str(function() return T.spawn(add).CleanName() end))
        end
        return done('SKIP_FRESHADD')
    end
    local f = Spell.facts(spell)
    if id ~= T.myId() then
        if (f.range > 0 and T.num(function() return sp.Distance3D() end) > f.range + 5) or not T.bool(function() return sp.LineOfSight() end) then
            Cast.hooks.moveForCast(id, f.range, 'SmartHeal/' .. spell)
        end
        if f.range > 0 and T.num(function() return sp.Distance3D() end) > f.range + 5 then return done('SKIP_RANGE') end
        if not T.bool(function() return sp.LineOfSight() end) then return done('SKIP_LOS') end
    end
    if not known(spell) then return done('SKIP_NOSPELL') end
    if f.mana + 20 > T.num(function() return mq.TLO.Me.CurrentMana() end) then return done('SKIP_MANA') end
    mq.doevents()
    if seq ~= s.seq then s.result = 'SKIP_STALE' s.passResult = 'SKIP_STALE' s.ack = seq reportSmart(seq, 'SKIP_STALE') return end
    if ty == 'Pet' and self:anyPCNeedsHeal() then return done('SKIP_PET_PRIORITY') end
    if announced(spell) then Comms.say('o', '%s on >> %s << (smart)', spell, T.str(function() return sp.CleanName() end)) end
    local res = Cast.cast(spell, id, 'SingleHeal', { tag = 'Heal' })
    done(res)
    if res == 'CAST_SUCCESS' then self.healAgain = true Stats.bump('smart') else Stats.bump('smartFail') Stats.hs.failLast = res .. ' ' .. spell end
    return res
end

-- ------------------------------------------------------------- CheckHealth
local function memberFacts(i)
    local m = T.groupMember(i)
    local id = T.num(function() return m.ID() end)
    if id == 0 then return nil end
    return { id = id, name = T.str(function() return m.CleanName() end), ty = T.str(function() return m.Type() end), hp = spawnHP(m),
        dist = T.num(function() return m.Distance() end), cls = T.str(function() return m.Class.ShortName() end), level = T.num(function() return m.Level() end), node = m }
end

--- The most-hurt scan: group members (HealsOn 1/2), the XTarHeal slots (mode 2/3), pets after PCs.
function M:mostHurt()
    local c = self.cfg
    local range = self.singleRange
    local best = nil
    local bestPet = nil
    local tid = tankId()
    local tankPet = 0
    if c.XTarHealMode ~= 3 and (c.HealsOn == 1 or c.HealsOn == 2) then
        for i = 0, T.groupCount() do
            local m = memberFacts(i)
            if m then
                if c.HealsOn == 2 and tid > 0 then tankPet = T.num(function() return m.node.Pet.ID() end) end
                local skip = c.HealsOn == 2 and tid > 0 and (m.id == tid or (tankPet > 0 and tankPet == tid))
                if not skip and m.ty ~= 'Corpse' and m.hp >= 1 then
                    local pc = m.dist <= range and not (m.cls == 'BER' and m.level >= 95 and m.hp >= 70)
                    if pc and (not best or m.hp <= best.hp) then best = { id = m.id, name = m.name, ty = m.ty, hp = m.hp, who = 'group' } end
                    if (c.HealGroupPetsOn or 0) ~= 0 and m.cls ~= 'CLR' and m.cls ~= 'WIZ' then
                        local pet = m.node.Pet
                        local pid = T.num(function() return pet.ID() end)
                        if pid > 0 then
                            local php, pdist = T.num(function() return pet.PctHPs() end), T.num(function() return pet.Distance() end)
                            if (not bestPet or php <= bestPet.hp) and pdist <= range then bestPet = { id = pid, name = T.str(function() return pet.CleanName() end), ty = 'Pet', hp = php, who = 'pet' } end
                        end
                    end
                end
            end
        end
    end
    if c.XTarHealMode >= 2 then
        for _, slot in ipairs(self:xtarSlots()) do
            local sp = T.spawn(T.num(function() return mq.TLO.Me.XTarget(slot).ID() end))
            if sp and T.num(function() return sp.ID() end) ~= T.myId() then
                local ty = T.str(function() return sp.Type() end)
                local hp = spawnHP(sp)
                if (ty == 'PC' or ty == 'Mercenary') and T.num(function() return sp.Distance() end) <= range and hp >= 1 and (not best or hp <= best.hp) then
                    best = { id = T.num(function() return sp.ID() end), name = T.str(function() return sp.CleanName() end), ty = ty, hp = hp, who = 'oog' }
                end
            end
        end
    end
    if bestPet and bestPet.hp <= self.singlePoint and (not best or best.hp > self.singlePoint) and not self:anyPCNeedsHeal() then best = bestPet end
    return best
end

function M:xtarPass()
    local c = self.cfg
    local slots = self:xtarSlots()
    if #slots == 0 then return end
    local range = self.singleRange
    if not self:smartActive() and c.XTarHealMode == 1 then
        local done = {}
        for _ = 1, #slots do
            local best, bestHP = nil, 101
            for _, slot in ipairs(slots) do
                if not done[slot] then
                    local sp = T.spawn(T.num(function() return mq.TLO.Me.XTarget(slot).ID() end))
                    if sp then
                        local ty = T.str(function() return sp.Type() end)
                        local hp = spawnHP(sp)
                        if (ty == 'PC' or ty == 'Mercenary') and T.num(function() return sp.Distance() end) <= range and hp <= self.singlePoint and hp < bestHP then best, bestHP = { slot = slot, sp = sp, ty = ty, hp = hp }, hp end
                    end
                end
            end
            if not best then break end
            done[best.slot] = true
            self:singleHeal(T.num(function() return best.sp.ID() end), best.ty, best.hp, 'oog')
        end
    end
    if not self:anyPCNeedsHeal() then
        for _, slot in ipairs(slots) do
            local sp = T.spawn(T.num(function() return mq.TLO.Me.XTarget(slot).ID() end))
            if sp and T.str(function() return sp.Type() end) == 'Pet' then
                local hp = spawnHP(sp)
                if hp <= self.singlePoint then self:singleHeal(T.num(function() return sp.ID() end), 'Pet', hp, 'oog') end
            end
        end
    end
end

--- One CheckHealth call: up to six passes while a heal landed (HealAgain).
function M:checkHealth()
    if State.buffMode or State.zombieMode then return end
    self.hooks.healerAggroCheck()
    local tank = tankSpawn()
    if tank then Stats.tankLow(spawnHP(tank)) end
    if T.bool(function() return mq.TLO.Me.Feigning() end) and Timers.running('combat:aggrooff') then return end
    Cast.hooks.ohShit('CheckHealth')
    if not State.healsOn then return end
    if T.bool(function() return mq.TLO.Me.Invis() end) and T.aggroTargetId() == 0 then return end
    local c = self.cfg
    local cls = T.myClass()
    for pass = 1, 6 do
        self.healAgain = false
        if State.smartHealsOn then
            -- the engine's loop is the main loop's Tick; a blocking cast starves it, so tick it here (it throttles itself)
            local sh = package.loaded['modules.smartheal']
            if sh and sh.Tick then pcall(sh.Tick, sh) end
            self:smartHeartbeat()
        else
            self.smart.armed = nil
        end
        local smart = self:smartActive()
        local hp = myHP()
        if hp <= self.singlePoint and (not smart or hp <= (c.SmartHealEmergencyPct or 45)) then self:singleHeal(T.myId(), 'PC', hp, 'self') end
        tank = tankSpawn()
        if smart then
            self.smart.passResult = 'IDLE'
            self:doSmartHeal()
            if tank and spawnHP(tank) <= (c.SmartHealEmergencyPct or 45) and T.str(function() return tank.Type() end) ~= 'Corpse' and self.smart.passResult ~= 'CAST_SUCCESS' then
                self.smart.netFires = self.smart.netFires + 1
                self:singleHeal(T.num(function() return tank.ID() end), State.healTankType, spawnHP(tank), 'tank')
            end
        elseif LEGACY_CLASSES[cls] then
            local tid = tank and T.num(function() return tank.ID() end) or 0
            if (c.HealsOn == 1 or c.HealsOn == 3) and tid > 0 and tid ~= T.myId() and spawnHP(tank) <= self.singlePointMA then
                self:singleHeal(tid, State.healTankType, spawnHP(tank), T.inGroup(tid) and 'tank' or 'oog')
            end
            if ((c.HealsOn == 1 or c.HealsOn == 2) and T.groupCount() > 0) or (c.XTarHealMode >= 2 and #self:xtarSlots() > 0) then
                local best = self:mostHurt()
                if best then
                    Stats.low(best.name, best.hp)
                    if best.hp <= self.singlePoint then self:singleHeal(best.id, best.ty, best.hp, best.id == tid and 'tank' or best.who) end
                end
            end
        end
        if not smart and GROUP_CLASSES[cls] and T.groupCount() > 0 then self:groupHeals(T.num(function() return mq.TLO.Group.AvgHPs() end)) end
        self:xtarPass()
        if State.petOn and T.num(function() return mq.TLO.Me.Pet.ID() end) > 0 and T.num(function() return mq.TLO.Me.Pet.PctHPs() end) < 100 and not self:anyPCNeedsHeal() then self:petHeals() end
        if (c.CharmHealOn or 0) ~= 0 then self.hooks.charmPetHeal() end
        if not self.healAgain then break end
        mq.doevents()
    end
    self.hooks.rezCheck()
end

--- A heal pass from inside another module's loop (the macro's per-line CheckHealth calls).
function M:checkHealthIfOn()
    if State.healsOn then self:checkHealth() end
end

-- ------------------------------------------------------------- ManaFeed
function M:manaFeed()
    if State.buffMode or State.zombieMode or not self.manaFeedOn then return end
    if T.bool(function() return mq.TLO.Me.Hovering() end) or State.iAmDead or T.bool(function() return mq.TLO.Me.Moving() end) then return end
    if T.bool(function() return mq.TLO.Me.Invis() end) and T.aggroTargetId() == 0 then return end
    if myHP() < (self.cfg.ManaFeedMinHP or 60) then return end
    local inFight = T.aggroTargetId() > 0
    local stopAt = inFight and (self.cfg.ManaFeedCombatStopAt or 35) or (self.cfg.ManaFeedStopAt or 80)
    local best, bestPct = nil, stopAt
    for i = 1, T.groupCount() do
        local m = T.groupMember(i)
        local id = T.num(function() return m.ID() end)
        if id > 0 and id ~= T.myId() and not T.bool(function() return m.OtherZone() end) and T.str(function() return m.Type() end) ~= 'Corpse' and spawnHP(m) >= 1 then
            local cls = T.str(function() return m.Class.ShortName() end)
            local pm = T.num(function() return m.PctMana() end)
            if cls ~= '' and lower(self.cfg.ManaFeedClasses):find(lower(cls), 1, true) and pm < bestPct then best, bestPct = { id = id, name = T.str(function() return m.CleanName() end), node = m }, pm end
        end
    end
    if not best then
        Log.info('ManaFeed: everyone eligible is at %d%%+ mana - done%s.', stopAt, inFight and string.format(' (combat cap %d%%)', self.cfg.ManaFeedCombatStopAt or 35) or '')
        self:manaFeedOff()
        return
    end
    for _, l in ipairs(self.manaFeedLines) do
        local ok = (self.cfg.ManaFeedCOn or 0) == 0 or l.cond == 'TRUE' or l.cond == 'NULL' or l.cond == '' or condOk(l.cond, true)
        if ok and T.bool(function() return mq.TLO.Me.SpellReady(l.name)() end) then
            local range = Spell.facts(l.name).range
            if range == 0 then range = 100 end
            if T.num(function() return best.node.Distance3D() end) <= range then
                local res = Cast.cast(l.name, best.id, 'ManaFeed')
                if res == 'CAST_SUCCESS' then Comms.say('o', 'MANA FEED >> %s << with %s (was %d%% mana)', best.name, l.name, bestPct) return end
            end
        end
    end
end

function M:manaFeedOff()
    self.manaFeedOn = false
    for gem, old in pairs(self.manaFeedOldGems) do
        if old and old ~= '' and old ~= 'NULL' then Cast.memSpell(old, gem, 'ManaFeedHeal') end
    end
    self.manaFeedOldGems = {}
    Log.info('ManaFeed is now OFF - restored my old spell lineup.')
end

function M:manaFeedStart()
    local gems = T.num(function() return mq.TLO.Me.NumGems() end)
    if gems == 0 then gems = 12 end
    for _, l in ipairs(self.manaFeedLines) do
        if l.gem <= gems then
            if T.num(function() return mq.TLO.Me.Book(l.name)() end) == 0 then
                Log.info('ManaFeed: %s is not in my spell book - skipping gem %d.', l.name, l.gem)
            else
                self.manaFeedOldGems[l.gem] = T.str(function() return mq.TLO.Me.Gem(l.gem).Name() end)
                Cast.memSpell(l.name, l.gem, 'ManaFeedHeal')
            end
        end
    end
    self.manaFeedOn = true
    Log.info('ManaFeed is now ON - feeding %s up to %d%% mana (HP floor %d%%), then restoring my lineup.', self.cfg.ManaFeedClasses, self.cfg.ManaFeedStopAt or 80, self.cfg.ManaFeedMinHP or 60)
end

function M:manaFeedAutoCheck()
    local c = self.cfg
    if self.manaFeedOn or (c.ManaFeedAutoAt or 0) == 0 or Timers.running('heals:mfhold') then return end
    if Timers.running('heals:mfauto') then return end
    Timers.set('heals:mfauto', 5000)
    if T.bool(function() return mq.TLO.Me.Hovering() end) or State.iAmDead or T.bool(function() return mq.TLO.Me.Moving() end) then return end
    if T.bool(function() return mq.TLO.Me.Invis() end) and T.aggroTargetId() == 0 then return end
    if myHP() < (c.ManaFeedMinHP or 60) then return end
    local range = 0
    for _, l in ipairs(self.manaFeedLines) do
        if T.num(function() return mq.TLO.Me.Book(l.name)() end) > 0 then
            local r = Spell.facts(l.name).range
            if r == 0 then r = 100 end
            if r > range then range = r end
        end
    end
    if range == 0 then return end
    for i = 1, T.groupCount() do
        local m = T.groupMember(i)
        local id = T.num(function() return m.ID() end)
        if id > 0 and id ~= T.myId() and not T.bool(function() return m.OtherZone() end) and spawnHP(m) >= 1 then
            local cls = T.str(function() return m.Class.ShortName() end)
            local pm = T.num(function() return m.PctMana() end)
            if cls ~= '' and lower(c.ManaFeedAutoClasses):find(lower(cls), 1, true) and pm < c.ManaFeedAutoAt and T.num(function() return m.Distance3D() end) <= range then
                Log.info('ManaFeed: auto-starting - %s is at %d%% mana (under %d%%).', T.str(function() return m.CleanName() end), pm, c.ManaFeedAutoAt)
                self:manaFeedStart()
                return
            end
        end
    end
end

-- ------------------------------------------------------------- the interrupt rules (WaitCast + KACheckHP)
local function judgeHP()
    local tag = State.castTag or 'Heal'
    if tag == 'Tap' then return myHP() end
    if tag == 'Mob' then local t = tankSpawn() return t and spawnHP(t) or 0 end
    return T.num(function() return mq.TLO.Target.PctHPs() end)
end
--- Any non-heal cast on a healer (a buff, a nuke, a debuff, a pet spell) is cut when me, the heal tank or a
--- group member drops under the emergency line (the lower of SingleHealPoint and 50) with more than half
--- a second of the cast left: the ladder gets its turn instead of waiting out the bar.
local function emergencyInterrupt(ctx)
    local from = lower(ctx.from)
    if from:find('heal', 1, true) or from:find('rez', 1, true) or from == 'ohshitstuff' or from == 'cure' then return nil end
    if not State.healsOn or #M.single == 0 or (ctx.timeLeftMs or 0) < 500 then return nil end
    if (M.cfg.CastingInterruptOn or 0) == 0 then return nil end
    local line = math.min(M.singlePoint > 0 and M.singlePoint or 50, 50)
    local function low(sp) return sp and T.num(function() return sp.PctHPs() end) > 0 and T.num(function() return sp.PctHPs() end) <= line and T.str(function() return sp.Type() end) ~= 'Corpse' end
    if myHP() > 0 and myHP() <= line then return string.format('I am at %d%%', myHP()) end
    local tank = tankSpawn()
    if low(tank) then return string.format('%s at %d%%', State.healTank, spawnHP(tank)) end
    for i = 1, T.groupCount() do
        local m = mq.TLO.Group.Member(i)
        if T.num(function() return m.ID() end) > 0 and T.str(function() return m.Type() end) ~= 'Corpse' and T.num(function() return m.Distance() end) <= 200 then
            local hp = T.num(function() return m.PctHPs() end)
            if hp > 0 and hp <= line then return string.format('%s at %d%%', T.str(function() return m.CleanName() end), hp) end
        end
    end
    return nil
end
M.emergencyInterrupt = emergencyInterrupt

function M.interruptHook(ctx)
    if lower(ctx.from) ~= 'singleheal' then
        local why = emergencyInterrupt(ctx)
        if why then Stats.bump('intEmergency') return 'heal emergency: ' .. why end
        return nil
    end
    local f = ctx.facts or {}
    local c = M.cfg
    local tt = lower(f.targetType)
    local sub = lower(f.subcategory)
    if T.str(function() return mq.TLO.Target.Type() end) == 'NPC' and f.beneficial then
        Stats.bump('intNPC')
        return 'heal on an NPC'
    end
    if tt:find('group') or sub == 'delayed' or sub == 'duration heals' or lower(ctx.name):find('promised', 1, true) then return nil end
    if (ctx.timeLeftMs or 0) >= 800 then return nil end
    local hp = judgeHP()
    local limit = c.InterruptHeals or 100
    local lineRule = ((c.CastingInterruptOn or 0) ~= 0 or limit < 100) and hp > M.curLinePct
    if hp >= limit or lineRule then
        local tag = State.castTag or 'Heal'
        Stats.bump(tag == 'Tap' and 'intTap' or (tag == 'Mob' and 'intMob') or 'intHeal')
        local who = tag == 'Tap' and 'I am' or (tag == 'Mob' and (State.healTank .. ' is')) or (T.str(function() return mq.TLO.Target.CleanName() end) .. ' is')
        return string.format('%s at %d%%, past %d%% / InterruptHeals %d', who, hp, M.curLinePct, limit)
    end
    return nil
end

-- ------------------------------------------------------------- the module hooks
function M:Init()
    Cast.addInterruptHook('heals', M.interruptHook)
end

function M:Shutdown()
    if self.manaFeedOn then self:manaFeedOff() end
end

function M:GiveTime(ctx)
    if State.chainPull == 2 or State.getAwayFollow then return end
    if State.healsOn then self:checkHealth() end
    if self.manaFeedOn then self:manaFeed() else self:manaFeedAutoCheck() end
end

M.Binds = {
    ['/healson'] = function(self, arg)
        local v = tonumber(arg)
        if arg == 'on' then v = 1 elseif arg == 'off' then v = 0 end
        if v == nil then v = (self.cfg.HealsOn or 0) == 0 and 1 or 0 end
        self.cfg.HealsOn = v
        State.healsOn = v ~= 0
        Config.set('Heals', 'HealsOn', v)
        self:buildLists()
        Log.info('HealsOn %d', v)
    end,
    ['/smarthealson'] = function(self, arg)
        local v = tonumber(arg)
        if arg == 'on' then v = 1 elseif arg == 'off' then v = 0 end
        if v == nil then v = (self.cfg.SmartHealsOn or 0) == 0 and 1 or 0 end
        self.cfg.SmartHealsOn = v
        State.smartHealsOn = v ~= 0
        Config.set('Heals', 'SmartHealsOn', v)
        if v == 0 then self.smart.fallback = 1 self.smart.beat, self.smart.beatLast, self.smart.seq, self.smart.ack = 0, 0, 0, 0 self.smart.warned = false end
        Log.info('SmartHealsOn %d', v)
    end,
    ['/manafeed'] = function(self)
        if self.manaFeedOn then
            if (self.cfg.ManaFeedAutoAt or 0) ~= 0 then Timers.set('heals:mfhold', 120000) end
            self:manaFeedOff()
        else
            self:manaFeedStart()
        end
    end,
}

return M
