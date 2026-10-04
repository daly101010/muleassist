-- luajit tests/cures_test.lua   (from lua/muleassist)
package.path = './?.lua;./?/init.lua;' .. package.path
local Stub = require('tests.stub_mq')
Stub.new({})
local Cures = require('modules.cures')
local State = require('core.state')

-- the XTarHeal slots the cure watch reads
do
    State.xtarHealLive = '1|3'
    local s = Cures:xtarSlots()
    assert(#s == 2 and s[1] == 1 and s[2] == 3, 'live slots')
    State.xtarHealLive = '0'
    assert(#Cures:xtarSlots() == 0, 'off')
    State.xtarHealLive = nil
    assert(#Cures:xtarSlots() == 0, 'nothing configured')
end

-- parseLine
do
    local l = Cures.parseLine('Cure Poison|poison')
    assert(l.name == 'Cure Poison' and l.types.poison and not l.any, 'typed line')
    local l2 = Cures.parseLine('Blood of Nadox|disease,poison')
    assert(l2.types.disease and l2.types.poison, 'comma types')
    local l3 = Cures.parseLine('Radiant Cure|curse|disease')
    assert(l3.types.curse and l3.types.disease and not l3.any, 'pipe types')
    local l4 = Cures.parseLine('Radiant Cure')
    assert(l4.any, 'no types = any')
    assert(Cures.parseLine('NULL') == nil, 'NULL')
end

-- parseDebuffs
do
    local d = Cures.parseDebuffs('2|1234|0|555|0')
    assert(d.any and d.poison and not d.disease and d.curse and not d.corruption, 'counters')
    local c = Cures.parseDebuffs('0')
    assert(not c.any and not c.poison, 'clean')
    assert(not Cures.parseDebuffs(nil).any, 'nil line')
end

-- decide
do
    local poisonLine = Cures.parseLine('Cure Poison|poison')
    local anyLine = Cures.parseLine('Radiant Cure')
    local poisoned = Cures.parseDebuffs('1|1234|0|0|0')
    local diseased = Cures.parseDebuffs('1|0|1234|0|0')
    local go, ty = Cures.decide(poisonLine, poisoned, nil)
    assert(go and ty == 'poison', 'poison line cures poison')
    assert(not Cures.decide(poisonLine, diseased, nil), 'poison line does not cure disease')
    assert(Cures.decide(anyLine, diseased, nil), 'untyped line cures any')
    -- the counter-SPA gate: a line whose spell cannot remove the type is skipped
    assert(not Cures.decide(poisonLine, poisoned, function(t) return false end), 'spell lacks the SPA')
    assert(Cures.decide(poisonLine, poisoned, function(t) return t == 'poison' end), 'spell has the SPA')
    assert(not Cures.decide(anyLine, Cures.parseDebuffs('0'), nil), 'clean target: nothing')
    -- priority: poison before disease before curse before corruption
    local both = Cures.parseDebuffs('2|1|1|0|0')
    local _, first = Cures.decide(anyLine, both, nil)
    assert(first == 'poison', 'order')
end

print('cures_test OK')
