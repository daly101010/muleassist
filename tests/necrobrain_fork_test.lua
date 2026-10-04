-- lua tests/necrobrain_fork_test.lua   (from lua/muleassist)
-- The forked necrobrain modules exist, load, and stay byte-identical to F:/lua/necrobrain @ 194f9a7.
package.path = './?.lua;./?/init.lua;' .. package.path
local MODULES = { 'bridge', 'ranker', 'ttd', 'holds', 'resist', 'dpslist', 'procs', 'feed', 'history', 'logger', 'vesagran', 'vesclaim' }
for _, m in ipairs(MODULES) do
    local f = io.open('necrobrain/' .. m .. '.lua', 'rb')
    assert(f, 'missing necrobrain/' .. m .. '.lua')
    local data = f:read('a') f:close()
    assert(not data:find('\r', 1, true), m .. ' has CR line endings')
    assert(loadfile('necrobrain/' .. m .. '.lua'), m .. ' does not compile')
end
assert(not io.open('necrobrain/init.lua', 'rb'), 'necrobrain/init.lua must not be copied (modules/smartdps.lua replaces it)')
local ok = os.execute('python tools/fork_necrobrain.py --check')
assert(ok == true or ok == 0, 'fork --check: a copied module differs from 194f9a7')
print('necrobrain_fork_test OK')
