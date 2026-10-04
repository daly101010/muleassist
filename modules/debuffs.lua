-- modules/debuffs.lua: DoDebuffStuff / DebuffCast - the [DPS] lines tagged `debuffall` (Spell|pct|debuffall
-- |tag1|tag2 with tag1 strip / slow / tash / malo / crip / snare / always) on the kill target and the adds on
-- XTarget within MeleeDistance, the per-line done lists and timers (DBOList / DBOTimer), IsDispel and
-- DispelWorthwhile. DebuffAllOn 1 = adds without waiting for cooldowns, 2 = adds waited for too.
--
-- Not a transliteration: the 7 s wait for a cooling line is one mq.delay with a ready condition instead of
-- a busy loop; the lines come from the dps module's parse of [DPS].
local mq = require('mq')
local T = require('core.tlo')
local Config = require('core.config')
local Timers = require('core.timers')
local Spell = require('core.spell')
local Cast = require('core.cast')
local Log = require('core.log')
local Cond = require('core.cond')
local State = require('core.state')
local Buffcheck = require('core.buffcheck')

local M = { name = 'debuffs' }

M.Settings = {
    scalars = {
        { section = 'DPS', key = 'DebuffAllOn', type = 'int', default = 0 },
        { section = 'DPS', key = 'DPSCOn', type = 'int', default = 0 },
        { section = 'DPS', key = 'DPSInterval', type = 'int', default = 2 },
        { section = 'Melee', key = 'MeleeDistance', type = 'int', default = 30 },
    },
}
M.cfg = {}
M.lists = {}       -- line index -> set of mob ids already debuffed by that line (DBOList)
M.hooks = { lines = function() return {} end, ccHeldByOther = function(id) return nil end, mobRadar = function() end, mezPass = function() end }

local MEZ_ANIM = { [26] = true, [32] = true, [71] = true, [72] = true, [17] = true, [111] = true, [129] = true }
local function lower(s) return tostring(s or ''):lower() end
local function targetId() return T.num(function() return mq.TLO.Target.ID() end) end
local function iAmMA() return State.mainAssist ~= '' and lower(State.mainAssist) == lower(T.myName()) end
local function mezzed(sp) return Buffcheck.cachedHas(T.num(function() return sp.ID() end), '^Mezzed') or MEZ_ANIM[T.num(function() return sp.Animation() end)] == true end
local function spellOf(name)
    local sp = mq.TLO.Spell(name)
    if T.num(function() return sp.ID() end) > 0 then return sp end
    local aa = mq.TLO.Me.AltAbility(name).Spell
    if T.num(function() return aa.ID() end) > 0 then return aa end
    local it = mq.TLO.FindItem('=' .. name).Clicky.Spell
    if T.num(function() return it.ID() end) > 0 then return it end
    return nil
end

function M:LoadSettings()
    self.cfg = Config.load(self.Settings)
    self.lists = {}
end

--- IsDispel: the spell behind `name` carries SPA 27 or 209.
function M.isDispel(name)
    local sp = spellOf(name)
    if not sp then return false end
    return T.bool(function() return sp.HasSPA(27)() end) or T.bool(function() return sp.HasSPA(209)() end)
end

--- DispelWorthwhile: the mob carries a beneficial buff other than Mitigation of the Mighty and is not mezzed.
function M.dispelWorthwhile(id)
    local sp = T.spawn(id)
    if not sp then return false end
    Buffcheck.cacheBuffs(id)
    if Buffcheck.cachedHas(id, '^Mezzed') then return false end
    if not Buffcheck.cachedHas(id, '^Beneficial') then return false end
    if not Buffcheck.cachedHas(id, 'Mitigation of the Mighty') then return true end
    local n = T.num(function() return sp.CachedBuffCount() end)
    for c = 1, n do
        local b = sp.CachedBuff(c)
        if T.str(function() return b.SpellType() end):find('Beneficial', 1, true) and T.str(function() return b.Name() end) ~= 'Mitigation of the Mighty' then return true end
    end
    return false
end

local function ready(name)
    return T.bool(function() return mq.TLO.Me.SpellReady(name)() end) or T.bool(function() return mq.TLO.Me.AltAbilityReady(name)() end) or T.bool(function() return mq.TLO.Me.ItemReady('=' .. name)() end)
end
local function listed(i, id) return M.lists[i] ~= nil and M.lists[i][id] == true end
local function listAdd(i, id) M.lists[i] = M.lists[i] or {} M.lists[i][id] = true end

--- DebuffCast: every debuff line on one mob (wait = hold up to 7 s for a cooling line).
--- DPSPaused or a /getaway ends the debuff pass. Events are pumped all through a line (the mez pass, the
--- retarget and buff waits, the spell cooldown wait, the cast), so the pass checks before each action.
local function passOver() return State.dpsPaused or State.getAwayOn end

function M:debuffCast(id, wait)
    local lines = self.hooks.lines()
    local done = {}
    local c = self.cfg
    for _ = 1, #lines do
        -- the next candidate line
        local pick = nil
        for i, l in ipairs(lines) do
            if not done[i] and (not listed(i, id) or Timers.expired('dbo:' .. i)) then pick = i break end
        end
        if not pick then return end
        local l = lines[pick]
        if not ready(l.name) then
            if not wait then done[pick] = true
            else
                if Timers.expired('debuff:waitecho') then
                    Timers.set('debuff:waitecho', 3000)
                    Log.info('Waiting on %s to refresh before casting it', l.name)
                end
                Cast.tickDelay(7000, function() return ready(l.name) or passOver() end)
                if not ready(l.name) then done[pick] = true end
            end
        end
        if passOver() then return end
        if not done[pick] then
            done[pick] = true
            self.hooks.mezPass()
            if passOver() then return end   -- taken during the mez pass
            local sp = T.spawn(id)
            if not sp or T.str(function() return sp.Type() end) == 'Corpse' then return end
            local name = T.str(function() return sp.CleanName() end)
            local tag1, tag2 = lower(l.tag1), lower(l.tag2)
            if tag1 == 'always' then tag2 = 'always' end
            if tag1 ~= 'strip' and M.isDispel(l.name) then tag1 = 'strip' end
            local skip = false
            local f = Spell.facts(l.name)
            if id ~= (State.myTargetId or 0) and (f.hasSPA and (f.hasSPA(0) or f.hasSPA(79))) and M.groupMezzerUp() then
                Log.pm('debuffall: no %s on add %s (%d) - mezzer in group', l.name, name, id)
                skip = true
            end
            if not skip and T.num(function() return mq.TLO.Me.CurrentMana() end) < f.mana then
                Log.pm('debuffall: no %s on %s (%d) - not enough mana, retry next pass', l.name, name, id)
                skip = true
            end
            if not skip then
                if targetId() ~= id then
                    mq.cmdf('/squelch /target id %d', id)
                    mq.delay(1000, function() return targetId() == id end)
                    Buffcheck.targetBuffWait()
                end
                Buffcheck.cacheBuffs(id)
                local holdMs = 0
                if T.num(function() return sp.CachedBuffCount() end) > 0 then
                    local have = sp.CachedBuff(l.name)
                    if T.num(function() return have.ID() end) > 0 and (lower(T.str(function() return have.Caster() end)) == lower(T.myName()) or tag2 ~= 'always') then
                        holdMs = T.num(function() return have.Duration.TotalSeconds() end) * 1000
                    end
                    if holdMs == 0 then
                        if tag1 == 'strip' then
                            if not Buffcheck.cachedHas(id, '^Beneficial') or mezzed(sp) then holdMs = 7000 end
                        elseif tag2 ~= 'always' then
                            local probe = ({ slow = '^Slowed', tash = '^Tashed', malo = '^Maloed', crip = '^Crippled', snare = '^Snared' })[tag1]
                            if probe and Buffcheck.cachedHas(id, probe) then holdMs = Buffcheck.cachedSeconds(id, probe) * 1000 end
                        end
                    end
                end
                if holdMs > 0 then listAdd(pick, id) skip = true
                elseif tag1 == 'strip' and not M.dispelWorthwhile(id) then listAdd(pick, id) holdMs = 7000 skip = true end
                if not skip and (c.DPSCOn or 0) ~= 0 and l.cond ~= 'TRUE' and l.cond ~= '' and l.cond ~= 'NULL' then
                    if not Cond.ok(l.cond) then skip = true end
                end
                if not skip then
                    if T.bool(function() return mq.TLO.Me.SpellInCooldown() end) then mq.delay(1000, function() return not T.bool(function() return mq.TLO.Me.SpellInCooldown() end) end) end
                    if passOver() then return end   -- taken during the retarget / buff / cooldown waits
                    local res = Cast.cast(l.name, id, 'DebuffCast')
                    if res == 'CAST_RESIST' then Log.info('** %s on >> %s << - RESISTED', l.name, name)
                    elseif res == 'CAST_TAKEHOLD' then Log.info('** %s on >> %s << - DID NOT TAKE HOLD', l.name, name) holdMs = 180000
                    elseif res == 'CAST_IMMUNE' or res == 'CAST_RECOVER' then Log.info('** %s is IMMUNE to - %s', name, l.name) listAdd(pick, id) holdMs = 180000
                    elseif res == 'CAST_SUCCESS' then
                        Log.info('** Debuffing: ==> %s on >> %s <<', l.name, name)
                        listAdd(pick, id)
                        local kind = Spell.kind(l.name)
                        local ln = lower(l.name)
                        local cls = T.myClass()
                        if kind == 'item' then holdMs = f.durationSec * 1000
                        elseif kind == 'aa' then holdMs = T.num(function() return mq.TLO.Me.AltAbility(l.name).ReuseTime() end) * 1000
                        elseif cls == 'SHM' and ln:find('counterbias', 1, true) then holdMs = 90000
                        elseif cls == 'ENC' and ln:find('suffocation', 1, true) then holdMs = 60000
                        elseif cls == 'BST' and ln:find('feralgia', 1, true) then holdMs = 90000
                        elseif f.durationSec > 0 then holdMs = f.durationSec * 1000
                        else holdMs = (c.DPSInterval or 2) * 1000 end
                    end
                end
                if holdMs > 0 and Timers.expired('dbo:' .. pick) then Timers.set('dbo:' .. pick, math.floor(holdMs * 0.95)) end
            end
        end
    end
end

--- DoDebuffStuff: the kill target, then the adds within MeleeDistance.
function M:doDebuffStuff(firstId)
    local c = self.cfg
    if State.buffMode or State.zombieMode or (c.DebuffAllOn or 0) == 0 or passOver() then return end
    local lines = self.hooks.lines()
    if #lines == 0 then return end
    firstId = tonumber(firstId) or State.myTargetId or 0
    if firstId == 0 then return end
    if T.myClass() == 'BRD' and iAmMA() and T.aggroTargetId() > 0 then return end
    self.hooks.mobRadar()
    -- list maintenance: an expired line forgets everyone but the kill target; gone / far / dead mobs drop out
    for i in ipairs(lines) do
        if self.lists[i] then
            if Timers.expired('dbo:' .. i) then self.lists[i] = { [firstId] = true }
            else
                for id in pairs(self.lists[i]) do
                    local sp = T.spawn(id)
                    if not sp or T.num(function() return sp.Distance() end) > 200 or T.str(function() return sp.Type() end) == 'Corpse' then self.lists[i][id] = nil end
                end
            end
        end
    end
    self:debuffCast(firstId, true)
    if passOver() then return end
    local md = c.MeleeDistance or 30
    for j = 1, 13 do
        if passOver() then return end
        local xt = mq.TLO.Me.XTarget(j)
        local id = T.num(function() return xt.ID() end)
        local sp = id > 0 and id ~= firstId and T.spawn(id) or nil
        if sp and T.str(function() return xt.TargetType() end) == 'Auto Hater' and T.str(function() return sp.Type() end) ~= 'Corpse'
            and T.num(function() return sp.Distance() end) < md and T.bool(function() return sp.LineOfSight() end) then
            local name = T.str(function() return sp.CleanName() end)
            if mezzed(sp) then
                if Timers.expired('debuff:pm:' .. id) then Timers.set('debuff:pm:' .. id, 5000) Log.pm('debuffall: skipping %s (%d) - mezzed', name, id) end
            else
                local holder = self.hooks.ccHeldByOther(id)
                if holder then
                    if Timers.expired('debuff:pm:' .. id) then Timers.set('debuff:pm:' .. id, 5000) Log.pm('debuffall: skipping %s (%d) - CC held by %s', name, id, holder) end
                else
                    if T.bool(function() return mq.TLO.Me.Combat() end) and (not iAmMA() or id ~= targetId()) then mq.cmd('/attack off') mq.delay(1000, function() return not T.bool(function() return mq.TLO.Me.Combat() end) end) end
                    if passOver() then return end
                    self:debuffCast(id, c.DebuffAllOn == 2)
                end
            end
        end
    end
    local mt = State.myTargetId or 0
    if mt > 0 and targetId() ~= mt and T.spawn(mt) and T.str(function() return T.spawn(mt).Type() end) ~= 'Corpse' then
        mq.cmdf('/squelch /target id %d', mt)
        mq.delay(1000, function() return targetId() == mt end)
    end
end

function M.groupMezzerUp() return require('modules.mez').groupMezzerUp() end

function M:Init()
    local Combat = require('modules.combat')
    Combat.hooks.debuff = function(id) M:doDebuffStuff(id) end
    self.hooks.mobRadar = function() Combat:mobRadar() end
    self.hooks.ccHeldByOther = require('modules.mez').ccHeldByOther
    self.hooks.mezPass = function() if State.mezOn then require('modules.mez'):doMezStuff() end end
    self.hooks.lines = function() return require('modules.dps').debuffLines end
end

return M
