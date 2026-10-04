-- modules/dps.lua: CombatCast (the [DPS] list walk with the Me / MA / Feign / util / once / spam / <PC name>
-- targets and the if / notif / ifme / notifme buff conditions), the time-to-death estimate (TTD) and its
-- calibration, KACheckDPS (the DPS cast interrupt), CheckForAdds, RangerStuff, AECheck (the [AE] list),
-- the burn ([Burn] lines, /burn, the |Burn this| event, NamedWatch with MobsToBurn), Gift of Mana, the
-- resist-list binds and Event_ConCheck, with the same INI keys as the macro.
--
-- Not a transliteration: per-entry timers are `dps:<line>:<target id>` and die with the fight (the macro's
-- orphaned outer timers); the SmartDPS picks come from modules/smartdps.lua (necrobrain in-process) through
-- M.smartSet and each verdict goes back through its onResult; a |weave line lives only in the weave list; the
-- resist lists are evaluated per mob, not once at start.
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
local Ini = require('core.ini')
local Buffcheck = require('core.buffcheck')

local M = { name = 'dps' }

M.Settings = {
    scalars = {
        { section = 'DPS', key = 'DPSOn', type = 'int', default = 0 },
        { section = 'DPS', key = 'DPSCOn', type = 'int', default = 0 },
        { section = 'DPS', key = 'DPSSkip', type = 'int', default = 1 },
        { section = 'DPS', key = 'DPSInterval', type = 'int', default = 2 },
        { section = 'DPS', key = 'TTDOn', type = 'int', default = 1 },
        { section = 'DPS', key = 'TTDMinTicks', type = 'int', default = 3 },
        { section = 'DPS', key = 'TTDReport', type = 'int', default = 1 },
        { section = 'DPS', key = 'TTDWindow', type = 'int', default = 18 },
        { section = 'DPS', key = 'TTDCal', type = 'string', default = '1.0', rank = false },
        { section = 'DPS', key = 'SmartDPSOn', type = 'int', default = 0 },
        { section = 'DPS', key = 'SmartDPSDebug', type = 'int', default = 0 },
        { section = 'DPS', key = 'DebuffAllOn', type = 'int', default = 0 },
        { section = 'DPS', key = 'StayAwayToCast', type = 'int', default = 0 },
        { section = 'AE', key = 'AEOn', type = 'int', default = 0 },
        { section = 'AE', key = 'AERadius', type = 'int', default = 50 },
        { section = 'GoM', key = 'GoMOn', type = 'int', default = 1 },
        { section = 'GoM', key = 'GoMCOn', type = 'int', default = 0 },
        { section = 'Burn', key = 'BurnCOn', type = 'int', default = 0 },
        { section = 'Burn', key = 'BurnText', type = 'string', default = 'Burn this', rank = false },
        { section = 'Burn', key = 'BurnAllNamed', type = 'int', default = 0 },
        { section = 'Burn', key = 'UseTribute', type = 'int', default = 0 },
        { section = 'General', key = 'CampRadius', type = 'int', default = 30 },
        { section = 'General', key = 'CastingInterruptOn', type = 'int', default = 0 },
        { section = 'General', key = 'MoveCloserIfNoLOS', type = 'int', default = 0 },
        { section = 'General', key = 'CastRetries', type = 'int', default = 3 },
        { section = 'General', key = 'MobZRadius', type = 'int', default = 50 },
        { section = 'Melee', key = 'AssistAt', type = 'int', default = 95 },
        { section = 'Melee', key = 'FaceMobOn', type = 'int', default = 1 },
        { section = 'Melee', key = 'MeleeDistance', type = 'int', default = 30 },
        { section = 'Melee', key = 'AutoFireOn', type = 'int', default = 0 },
        { section = 'Pet', key = 'PetAssistAt', type = 'int', default = 95 },
        { section = 'Pet', key = 'PetCombatOn', type = 'int', default = 1 },
    },
    arrays = {
        { section = 'DPS', name = 'DPS', size = { key = 'DPSSize', default = 40 }, cond = 'DPSCond' },
        { section = 'AE', name = 'AE', size = { key = 'AESize', default = 20 } },
        { section = 'GoM', name = 'GoM', size = { key = 'GoMSize', default = 4 }, cond = 'GoMCond' },
        { section = 'Burn', name = 'Burn', size = { key = 'BurnSize', default = 40 }, cond = 'BurnCond' },
    },
}
M.cfg = {}
M.lines = {}          -- the DPS entries (debuffall, mash and weave lines excluded), descending by pct
M.debuffLines = {}    -- the debuffall lines for modules/debuffs.lua
M.ae, M.gom, M.burn = {}, {}, {}
M.mobsToBurn = {}
M.burnActive = false
M.ttd = { mobId = 0, startHP = 0, startSec = 0, name = '', aSec = 0, aHP = 0, mSec = 0, mHP = 0, cal = 1.0,
    skipCount = 0, passCount = 0, skipped = {}, firstSkipEst = -1, firstSkipRaw = -1, firstSkipAt = 0, lastEst = -1 }
M.smart = { spell = '', targetId = 0, mode = 'eff', seq = 0, ack = 0, beat = 0, beatLast = 0, ranked = '|', result = '', warned = false }
M.hooks = { mezNeeded = function() return false end, mezCount = function() return 0 end, mezCCOnlyAt = function() return 0 end,
    isDispel = function() return false end, dispelWorthwhile = function() return true end, healerDown = function() return false end,
    protectedNear = function(radius, targetId) return false end, mezzedNear = function(q) return 0 end }
M.clock = nil   -- seconds, injected by the tests

local NO_GOM = { BRD = true, BER = true, MNK = true, ROG = true, WAR = true }
local MEZ_ANIM = { [26] = true, [32] = true, [71] = true, [72] = true, [17] = true, [111] = true, [129] = true }
local function lower(s) return tostring(s or ''):lower() end
local function role() return lower(State.role) end
local function targetId() return T.num(function() return mq.TLO.Target.ID() end) end
local function iAmMA() return State.mainAssist ~= '' and lower(State.mainAssist) == lower(T.myName()) end
local function maSpawn() if State.mainAssist == '' then return nil end return T.spawnByName(State.mainAssist, lower(State.mainAssistType ~= '' and State.mainAssistType or 'pc')) end
local function nowSec() if M.clock then return M.clock() end return math.floor((mq.gettime() or 0) / 1000) end
local function condOk(cond, on)
    if on == 0 or cond == nil or cond == '' or cond == 'TRUE' or cond == 'NULL' then return true end
    return Cond.ok(cond)
end
-- A charm spell (SPA 22) in [DPS] is never cast by the rotation: it would charm the kill target. Charming
-- belongs to modules/charm.lua, which picks an extra hater. Checked once per entry, logged once per name.
M.charmWarned = {}
function M:isCharmEntry(e)
    if e.isCharm == nil and lower(e.name):find('^command:') then e.isCharm = false end
    if e.isCharm == nil then
        local f = Spell.facts(e.name)
        if not f.hasSPA then return false end   -- unknown name: ask again on a later pass
        e.isCharm = f.hasSPA(22) == true
    end
    if e.isCharm and not M.charmWarned[e.name] then
        M.charmWarned[e.name] = true
        Log.warn("DPS: skipping %s - it is a charm spell; charming is the [Charm] module's job (CharmOn/CharmAutoOn)", e.name)
    end
    return e.isCharm
end
local function hasBuffOrSong(name)
    return T.num(function() return mq.TLO.Me.Buff(name).ID() end) > 0 or T.num(function() return mq.TLO.Me.Song(name).ID() end) > 0
end

-- ------------------------------------------------------------- the entries
--- Parse one [DPS] entry: name, pct, part3 (target / behaviour), part4 (if|notif|ifme|notifme), part5 (buff).
function M.parseEntry(raw, cond)
    raw = tostring(raw or ''):gsub('^%s+', ''):gsub('%s+$', '')
    if raw == '' or raw:upper() == 'NULL' then return nil end
    local a = Lines.split(raw, '|')
    local e = { raw = raw, name = (a[1] or ''):gsub('%s+$', ''), pct = tonumber(a[2]), cond = cond or 'TRUE', part3 = '', part4 = '', part5 = '' }
    local p3 = lower((a[3] or ''):gsub('%s+', ''))
    if e.pct and e.pct > 0 and p3 ~= '' and p3 ~= 'null' then
        if p3 == 'if' or p3 == 'ifme' or p3 == 'notif' or p3 == 'notifme' then
            e.part3 = lower((a[5] or ''):gsub('%s+', ''))
            if e.part3 == 'null' then e.part3 = '' end
            e.part4, e.part5 = p3, (a[4] or '')
        else
            e.part3, e.part4, e.part5 = p3, lower((a[4] or ''):gsub('%s+', '')), (a[5] or '')
        end
    end
    e.tag1, e.tag2 = (a[4] or ''), (a[5] or '')
    return e
end

function M:LoadSettings()
    local c = Config.load(self.Settings)
    self.cfg = c
    State.dpsOn = (c.DPSOn or 0) ~= 0
    State.aeOn = (c.AEOn or 0) ~= 0
    local cal = tonumber(c.TTDCal) or 1.0
    if cal < 0.5 or cal > 3 then cal = 1.0 end
    self.ttd.cal = cal
    self.lines, self.debuffLines = {}, {}
    for i, raw in ipairs(c.DPS or {}) do
        local e = M.parseEntry(raw, c.DPSCond and c.DPSCond[i] or 'TRUE')
        if e and e.pct and e.pct ~= 0 then
            e.index = i
            local l = lower(raw)
            if e.part3 == 'debuffall' then self.debuffLines[#self.debuffLines + 1] = e
            elseif not l:find('|weave', 1, true) and not l:find('|mash', 1, true) then self.lines[#self.lines + 1] = e end
        end
    end
    table.sort(self.lines, function(a, b) if a.pct == b.pct then return a.index < b.index end return a.pct > b.pct end)
    table.sort(self.debuffLines, function(a, b) if a.pct == b.pct then return a.index < b.index end return a.pct > b.pct end)
    local sig = {}
    for i, raw in ipairs(c.DPS or {}) do sig[#sig + 1] = i .. '=' .. tostring(raw) end
    Timers.resetOnChange('dps', table.concat(sig, '|'), { 'dps:', 'debuff:' })
    if State.dpsOn and #self.lines == 0 and #self.debuffLines == 0 then
        local Combat = require('modules.combat')
        if #Combat.mash == 0 and #Combat.weave == 0 then
            Log.error('ERROR: DPSOn=1 but section is empty. Turning DPS off. Please check your ini file.')
            c.DPSOn = 0
            State.dpsOn = false
        end
    end
    self.ae = {}
    for i, raw in ipairs(c.AE or {}) do
        local a = Lines.split(tostring(raw), '|')
        if a[1] and a[1] ~= '' and a[1]:upper() ~= 'NULL' then
            self.ae[#self.ae + 1] = { name = a[1], count = tonumber(a[2]) or 1, target = lower((a[3] or ''):gsub('%s+', '')), part4 = (a[4] or ''), part5 = lower((a[5] or ''):gsub('%s+', '')) }
        end
    end
    self.gom = {}
    if not NO_GOM[T.myClass()] then
        for i, raw in ipairs(c.GoM or {}) do
            local a = Lines.split(tostring(raw), '|')
            if a[1] and a[1] ~= '' and a[1]:upper() ~= 'NULL' and not lower(a[1]):find('spell', 1, true) then
                self.gom[#self.gom + 1] = { name = a[1], target = lower((a[2] or 'mob'):gsub('%s+', '')), cond = c.GoMCond and c.GoMCond[i] or 'TRUE', index = i }
            end
        end
    end
    self.burn = {}
    for i, raw in ipairs(c.Burn or {}) do
        local a = Lines.split(tostring(raw), '|')
        if a[1] and a[1] ~= '' and a[1]:upper() ~= 'NULL' and (a[2] == nil or a[2] ~= '0') then
            self.burn[#self.burn + 1] = { name = a[1], target = lower((a[2] or 'mob'):gsub('%s+', '')), part3 = lower((a[3] or ''):gsub('%s+', '')), part4 = (a[4] or ''), cond = c.BurnCond and c.BurnCond[i] or 'TRUE', index = i }
        end
    end
    self.mobsToBurn = {}
    local zone = T.str(function() return mq.TLO.Zone.ShortName() end)
    local mtb = Ini.read('KissAssist_Info.ini', zone, 'MobsToBurn')
    if mtb and mtb ~= '' and not lower(mtb):find('null', 1, true) and not lower(mtb):find('list up to', 1, true) then
        for n in tostring(mtb):gmatch('[^,]+') do self.mobsToBurn[#self.mobsToBurn + 1] = n:gsub('^%s+', ''):gsub('%s+$', '') end
    end
    self:registerBurnEvent()
end

-- ------------------------------------------------------------- TTD (pure, over the injected clock)
--- TTDEstimate: seconds to death for `id` at hp% `cur`, -1 = no estimate yet, 999 = not dying.
function M:ttdEstimate(id, cur)
    local t = self.ttd
    local now = nowSec()
    if id ~= t.mobId then
        if t.mobId ~= 0 then self:ttdSummary('switch') end
        t.mobId, t.startHP, t.startSec = id, cur, now
        t.aSec, t.aHP, t.mSec, t.mHP = now, cur, now, cur
        local sp = T.spawn(id)
        t.name = sp and T.str(function() return sp.CleanName() end) or ''
        return -1
    end
    local win = self.cfg.TTDWindow or 18
    if now - t.aSec >= win then t.aSec, t.aHP = t.mSec, t.mHP end
    if t.mSec == t.aSec and now - t.aSec >= win / 2 then t.mSec, t.mHP = now, cur end
    local winSecs, winLost = now - t.aSec, t.aHP - cur
    if winSecs >= win / 2 then
        if winLost <= 0 then return 999 end
        return math.floor(cur * winSecs / winLost)
    end
    local elapsed, lost = now - t.startSec, t.startHP - cur
    if elapsed < 6 or lost < 5 then return -1 end
    return math.floor(cur * elapsed / lost)
end

function M:ttdSummary(why)
    local t = self.ttd
    local c = self.cfg
    if t.mobId ~= 0 then
        local elapsed = nowSec() - t.startSec
        local sp = T.spawn(t.mobId)
        local died = not sp or T.str(function() return sp.Type() end) == 'Corpse'
        local state = died and 'died' or string.format('dropped at %d%% (%s)', sp and T.num(function() return sp.PctHPs() end) or 0, why)
        if died and t.firstSkipRaw >= 2 and t.firstSkipRaw < 999 then
            local ratio = (elapsed - t.firstSkipAt) / t.firstSkipRaw
            ratio = math.max(0.25, math.min(4, ratio))
            t.cal = math.max(0.5, math.min(3, t.cal * 0.8 + ratio * 0.2))
            Config.set('DPS', 'TTDCal', string.format('%.2f', t.cal))
        end
        if (c.TTDReport or 0) ~= 0 and (t.skipCount > 0 or t.passCount > 0) then
            if t.skipCount > 0 then
                Log.info('TTD %s: %s after %ds from %d%%; first skip at t+%ds predicted %ds (raw %ds), actual %ds; last est %ds; cal %.2f; allowed %d, skipped %d: %s',
                    t.name, state, elapsed, t.startHP, t.firstSkipAt, t.firstSkipEst, t.firstSkipRaw, elapsed - t.firstSkipAt, t.lastEst, t.cal, t.passCount, t.skipCount, table.concat(t.skipped, ','))
            else
                Log.info('TTD %s: %s after %ds from %d%%; nothing skipped (%d allowed, last est %ds, cal %.2f)', t.name, state, elapsed, t.startHP, t.passCount, t.lastEst, t.cal)
            end
        end
    end
    t.skipCount, t.passCount, t.skipped, t.firstSkipEst, t.firstSkipRaw, t.firstSkipAt, t.lastEst = 0, 0, {}, -1, -1, 0, -1
end

-- ------------------------------------------------------------- SmartDPS
-- tell modules/smartdps how a pick ended (its verdict table: holds, refusals, resist streaks)
local function reportSmart(seq, res)
    local sd = package.loaded['modules.smartdps']
    if sd and sd.onResult then pcall(sd.onResult, seq, res) end
end

--- modules/smartdps's current pick: { spell, targetId, mode, seq, beat, ranked }.
function M.smartSet(rec)
    local s = M.smart
    if rec.spell ~= nil then s.spell = tostring(rec.spell) end
    if rec.targetId ~= nil then s.targetId = tonumber(rec.targetId) or 0 end
    if rec.mode ~= nil then s.mode = tostring(rec.mode) end
    if rec.seq ~= nil then s.seq = tonumber(rec.seq) or s.seq end
    if rec.beat ~= nil then s.beat = tonumber(rec.beat) or s.beat end
    if rec.ranked ~= nil then s.ranked = tostring(rec.ranked) end
end
function M:smartHeartbeat()
    local s = self.smart
    if s.beat ~= s.beatLast then s.beatLast = s.beat Timers.set('dps:smartfresh', 5000) s.warned = false
    elseif Timers.expired('dps:smartfresh') and not s.warned then
        Log.error('SmartDPS: bridge heartbeat stale >5s - walking the legacy DPS list until it returns')
        s.warned = true
    end
    if (self.cfg.SmartDPSDebug or 0) ~= 0 and Timers.running('dps:smartfresh') and s.seq ~= s.ack then
        local sp = T.spawn(s.targetId)
        Log.info('SmartDPS(shadow): would cast %s on %s [%s] seq %d', s.spell, sp and T.str(function() return sp.CleanName() end) or '?', s.mode, s.seq)
        s.result = 'shadow'
        s.ack = s.seq
        reportSmart(s.seq, 'shadow')
    end
end

-- ------------------------------------------------------------- CombatCast
local function entryReady(name)
    local rank = Spell.rank(name)
    return T.bool(function() return mq.TLO.Me.SpellReady(rank)() end) or T.bool(function() return mq.TLO.Me.AltAbilityReady(name)() end)
        or T.bool(function() return mq.TLO.Me.CombatAbilityReady(rank)() end) or T.bool(function() return mq.TLO.Me.AbilityReady(name)() end)
        or T.bool(function() return mq.TLO.Me.ItemReady(name)() end)
end
local function targetHasEntry(e, id)
    local sp = T.spawn(id)
    if not sp then return false end
    if targetId() == id then
        local b = mq.TLO.Target.Buff(e.name)
        if T.num(function() return b.ID() end) > 0 then
            local caster = T.str(function() return b.Caster() end)
            if caster == '' or lower(caster) == lower(T.myName()) then return true end
        end
    end
    if Buffcheck.cachedHas(id, e.name) then return true end
    local aaSpell = T.str(function() return mq.TLO.Me.AltAbility(e.name).Spell.Name() end)
    if aaSpell ~= '' and Buffcheck.cachedHas(id, aaSpell) then return true end
    local itemSpell = T.str(function() return mq.TLO.FindItem('=' .. e.name).Clicky.Spell.Name() end)
    if itemSpell ~= '' and Buffcheck.cachedHas(id, itemSpell) then return true end
    return false
end

--- One CombatCast pass on the kill target.
--- A /getaway, or a reset that cleared the kill target, ends the DPS pass. Events are pumped all through an
--- entry (the doevents below, the mez / heal passes, a cast's own wait), so the pass checks before each action.
local function passOver() return State.getAwayOn or (State.myTargetId or 0) == 0 end

function M:combatCast(mobId)
    local c = self.cfg
    if State.buffMode or State.zombieMode or State.getAwayOn then return end
    local cls = T.myClass()
    local ccHold = false
    if State.mezOn and not State.manualOn and (cls == 'ENC' or cls == 'BRD') then
        if self.hooks.mezNeeded() then
            if Timers.expired('dps:pmmez') then Timers.set('dps:pmmez', 5000) Log.pm('mez: holding DPS - crowd control needed (%d haters in MezRadius)', self.hooks.mezCount()) end
            return
        end
        local only = self.hooks.mezCCOnlyAt()
        if only > 0 and self.hooks.mezCount() >= only then
            ccHold = true
            if Timers.expired('dps:pmcc') then Timers.set('dps:pmcc', 5000) Log.pm('mez: CC only - %d haters in MezRadius (MezCCOnlyAt %d), debuffs only', self.hooks.mezCount(), only) end
        end
    end
    mobId = tonumber(mobId) or State.myTargetId or 0
    if mobId == 0 then return end
    local Combat = require('modules.combat')
    local Pet = require('modules.pet')
    if (c.FaceMobOn or 1) ~= 0 and targetId() > 0 and (T.bool(function() return mq.TLO.Me.Standing() end) or T.num(function() return mq.TLO.Me.Mount.ID() end) > 0) then mq.cmd('/squelch /face fast nolook') end
    local s = self.smart
    local seqAtStart = s.seq
    for _, e in ipairs(self.lines) do
        local mob = T.spawn(mobId)
        if not mob or T.str(function() return mob.Type() end) == 'Corpse' or State.dpsPaused then return end
        -- a /getaway (or a reset) that arrived through the doevents below clears the kill target: the macro's
        -- loop reads ${Spawn[${MyTargetID}]} each entry and stops there; this pass holds its own mobId
        if passOver() then return end
        local mobHP = T.num(function() return mob.PctHPs() end)
        if mobHP <= (c.PetAssistAt or 95) and (State.petOn or T.num(function() return mq.TLO.Me.Pet.ID() end) > 0) and (c.PetCombatOn or 1) ~= 0 and not T.bool(function() return mq.TLO.Me.Pet.Combat() end) then Pet.attackSafe(mobId) end
        Combat:doBandolier()
        Cast.hooks.ohShit('CombatCast')
        mq.doevents()
        if not ((cls == 'CLR' or cls == 'DRU' or cls == 'SHM') and State.healsOn) then Combat:combatTargetCheck() end
        if State.manualOn and not T.bool(function() return mq.TLO.Me.Combat() end) then return end
        local sd = package.loaded['modules.smartdps'] if sd then pcall(sd.Tick, sd) end
        if (c.SmartDPSOn or 0) ~= 0 then self:smartHeartbeat() end
        if State.mezOn then self.hooks.mezPass() end
        require('modules.heals'):checkHealthIfOn()
        if passOver() then return end   -- taken by the doevents / mez / heal passes above
        local skip = false
        if State.aggroPaused and lower(e.name) == 'taunt' then skip = true end
        if not skip and self:isCharmEntry(e) then skip = true end
        if not skip and ccHold then
            local f = Spell.facts(e.name)
            if f.hasSPA and f.hasSPA(0) then skip = true end
        end
        -- the live SmartDPS gate. seqCast is the pick this line casts (the macro's SmartDPSSeqCast): the engine can
        -- publish the next pick mid-cast (from the Cast tick hook), and the verdict belongs to the pick that was cast
        local smartActive, seqCast = false, nil
        if not skip and (c.SmartDPSOn or 0) ~= 0 and (c.SmartDPSDebug or 0) == 0 and Timers.running('dps:smartfresh')
            and e.part3 ~= 'me' and e.part3 ~= 'feign' and e.part3 ~= 'ma' and e.part3 ~= 'util' and s.ranked:find('|' .. e.name .. '|', 1, true) then
            if s.seq == s.ack or e.name ~= s.spell or s.targetId ~= mobId then skip = true else smartActive, seqCast = true, s.seq end
        end
        if not skip and not e.name:lower():find('^command:') and not entryReady(e.name) then skip = true end
        if not skip and not condOk(e.cond, c.DPSCOn or 0) then skip = true end
        -- the target
        local tid = mobId
        local friendly = false
        if not skip and e.part3 ~= '' and e.part3 ~= 'ma' and e.part3 ~= 'me' and e.part3 ~= 'feign' and e.part3 ~= 'util' and e.part3 ~= 'once' and e.part3 ~= 'spam' then
            local pc = T.spawnByName(e.part3, 'pc')
            if pc then tid = T.num(function() return pc.ID() end) friendly = true end
        end
        local key = 'dps:' .. e.index .. ':' .. tid
        local fast = false
        if not skip and e.part3 ~= 'me' and e.part3 ~= 'ma' and not friendly and Timers.expired(key)
            and (T.num(function() return mq.TLO.Me.CombatAbility(e.name)() end) > 0 or (T.num(function() return mq.TLO.Me.SkillCap(e.name)() end) > 0 and T.bool(function() return mq.TLO.Me.AbilityReady(e.name)() end))) then
            fast = true
        end
        local res = nil
        if not skip and fast then
            if passOver() then return end
            res = Cast.cast(e.name, tid, 'DPS', { kind = T.num(function() return mq.TLO.Me.CombatAbility(e.name)() end) > 0 and 'disc' or 'skill' })
        elseif not skip then
            if e.part3 ~= 'ma' and lower(Spell.facts(e.name).subcategory) ~= 'utility detrimental' then
                Buffcheck.cacheBuffs(mobId)
                if Buffcheck.cachedSeconds(mobId, '^Mezzed') > 0 then skip = true end
            end
            if not skip and T.num(function() return mq.TLO.Me.XTarget() end) == 0 and mobHP == 100 and not (State.killOrderOn and State.killOrderTarget == mobId) and not State.manualOn and not (State.manualMAOn and State.manualMATarget == mobId) then return end
            if not skip and (c.MoveCloserIfNoLOS or 0) ~= 0 and role() == 'assist' and targetId() > 0 and not T.bool(function() return mq.TLO.Target.LineOfSight() end) and T.num(function() return mq.TLO.Target.Distance3D() end) < 50 and T.bool(function() return mq.TLO.Navigation.MeshLoaded() end) then
                local ma = maSpawn()
                if ma and T.num(function() return ma.Distance() end) > 11 and T.bool(function() return mq.TLO.Navigation.PathExists('id ' .. T.num(function() return ma.ID() end))() end) then
                    mq.cmd('/moveto off') mq.cmd('/squelch /stick off')
                    mq.cmdf('/nav id %d distance=10', T.num(function() return ma.ID() end))
                    mq.delay(1000, function() return T.bool(function() return mq.TLO.Navigation.Active() end) end)
                    Cast.tickDelay(5000, function() return not T.bool(function() return mq.TLO.Navigation.Active() end) end)
                    return
                end
            end
            if not skip then
                if not (role() == 'tank' or role() == 'pullertank' or role() == 'pullerpettank' or role() == 'hunter') then Combat:homogenize() end
                if State.aeOn then self:aeCheck() end
                if (Combat.cfg.AggroOn or 0) ~= 0 then Combat:aggroCheck() end
                if (Combat.cfg.TankAllMobs or 0) ~= 0 then Combat:tankAllMobs() end
                if passOver() then return end   -- homogenize / aggro / tank-all can pump events
                if Pet:wantsAttack(mobId) then Pet:combatPet(mobId) end
            end
            local dpsAt = c.AssistAt or 95
            if not skip and e.pct and e.pct > 0 then
                dpsAt = e.pct
                if e.part3 == 'ma' then local ma = maSpawn() tid = ma and T.num(function() return ma.ID() end) or 0 end
                if e.part3 == 'me' or e.part3 == 'feign' then tid = T.myId() end
                if e.part3 == 'me' then
                    if e.part4 ~= '' then
                        local has = hasBuffOrSong(e.part5)
                        if (e.part4 == 'if' or e.part4 == 'ifme') and not has then skip = true end
                        if (e.part4 == 'notif' or e.part4 == 'notifme') and has then skip = true end
                    elseif hasBuffOrSong(e.name) then skip = true end
                end
                key = 'dps:' .. e.index .. ':' .. tid
            end
            if not skip and tid == 0 then skip = true end
            if not skip and cls == 'CLR' and lower(e.name):find('hammer', 1, true) and T.num(function() return mq.TLO.Me.Pet.ID() end) > 0 then skip = true end
            if not skip and cls == 'WIZ' and T.num(function() return mq.TLO.Me.Pet.ID() end) > 0 and (lower(e.name):find('sword', 1, true) or lower(e.name):find('blade', 1, true)) then skip = true end
            -- TTD
            local tsp = T.spawn(tid)
            if not skip then
                local ttdSecs = -1
                local exempt = e.part3 == 'me' or e.part3 == 'feign' or e.part3 == 'ma' or e.part3 == 'util' or friendly
                -- the estimate tracks the kill target only: a Me / MA / util line must not restart its window
                if (c.TTDOn or 0) ~= 0 and tsp and not exempt and tid == mobId then
                    ttdSecs = self:ttdEstimate(tid, T.num(function() return tsp.PctHPs() end))
                    self.ttd.raw = ttdSecs
                    if ttdSecs > 0 and ttdSecs < 999 then ttdSecs = math.floor(ttdSecs * self.ttd.cal) end
                end
                if smartActive or (tsp and T.bool(function() return tsp.Named() end)) then ttdSecs = 999 end
                if exempt then ttdSecs = 999 end
                if ttdSecs < 0 then
                    if tsp and T.num(function() return tsp.PctHPs() end) < (c.DPSSkip or 1) and not friendly then skip = true end
                else
                    local f = Spell.facts(e.name)
                    local need = 1
                    if Spell.kind(e.name) == 'spell' then need = math.floor(f.castMs / 1000) + (f.durationSec > 0 and (c.TTDMinTicks or 3) * 6 or 1) end
                    self.ttd.lastEst = ttdSecs
                    if ttdSecs < need then
                        local t = self.ttd
                        t.skipCount = t.skipCount + 1
                        if t.firstSkipEst < 0 then t.firstSkipEst, t.firstSkipRaw, t.firstSkipAt = ttdSecs, t.raw or -1, nowSec() - t.startSec end
                        local listed = false
                        for _, n in ipairs(t.skipped) do if n == e.name then listed = true end end
                        if not listed then t.skipped[#t.skipped + 1] = e.name end
                        if Timers.expired('dps:ttdecho') then Timers.set('dps:ttdecho', 10000) Log.info('TTD skip %s: mob dies in ~%ds, needs %ds', e.name, ttdSecs, need) end
                        skip = true
                    else self.ttd.passCount = self.ttd.passCount + 1 end
                end
            end
            if not skip and Timers.running('dps:ab:' .. e.index) then skip = true end
            if not skip and tsp and T.num(function() return T.spawn(tid).PctHPs() end) > dpsAt and c.DPSOn == 1 and not friendly then skip = true end
            if not skip and Timers.running('dps:fd:' .. e.index) then skip = true end
            if not skip and not friendly then
                local tsp2 = T.spawn(tid)
                -- the macro's "no PvP" test: a non-NPC with a non-NPC master (a PC's pet); a PC has no master, so it passes
                if tsp2 and T.str(function() return tsp2.Type() end) ~= 'NPC' and T.num(function() return tsp2.Master.ID() end) > 0 and T.str(function() return tsp2.Master.Type() end) ~= 'NPC' and lower(T.str(function() return mq.TLO.EverQuest.Server() end)) ~= 'zek' then skip = true end
            end
            if not skip and (e.part3 == 'me' or e.part3 == 'ma' or friendly) and T.bool(function() return mq.TLO.Me.Combat() end) and not iAmMA() then
                mq.cmd('/attack off')
                mq.delay(1000, function() return not T.bool(function() return mq.TLO.Me.Combat() end) end)
            end
            if not skip and passOver() then return end
            if not skip and lower(e.name):find('^command:') then
                Cast.cast(e.name, tid, 'DPS', { kind = 'command' })
                skip = true
            end
            if not skip and e.part3 ~= 'me' and e.part3 ~= 'feign' and e.part3 ~= 'ma' and self.hooks.isDispel(e.name) and not self.hooks.dispelWorthwhile(tid) then skip = true end
            if not skip and e.part4 ~= '' then
                if e.part4 == 'if' or e.part4 == 'notif' then
                    Buffcheck.cacheBuffs(tid)
                    local has = Buffcheck.cachedHas(tid, e.part5)
                    if (e.part4 == 'if' and not has) or (e.part4 == 'notif' and has) then skip = true end
                elseif e.part4 == 'ifme' or e.part4 == 'notifme' then
                    local has = hasBuffOrSong(e.part5)
                    if (e.part4 == 'ifme' and not has) or (e.part4 == 'notifme' and has) then skip = true end
                else
                    Log.debug('What The! There is no such DPS parameter: %s', e.part4)
                end
            end
            if not skip and #Combat.weave > 0 and T.bool(function() return mq.TLO.Me.SpellInCooldown() end) then Combat:weaveStuff(tid) skip = true end
            if not skip and Timers.running(key) then
                local f = Spell.facts(e.name)
                if f.durationSec == 0 or e.part3 == 'once' then skip = true
                elseif targetHasEntry(e, tid) then skip = true end
            end
            if not skip then res = Cast.cast(e.name, tid, 'DPS', { dontRecast = smartActive }) end
        end
        -- the verdict
        if res then
            if smartActive then s.result = res s.ack = seqCast reportSmart(seqCast, res) end
            local tname = T.spawn(tid) and T.str(function() return T.spawn(tid).CleanName() end) or '?'
            if res == 'CAST_OUTOFRANGE' or res == 'CAST_CANNOTSEE' or res == 'CAST_OUTOFMANA' or res == 'CAST_STUNNED' or res == 'CAST_SILENCED' or res == 'CAST_STANDING' or res == 'CAST_NOTARGET' then
                if Timers.expired('dps:verdict') then Timers.set('dps:verdict', 5000) Log.pm('cast: %s on >> %s << - %s (dist %d) - ending DPS pass', e.name, tname, res, T.spawn(tid) and T.num(function() return T.spawn(tid).Distance() end) or 0) end
                if res == 'CAST_NOTARGET' and T.spawn(tid) then mq.cmdf('/squelch /target id %d', tid) end
                return
            elseif res == 'CAST_RESIST' then
                Log.info('** %s on >> %s << - RESISTED', e.name, tname)
                if e.part3 == 'once' or Cast.castWhatFails >= (c.CastRetries or 3) then Timers.set(key, 5000) end
            elseif res == 'CAST_TAKEHOLD' then
                Log.info('** %s on >> %s << - DID NOT TAKE HOLD', e.name, tname)
                Timers.set(key, 300000)
            elseif res == 'CAST_SUCCESS' then
                local f = Spell.facts(e.name)
                local kind = Spell.kind(e.name)
                local interval = (c.DPSInterval or 2) * 1000
                if e.part3 == 'once' then Timers.set(key, 300000)
                elseif kind == 'item' then Timers.set(key, f.durationSec * 1000)
                else
                    if (cls == 'BST' or cls == 'MNK' or cls == 'NEC' or cls == 'SHD') and e.part3 == 'feign' then
                        mq.delay(3000, function() return T.str(function() return mq.TLO.Me.State() end) == 'FEIGN' end)
                        Timers.set('dps:fd:' .. e.index, 60000)
                        Cast.tickDelay(10000, function() return T.str(function() return mq.TLO.Me.State() end) ~= 'FEIGN' end)
                        if T.str(function() return mq.TLO.Me.State() end) == 'FEIGN' and not T.bool(function() return mq.TLO.Me.Sitting() end) then
                            if self.hooks.healerDown() then Log.info('Holding feign - healer is down.') else mq.cmd('/stand') end
                        end
                    end
                    Timers.set(key, interval)
                    local ln = lower(e.name)
                    if kind == 'spell' then
                        if tid == T.myId() or e.part3 == 'ma' then Timers.set('dps:ab:' .. e.index, math.floor(f.durationSec * require('modules.heals').durationMod * 1000))
                        elseif cls == 'SHM' and ln:find('counterbias', 1, true) then Timers.set(key, 90000)
                        elseif cls == 'ENC' and ln:find('suffocation', 1, true) then Timers.set(key, 60000)
                        elseif cls == 'BST' and ln:find('feralgia', 1, true) then Timers.set(key, 90000)
                        elseif e.part3 == 'spam' then Timers.set(key, interval)
                        elseif f.durationSec > 0 then Timers.set(key, f.durationSec * 1000) end
                    elseif f.durationSec > 0 and (kind == 'aa' or kind == 'disc') then Timers.set(key, f.durationSec * 1000) end
                end
            end
        elseif smartActive and seqCast ~= s.ack then
            s.result = 'SKIPPED' s.ack = seqCast
            reportSmart(seqCast, 'SKIPPED')
        end
        if passOver() then return end   -- taken during this entry's cast
        if e.part3 == 'me' or e.part3 == 'ma' then Combat:combatTargetCheck() end
        if #Combat.weave > 0 and T.bool(function() return mq.TLO.Me.SpellInCooldown() end) then Combat:weaveStuff(mobId) end
        if #Combat.mash > 0 then Combat:mashButtons() end
    end
    if (c.SmartDPSOn or 0) ~= 0 and (c.SmartDPSDebug or 0) == 0 and Timers.running('dps:smartfresh') and s.seq ~= s.ack and s.seq == seqAtStart and (s.targetId == 0 or s.targetId == mobId) then
        s.result = 'NOMATCH' s.ack = s.seq
        reportSmart(s.seq, 'NOMATCH')
    end
end

-- ------------------------------------------------------------- KACheckDPS (the cast interrupt)
function M.interruptHook(ctx)
    local from = lower(ctx.from)
    if from ~= 'dps' and from ~= 'gom' and from ~= 'burn' then return nil end
    local c = M.cfg
    if (c.CastingInterruptOn or 0) == 0 then return nil end
    local f = ctx.facts or {}
    local cls = T.myClass()
    if (cls == 'ENC' or cls == 'BRD') and State.mezOn and not f.beneficial then
        local Mez = require('modules.mez')
        local protect = (f.hasSPA and (f.hasSPA(31) or f.hasSPA(11))) or lower(ctx.name) == lower(Mez.cfg.MezDebuffSpell or '')
        if not protect and f.hasSPA then for spa = 46, 50 do if f.hasSPA(spa) then protect = true end end end
        if protect and not (f.hasSPA and f.hasSPA(31)) then
            if lower(f.subcategory) == 'disempowering' then protect = false end
            for frag in tostring(Mez.cfg.MezInterruptOK or ''):gmatch('[^|]+') do if lower(ctx.name):find(lower(frag), 1, true) then protect = false end end
        end
        if not protect and M.hooks.mezNeeded() then
            Log.pm('mez: stopcast %s - crowd control needed', ctx.name)
            return 'crowd control needed'
        end
    end
    if T.str(function() return mq.TLO.Target.Type() end) == 'PC' then return nil end
    local tid = targetId()
    local special = (State.killOrderOn and State.killOrderTarget == tid) or State.manualOn or (State.manualMAOn and State.manualMATarget == tid) or (State.markAssistOn and State.markId == tid)
    local alive = tid > 0 and T.str(function() return mq.TLO.Target.Type() end) == 'NPC' and T.num(function() return mq.TLO.Target.PctHPs() end) >= 1
    if not (special and alive) then
        if T.num(function() return mq.TLO.Target.PctHPs() end) < 1 or T.str(function() return mq.TLO.Target.Type() end) == 'Corpse' or tid == 0 or T.num(function() return mq.TLO.Me.XTarget() end) == 0 then return 'target is dead' end
    end
    local Heals = require('modules.heals')
    if State.healsOn and #Heals.single > 0 then
        local r = role()
        local healer = (cls == 'CLR' or cls == 'SHM' or cls == 'DRU' or cls == 'PAL' or cls == 'RNG' or cls == 'BST') and lower(State.healTank) ~= lower(T.myName())
        local petTank = r == 'pettank' or r == 'pullerpettank' or r == 'hunterpettank'
        if healer or petTank then
            local at = math.min(Heals.singlePointMA or 70, 70)
            local tank = State.healTank ~= '' and T.spawnByName(State.healTank, lower(State.healTankType ~= '' and State.healTankType or 'pc')) or nil
            if tank and T.num(function() return tank.PctHPs() end) < at then Stats.bump('dpsCut') return string.format('%s at %d%% needs a heal (line %d%%)', State.healTank, T.num(function() return tank.PctHPs() end), at) end
            if petTank and T.num(function() return mq.TLO.Me.Pet.ID() end) > 0 and T.num(function() return mq.TLO.Me.Pet.PctHPs() end) < at then Stats.bump('dpsCut') return string.format('pet tank at %d%% needs a heal (line %d%%)', T.num(function() return mq.TLO.Me.Pet.PctHPs() end), at) end
        end
    end
    return nil
end

-- ------------------------------------------------------------- CheckForAdds, RangerStuff
function M:checkForAdds()
    if State.buffMode or State.zombieMode or T.num(function() return mq.TLO.Me.XTarget() end) == 0 then return end
    local Combat = require('modules.combat')
    local Mv = require('modules.movement')
    local c = self.cfg
    Combat:mobRadar()
    local aggro = T.aggroTargetId()
    local r = role()
    local puller = r == 'puller' or r == 'pullertank' or r == 'pullerpettank'
    if State.mobCount <= 1 or State.pulling or (not State.dpsOn and not State.meleeOn) or State.iAmDead or State.chainPull == 2 or State.dpsPaused then return end
    if puller and Mv.distToCampLoc() > (c.CampRadius or 30) then return end
    local mt = State.myTargetId or 0
    if targetId() == 0 and mt > 0 and T.spawn(mt) and T.num(function() return T.spawn(mt).Distance() end) < (c.CampRadius or 30) then mq.cmdf('/squelch /target id %d', mt) return end
    if aggro > 0 and T.spawn(aggro) and T.num(function() return T.spawn(aggro).Distance() end) <= (c.CampRadius or 30) and mt == 0 and Timers.expired('dps:addspam') then
        if not State.markAssistOn then
            mq.cmd('/popup Add(s) in camp detected')
            if iAmMA() or r == 'tank' or r == 'pullertank' or r == 'pettank' or r == 'pullerpettank' then Comms.say('r', 'Add(s) in camp detected') end
        end
        if r == 'pullertank' or r == 'pullerpettank' then State.pulled = false end
        Timers.set('dps:addspam', 5000)
        if targetId() > 0 and not State.markAssistOn then mq.cmd('/squelch /target clear') end
    end
    if puller and State.pulled and Mv.distToCampLoc() >= 15 then return end
    if targetId() == 0 and (r == 'tank' or r == 'pullertank' or r == 'pettank' or r == 'pullerpettank' or r == 'hunter' or r == 'hunterpettank') and aggro > 0 then
        local a = T.spawn(aggro)
        if a and not Buffcheck.cachedHas(aggro, '^Mezzed') and not MEZ_ANIM[T.num(function() return a.Animation() end)] then mq.cmdf('/squelch /target id %d', aggro) end
    end
    if targetId() > 0 and T.str(function() return mq.TLO.Target.Type() end) ~= 'NPC' then mq.cmd('/squelch /target clear') end
end

function M:rangerStuff()
    if State.buffMode or State.zombieMode then return end
    local c = self.cfg
    local mt = State.myTargetId or 0
    if targetId() ~= mt or T.num(function() return mq.TLO.Target.Mezzed.ID() end) > 0 then return end
    if T.num(function() return mq.TLO.Target.Distance3D() end) < 30 or not T.bool(function() return mq.TLO.Target.LineOfSight() end) then
        if not (T.str(function() return mq.TLO.Zone.ShortName() end) == 'trialsofsmoke_mission' and T.num(function() return mq.TLO.Me.Z() end) < 1) then
            mq.cmd('/squelch /stick off') mq.cmd('/moveto off')
            Log.info('need to move back a little')
            require('modules.movement').rangeLocation(mt, 33)
        end
    end
    if T.bool(function() return mq.TLO.Me.Sitting() end) and (c.AutoFireOn or 0) ~= 0 then
        mq.cmd('/stand')
        mq.delay(1000, function() return T.bool(function() return mq.TLO.Me.Standing() end) end)
        if not T.bool(function() return mq.TLO.Me.Standing() end) then return end
    end
    if not T.bool(function() return mq.TLO.Me.AutoFire() end) and (c.StayAwayToCast or 0) == 0 then
        Log.info('turning on autofire target is %d feet away', T.num(function() return mq.TLO.Target.Distance3D() end))
        mq.cmd('/autofire on')
        mq.cmd('/squelch /face fast')
    end
end

-- ------------------------------------------------------------- AECheck
function M:aeCheck()
    local c = self.cfg
    if State.buffMode or State.zombieMode or not State.aeOn or State.getAwayOn then return end
    if T.str(function() return mq.TLO.Target.Type() end) == 'Corpse' then return end
    local aggro = T.aggroTargetId()
    if aggro == 0 then return end
    if Timers.running('dps:aescan') then return end   -- per pass and per DPS line: 300 ms is plenty
    Timers.set('dps:aescan', 300)
    local Combat = require('modules.combat')
    local radius = c.AERadius or 50
    local n = Combat:mobRadar(radius)
    local q = string.format('npc targetable los radius %d zradius %d noalert 3', radius, c.MobZRadius or 50)
    local xt = {}
    for i = 1, 13 do
        local x = mq.TLO.Me.XTarget(i)
        if T.str(function() return x.TargetType() end) == 'Auto Hater' then xt[T.num(function() return x.ID() end)] = true end
    end
    local count = 0
    for j = 1, n do
        local id = T.num(function() return mq.TLO.NearestSpawn(j, q).ID() end)
        if xt[id] then count = count + 1 end
    end
    if count <= 0 then return end
    if self.hooks.protectedNear(radius, State.myTargetId or 0) then
        if Timers.expired('dps:pmprot') then Timers.set('dps:pmprot', 5000) Log.pm('ae: holding - a MobsToProtect NPC is within %d of me or the target', radius) end
        return
    end
    local mt = State.myTargetId or 0
    for _, e in ipairs(self.ae) do
        local isBurn = lower(e.name) == 'burn'
        local go = true
        if not isBurn and not entryReady(e.name) then go = false end
        if go and not isBurn and T.num(function() return mq.TLO.FindItem('=' .. e.name).ID() end) > 0 and not T.bool(function() return mq.TLO.Me.ItemReady('=' .. e.name)() end) then go = false end
        if go and e.count > count then go = false end
        if go then
            local tid = mt
            if e.target == 'me' then tid = T.myId()
            elseif e.target == 'ma' then local ma = maSpawn() tid = ma and T.num(function() return ma.ID() end) or 0
            elseif e.target == 'pet' then tid = T.num(function() return mq.TLO.Me.Pet.ID() end) end
            if isBurn then
                if not self.burnActive then
                    Log.info('AE-> %d Mobs: Activating BURN', count)
                    self.burnActive = true
                    self:burnTrigger()
                    return
                end
                go = false
            end
            if go and not Spell.facts(e.name).beneficial then
                local tsp = T.spawn(tid)
                local f = Spell.facts(e.name)
                if tsp and T.str(function() return tsp.Type() end) == 'NPC' then
                    local loc = string.format('loc %d %d %d radius %d', T.num(function() return tsp.X() end), T.num(function() return tsp.Y() end), T.num(function() return tsp.Z() end), f.aerange)
                    if f.hasSPA and (f.hasSPA(0) or f.hasSPA(79)) then
                        local mz = self.hooks.mezzedNear('npc ' .. loc)
                        if mz > 0 then
                            if Timers.expired('dps:pmaemez') then Timers.set('dps:pmaemez', 5000) Log.pm('ae: holding %s - %d mezzed mob(s) within %d of %s', e.name, mz, f.aerange, T.str(function() return tsp.CleanName() end)) end
                            go = false
                        end
                    end
                    if go and e.target ~= 'single' and T.num(function() return mq.TLO.SpawnCount('npc xtarhater ' .. loc)() end) < T.num(function() return mq.TLO.SpawnCount('npc ' .. loc)() end) then
                        Log.info('AE-> Casting %s now would aggro more mobs than we have on xtarget (%d)', e.name, count)
                        go = false
                    end
                end
            end
            if go and e.part4 ~= '' then
                local p4 = lower(e.part4)
                local buff = e.part5 ~= '' and e.part5 or ''
                -- AEn=<spell>|<count>|<if|notif>|<buff>|<mob>
                if e.target == 'if' or e.target == 'notif' then p4, buff = e.target, e.part4 end
                local has
                if e.part5 == 'mob' and tid == mt then has = T.num(function() return mq.TLO.Target.Buff(buff).ID() end) > 0
                else has = hasBuffOrSong(buff) or T.str(function() return mq.TLO.Me.ActiveDisc.Name() end):find(buff, 1, true) ~= nil end
                if (p4 == 'if' and not has) or (p4 == 'notif' and has) then go = false end
            end
            if go and State.getAwayOn then return end   -- taken during the previous AE entry
            if go then
                if count == 1 and e.target == 'single' then
                    if Cast.cast(e.name, tid, 'AoE') == 'CAST_SUCCESS' then Log.info('AE-> %s on Single target  >> %s <<', e.name, T.spawn(tid) and T.str(function() return T.spawn(tid).CleanName() end) or '?') end
                elseif not (count >= 2 and e.target == 'single') then
                    if Cast.cast(e.name, tid, 'AoE') == 'CAST_SUCCESS' then Log.info('AE-> %d Mobs: Casting AE %s', count, e.name) end
                end
            end
        end
    end
end

-- ------------------------------------------------------------- burn
function M:burnTrigger()
    if State.iAmDead or T.bool(function() return mq.TLO.Me.Hovering() end) or State.campZone ~= T.zoneId() then return end
    local bt = self.cfg.BurnText or 'Burn this'
    if bt == '' or bt:upper() == 'NULL' then return end
    Comms.say('r', 'BURN ACTIVATED => Autobots Transform <=')
    self:burnPass()
end

function M:burnPass()
    local c = self.cfg
    if State.iAmDead or T.bool(function() return mq.TLO.Me.Hovering() end) or State.campZone ~= T.zoneId() or #self.burn == 0 or State.getAwayOn then return end
    if (c.UseTribute or 0) ~= 0 and not T.bool(function() return mq.TLO.Me.TributeActive() end) then mq.cmd('/squelch /tribute personal on') Timers.set('dps:tribute', 570000) self.tributeOn = true end
    for _, b in ipairs(self.burn) do
        -- the heal ladder and the emergency list get a turn before every burn entry
        Cast.hooks.ohShit('Burn')
        require('modules.heals'):checkHealthIfOn()
        if State.getAwayOn then return end   -- no burn cooldowns spent during a get away
        local tid = State.myTargetId or 0
        if b.target == 'me' then tid = T.myId()
        elseif b.target == 'ma' then local ma = maSpawn() tid = ma and T.num(function() return ma.ID() end) or 0
        elseif b.target == 'pet' then tid = T.num(function() return mq.TLO.Me.Pet.ID() end)
        elseif b.target ~= '' and b.target ~= 'mob' then Log.warn('Burn entry %d (%s): unknown target %s - use Mob, Me, MA or Pet. Casting at my target.', b.index, b.name, b.target) end
        local go = condOk(b.cond, c.BurnCOn or 0)
        if go and (b.part3 == 'if' or b.part3 == 'notif') and b.part4 ~= '' then
            local has = hasBuffOrSong(b.part4) or T.str(function() return mq.TLO.Me.ActiveDisc.Name() end):find(b.part4, 1, true) ~= nil
            if (b.part3 == 'if' and not has) or (b.part3 == 'notif' and has) then go = false end
        end
        if go and tid > 0 then
            local res = Cast.cast(b.name, tid, 'Burn')
            if res == 'CAST_SUCCESS' then Log.info('Casting >> BURN%d:%s', b.index, b.name)
            elseif res == 'CAST_INTERRUPTED_BY_ME' then require('modules.heals'):checkHealthIfOn() end
        end
    end
end

--- NamedWatch: a named (or a MobsToBurn / rare-list name) burns once per fight.
function M:namedWatch(id)
    local c = self.cfg
    if (c.BurnAllNamed or 0) == 0 then return end
    local sp = T.spawn(id)
    if not sp then return end
    local name = T.str(function() return sp.CleanName() end)
    local fire = T.bool(function() return sp.Named() end)
    if not fire then
        local rare = Ini.read('Map_Labels.ini', 'RareMobs', name)
        if rare and rare ~= '' then fire = true end
    end
    if not fire then
        for _, n in ipairs(self.mobsToBurn) do if lower(n) == lower(name) then fire = true end end
    end
    if fire then
        mq.cmdf('/popup *** Mob:(%s) is a NAMED!', name)
        Log.info('*** Mob:(%s) is a NAMED!', name)
        self:burnTrigger()
    end
    State.namedCheck = true   -- the verdict cannot change mid-fight: no Map_Labels.ini read per pass
end

--- The |Burn this| chat event, re-registered when settings load so a custom BurnText is honoured.
function M:registerBurnEvent()
    -- /muleassist reload runs LoadSettings from a bind (a throwaway coroutine): register from Tick instead
    if not Cast.canRegister() then self.burnEventPending = true return end
    self.burnEventPending = false
    pcall(mq.unevent, 'ma_burn')
    local bt = self.cfg.BurnText
    if bt == nil or bt == '' or tostring(bt):upper() == 'NULL' then bt = 'Burn this' end
    mq.event('ma_burn', '[MQ2] |' .. bt .. '|', function() M:burnTrigger() end)
end

--- Tribute off once the burn's 9.5 minutes are up, unless a named is still the target (then 580 s more).
function M:tributeTick()
    if not self.tributeOn or Timers.running('dps:tribute') then return end
    if (self.cfg.UseTribute or 0) == 0 or not T.bool(function() return mq.TLO.Me.TributeActive() end) then self.tributeOn = false return end
    local tn = T.bool(function() return mq.TLO.Target.Named() end) and T.num(function() return mq.TLO.Target.ID() end) > 0
    if T.aggroTargetId() == 0 or not tn then mq.cmd('/squelch /tribute personal off') self.tributeOn = false
    else Timers.set('dps:tribute', 580000) end
end

-- ------------------------------------------------------------- Gift of Mana
function M:onGoM()
    local c = self.cfg
    if NO_GOM[T.myClass()] or self.gomBypass then return end
    if T.num(function() return mq.TLO.Me.Casting.ID() end) > 0 then self.gomPending = true return end   -- fired from Cast.wait's doevents
    self.gomPending = false
    if not State.combatStart or State.getAwayOn or Timers.running('dps:gom') or (c.GoMOn or 1) == 0 then return end
    Timers.set('dps:gom', 3000)
    for _, g in ipairs(self.gom) do
        if condOk(g.cond, c.GoMCOn or 0) and Timers.expired('dps:gom:' .. g.index) then
            Log.info('Gift of Mana detected! Trying to cast %s', g.name)
            local tid = State.myTargetId or 0
            if g.target == 'me' then tid = T.myId() elseif g.target == 'ma' then local ma = maSpawn() tid = ma and T.num(function() return ma.ID() end) or 0 end
            if g.target == 'mob' or g.target == '' then
                local sp = T.spawn(tid)
                if not sp or T.str(function() return sp.Type() end) == 'Corpse' then Log.info('[GoM] being skipped, because target is a corpse.') Timers.clear('dps:gom') return end
            end
            Cast.tickDelay(6000, function() return not T.bool(function() return mq.TLO.Me.SpellInCooldown() end) end)
            if State.getAwayOn then return end
            if T.bool(function() return mq.TLO.Me.SpellReady(g.name)() end) then
                if Cast.cast(g.name, tid, 'GoM') == 'CAST_SUCCESS' then
                    Log.info('Gift of Mana Casting >> %s << ', g.name)
                    Timers.clear('dps:gom')
                    Timers.set('dps:gom:' .. g.index, math.floor(Spell.facts(g.name).durationSec * require('modules.heals').durationMod * 1000))
                    return
                end
            else Log.info('"%s" is not ready!', g.name) end
        end
    end
end

-- ------------------------------------------------------------- module hooks
function M:onReset(from)
    self:ttdSummary(from)
    self.ttd.mobId = 0
    self.burnActive = false
    Timers.clearPrefix('dps:fd:')
    Timers.clearPrefix('dps:gom')
end

function M:Init()
    Cast.addInterruptHook('dps', M.interruptHook)
    local Combat = require('modules.combat')
    Combat.hooks.dps = function(id) M:combatCast(id) end
    Combat.hooks.ae = function() if State.aeOn then M:aeCheck() end end
    Combat.hooks.burnNamed = function(id) M:namedWatch(id) end
    Combat.hooks.checkForAdds = function() M:checkForAdds() end
    Combat.hooks.ranger = function() M:rangerStuff() end
    Combat.addResetHook('dps', function(from) M:onReset(from) end)
    local Mez = require('modules.mez')
    self.hooks.mezNeeded = function() return Mez:needed() end
    self.hooks.mezCount = function() return Mez.aeCount end
    self.hooks.mezCCOnlyAt = function() return Mez.cfg.MezCCOnlyAt or 0 end
    self.hooks.mezPass = function() Mez:doMezStuff() end
    self.hooks.mezzedNear = Mez.aeMezzedNear
    local Debuffs = require('modules.debuffs')
    self.hooks.isDispel = Debuffs.isDispel
    self.hooks.dispelWorthwhile = Debuffs.dispelWorthwhile
    self.hooks.healerDown = require('modules.healeraggro').healerDown
    self.hooks.protectedNear = function(radius, tid)
        if #(State.mobsToProtect or {}) == 0 then return false end
        local zr = self.cfg.MobZRadius or 50
        if T.num(function() return mq.TLO.SpawnCount(string.format('npc alert 5 radius %d zradius %d', radius, zr))() end) > 0 then return true end
        local tsp = tid > 0 and T.spawn(tid) or nil
        if tsp and T.num(function() return mq.TLO.SpawnCount(string.format('npc alert 5 loc %d %d radius %d zradius %d', T.num(function() return tsp.X() end), T.num(function() return tsp.Y() end), radius, zr))() end) > 0 then return true end
        return false
    end
    self:registerBurnEvent()
    for i, p in ipairs({ 'The gift of magic fades.', 'Your#*#gift of#*#mana fades.' }) do mq.event('ma_gomoff' .. i, p, function() end) end
    for i, p in ipairs({ '#*#granted#*#gift of#*#mana#*#', 'You feel strengthened by a gift of magic.', 'You feel strengthened by magic.' }) do mq.event('ma_gomon' .. i, p, function() M:onGoM() end) end
    mq.event('ma_concheck', '#1# -#*#a rare creature#*#', function(_, mob)
        Log.info('Con Check |%s|', mob)
        if not Ini.read('Map_Labels.ini', 'RareMobs', mob) then Ini.write('Map_Labels.ini', 'RareMobs', mob, T.str(function() return mq.TLO.Zone.Name() end)) end
    end)
end

function M:Shutdown()
    for _, e in ipairs({ 'ma_burn', 'ma_gomoff1', 'ma_gomoff2', 'ma_gomon1', 'ma_gomon2', 'ma_gomon3', 'ma_concheck' }) do pcall(mq.unevent, e) end
end

function M:Tick()
    if self.burnEventPending then self:registerBurnEvent() end
end

function M:GiveTime(ctx)
    self:tributeTick()
    if self.gomPending and T.num(function() return mq.TLO.Me.Casting.ID() end) == 0 then self:onGoM() end
    if State.chainPull == 2 or State.getAwayFollow then return end
    if State.aeOn and not State.getAwayOn and not ctx.inCombat then self:aeCheck() end
end

function M:OnZone() self:LoadSettings() end

local function resistBind(section, label)
    return function(self, arg)
        if lower(arg):find('zone', 1, true) then
            Log.info('Adding the entire zone of %s - %s to the %s list', T.str(function() return mq.TLO.Zone.Name() end), T.str(function() return mq.TLO.Zone.ShortName() end), label)
            Ini.write('Lemons_Info.ini', section, T.str(function() return mq.TLO.Zone.ShortName() end), '')
        else
            Log.info('Adding %s to the %s resist list', T.str(function() return mq.TLO.Target.CleanName() end), label)
            Ini.write('Lemons_Info.ini', section, T.str(function() return mq.TLO.Target.CleanName() end), '')
        end
    end
end
M.Binds = {
    ['/burn'] = function(self) self:burnTrigger() end,
    ['/dpson'] = function(self, arg)
        local v = tonumber(arg)
        if arg == 'on' then v = 1 elseif arg == 'off' then v = 0 end
        if v == nil then v = (self.cfg.DPSOn or 0) == 0 and 1 or 0 end
        self.cfg.DPSOn = v
        State.dpsOn = v ~= 0
        Config.set('DPS', 'DPSOn', v)
        Log.info('DPSOn %d', v)
    end,
    ['/dpsinterval'] = function(self, arg) local v = tonumber(arg) if v then self.cfg.DPSInterval = v Config.set('DPS', 'DPSInterval', v) Log.info('DPSInterval %d', v) end end,
    ['/dpsskip'] = function(self, arg) local v = tonumber(arg) if v then self.cfg.DPSSkip = v Config.set('DPS', 'DPSSkip', v) Log.info('DPSSkip %d', v) end end,
    ['/aeon'] = function(self, arg)
        local v = tonumber(arg)
        if arg == 'on' then v = 1 elseif arg == 'off' then v = 0 end
        if v == nil then v = (self.cfg.AEOn or 0) == 0 and 1 or 0 end
        self.cfg.AEOn = v
        State.aeOn = v ~= 0
        Log.info('AEOn %d', v)
    end,
    ['/addfire'] = resistBind('FireMobs', 'Fire'),
    ['/addcold'] = resistBind('ColdMobs', 'Cold'),
    ['/addslow'] = resistBind('SlowMobs', 'Slow'),
    ['/adddisease'] = resistBind('DiseaseMobs', 'Disease'),
    ['/addmagic'] = resistBind('MagicMobs', 'Magic'),
    ['/addpoison'] = resistBind('PoisonMobs', 'Poison'),
}

return M
