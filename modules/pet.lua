-- modules/pet.lua: the pet (DoPetStuff, PetStateCheck, CombatPet, BreakMez, PetAttackSafe, ProtectWatch's pet
-- part, the pet events) with the same [Pet] keys as the macro. The summon, the focus-item swap and the
-- suspend pair are sequenced across ticks instead of a blocking loop.
local mq = require('mq')
local T = require('core.tlo')
local Config = require('core.config')
local Timers = require('core.timers')
local Cast = require('core.cast')
local Comms = require('core.comms')
local Log = require('core.log')
local State = require('core.state')

local M = { name = 'pet' }

M.Settings = {
    scalars = {
        { section = 'Pet', key = 'PetOn', type = 'int', default = 0 },
        { section = 'Pet', key = 'PetSpell', type = 'string', default = 'YourPetSpell' },
        { section = 'Pet', key = 'PetCombatOn', type = 'int', default = 1 },
        { section = 'Pet', key = 'PetAssistAt', type = 'int', default = 95 },
        { section = 'Pet', key = 'PetBreakMezSpell', type = 'string', default = 'NULL' },
        { section = 'Pet', key = 'PetRampPullWait', type = 'int', default = 0 },
        { section = 'Pet', key = 'PetSuspend', type = 'int', default = 0 },
        { section = 'Pet', key = 'MoveWhenHit', type = 'int', default = 0 },
        { section = 'Pet', key = 'PetHoldOn', type = 'int', default = 1 },
        { section = 'Pet', key = 'PetForceHealOnMed', type = 'int', default = 0 },
        { section = 'Pet', key = 'PetBehind', type = 'string', default = 'TRUE', rank = false },
        { section = 'General', key = 'CampRadius', type = 'int', default = 30 },
    },
}
M.cfg = {}
M.petHold = ''            -- 'ghold' | 'hold' | '' (no Pet Discipline AA)
M.tauntOn = false
M.sus = { active = 0, suspended = 0, total = 0 }
M.focusSwapped, M.focusOffhand = nil, nil
M.usedReloc = false
M.focusSlot = nil

local PET_CLASSES = { CLR = true, DRU = true, SHM = true, BST = true, ENC = true, MAG = true, NEC = true, SHD = true }
local FOCUS_CLASSES = { BST = true, MAG = true, NEC = true }
local function lower(s) return tostring(s or ''):lower() end
local function role() return lower(State.role) end
local function petTankRole(r) r = r or role() return r == 'pettank' or r == 'pullerpettank' or r == 'hunterpettank' end
local function petId() return T.num(function() return mq.TLO.Me.Pet.ID() end) end
local function petCombat() return T.bool(function() return mq.TLO.Me.Pet.Combat() end) end
local function petDistToCamp()
    local x, y = T.num(function() return mq.TLO.Me.Pet.X() end), T.num(function() return mq.TLO.Me.Pet.Y() end)
    return math.sqrt((x - State.campX) ^ 2 + (y - State.campY) ^ 2)
end
local function myDistToCamp()
    local x, y = T.num(function() return mq.TLO.Me.X() end), T.num(function() return mq.TLO.Me.Y() end)
    return math.sqrt((x - State.campX) ^ 2 + (y - State.campY) ^ 2)
end

function M:LoadSettings()
    local cls = T.myClass()
    if PET_CLASSES[cls] then
        self.cfg = Config.load(self.Settings)
        if FOCUS_CLASSES[cls] then self.cfg.PetFocus = Config.scalar({ section = 'Pet', key = 'PetFocus', type = 'string', default = 'NULL', rank = false }) else self.cfg.PetFocus = 'NULL' end
    else
        self.cfg = { PetOn = 0, PetSpell = 'NULL', PetCombatOn = 1, PetAssistAt = 95, PetBreakMezSpell = 'NULL', PetHoldOn = 1, PetFocus = 'NULL', PetBehind = 'TRUE',
            CampRadius = Config.scalar({ section = 'General', key = 'CampRadius', type = 'int', default = 30 }) }
    end
    State.petOn = (self.cfg.PetOn or 0) ~= 0
    self.petBehind = lower(self.cfg.PetBehind) ~= 'false' and self.cfg.PetBehind ~= '0'
    local rank = T.num(function() return mq.TLO.Me.AltAbility('Pet Discipline').Rank() end)
    if rank >= 1 then
        if (cls == 'BST' or cls == 'SHM' or cls == 'NEC' or cls == 'MAG' or cls == 'SHD') or rank >= 4 then self.petHold = 'ghold' else self.petHold = 'hold' end
        if petId() > 0 then mq.cmdf('/pet %s on', self.petHold) end
    else
        self.petHold = ''
    end
    if petTankRole() then State.petAttackRange = 115 end
end

function M:Init()
    mq.event('ma_pet_taunt', '#*#Taunting attackers as normal, Master.#*#', function() M.tauntOn = true end)
    mq.event('ma_pet_sus1', "#*# tells you, 'By your command, master.#*#", function() M.sus = { active = 0, suspended = 1, total = 1 } end)
    mq.event('ma_pet_sus2', '#*#You cannot have more than one pet at a time.#*#', function() M.sus = { active = 1, suspended = 1, total = 2 } end)
    mq.event('ma_pet_sus3', "#*# tells you, 'I live again...'#*#", function() M.sus = { active = 1, suspended = 0, total = 1 } end)
end
function M:Shutdown()
    for _, e in ipairs({ 'ma_pet_taunt', 'ma_pet_sus1', 'ma_pet_sus2', 'ma_pet_sus3' }) do pcall(mq.unevent, e) end
end

-- ------------------------------------------------------------- protection
--- IsProtectedMob: on the MobsToProtect list (alert list 5) unless it is the mark.
function M.isProtected(id)
    id = tonumber(id) or 0
    if id == 0 or not T.spawn(id) then return false end
    if State.markAssistOn and (State.markId or 0) == id then return false end
    if T.num(function() return mq.TLO.Spawn('id ' .. id .. ' alert 5').ID() end) > 0 then return true end
    local name = lower(T.str(function() return T.spawn(id).CleanName() end))
    for _, n in ipairs(State.mobsToProtect or {}) do
        if name ~= '' and name:find(lower(n), 1, true) then return true end
    end
    return false
end

--- PetAttackSafe: send the pet unless the mob is protected (then call it off it).
function M.attackSafe(id)
    id = tonumber(id) or 0
    if id == 0 or petId() == 0 then return false end
    if M.isProtected(id) then
        if T.num(function() return mq.TLO.Me.Pet.Target.ID() end) == id then mq.cmd('/pet back off') end
        return false
    end
    mq.cmdf('/pet attack %d', id)
    return true
end

function M.backOff()
    if petId() > 0 then
        Timers.clear('pet:attack')
        mq.cmd('/pet back off')
    end
end

--- CombatReset's pet part: hold on, back, and call it off a mob it is still on.
function M.onCombatReset()
    if petId() == 0 then return end
    if M.petHold ~= '' then mq.cmdf('/pet %s on', M.petHold) end
    mq.cmd('/pet back')
    M.usedReloc = false
    if T.num(function() return mq.TLO.Me.Pet.TargetOfTarget.ID() end) > 0 then
        Timers.clear('pet:attack')
        mq.cmd('/pet back off')
        if (M.cfg.PetHoldOn or 1) ~= 0 and M.petHold ~= '' then mq.cmdf('/pet %s on', M.petHold) end
    end
end

-- ------------------------------------------------------------- the fight (CombatPet)
local function mezzed(id)
    local sp = T.spawn(id)
    return sp ~= nil and T.num(function() return sp.CachedBuff('^Mezzed').Duration() end) > 0
end

--- Reposition the pet behind the mob with the pet relocation AA (3816), once per fight.
local function petBehind(targetId)
    if M.usedReloc or T.num(function() return mq.TLO.Me.Casting.ID() end) > 0 then return end
    if not T.bool(function() return mq.TLO.Me.AltAbilityReady(3816)() end) then return end
    local sp = T.spawn(targetId)
    if not sp then return end
    local mobClock = T.num(function() return sp.Heading.Clock() end)
    local petClock = T.num(function() return mq.TLO.Me.Pet.Heading.Clock() end)
    if petClock >= mobClock - 3 and petClock <= mobClock + 3 then return end
    local myClock = T.num(function() return mq.TLO.Me.Heading.Clock() end)
    if petClock <= myClock - 3 or petClock >= myClock + 3 then mq.cmdf('/squelch /face away id %d', targetId) else mq.cmdf('/squelch /face id %d', targetId) end
    mq.delay(1000)
    mq.cmd('/alt activate 3816')
    mq.delay(1000, function() return T.num(function() return mq.TLO.Me.Casting.ID() end) > 0 end)
    mq.delay(1000, function() return T.num(function() return mq.TLO.Me.Casting.ID() end) == 0 end)
    Log.info('Repositioning pet behind mob ')
    M.usedReloc = true
end

--- Break the mez on the kill target so the pet tank can take it (BreakMez).
function M:breakMez(targetId)
    local spell = self.cfg.PetBreakMezSpell
    if not spell or spell == '' or lower(spell) == 'null' then return end
    Log.info('ATTEMPTING TO BREAK MEZ ON: (%s) ID:(%d)', T.str(function() return T.spawn(targetId).CleanName() end), targetId)
    for try = 1, 5 do
        Cast.cast(spell, targetId, 'BreakMez')
        if not mezzed(targetId) then
            Timers.clear('pet:attack')
            Log.info('+ Mez broken !')
            if petId() > 0 and not petCombat() then M.attackSafe(targetId) end
            return
        end
    end
    Log.info("Couldn't break the mez after 5 tries - giving up this pass.")
end

--- CombatPet: send the pet in on the kill target (pet tanks first, the pet-behind move, the 3 s re-send).
function M:combatPet(targetId)
    targetId = tonumber(targetId) or State.myTargetId or 0
    if targetId == 0 or petId() == 0 then return end
    if Timers.running('pet:attack') or State.dpsPaused then return end
    local r = role()
    if petCombat() then return end
    -- a pet tank sends the pet in even on a mezzed target (the macro's first attack); the mez test below
    -- then decides between the positioned attack and BreakMez. Either way the 3 s re-send timer is armed.
    local sentIn = false
    if petTankRole(r) then
        M.attackSafe(targetId)
        mq.cmd('/pet swarm')
        sentIn = true
    end
    if not mezzed(targetId) then
        if r == 'pettank' or r == 'pullerpettank' then
            local stance = T.str(function() return mq.TLO.Me.Pet.Stance() end):upper()
            local radius = self.cfg.CampRadius or 30
            if (stance ~= 'FOLLOW' and petDistToCamp() > radius) or myDistToCamp() > radius then mq.cmd('/pet follow') end
        end
        if petTankRole(r) or self.petBehind then petBehind(targetId) end
        if not sentIn then
            M.attackSafe(targetId)
            mq.cmd('/pet swarm')
        end
        Timers.set('pet:attack', 3000)
    elseif (r == 'pettank' or r == 'pullerpettank') then
        Timers.set('pet:attack', 3000)
        self:breakMez(targetId)
    end
end

--- Should the pet be sent on this target now (the PetAssistAt rule the fight loop applies)?
function M:wantsAttack(targetId)
    if (self.cfg.PetCombatOn or 1) == 0 then return false end
    if not (State.petOn or petId() > 0) then return false end
    local sp = T.spawn(targetId)
    if not sp then return false end
    return T.num(function() return sp.PctHPs() end) <= (self.cfg.PetAssistAt or 95)
end

--- ProtectWatch's pet part (1 s): call the pet off a protected mob.
function M:protectTick()
    if not Timers.expired('pet:protect') then return end
    Timers.set('pet:protect', 1000)
    if petId() > 0 and petCombat() then
        local tid = T.num(function() return mq.TLO.Me.Pet.Target.ID() end)
        if tid > 0 and M.isProtected(tid) then
            Log.pm('protect: pet was on %s - calling it off', T.str(function() return mq.TLO.Me.Pet.Target.CleanName() end))
            mq.cmd('/pet back off')
        end
    end
end

-- ------------------------------------------------------------- the summon (DoPetStuff)
--- PetStateCheck: Companion's Suspension (suspend or restore, the game decides).
function M:stateCheck()
    if T.bool(function() return mq.TLO.Me.Hovering() end) then return end
    if T.num(function() return mq.TLO.Me.AltAbility("Companion's Suspension").ID() end) == 0 then
        Log.warn('You do not have the "Companion\'s Suspension" AA, PetSuspend being turned off.')
        self.cfg.PetSuspend = 0
        return
    end
    local ok = Cast.tickDelay(10000, function() return T.bool(function() return mq.TLO.Me.AltAbilityReady("Companion's Suspension")() end) end)
    if T.bool(function() return mq.TLO.Me.AltAbilityReady("Companion's Suspension")() end) then
        Cast.cast("Companion's Suspension", T.myId(), 'PetStateCheck', { kind = 'aa', skipOhShit = true })
        mq.doevents()
    else
        Log.info('Suspend Minion AA still not ready - skipping the suspend this pass.')
    end
    if petId() > 0 then self.sus.active = 1 end
end

local function focusParts(cfg)
    local f = tostring(cfg.PetFocus or 'NULL')
    if f == '' or f:upper() == 'NULL' or not f:find('|', 1, true) then return nil end
    local item, slot = f:match('^(.-)|(.+)$')
    return item, slot
end

--- Swap the pet focus item (or bandolier set) in before the summon.
function M:focusIn()
    local item, slot = focusParts(self.cfg)
    if not item or T.num(function() return mq.TLO.FindItemCount('=' .. item)() end) == 0 then return end
    if T.num(function() return mq.TLO.Cursor.ID() end) > 0 then return end
    if slot:lower():find('^band:') then
        local set = slot:sub(6)
        local current = nil
        for i = 1, 20 do
            local b = mq.TLO.Me.Bandolier(i)
            if T.bool(function() return b.Active() end) then current = T.str(function() return b.Name() end) end
        end
        -- a retry after a failed summon must not record the summon set as the original
        if self.focusSwapped == nil then self.focusSwapped = current or '' self.focusSlot = slot end
        mq.cmdf('/invoke ${Me.Bandolier[%s].Activate}', set)
        mq.delay(1000)
        return
    end
    local current = T.str(function() return mq.TLO.InvSlot(slot).Item.Name() end)
    if current == item then return end
    if slot:lower() == 'mainhand' and T.str(function() return mq.TLO.FindItem('=' .. item).Type() end):lower():find('2h') and T.num(function() return mq.TLO.InvSlot(14).ID() end) > 0 then
        self.focusOffhand = T.str(function() return mq.TLO.InvSlot(14).Item.Name() end)
        mq.cmd('/unequip 14')
        mq.delay(2000)
    end
    mq.cmdf('/exchange "%s" %s', item, slot)
    if self.focusSwapped == nil then
        self.focusSwapped = current
        self.focusSlot = slot
        self.focusWasEmpty = current == ''   -- the slot was empty: take the focus off again afterwards
    end
    mq.delay(1000)
end

--- Swap the original back once the pet is up (also on a later pass after an interrupted summon).
function M:focusOut()
    if not self.focusSwapped or T.num(function() return mq.TLO.Cursor.ID() end) > 0 then return end
    local slot = self.focusSlot or ''
    if slot:lower():find('^band:') then
        if self.focusSwapped ~= '' then mq.cmdf('/invoke ${Me.Bandolier[%s].Activate}', self.focusSwapped) end
    else
        if self.focusSwapped ~= '' and T.num(function() return mq.TLO.FindItem('=' .. self.focusSwapped).ID() end) > 0 then
            mq.cmdf('/exchange "%s" %s', self.focusSwapped, slot)
            mq.delay(300)
        elseif self.focusWasEmpty and T.str(function() return mq.TLO.InvSlot(slot).Item.Name() end) ~= '' then
            mq.cmdf('/unequip %s', slot)
            mq.delay(300)
        end
        if self.focusOffhand and self.focusOffhand ~= '' and T.num(function() return mq.TLO.FindItem('=' .. self.focusOffhand).ID() end) > 0 then
            mq.cmdf('/exchange "%s" 14', self.focusOffhand)
            mq.delay(200)
        end
    end
    self.focusSwapped, self.focusOffhand, self.focusSlot, self.focusWasEmpty = nil, nil, nil, nil
end

--- The stances after a summon: guard / follow by camp, hold, focus, taunt.
function M:stances()
    local r = role()
    local c = self.cfg
    if petId() == 0 then return end
    if r == 'puller' or r == 'pullertank' or r == 'pettank' or r == 'pullerpettank' then
        if T.num(function() return mq.TLO.Me.Pet.Distance() end) <= (c.CampRadius or 30) then mq.cmd('/pet guard') else mq.cmd('/pet follow') end
    end
    if (c.PetHoldOn or 1) ~= 0 and self.petHold ~= '' then mq.cmdf('/pet %s on', self.petHold) end
    if T.num(function() return mq.TLO.Me.AltAbility('Pet Discipline').Rank() end) > 5 then mq.cmd('/pet focus on') end
    if not self.tauntOn and (r == 'pettank' or r == 'pullerpettank') then mq.cmd('/pet taunt on') end
end

function M:doPetStuff()
    local c = self.cfg
    if State.buffMode or State.zombieMode then return end
    if T.aggroTargetId() > 0 or T.bool(function() return mq.TLO.Me.Invis() end) or T.bool(function() return mq.TLO.Me.Hovering() end) then return end
    local spell = c.PetSpell or 'NULL'
    local spellOk = spell ~= '' and spell:upper() ~= 'NULL' and spell ~= 'YourPetSpell'
    if spellOk and State.petOn then
        local reagent = T.num(function() return mq.TLO.Spell(spell).ReagentID(1)() end)
        if reagent > 0 and T.num(function() return mq.TLO.FindItemCount(reagent)() end) < T.num(function() return mq.TLO.Spell(spell).ReagentCount(1)() end) then
            Log.warn("%s requires a Reagent to cast it's ID is %d and you don't have any.", spell, reagent)
            Log.warn('You are missing components. Turning off %s.', spell)
            State.petOn = false
            self.cfg.PetOn = 0
            return
        end
    end
    local familiar = T.myName() .. '`s familiar'
    if T.str(function() return mq.TLO.Me.Pet.CleanName() end) == familiar then mq.cmd('/pet get lost') return end
    if petId() == 0 then
        self.sus.active = 0
        if not spellOk or T.num(function() return mq.TLO.Me.Casting.ID() end) > 0 then return end
        if T.num(function() return mq.TLO.Spell(spell).Mana() end) > T.num(function() return mq.TLO.Me.CurrentMana() end) then return end
        if not Timers.expired('pet:summon') then return end
        Timers.set('pet:summon', 3000)
        Log.info('I have no pet. %ss live longer when we have pets.', T.str(function() return mq.TLO.Me.Class.Name() end))
        self:focusIn()
        -- a suspended pet waiting: restore it instead of summoning over it
        if (c.PetSuspend or 0) ~= 0 and self.sus.total == 1 and self.sus.active == 0 and self.sus.suspended == 1 then
            Log.info('I have a suspended pet, summoning it now!')
            self:stateCheck()
            return
        end
        local res = Cast.cast(spell, T.myId(), 'DoPetStuff', { skipOhShit = true })
        if res == 'CAST_COMPONENTS' then Log.error('You are missing components to make this pet.') return end
        mq.delay(1000, function() return petId() > 0 end)
        if petId() > 0 then
            Log.info('My pet is now: %s from %s', T.str(function() return mq.TLO.Me.Pet.CleanName() end), spell)
            self.sus.active = 1
            if (c.PetSuspend or 0) ~= 0 and self.sus.total < 2 and self.sus.suspended == 0 then
                -- build the pair: suspend this one, the next pass summons the active one
                self:stateCheck()
            end
            self:stances()
        end
        return
    end
    self:focusOut()
    -- the owner left camp with the pet guarding inside it
    local r = role()
    if (r == 'pettank' or r == 'hunterpettank') and myDistToCamp() > (c.CampRadius or 30) and petDistToCamp() <= (c.CampRadius or 30)
        and T.str(function() return mq.TLO.Me.Pet.Stance() end):upper() == 'GUARD' then
        mq.cmd('/pet follow')
    end
end

-- ------------------------------------------------------------- the tick
function M:GiveTime(ctx)
    self:protectTick()
    local familiar = T.myName() .. '`s familiar'
    local petUp = petId() > 0 and T.str(function() return mq.TLO.Me.Pet.CleanName() end) ~= familiar
    if not (State.petOn or petUp) then return end
    if not Timers.expired('pet:tick') then return end
    Timers.set('pet:tick', 1000)
    self:doPetStuff()
end

function M:OnCombatEnd()
    M.usedReloc = false
end

M.Binds = {
    ['/peton'] = function(self, arg)
        local v = tonumber(arg)
        if arg == 'on' then v = 1 elseif arg == 'off' then v = 0 end
        if v == nil then v = (self.cfg.PetOn or 0) == 0 and 1 or 0 end
        self.cfg.PetOn = v
        State.petOn = v ~= 0
        Log.info('PetOn %d', v)
    end,
    ['/pethold'] = function(self, arg)
        local v = tonumber(arg)
        if arg == 'on' then v = 1 elseif arg == 'off' then v = 0 end
        if v == nil then v = (self.cfg.PetHoldOn or 1) == 0 and 1 or 0 end
        self.cfg.PetHoldOn = v
        Log.info('PetHoldOn %d', v)
    end,
    ['/movewhenhit'] = function(self, arg)
        local v = tonumber(arg)
        if v == nil then v = (self.cfg.MoveWhenHit or 0) == 0 and 1 or 0 end
        self.cfg.MoveWhenHit = v
        Log.info('MoveWhenHit %d', v)
    end,
}

return M
