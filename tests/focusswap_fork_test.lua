-- lua tests/focusswap_fork_test.lua   (from lua/muleassist)
-- The copied focusswap modules exist, load, and stay byte-identical to F:/lua/focusswap @ 7c91d84.
package.path = './?.lua;./?/init.lua;' .. package.path
for _, m in ipairs({ 'limits', 'plan', 'ini', 'scan' }) do
    local f = io.open('focusswap/' .. m .. '.lua', 'rb')
    assert(f, 'missing focusswap/' .. m .. '.lua')
    local data = f:read('a') f:close()
    assert(not data:find('\r', 1, true), m .. ' has CR line endings')
    assert(loadfile('focusswap/' .. m .. '.lua'), m .. ' does not compile')
end
assert(not io.open('focusswap/init.lua', 'rb'), 'focusswap/init.lua must not be copied (modules/focusswap.lua replaces it)')
local ok = os.execute('python tools/fork_focusswap.py --check')
assert(ok == true or ok == 0, 'fork --check: a copied module differs from 7c91d84')
print('focusswap_fork_test OK')
