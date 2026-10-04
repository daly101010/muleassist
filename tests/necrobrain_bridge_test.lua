-- Run: luajit tests/test_bridge.lua   (from F:\lua\necrobrain)
package.path = './necrobrain/?.lua;./?.lua;' .. package.path
require('tests.necrobrain_fakes')
local pass, fail = 0, 0
local function check(name, cond, detail)
  if cond then pass = pass + 1 else fail = fail + 1; io.write('FAIL: ' .. name .. (detail and (' -- ' .. tostring(detail)) or '') .. '\n') end
end
local B = require('bridge')

local st = B.newState()
check('fresh state', st.seq == 0 and st.beat == 0)

local a = { spellName = 'Venin', targetId = 42, mode = 'eff' }
local batch = B.next(st, a, 0, 'SmartDPS')
check('first publish', batch and #batch == 4 and st.seq == 1)
check('Seq is last', batch[4][1] == 'SmartDPSSeq' and batch[4][2] == '1')
check('fields', batch[1][1] == 'SmartDPSSpell' and batch[1][2] == 'Venin' and batch[2][1] == 'SmartDPSTargetID' and batch[2][2] == '42' and batch[3][1] == 'SmartDPSMode' and batch[3][2] == 'eff')

check('same action, unconsumed -> nil', B.next(st, a, 0, 'SmartDPS') == nil)
check('same action, consumed -> republish', B.next(st, a, 1, 'SmartDPS') ~= nil and st.seq == 2)
check('changed action -> publish', B.next(st, { spellName = 'Dread Pyre', targetId = 42, mode = 'eff' }, 0, 'SmartDPS') ~= nil and st.seq == 3)
check('nil action -> nil, key cleared', B.next(st, nil, 3, 'SmartDPS') == nil and st.lastKey == nil)

-- live retraction: a nil action while the last pick is unconsumed publishes a fresh seq naming NULL
local rt = B.newState()
B.next(rt, a, 0, 'SmartDPS', true)
local r = B.next(rt, nil, 0, 'SmartDPS', true)
check('nil action retracts an unconsumed pick', r and #r == 4 and r[1][1] == 'SmartDPSSpell' and r[1][2] == 'NULL' and r[2][2] == '0' and r[4][1] == 'SmartDPSSeq' and r[4][2] == '2' and rt.seq == 2 and rt.lastKey == nil)
check('retraction is sent once', B.next(rt, nil, 0, 'SmartDPS', true) == nil and rt.seq == 2)
check('pick after a retraction publishes a new seq', B.next(rt, a, 0, 'SmartDPS', true) ~= nil and rt.seq == 3)
check('nil action after the pick was consumed retracts nothing', B.next(rt, nil, 3, 'SmartDPS', true) == nil and rt.seq == 3)
B.next(rt, a, 3, 'SmartDPS', true)
check('shadow (no retract) leaves an unconsumed pick alone', B.next(rt, nil, 3, 'SmartDPS', false) == nil and rt.seq == 4 and rt.lastKey == nil)

local hb = B.heartbeat(st, 'SmartDPS')
check('heartbeat increments', hb[1] == 'SmartDPSBeat' and hb[2] == '1' and st.beat == 1)

local rs, cut = B.rankedSet({ 'Venin', "Vakk`dra's Sickly Mists" }, 2000)
check('ranked set format', rs == "|Venin|Vakk`dra's Sickly Mists|" and cut == false, rs)
rs, cut = B.rankedSet({}, 2000)
check('empty ranked set is a lone bar', rs == '|' and cut == false, rs)
rs, cut = B.rankedSet({ 'Venin', 'Dread Pyre' }, 12)
check('truncates on whole entries', rs == '|Venin|' and cut == true, rs)

io.write(string.format('test_bridge: %d passed, %d failed\n', pass, fail))
os.exit(fail == 0 and 0 or 1)
