-- Run: lua tests/test_logger.lua
package.path = './necrobrain/?.lua;./?.lua;' .. package.path
local Logger = require('logger')
local pass, fail = 0, 0
local function check(name, condition)
    if condition then pass = pass + 1
    else fail = fail + 1; io.write('FAIL: ' .. name .. '\n') end
end
local path = os.tmpname()
local output = {}
local log = Logger.new(path, function(line) output[#output + 1] = line end)
check('file logging succeeds with console disabled', log.write('\arrefused\ax %s: %d%%', 'Test Spell', 50))
check('console is silent by default', #output == 0)
log.console = true
check('file logging continues with console enabled', log.write('enabled'))
check('console opt-in emits messages', #output == 1 and output[1]:find('enabled', 1, true))
log.console = false
check('file logging continues after disabling console', log.write('disabled'))
check('console stops immediately', #output == 1)
local restarted = Logger.new(path, function() error('console should default off again') end)
check('restart appends to existing file', restarted.write('restarted'))
local file = assert(io.open(path, 'r'))
local contents = file:read('*a'); file:close()
check('formatted message saved without MQ color escapes', contents:find('refused Test Spell: 50%', 1, true) and not contents:find('\a', 1, true))
check('messages from both modes and restart retained', contents:find('enabled', 1, true) and contents:find('disabled', 1, true) and contents:find('restarted', 1, true))
check('timestamp and component included', contents:match('%[%d%d%d%d%-%d%d%-%d%d %d%d:%d%d:%d%d%] %[necrobrain%]'))
local open = io.open
io.open = function() return nil, 'disk unavailable' end
local ok, err = log.write('failed open')
io.open = open
check('open failure returned without interrupting caller or printing', not ok and err == 'disk unavailable' and #output == 1)
local closed = false
io.open = function() return {
    write = function() return nil, 'disk full' end,
    close = function() closed = true; return true end,
} end
ok, err = log.write('failed write')
io.open = open
check('write failure closes handle and returns error', not ok and err == 'disk full' and closed)
check('file logging recovers on next message', log.write('recovered') and log.lastError == nil)
os.remove(path)
io.write(string.format('test_logger: %d passed, %d failed\n', pass, fail))
os.exit(fail == 0 and 0 or 1)
