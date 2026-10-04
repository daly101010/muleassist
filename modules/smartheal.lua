-- modules/smartheal.lua: the SmartHeals engine, in-process (spec
-- muleassist/docs/superpowers/specs/2026-10-02-luaport-smartheal-fork-design.md). It does the job of
-- sidekick-next's ma_healbridge.lua inside the bot: initializes the forked engine (smartheal/) one phase per
-- pass, ticks its sensors every 200 ms, picks a heal (buildHealAction + the HoT veto) and hands it to
-- modules/heals.lua (smartSet); heals reports each cast or skip back through M.onResult. CLR/DRU/SHM/PAL
-- while SmartHealsOn. Telemetry goes to the companion / MAUI / medley SmartHeals cards as before.
local mq = require('mq')
local State = require('core.state')
local Log = require('core.log')
local T = require('core.tlo')

local M = { name = 'smartheal' }

M.HEALERS = { CLR = true, DRU = true, SHM = true, PAL = true }
M.TANK_ROLES = { tank = true, pullertank = true }
M.LOOP_MS = 200
M.GEM_SCAN_MS = 10000
M.HEAL_GEM_CHECK_MS = 1000
M.ERROR_LOG_MS = 30000
-- the Config keys the bot overrides at runtime; a gem-bar save persists the profile's own values instead
M.OVERRIDES = { 'broadcastEnabled', 'healPetsEnabled', 'defaultRemoteMaxHP', 'minHealPct',
    'nonSquishyMinHealPct', 'lowPressureMinDeficitPct', 'emergencyPct' }
-- every mq.event the engine registers (spell_events, damage_parser, damage_attribution, mob_assessor)
M.EVENT_NAMES = {
    'HealLandedCrit', 'HealLanded', 'HealLandedNoFullCrit', 'HealLandedNoFull', 'HealLandedHaveCrit',
    'HealLandedHave', 'HealLandedHaveNoFullCrit', 'HealLandedHaveNoFull', 'HotLandedCrit',
    'HotLandedNoFullCrit', 'HotLanded', 'HotLandedNoFull', 'HotLandedHave', 'HotLandedHaveNoFull',
    'HotLandedHaveCrit', 'HotLandedHaveNoFullCrit', 'SpellInterrupted', 'SpellFizzle', 'SpellNotHold',
    'DmgMelee', 'DmgSpell', 'DmgDot', 'DmgDs',
    'DmgAttrPunch', 'DmgAttrHit', 'DmgAttrSlash', 'DmgAttrBite', 'DmgAttrPierce', 'DmgAttrKick',
    'DmgAttrStrike', 'DmgAttrBash', 'DmgAttrFrenzy', 'DmgAttrClaw', 'DmgAttrShoot', 'DmgAttrBackstab',
    'DmgAttrCrush', 'DmgAttrSmash', 'DmgAttrSting', 'DmgAttrSlice', 'DmgAttrGore', 'DmgAttrRend',
    'DmgAttrMaul', 'DmgAttrSpell', 'DmgAttrDot', 'DmgAttrNonMeleeSelf', 'DmgAttrNonMeleeOther',
    'MobAssessorArmy', 'MobAssessorImpossible', 'MobAssessorExtreme', 'MobAssessorDifficult',
    'MobAssessorFormidable', 'MobAssessorEasy', 'MobAssessorEvenMatch',
}

local function Heals() return require('modules.heals') end
local function BS() return require('smartheal.util.ma_bridge_state') end
local function num(fn, d) local ok, v = pcall(fn) return tonumber(ok and v or nil) or d end

function M.reset()
    M.engine, M.phase, M.ready = nil, 0, false
    M.state, M.published, M.lastAck = nil, {}, 0
    M.nextTick, M.lastErrorLog = 0, nil
    M.profileValues = {}
    M.lastFloor, M.lastEmergency, M.lastGemScan = nil, nil, 0
    M.lastHealGemCheck, M.healGemCached = -math.huge, false
    M.shActor, M.shWarned, M.shLastConfig, M.shLastNet = nil, false, nil, nil
end
M.reset()

function M:wanted() return State.smartHealsOn == true and M.HEALERS[T.myClass()] == true end

--- Diagnostics go to the engine's file log (category 'bridge'), Log.debug when it has no logger.
function M:flog(fmt, ...)
    local logger = self.engine and self.engine.Logger
    if logger and logger.info then
        pcall(logger.info, 'bridge', fmt, ...)
    else
        Log.debug('SmartHeals ' .. fmt, ...)
    end
end

-- ------------------------------------------------------------- telemetry (companion / maui / medley cards)
function M:send(payload)
    if not self.shActor then
        if not self.shWarned then
            self.shWarned = true
            Log.info('SmartHeals: companion feed unavailable - SmartHeals cards will show no data.')
        end
        return
    end
    pcall(BS().sendTelemetry, self.shActor, payload, T.myName(), T.str(function() return mq.TLO.EverQuest.Server() end))
end

function M:shConfig(maId, shadow)
    local cfg = self.engine.Config
    local maName = maId > 0 and T.str(function() return mq.TLO.Spawn(maId).CleanName() end) or ''
    local key = string.format('%s|%s|%s|%s', tostring(cfg.emergencyPct), tostring(cfg.minHealPct), maName, tostring(shadow))
    if key == self.shLastConfig then return end
    self.shLastConfig = key
    self:send({ kind = 'config', emergencyPct = tonumber(cfg.emergencyPct), floorPct = tonumber(cfg.minHealPct),
        maName = maName, shadow = shadow })
end

function M:shNet(n)
    if self.shLastNet == nil then self.shLastNet = n return end
    if n > self.shLastNet then self:send({ kind = 'net', count = n - self.shLastNet }) end
    self.shLastNet = n -- a reset counter resyncs without reporting a negative
end

-- ------------------------------------------------------------- the bridge's per-tick steps
function M:feedExternalTargets(maId, xtarHeal)
    local tm = self.engine.TargetMonitor
    if not (tm and tm.updateActorTargets) then return end
    local feed, zone, myId = {}, T.str(function() return mq.TLO.Zone.ShortName() end), T.myId()
    local function pcSpawn(id)
        local sp = T.spawn(id)
        if sp and T.str(function() return sp.Type() end) == 'PC' then return sp end
        return nil
    end
    if maId > 0 and maId ~= myId and not T.inGroup(maId) then
        local sp = pcSpawn(maId)
        if sp then feed[#feed + 1] = { id = maId, zone = zone, role = 'tank', hp = num(function() return sp.PctHPs() end, 100) } end
    end
    local xt = tostring(xtarHeal or '0')
    if xt ~= '0' and xt ~= '' and xt ~= 'NULL' then
        for slot in xt:gmatch('[^|]+') do
            local id = num(function() return mq.TLO.Me.XTarget(tonumber(slot) or 0).ID() end, 0)
            if id > 0 and id ~= myId and id ~= maId and not T.inGroup(id) then
                local sp = pcSpawn(id)
                if sp then feed[#feed + 1] = { id = id, zone = zone, role = 'dps', hp = num(function() return sp.PctHPs() end, 100) } end
            end
        end
    end
    if #feed > 0 then tm.updateActorTargets(feed) end
end

-- group scans rebuild each entry's role from class every tick: re-apply the MA as the engine's tank
function M:applyTankRole(maId)
    local tm = self.engine.TargetMonitor
    if maId <= 0 or not (tm and tm.getTarget) then return end
    local t = tm.getTarget(maId)
    if t and t.role ~= 'pet' then t.role = 'tank' end
end

function M:applyMaxHPFallback()
    local best = num(function() return mq.TLO.Me.MaxHPs() end, 0)
    local tm = self.engine.TargetMonitor
    if tm and tm.getAllTargets then
        for _, t in pairs(tm.getAllTargets() or {}) do
            if t.maxHPKnown and (tonumber(t.maxHP) or 0) > best then best = tonumber(t.maxHP) end
        end
    end
    if best > 100 and self.engine.Config.defaultRemoteMaxHP ~= best then self.engine.Config.defaultRemoteMaxHP = best end
end

function M:applyHealFloor(floor)
    if floor <= 0 or floor == self.lastFloor then return end
    self.lastFloor = floor
    local cfg = self.engine.Config
    cfg.minHealPct = floor
    cfg.nonSquishyMinHealPct = math.max(floor, 15)
    cfg.lowPressureMinDeficitPct = math.max(floor, 20)
    Log.info('SmartHeals floor: %d%% deficit (nonSquishy %d%%, lowPressure %d%%)', floor, cfg.nonSquishyMinHealPct, cfg.lowPressureMinDeficitPct)
end

function M:applyEmergencyPct(pct)
    if pct <= 0 then pct = 45 end
    if pct == self.lastEmergency then return end
    self.lastEmergency = pct
    self.engine.Config.emergencyPct = pct
    Log.info('SmartHeals emergency line: %d%% (fastest direct heal, HoTs/group heals suppressed below it)', pct)
end

-- put `values` into Config for every overridden key; returns what was there
function M:swapOverrides(values)
    local cfg, prev = self.engine.Config, {}
    for _, k in ipairs(self.OVERRIDES) do prev[k] = cfg[k] cfg[k] = values[k] end
    if cfg.logCategories then
        prev.hotCoverage = cfg.logCategories.hotCoverage
        cfg.logCategories.hotCoverage = values.hotCoverage
    end
    return prev
end

function M:rescanGems()
    local now = mq.gettime()
    if now - self.lastGemScan < self.GEM_SCAN_MS then return end
    self.lastGemScan = now
    local cfg = self.engine.Config
    if not cfg.mergeFromSpellBar then return end
    -- mergeFromSpellBar saves the whole Config when it adds a heal: persist the profile's values
    local live = self:swapOverrides(self.profileValues)
    local _, additions = cfg.mergeFromSpellBar()
    self:swapOverrides(live)
    for _, add in ipairs(additions or {}) do Log.info('SmartHeals: memorized heal added: %s -> %s', tostring(add.name), tostring(add.category)) end
end

-- a single HoT on a target below 100 - hotMaxDeficitPct is replaced by the best direct heal
function M:vetoHot(action, opts, reason)
    if not action or not action.isHoT or action.tier == 'groupHot' then return action, reason end
    local cfg, tm = self.engine.Config, self.engine.TargetMonitor
    local t = tm and tm.getTarget and tm.getTarget(tonumber(action.targetId) or 0) or nil
    local pct = t and tonumber(t.pctHP) or 100
    local floor = 100 - (tonumber(cfg.hotMaxDeficitPct) or 35)
    if pct >= floor then return action, reason end
    local saved = cfg.hotEnabled
    cfg.hotEnabled = false
    local direct, directReason = self.engine.buildHealAction(opts)
    cfg.hotEnabled = saved
    -- the veto re-fires every tick while it stands: the engine's file log, not chat
    self:flog('HoT veto: %s on %s at %d%% (< %d%%) -> %s', tostring(action.spellName), tostring(action.targetName), pct, floor, direct and tostring(direct.spellName) or 'none')
    self:send({ kind = 'veto', spell = tostring(action.spellName), target = tostring(action.targetName), pct = pct,
        replacement = direct and tostring(direct.spellName) or nil })
    return direct, directReason
end

-- a configured heal is memorized (promised is never picked; selfHeal only with selfHealEnabled)
function M:healMemorized()
    local now = mq.gettime()
    if now - self.lastHealGemCheck < self.HEAL_GEM_CHECK_MS then return self.healGemCached end
    self.lastHealGemCheck = now
    self.healGemCached = false
    local cfg = self.engine.Config
    for cat, list in pairs(cfg.spells or {}) do
        if type(list) == 'table' and cat ~= 'promised' and (cat ~= 'selfHeal' or cfg.selfHealEnabled) then
            for _, name in ipairs(list) do
                if type(name) == 'string' and name ~= '' and num(function() return mq.TLO.Me.Gem(name)() end, 0) > 0 then
                    self.healGemCached = true
                    return true
                end
            end
        end
    end
    return false
end

-- ------------------------------------------------------------- publish / results
function M:sendDecision(action)
    local tm = self.engine.TargetMonitor
    local t = tm and tm.getTarget and tm.getTarget(tonumber(action.targetId) or 0) or nil
    self:send({ kind = 'decision', seq = self.state.seq, spell = tostring(action.spellName), target = tostring(action.targetName),
        tier = tostring(action.tier or 'single'), trigger = action.reason and tostring(action.reason) or nil,
        targetPct = t and tonumber(t.pctHP) or nil, targetDps = t and tonumber(t.recentDps) or nil, isHoT = action.isHoT == true })
end

--- Hand the pick to modules/heals.lua with the old bridge's seq / beat / fallback rules.
function M:publish(action, fallback)
    local H = Heals()
    local rec = { fallback = fallback and 1 or 0 }
    if self.state then
        BS().noteMacroSeq(self.state, H.smart.seq) -- heals' counters reset (/smarthealson off): republish fresh
        local batch = BS().next(self.state, action, H.smart.ack)
        if batch then
            self.published[self.state.seq] = action
            rec.seq = self.state.seq
            if action then
                rec.spell, rec.targetId, rec.tier = tostring(action.spellName or ''), tonumber(action.targetId) or 0, tostring(action.tier or 'single')
                self:flog('PUBLISH seq=%d %s on %s [%s] %s', self.state.seq, rec.spell, tostring(action.targetName), rec.tier, tostring(action.details or action.reason or ''))
                self:sendDecision(action)
            else
                rec.spell, rec.targetId, rec.tier = '', 0, 'none'
                self:flog('WITHDRAW seq=%d', self.state.seq)
            end
        end
        -- no beat while no configured heal is memorized: heals' fresh timer lapses and legacy heals take over
        if action or self:healMemorized() then rec.beat = self.state.beat end
    end
    H.smartSet(rec)
end

function M:logError(err)
    local now = mq.gettime()
    if self.lastErrorLog and now - self.lastErrorLog < self.ERROR_LOG_MS then return end
    self.lastErrorLog = now
    Log.error('SmartHeals engine: %s - legacy heals in use', tostring(err))
end

--- heals reports every smart cast or skip: a successful HoT enters the engine's HoT ledger.
function M.onResult(seq, result)
    local self = M
    seq = tonumber(seq) or 0
    if not self.ready or seq <= self.lastAck then return end
    self.lastAck = seq
    local action = self.published[seq]
    local ok, err = pcall(function()
        if action then
            self:flog('ACK seq=%d result=%s (%s on %s)', seq, tostring(result), tostring(action.spellName), tostring(action.targetName))
            self:send({ kind = 'ack', seq = seq, result = tostring(result) })
        end
        if action and action.isHoT and tostring(result) == 'CAST_SUCCESS' then
            local info = self.engine.prepareHealCast(action)
            if info then
                info.confirmedLanded = true
                self.engine.registerHealCast(info)
            end
        end
    end)
    if not ok then self:logError(err) end
    for s in pairs(self.published) do if s <= seq then self.published[s] = nil end end
end

-- ------------------------------------------------------------- lifecycle
function M:onReady()
    local cfg = self.engine.Config
    for _, k in ipairs(self.OVERRIDES) do self.profileValues[k] = cfg[k] end
    self.profileValues.hotCoverage = cfg.logCategories and cfg.logCategories.hotCoverage
    cfg.broadcastEnabled = false
    if cfg.logCategories then cfg.logCategories.hotCoverage = false end
    local ok, actors = pcall(require, 'actors')
    if ok and actors and actors.register then
        local okReg, a = pcall(actors.register, 'companion_smartheal', function() end)
        if okReg then self.shActor = a end
    end
    self.ready = true
    Log.info('SmartHeals engine ready (in-process)')
    if cfg.HasConfiguredSpells and not cfg.HasConfiguredSpells() then
        Log.info('SmartHeals: no heal spells assigned yet - memorize heals; categories auto-assign from the gem bar')
    end
end

function M:step()
    if not self.engine then
        self.engine = require('smartheal')
        self.state = BS().newState()
        require('smartheal.env').setTank(function() return M.TANK_ROLES[tostring(State.role or ''):lower()] == true end)
    end
    local eng = self.engine
    local total = tonumber(eng.TOTAL_INIT_PHASES) or 5
    local function initialized() return eng.isInitialized == nil or eng.isInitialized() end
    if self.phase < total then
        eng.initPhased(self.phase + 1) -- a failure propagates to Tick's pcall and the phase is retried next tick
        self.phase = self.phase + 1
        if self.phase >= total and initialized() then self:onReady() end
        Heals().smartSet({ fallback = 1 })
        return
    end
    if not self.ready then
        if initialized() then self:onReady() end
        Heals().smartSet({ fallback = 1 })
        return
    end
    local H = Heals()
    local c = H.cfg or {}
    local active = State.healsOn == true and not State.buffMode and not State.zombieMode
    local action, reason = nil, nil
    if active then
        eng.Config.healPetsEnabled = (tonumber(c.HealGroupPetsOn) or 0) > 0
        local maId = tonumber(State.mainAssistId) or 0
        self:feedExternalTargets(maId, H.xtarOverride or c.XTarHeal)
        eng.tickSensors({ readOnly = true })
        self:applyTankRole(maId)
        self:applyMaxHPFallback()
        self:applyHealFloor(tonumber(c.SmartHealFloorPct) or 0)
        self:applyEmergencyPct(tonumber(c.SmartHealEmergencyPct) or 0)
        self:shConfig(maId, (tonumber(c.SmartHealDebug) or 0) > 0)
        self:shNet(tonumber(H.smart.netFires) or 0)
        self:rescanGems()
        local opts = { ignoreSpellEngine = true, skipIfCasting = false, pcHealPct = tonumber(State.singleHealPoint) or 0 }
        action, reason = eng.buildHealAction(opts)
        action, reason = self:vetoHot(action, opts, reason)
    end
    -- an intentional HoT wait keeps smart heals; inability to heal a player restores the legacy paths
    local fallback = not active or (not action and (reason == 'unserviceable' or not self:healMemorized()))
    self:publish(action, fallback)
end

function M:Tick()
    if not self:wanted() then return end
    local now = mq.gettime()
    if now < self.nextTick then return end
    self.nextTick = now + self.LOOP_MS
    local ok, err = pcall(self.step, self)
    if not ok then
        pcall(function() Heals().smartSet({ fallback = 1 }) end)
        self:logError(err)
    end
end

function M:Shutdown()
    if not self.engine then return end
    if self.ready then
        -- engine.shutdown saves its Config: persist the profile's values, not the bot's overrides
        self:swapOverrides(self.profileValues)
        if self.engine.shutdown then pcall(self.engine.shutdown) end
    end
    for _, n in ipairs(self.EVENT_NAMES) do pcall(mq.unevent, n) end
end

return M
