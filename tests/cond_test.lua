-- lua tests/cond_test.lua   (from lua/muleassist): core/cond, the shared condition evaluator
package.path = './?.lua;./?/init.lua;' .. package.path
local Stub = require('tests.stub_mq')
local v = { named = false, xt = 0, snared = 0, injured = 0, mana = 50 }
local mq = Stub.new({
    Target = { Named = { _ = function() return v.named end }, Snared = { ID = { _ = function() return v.snared end } } },
    Me = { XTarget = { _ = function() return v.xt end }, PctMana = { _ = function() return v.mana end } },
    Group = { Injured = { _ = function(pct) if tonumber(pct) == 80 then return v.injured end return 0 end } },
})
local Cond = require('core.cond')

-- capture the log output
local lines = {}
local realPrint = print
print = function(s) lines[#lines + 1] = tostring(s) end
local function logged(pat)
    local n = 0
    for _, l in ipairs(lines) do if l:find(pat, 1, true) then n = n + 1 end end
    return n
end

-- blank / TRUE / NULL pass
assert(Cond.ok(nil) and Cond.ok('') and Cond.ok('TRUE') and Cond.ok('NULL') and Cond.ok('  '), 'blank, TRUE, NULL pass')
assert(Cond.ok('true') and Cond.ok('null'), 'case-insensitive TRUE / NULL')
assert(not Cond.ok('FALSE'), 'FALSE fails')

-- native Lua: true and false
assert(Cond.ok('1 < 2'), 'native true')
assert(not Cond.ok('1 > 2'), 'native false')
assert(not Cond.ok('nil'), 'native nil is false')
assert(not Cond.ok('0') and Cond.ok('1'), 'numbers: 0 is false, as in the macro')

-- the real INI examples
do
    local c = 'mq.TLO.Target.Named() == true or mq.TLO.Me.XTarget() >= 3'
    v.named, v.xt = false, 1
    assert(not Cond.ok(c), 'DPSCond5 false')
    v.named = true
    assert(Cond.ok(c), 'DPSCond5 named')
    v.named, v.xt = false, 3
    assert(Cond.ok(c), 'DPSCond5 three haters')

    c = 'mq.TLO.Target.Snared.ID() == 0'
    v.snared = 0
    assert(Cond.ok(c), 'DPSCond17 not snared')
    v.snared = 55
    assert(not Cond.ok(c), 'DPSCond17 snared')

    c = 'mq.TLO.Group.Injured(80)() >= 3'
    v.injured = 2
    assert(not Cond.ok(c), 'HealsCond7 two injured')
    v.injured = 3
    assert(Cond.ok(c), 'HealsCond7 three injured')

    c = 'mq.TLO.Me.PctMana() > 80'
    v.mana = 50
    assert(not Cond.ok(c), 'BuffsCond1 low mana')
    v.mana = 90
    assert(Cond.ok(c), 'BuffsCond1 high mana')
end

-- a compile error fails and logs once over repeated calls
do
    lines = {}
    local bad = 'mq.TLO.Me.PctMana() >'
    for _ = 1, 5 do assert(not Cond.ok(bad), 'compile error fails') end
    assert(logged(bad) == 1, 'compile error logged once, got ' .. logged(bad))
end

-- a runtime error fails and logs once
do
    lines = {}
    local bad = 'mq.TLO.Me.Nope.Deeper() > 3'   -- nil > 3: a runtime error
    for _ = 1, 5 do assert(not Cond.ok(bad), 'runtime error fails') end
    assert(logged(bad) == 1, 'runtime error logged once, got ' .. logged(bad))
end

-- ${...}: expanded by mq.parse, a NULL read as 0, then the If wrapper on the expanded text
do
    local seen = {}
    local realParse = mq.parse
    local values = { ['${Me.PctMana}'] = '85', ['${Me.PctHPs}'] = '90', ['${Target.Named}'] = 'NULL',
        ['${Me.Buff[Mind Flay Recourse].ID}'] = 'NULL', ['${Target.Body.Name.Equal[Undead]}'] = 'NULL' }
    local calc = { ['85>80'] = '1', ['90<50'] = '0', ['0'] = '0', ['!0'] = '1', ['!0 && 85>40'] = '1' }
    mq.parse = function(str)
        seen[#seen + 1] = str
        local inner = str:match('^%${If%[(.*),1,0%]}$')
        if inner then
            assert(not inner:find('NULL', 1, true), 'a NULL reached the calculator: ' .. inner)
            return calc[inner] or error('unexpected calc: ' .. inner)
        end
        return (str:gsub('%${[^}]*}', function(tok) return values[tok] or tok end))
    end
    assert(Cond.ok('${Me.PctMana}>80'), 'macro condition true')
    assert(seen[1] == '${Me.PctMana}>80' and seen[2] == '${If[85>80,1,0]}', 'expanded, then the If wrapper: ' .. tostring(seen[2]))
    assert(not Cond.ok('${Me.PctHPs}<50'), 'macro condition false')
    -- NULL (no target / no such buff) is 0: no "Unparsable in Calculation: 'N'" spam
    assert(not Cond.ok('${Target.Named}'), 'a NULL condition is false')
    assert(not Cond.ok('${Target.Body.Name.Equal[Undead]}'), 'NULL .Equal with no target is false')
    assert(Cond.ok('!${Me.Buff[Mind Flay Recourse].ID} && ${Me.PctMana}>40'), '!NULL is true')
    -- a parse that throws is false, not an error
    mq.parse = function() error('boom') end
    assert(not Cond.ok('${Me.PctHPs}<50'), 'throwing parse is false')
    mq.parse = realParse
end

-- the sandbox: no os / io / load / require / dofile
do
    lines = {}
    local ran = false
    local realExecute = os.execute
    os.execute = function() ran = true return true end
    assert(not Cond.ok('os.execute("echo hi")'), 'os.execute is not reachable')
    assert(not Cond.ok('io ~= nil'), 'io is not in scope')
    assert(not Cond.ok('load ~= nil or require ~= nil or dofile ~= nil or loadstring ~= nil'), 'loaders are not in scope')
    assert(not Cond.ok('_G ~= nil'), '_G is not in scope')
    assert(not ran, 'os.execute never ran')
    os.execute = realExecute
end

-- a statement is not an expression
assert(not Cond.ok('x = 1'), 'assignment does not compile')

-- every condition site goes through Cond.ok: no module builds its own ${If[...]} parse
do
    local f = assert(io.open('init.lua', 'r'))
    local init = f:read('a')
    f:close()
    local n = 0
    for name in init:gmatch("require%('modules%.([%w_]+)'%)") do
        local mf = assert(io.open('modules/' .. name .. '.lua', 'r'))
        local src = mf:read('a')
        mf:close()
        n = n + 1
        assert(not src:find("'${If[' ..", 1, true), 'modules/' .. name .. '.lua still evaluates a condition with its own ${If[ parse')
    end
    assert(n > 10, 'found the modules in init.lua')
end

print = realPrint
print('cond_test ok')
