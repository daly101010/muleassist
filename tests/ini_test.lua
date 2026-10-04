-- lua tests/ini_test.lua   (from lua/muleassist): core/ini.lua's parse-once path and Config's LoadSettings
-- rounds. The expected values in the parity table were read from the same text with kernel32
-- GetPrivateProfileStringA on Windows 11 (what mq.TLO.Ini calls), then mapped as the game backend maps them:
-- nothing returned (missing key, empty value, "") is nil, and so is NULL.
package.path = './?.lua;./?/init.lua;' .. package.path
local Stub = require('tests.stub_mq')
Stub.new({})
local Ini = require('core.ini')
local Config = require('core.config')

local pass, fail = 0, 0
local function check(name, cond, detail)
    if cond then pass = pass + 1 else fail = fail + 1 print('FAIL: ' .. name .. (detail ~= nil and (' -- ' .. tostring(detail)) or '')) end
end

-- ---------------------------------------------------------------- parity with GetPrivateProfileString
local TEXT = table.concat({
    '; leading comment\r\n',
    'orphan=before any section\r\n',
    '[General]\r\n',
    'Role=assist\r\n',
    'role=second (case dup)\r\n',
    '  Spaced Key   =   spaced value   \r\n',
    '\tTabbed\t=\tv\t\r\n',
    'Quoted="  in quotes  "\r\n',
    "Single='single'\r\n",
    'Unmatched="open\r\n',
    'Mixed=\'a"\r\n',
    'Lone="\r\n',
    'EmptyQ=""\r\n',
    'NullV=NULL\r\n',
    'nullLower=null\r\n',
    'Empty=\r\n',
    'EqInValue=a=b=c\r\n',
    'Brackets=x [y] z\r\n',
    ';DPS1=commented\r\n',
    '# Hash=hash comment\r\n',
    'NoEquals\r\n',
    'Dup=first\r\n',
    'Dup=second\r\n',
    'InnerQ="a"b"\r\n',
    '[ Spaced ]\r\n',
    'k=spaced section\r\n',
    '[general]\r\n',
    'Role=dup section\r\n',
    'OnlyInDup=yes\r\n',
    '[DPS]junk after\n',
    'DPS1=Spell A|99\n',
    'dps2=Spell B|50\n',
    'DPS3 = Spell C | 10 \n',
    '[Empty Section]\n',
    '[A]B]\r\n',
    'k=1\r\n',
    '[Sec]\r\n',
    '  ;c=comment\r\n',
    '\t;t=tabcomment\r\n',
    'normal=1\r\n',
    ' [Lead]\r\n',
    'k=lead\r\n',
    '[Tab\t]\r\n',
    'k=tab\r\n',
    '[Last]\n',
    'Tail=no newline at end',
})
local PARITY = {
    { 'General', 'Role', 'assist' }, { 'GENERAL', 'role', 'assist' },
    { 'General', 'Spaced Key', 'spaced value' }, { 'General', 'spaced key', 'spaced value' },
    { 'General', 'Tabbed', 'v' }, { 'General', 'Quoted', '  in quotes  ' }, { 'General', 'Single', 'single' },
    { 'General', 'Unmatched', '"open' }, { 'General', 'Mixed', '\'a"' }, { 'General', 'Lone', '"' },
    { 'General', 'EmptyQ', nil }, { 'General', 'NullV', nil }, { 'General', 'nullLower', 'null' },
    { 'General', 'Empty', nil }, { 'General', 'EqInValue', 'a=b=c' }, { 'General', 'Brackets', 'x [y] z' },
    { 'General', 'DPS1', nil }, { 'General', ';DPS1', nil }, { 'General', '# Hash', 'hash comment' },
    { 'General', 'NoEquals', nil }, { 'General', 'Dup', 'first' }, { 'General', 'InnerQ', 'a"b' },
    { 'General', 'OnlyInDup', nil }, { 'General', 'Missing', nil },
    { ' Spaced ', 'k', 'spaced section' }, { 'Spaced', 'k', 'spaced section' },
    { 'DPS', 'DPS1', 'Spell A|99' }, { 'DPS', 'DPS2', 'Spell B|50' }, { 'dps', 'dps3', 'Spell C | 10' },
    { 'Empty Section', 'x', nil }, { 'Last', 'Tail', 'no newline at end' }, { 'NoSection', 'x', nil },
    { 'A]B', 'k', nil }, { 'A', 'k', '1' }, { 'Sec', ';c', nil }, { 'Sec', '  ;c', nil }, { 'Sec', ';t', nil },
    { 'Sec', 'normal', '1' }, { 'Lead', 'k', 'lead' }, { 'Tab', 'k', 'tab' },
    { 'General', ' Role ', 'assist' }, { ' General ', 'Role', 'assist' },
}
local p = Ini.parse(TEXT)
for _, c in ipairs(PARITY) do
    local got = Ini.get(p, c[1], c[2])
    check(string.format('parity [%s] %s', c[1], c[2]), got == c[3], string.format('got %q want %q', tostring(got), tostring(c[3])))
end
check('present with a NULL value', Ini.has(p, 'General', 'NullV') and Ini.has(p, 'general', 'EMPTY') and Ini.has(p, 'General', 'EmptyQ'))
check('absent keys are not present', not Ini.has(p, 'General', 'Missing') and not Ini.has(p, 'General', 'NoEquals')
    and not Ini.has(p, 'General', 'OnlyInDup') and not Ini.has(p, 'Nope', 'x'))
check('empty text parses', Ini.get(Ini.parse(''), 'A', 'b') == nil and Ini.get(Ini.parse(nil), 'A', 'b') == nil)
-- kernel32: a '[' line with no ']' is still a header, its name running to the end of the line (a hand edit
-- that drops a ']' must not file its keys under the previous section and get them rewritten to defaults)
do
    local u = Ini.parse('[General]\r\nRole=Assist\r\n[DPS  \r\nDPSOn=1\r\n[Heals]\r\nHealsOn=1\r\n')
    check('unterminated header is a section', Ini.get(u, 'DPS', 'DPSOn') == '1' and Ini.has(u, 'DPS', 'DPSOn'),
        tostring(Ini.get(u, 'DPS', 'DPSOn')))
    check('its keys are not filed under the previous section', Ini.get(u, 'General', 'DPSOn') == nil)
    check('the next header still starts a section', Ini.get(u, 'Heals', 'HealsOn') == '1')
end

-- ---------------------------------------------------------------- holding a file
local FILE = 'MuleAssist_srv_Bob.ini'
local texts = { [FILE] = '[General]\r\nRole=assist\r\nMainAssist=NULL\r\nEmpty=\r\n[DPS]\r\nDPSSize=2\r\nDPS1=Spell A|99\r\nDPS2=NULL\r\n' }
local tlo, writes, deletes = 0, {}, {}
local backend = {
    read = function() tlo = tlo + 1 return 'from the TLO' end,
    exists = function() tlo = tlo + 1 return false end,
    write = function(file, section, key, value) writes[#writes + 1] = string.format('%s|%s|%s|%s', file, section, key, tostring(value)) end,
    sections = function() return {} end,
    deleteSection = function(file, section) deletes[#deletes + 1] = section end,
    text = function(file) return texts[file] end,
}
Ini.use(backend)
check('not held: reads go to the backend', Ini.read(FILE, 'General', 'Role') == 'from the TLO' and tlo == 1)
check('hold parses the file', Ini.hold(FILE) == true and Ini.isHeld(FILE))
tlo = 0
check('held: answered from the parse', Ini.read(FILE, 'General', 'Role') == 'assist' and Ini.read(FILE, 'general', 'ROLE') == 'assist' and tlo == 0)
check('held: NULL and empty read nil but exist', Ini.read(FILE, 'General', 'MainAssist') == nil and Ini.exists(FILE, 'General', 'MainAssist')
    and Ini.read(FILE, 'General', 'Empty') == nil and Ini.exists(FILE, 'General', 'Empty') and tlo == 0)
check('held: a missing key is nil and absent', Ini.read(FILE, 'General', 'Nope') == nil and not Ini.exists(FILE, 'General', 'Nope') and tlo == 0)
Ini.write(FILE, 'General', 'Nope', '  "quoted"  ')
check('write still goes to /ini', writes[#writes] == FILE .. '|General|Nope|  "quoted"  ')
check('and lands in the parse as a read would see it', Ini.read(FILE, 'General', 'Nope') == 'quoted' and Ini.read(FILE, 'GENERAL', 'nope') == 'quoted')
Ini.write(FILE, 'general', 'ROLE', 'puller')
check('a write replaces the first key of that name, any case', Ini.read(FILE, 'General', 'Role') == 'puller' and Ini.read(FILE, 'GENERAL', 'role') == 'puller')
Ini.write(FILE, 'NewSec', 'K', 'v')
check('a write to a new section', Ini.read(FILE, 'NewSec', 'K') == 'v' and Ini.read(FILE, 'newsec', 'k') == 'v')
Ini.write(FILE, 'General', 'Role', 'NULL')
check('writing NULL reads nil, the key stays', Ini.read(FILE, 'General', 'Role') == nil and Ini.exists(FILE, 'General', 'Role'))
Ini.deleteSection(FILE, 'dps')
check('deleteSection drops it from the parse', Ini.read(FILE, 'DPS', 'DPS1') == nil and not Ini.exists(FILE, 'DPS', 'DPSSize') and deletes[1] == 'dps')
check('nested holds count', Ini.hold(FILE) == true)
Ini.release(FILE)
check('still held after the inner release', Ini.isHeld(FILE))
Ini.release(FILE)
check('released', not Ini.isHeld(FILE))
tlo = 0
check('released: back on the backend', Ini.read(FILE, 'General', 'Role') == 'from the TLO' and tlo == 1)
check('a file the backend has no text for is not held', Ini.hold('Other.ini') == false and not Ini.isHeld('Other.ini'))
Ini.release('Other.ini')

-- ---------------------------------------------------------------- Config: rounds, and present keys never rewritten
texts[FILE] = table.concat({
    '[General]\r\n', 'Role=assist\r\n', 'MainAssist=NULL\r\n', 'GemStuckAbility=NULL\r\n', 'Blank=\r\n',
    '[DPS]\r\n', 'DPSSize=3\r\n', 'DPS1=Spell A|99\r\n', 'DPS2=NULL\r\n', 'DPS3=Spell C|50\r\n',
    'DPSCond1=TRUE\r\n', 'DPSCond2=NULL\r\n',
})
writes, tlo = {}, 0
Config.iniFile, Config.condFile = FILE, FILE
Config.rankFn = function(n) return n end
Config.zoneId = function() return 0 end
Config.conditionsOn = 2
local schema = {
    scalars = {
        { section = 'General', key = 'Role', type = 'string', default = 'assist', rank = false },
        { section = 'General', key = 'MainAssist', type = 'string', default = 'NULL', rank = false },
        { section = 'General', key = 'GemStuckAbility', type = 'string', default = 'NULL', rank = false },
        { section = 'General', key = 'Blank', type = 'int', default = 7 },
        { section = 'General', key = 'Absent', type = 'int', default = 5 },
        { section = 'General', key = 'AbsentNull', type = 'string', default = 'NULL', rank = false },
    },
    arrays = { { section = 'DPS', name = 'DPS', size = { key = 'DPSSize', default = 20 }, cond = 'DPSCond' } },
}
local out
Config.round(function() out = Config.load(schema) end)
check('round: no TLO read', tlo == 0, tlo)
check('round released the file', not Ini.isHeld(FILE))
check('values as before', out.Role == 'assist' and out.MainAssist == 'NULL' and out.GemStuckAbility == 'NULL' and out.Blank == 7
    and out.Absent == 5 and out.AbsentNull == 'NULL' and out.DPS[1] == 'Spell A|99' and out.DPS[2] == 'NULL' and out.DPS[3] == 'Spell C|50'
    and out.DPSSize == 3 and out.DPSCond[1] == 'TRUE' and out.DPSCond[2] == 'FALSE' and out.DPSCond[3] == 'TRUE')
local wrote = {}
for _, w in ipairs(writes) do wrote[w:match('^[^|]*|([^|]*|[^|]*)')] = true end
check('present NULL / empty keys are not rewritten', not wrote['General|MainAssist'] and not wrote['General|GemStuckAbility']
    and not wrote['General|Blank'] and not wrote['DPS|DPS2'] and not wrote['DPS|DPSCond2'], table.concat(writes, '; '))
check('absent keys get their default', wrote['General|Absent'] and wrote['General|AbsentNull'] and wrote['DPS|DPSCond3'], table.concat(writes, '; '))
-- the same load outside a round (the TLO path, through backend.exists) writes the same keys
local roundWrites = #writes
writes, tlo = {}, 0
Ini.use(Ini.tableBackend({ [FILE] = {
    General = { Role = 'assist', MainAssist = 'NULL', GemStuckAbility = 'NULL', Blank = '' },
    DPS = { DPSSize = '3', DPS1 = 'Spell A|99', DPS2 = 'NULL', DPS3 = 'Spell C|50', DPSCond1 = 'TRUE', DPSCond2 = 'NULL' },
} }))
local tb = Ini.backend()
local realWrite = tb.write
tb.write = function(file, section, key, value) writes[#writes + 1] = string.format('%s|%s|%s|%s', file, section, key, tostring(value)) realWrite(file, section, key, value) end
local out2 = Config.load(schema)
check('outside a round: same writes', #writes == roundWrites, table.concat(writes, '; '))
check('outside a round: same values', out2.Role == out.Role and out2.Blank == out.Blank and out2.DPSSize == out.DPSSize and out2.DPSCond[2] == out.DPSCond[2])
-- a round ends (and releases) even when its body raises
Ini.use(backend)
local ok = pcall(Config.round, function() error('boom') end)
check('a raising round still releases', not ok and not Ini.isHeld(FILE))
-- nested rounds
Config.beginRound()
Config.beginRound()
Config.endRound()
check('nested round keeps the hold', Ini.isHeld(FILE))
Config.endRound()
check('outer endRound releases', not Ini.isHeld(FILE))
-- Config.set inside a round is seen by the next read
Config.round(function()
    Config.set('General', 'Role', 'tank')
    check('Config.set inside a round is read back', Ini.read(FILE, 'General', 'Role') == 'tank')
end)

print(string.format('ini_test: %d passed, %d failed', pass, fail))
if fail > 0 then os.exit(1) end
print('ini_test OK')
