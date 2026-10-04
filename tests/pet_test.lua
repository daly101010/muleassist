-- luajit tests/pet_test.lua   (from lua/muleassist)
package.path = './?.lua;./?/init.lua;' .. package.path
local Stub = require('tests.stub_mq')
local mq = Stub.new({})
local World = require('tests.world')
local Ini = require('core.ini')
local Config = require('core.config')
local Timers = require('core.timers')
local State = require('core.state')
local Spell = require('core.spell')
local T = require('core.tlo')
local Pet = require('modules.pet')

local data = { ['MuleAssist_srv_Bob.ini'] = {
    General = { CampRadius = '30' },
    Pet = { PetOn = '1', PetSpell = 'Elementalkin: Fire', PetCombatOn = '1', PetAssistAt = '95', PetHoldOn = '1', PetBehind = 'FALSE' },
} }
Ini.use(Ini.tableBackend(data))
Config.iniFile = 'MuleAssist_srv_Bob.ini'
Config.condFile = Config.iniFile
Config.rankFn = function(n) return n end
Config.zoneId = function() return 100 end
local now = 0
Timers.setClock(function() return now end)
local function tick(ms) now = now + (ms or 1100) mq.now = now T.xtargetReset() end
local w = World.build(mq, {
    me = { class = 'MAG', petId = 0, curMana = 1000 },
    spells = { ['Elementalkin: Fire'] = { castMs = 5000, mana = 300, dur = 0, pet = 7 } },
})
w.spawns[1] = { id = 1, name = 'Bob', type = 'PC', dist = 0 }
w.spawns[9] = { id = 9, name = 'a rat', type = 'NPC', dist = 20, hp = 90 }
w.spawns[21] = { id = 21, name = 'a guard', type = 'NPC', dist = 120, protected = true }
Spell.clearCache()
State.role = 'assist'
State.campX, State.campY, State.campZone = 0, 0, 100
Pet:Init()
Pet:LoadSettings()
assert(State.petOn and Pet.cfg.PetSpell == 'Elementalkin: Fire' and Pet.petHold == '', 'settings: no Pet Discipline AA -> no hold word')

-- the summon: no pet -> cast the pet spell once, then stances
do
    mq.cmds = {}
    Pet:GiveTime({})
    assert(World.count(mq, '^/cast "Elementalkin: Fire"') == 1, 'summoned: ' .. table.concat(mq.cmds, ';'))
    assert(T.num(function() return mq.TLO.Me.Pet.ID() end) == 7, 'the pet is up')
    assert(Pet.sus.active == 1, 'one active pet')
    tick()
    mq.cmds = {}
    Pet:GiveTime({})
    assert(World.count(mq, '^/cast') == 0, 'no second summon: ' .. table.concat(mq.cmds, ';'))
end

-- protection: the guard is on the protect list
do
    assert(Pet.isProtected(21) and not Pet.isProtected(9), 'protect list')
    mq.cmds = {}
    assert(not Pet.attackSafe(21) and World.count(mq, '^/pet attack') == 0, 'never on a protected mob')
    assert(Pet.attackSafe(9) and World.count(mq, '^/pet attack 9') == 1, 'sent on the rat')
    assert(T.bool(function() return mq.TLO.Me.Pet.Combat() end), 'the fixture puts the pet in combat')
    mq.cmd('/pet back off')
    State.markAssistOn, State.markId = true, 21
    assert(not Pet.isProtected(21), 'the mark is never protected')
    State.markAssistOn, State.markId = false, 0
end

-- wantsAttack: the PetAssistAt gate
do
    assert(Pet:wantsAttack(9), 'rat at 90% under PetAssistAt 95')
    w.spawns[9].hp = 100
    assert(not Pet:wantsAttack(9), 'full health waits')
    w.spawns[9].hp = 90
    Pet.cfg.PetCombatOn = 0
    assert(not Pet:wantsAttack(9), 'PetCombatOn 0')
    Pet.cfg.PetCombatOn = 1
end

-- combatPet: one send per 3 s, swarm, nothing while the pet already fights
do
    mq.cmds = {}
    Pet:combatPet(9)
    assert(World.count(mq, '^/pet attack 9') == 1 and World.count(mq, '^/pet swarm') == 1, 'attack + swarm: ' .. table.concat(mq.cmds, ';'))
    mq.cmds = {}
    Pet:combatPet(9)
    assert(#mq.cmds == 0, 'already fighting: nothing')
    mq.cmd('/pet back off')
    mq.cmds = {}
    Pet:combatPet(9)
    assert(World.count(mq, '^/pet attack 9') == 0, 'the 3 s re-send timer holds: ' .. table.concat(mq.cmds, ';'))
    tick(3100)
    mq.cmds = {}
    Pet:combatPet(9)
    assert(World.count(mq, '^/pet attack 9') == 1, 're-sent after 3 s')
    State.dpsPaused = true
    tick(3100)
    mq.cmd('/pet back off')
    mq.cmds = {}
    Pet:combatPet(9)
    assert(#mq.cmds == 0, 'backoff holds the pet')
    State.dpsPaused = false
end

-- a pet tank: the pet goes in even on a mezzed mob, then BreakMez casts and the 3 s timer is armed
do
    State.role = 'pettank'
    Pet.cfg.PetBreakMezSpell = 'Pet Nuke'
    w.spells['Pet Nuke'] = { st = 'Detrimental', tt = 'Single', range = 200, castMs = 1000, mana = 10 }
    w.gems = { [1] = 'Pet Nuke' }
    w.spawns[9].mezzed = true
    w.spawns[9].buffs = { ['^Mezzed'] = 20 }
    tick(3100)
    mq.cmd('/pet back off')
    Timers.clear('pet:attack')
    mq.cmds = {}
    Pet:combatPet(9)
    assert(World.count(mq, '^/pet attack 9') == 1 and World.count(mq, '^/pet swarm') == 1, 'the pet tank sends the pet in: ' .. table.concat(mq.cmds, ';'))
    assert(World.count(mq, '^/cast "Pet Nuke"') >= 1, 'break mez cast: ' .. table.concat(mq.cmds, ';'))
    assert(Timers.running('pet:attack'), 'the 3 s re-send timer is armed for a pet tank')
    mq.cmds = {}
    Pet:combatPet(9)
    assert(World.count(mq, '^/pet attack') == 0, 'no spam while the timer runs')
    w.spawns[9].mezzed = nil
    w.spawns[9].buffs = nil
    Pet.cfg.PetBreakMezSpell = 'NULL'
    State.role = 'assist'
    tick(3100)
end

-- the reset calls the pet back off a mob it is still on
do
    mq.cmd('/pet attack 9')
    World.set(mq, 'Me.Pet.TargetOfTarget.ID', 9)
    mq.cmds = {}
    Pet.onCombatReset()
    assert(World.count(mq, '^/pet back off') == 1 and World.count(mq, '^/pet back$') == 1, 'called back: ' .. table.concat(mq.cmds, ';'))
    World.set(mq, 'Me.Pet.TargetOfTarget.ID', 0)
end

-- the protect watch: the pet wandered onto the guard
do
    w.spawns[21].dist = 10
    mq.cmd('/pet attack 21')
    tick()
    mq.cmds = {}
    Pet:GiveTime({})
    assert(World.count(mq, '^/pet back off') == 1, 'protect watch calls it off: ' .. table.concat(mq.cmds, ';'))
end

-- a pet tank role fixes the attack range; /peton toggles
do
    State.role = 'pettank'
    Pet:LoadSettings()
    assert(State.petAttackRange == 115, 'pet tank range')
    State.role = 'assist'
    Pet.Binds['/peton'](Pet, 'off')
    assert(not State.petOn and Pet.cfg.PetOn == 0, '/peton off')
    Pet.Binds['/peton'](Pet, '')
    assert(State.petOn, '/peton toggles back')
end

-- the suspend events
do
    mq.events['ma_pet_sus1'].fn("Pet tells you, 'By your command, master.'")
    assert(Pet.sus.suspended == 1 and Pet.sus.active == 0, 'suspended')
    mq.events['ma_pet_sus3'].fn("Pet tells you, 'I live again...'")
    assert(Pet.sus.active == 1 and Pet.sus.suspended == 0, 'restored')
end

-- the focus swap: a retried summon keeps the first original; an empty original slot is emptied again
do
    local slotItem = { Charm = 'Old Charm', Ear = '' }
    local bandActive = 'Combat'
    local function setFn(path, fn)
        local node = mq.TLO
        for part in path:gmatch('[^.]+') do node = rawget(node, '__children')[part] end
        rawset(node, '__value', fn)
    end
    setFn('FindItemCount', function() return 1 end)
    setFn('InvSlot', function(slot) return mq.build({ ID = 1, Item = { Name = slotItem[slot] or '' } }) end)
    setFn('FindItem', function(n) return mq.build({ ID = 1, Type = 'Charm', Name = n }) end)
    setFn('Me.Bandolier', function(i)
        local names = { 'Combat', 'Summon' }
        local nm = names[tonumber(i) or 0]
        return mq.build({ Active = nm ~= nil and nm == bandActive, Name = nm or '' })
    end)
    -- a bandolier focus: the first focusIn saves Combat; a retry with Summon active must not overwrite it
    Pet.cfg.PetFocus = 'Focus Item|band:Summon'
    Pet:focusIn()
    assert(Pet.focusSwapped == 'Combat', 'the original set: ' .. tostring(Pet.focusSwapped))
    bandActive = 'Summon'
    Pet:focusIn()
    assert(Pet.focusSwapped == 'Combat', 'a retry keeps the original: ' .. tostring(Pet.focusSwapped))
    mq.cmds = {}
    Pet:focusOut()
    assert(World.count(mq, 'Bandolier%[Combat%]%.Activate') == 1 and Pet.focusSwapped == nil, 'Combat restored: ' .. table.concat(mq.cmds, ';'))
    -- an item focus into an empty slot comes off again
    Pet.cfg.PetFocus = 'Focus Earring|Ear'
    mq.cmds = {}
    Pet:focusIn()
    assert(World.count(mq, '^/exchange "Focus Earring" Ear') == 1 and Pet.focusWasEmpty, 'equipped into the empty slot')
    slotItem.Ear = 'Focus Earring'
    mq.cmds = {}
    Pet:focusOut()
    assert(World.count(mq, '^/unequip Ear') == 1 and Pet.focusSwapped == nil, 'taken off again: ' .. table.concat(mq.cmds, ';'))
    Pet.cfg.PetFocus = 'NULL'
end

print('pet_test OK')
