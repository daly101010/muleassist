-- luajit tests/buffrules_test.lua   (from lua/muleassist)
package.path = './?.lua;./?/init.lua;' .. package.path
local R = require('core.buffrules')

-- willStick level floors (WillItStick 7809-7921)
do
    assert(R.willStick(50, 1) and R.willStick(10, 1), '<= 50 lands on everyone')
    assert(not R.willStick(51, 39) and R.willStick(51, 40), '51 -> 40')
    assert(not R.willStick(53, 40) and R.willStick(52, 41), '52-53 -> 41')
    assert(R.willStick(65, 47) and not R.willStick(64, 46), '64-65 -> 47')
    assert(R.willStick(66, 61) and not R.willStick(95, 60), '66-95 -> 61')
    assert(R.willStick(96, 66) and not R.willStick(100, 65), '96-100 -> 66')
    assert(R.willStick(105, 71) and not R.willStick(101, 70), '101-105 -> 71')
    assert(R.willStick(110, 76) and not R.willStick(106, 75), '106-110 -> 76')
    assert(R.willStick(115, 81) and not R.willStick(111, 80), '111-115 -> 81')
    assert(R.willStick(120, 1), '> 115 no check')
end

-- class tags
do
    assert(R.inList('CLR,DRU, shm', 'SHM') and not R.inList('CLR,DRU', 'WAR') and not R.inList('', 'WAR'), 'inList')
    assert(not R.classTagSkip('caster', '', '', '', 'CLR'), 'caster tag keeps a caster')
    assert(R.classTagSkip('caster', '', '', '', 'WAR'), 'caster tag skips a warrior')
    assert(not R.classTagSkip('caster', 'WAR', '', '', 'WAR'), 'listed class overrides the archetype')
    assert(R.classTagSkip('Melee', '', '', '', 'WIZ') and not R.classTagSkip('melee', '', '', '', 'ROG'), 'Melee tag')
    assert(R.classTagSkip('class', 'CLR,DRU', '', '', 'WAR') and not R.classTagSkip('class', 'CLR,DRU', '', '', 'DRU'), 'class list')
    assert(not R.classTagSkip('caster', 'class', 'CLR', '', 'SHM'), 'caster|class keeps any caster')
    assert(not R.classTagSkip('Single', '', '', '', 'WAR'), 'no archetype tag = nobody skipped')
end

-- beg
do
    local e = R.parseBeg('Talisman of Celerity Rk. II|tal, celerity,haste|item')
    assert(e.name == 'Talisman of Celerity Rk. II' and #e.aliases == 3 and e.aliases[2] == 'celerity' and e.item, 'parseBeg')
    assert(R.parseBeg('NULL') == nil and R.parseBeg('') == nil, 'NULL beg')
    local entries = { R.parseBeg('Spiritual Vigor|sv,vigor'), R.parseBeg('Talisman of Celerity|tal,celerity') }
    assert(R.begMatch('can i get TAL please', entries).name == 'Talisman of Celerity', 'alias match is case-insensitive substring')
    assert(R.begMatch('hello there', entries) == nil, 'no alias no match')
    assert(R.begMatch('sv and tal', entries).name == 'Spiritual Vigor', 'first entry wins')
    assert(R.begApproved('all', {}), 'all')
    assert(R.begApproved('|raid|group', { inRaid = true }) and not R.begApproved('|raid|group', { inGroup = false }), 'raid')
    assert(R.begApproved('guild', { sameGuild = true }) and not R.begApproved('guild', {}), 'guild')
    assert(R.begApproved('fellowship', { inFellowship = true }), 'fellowship')
    assert(R.begApproved('tell', { medium = 'tell' }) and not R.begApproved('tell', { medium = 'group' }), 'tell needs the tell medium')
    assert(R.begApproved('group', { inGroup = true }) and not R.begApproved('NULL', { inGroup = true, inRaid = true }), 'group / NULL')
end

-- range OOG recast rows
do
    local skip, n = R.oogRecast('1234|1000|3', 1234, 1500, 3600, 'commonlands')
    assert(skip and n == 3, 'buff still running')
    skip, n = R.oogRecast('1234|1000|3', 1234, 5000, 3600, 'commonlands')
    assert(not skip and n == 3, 'buff expired')
    skip = R.oogRecast('1234|86000|1', 1234, 100, 3600, 'commonlands')
    assert(skip, 'midnight wrap: 500 s elapsed')
    skip = R.oogRecast('1234|1000|1', 1234, 50000, 3600, 'guildlobby')
    assert(skip, 'no-drop zone: once per spawn instance')
    skip, n = R.oogRecast('9999|1000|1', 1234, 1500, 3600, 'guildlobby')
    assert(not skip and n == 0, 'different spawn id = they re-zoned')
    assert(not R.oogRecast(nil, 1234, 0, 0, '') and not R.oogRecast('NULL', 1234, 0, 0, ''), 'no row')
end

-- regen pick
do
    local members = { { id = 1, class = 'WAR', pct = 40 }, { id = 2, class = 'CLR', pct = 30 }, { id = 3, class = 'WIZ', pct = 20 } }
    assert(R.regenPick(members, 'mana', 35, '0').id == 2, 'default mana classes, first under the line')
    assert(R.regenPick(members, 'endurance', 50, nil).id == 1, 'default endurance classes')
    assert(R.regenPick(members, 'mana', 35, 'WIZ').id == 3, 'explicit class list')
    assert(R.regenPick(members, 'mana', 10, '0') == nil, 'nobody under the line')
    assert(R.regenPick({ { id = 1, class = 'CLR', pct = 0 } }, 'mana', 50, '0') == nil, 'pct 0 (dead/unknown) is never picked')
    local six = { { id = 1, class = 'WAR', pct = 100 }, { id = 2, class = 'WAR', pct = 100 }, { id = 3, class = 'WAR', pct = 100 }, { id = 4, class = 'WAR', pct = 100 }, { id = 5, class = 'WAR', pct = 100 }, { id = 6, class = 'CLR', pct = 5 } }
    assert(R.regenPick(six, 'mana', 50, '0') == nil, 'slots beyond 5 are not scanned')
end

print('buffrules_test OK')
