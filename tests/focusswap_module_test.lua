-- lua tests/focusswap_module_test.lua   (from lua/muleassist)
-- modules/focusswap.lua: in-process planning (rebuild triggers, cursor hold) and the swap (port of the
-- macro's Sub FocusSwapFor) against a simulated /itemnotify.
package.path = './?.lua;./?/init.lua;' .. package.path
local Stub = require('tests.stub_mq')
local mq = Stub.new({})
local World = require('tests.world')
local Ini = require('core.ini')
local Config = require('core.config')
local Timers = require('core.timers')
local Fx = require('tests.focusswap.fixtures')

local POISON = 'Breeches of Whispered Death'
local FIRE = 'Breeches of Phenomenal Power'
local poisonPants = Fx.item(POISON, Fx.MURK_BLOOD, { 'legs' }, 'Murk Blood')
local firePants = Fx.item(FIRE, Fx.PYRILEN_FURY, { 'legs' }, 'Pyrilen Fury')

-- fake scan (the real one reads TLOs the world does not model); counts inventory reads = rebuilds
local scan = { fp = 'A', inventories = 0 }
function scan.fingerprint() return scan.fp end
function scan.inventory()
    scan.inventories = scan.inventories + 1
    return { worn = { legs = poisonPants }, bag = { firePants }, attune = {} }
end
function scan.spellInfo(name)
    if name == 'Chaos Venom' then return Fx.POISON_DOT end
    if name == 'Ignite Blood' then return Fx.FIRE_DOT end
    return nil
end
package.loaded['focusswap.scan'] = scan

-- the character INI: the planner reads the file text; the bot's config reads the Ini backend
local WIN = package.config:sub(1, 1) == '\\'
local tmp = ((os.getenv('TEMP') or '/tmp'):gsub('\\', '/')) .. '/ma_focusswap_' .. os.time() .. '_' .. math.random(1000, 9999)
os.execute(WIN and ('mkdir "' .. tmp:gsub('/', '\\') .. '" 2>nul') or ('mkdir -p "' .. tmp .. '"'))
local INI = 'MuleAssist_srv_Bob.ini'
local f = assert(io.open(tmp .. '/' .. INI, 'wb'))
f:write('[DPS]\nDPSSize=2\nDPS1=Chaos Venom|99\nDPS2=Ignite Blood|99\n[FocusSwap]\nFocusSwapOn=1\nFocusSwapMinGain=3\n')
f:close()
mq.configDir = tmp
Ini.use(Ini.tableBackend({ [INI] = { FocusSwap = { FocusSwapOn = '1' } } }))
Config.iniFile = INI
Config.condFile = INI
Config.rankFn = function(n) return n end
Config.zoneId = function() return 100 end
Timers.setClock(function() return mq.now end)
World.build(mq, { me = { class = 'NEC' } })

-- simulated inventory: worn slot -> item, bag slot 'pack<b>:<s>' (s=0 loose) -> item, the cursor
local worn = { legs = POISON }
local bags = { ['pack2:3'] = FIRE }
local cursor = nil
local refuse = false
local function sim(c)
    local b, s = c:match('/itemnotify in pack(%d+) (%d+) leftmouseup')
    local key = b and ('pack' .. b .. ':' .. s) or nil
    if not key then local tb = c:match('/itemnotify pack(%d+) leftmouseup') if tb then key = 'pack' .. tb .. ':0' end end
    if key then cursor, bags[key] = bags[key], cursor return end
    local slot = c:match('/itemnotify (%a+) leftmouseup')
    if slot then if not refuse then cursor, worn[slot] = worn[slot], cursor end return end
    if c == '/autoinventory' then cursor = nil end
end
local rawCmd = mq.cmd
mq.cmd = function(s) rawCmd(s) sim(s) end
mq.cmdf = function(fmt, ...) mq.cmd(string.format(fmt, ...)) end
World.set(mq, 'Cursor.ID', function() return cursor and 77 or 0 end)
World.set(mq, 'Cursor.Name', function() return cursor or '' end)
World.set(mq, 'Me.Inventory', function(slot) return mq.build({ Name = worn[slot] or '' }) end)
World.set(mq, 'Me.Zoning', false)
World.set(mq, 'FindItem', function(q)
    local n = tostring(q):gsub('^=', '')
    for key, it in pairs(bags) do
        if it == n then
            local b, s = key:match('pack(%d+):(%d+)')
            return mq.build({ ID = 1, Name = n, ItemSlot = 22 + tonumber(b), ItemSlot2 = tonumber(s) - 1 })
        end
    end
    for slot, it in pairs(worn) do if it == n then return mq.build({ ID = 1, Name = n, ItemSlot = 18, ItemSlot2 = -1 }) end end
    return mq.build({ ID = 0 })
end)

local Cast = require('core.cast')
local FS = require('modules.focusswap')
FS.reset()
FS:LoadSettings({})
local function pass(ms) mq.now = mq.now + (ms or 250) FS:Tick({}) end
local function count(pat) local n = 0 for _, c in ipairs(mq.cmds) do if c:find(pat) then n = n + 1 end end return n end

-- 1: the first tick builds the map (both DoTs contest the legs)
pass()
assert(scan.inventories == 1, 'one rebuild: ' .. scan.inventories)
assert(FS.entries['chaos venom'] and FS.entries['chaos venom'].item == POISON and FS.entries['chaos venom'].slot == 'legs', 'poison entry')
assert(FS.entries['ignite blood'] and FS.entries['ignite blood'].item == FIRE, 'fire entry')
assert(type(Cast.hooks.preCast) == 'function', 'preCast installed')

-- 2: unchanged fingerprint -> no rebuild; changed -> rebuild after the 5 s check
pass(1000)
assert(scan.inventories == 1, 'no rebuild inside 5 s')
scan.fp = 'B'
pass(5000)
assert(scan.inventories == 2, 'rebuild on a changed fingerprint')

-- 3: a busy cursor holds a pending rebuild; it runs once the cursor clears
FS.Binds['/focusswap'](FS, 'rebuild')
cursor = 'a gem'
pass()
assert(scan.inventories == 2, 'held while the cursor is busy')
cursor = nil
pass()
assert(scan.inventories == 3, 'rebuilt once clear')

-- 4: preCast for a worn item does nothing; for the fire DoT it swaps from the bag slot and puts the old pants back
mq.cmds = {}
Cast.hooks.preCast('Chaos Venom', 9, 'DPS', {})
assert(count('/itemnotify') == 0, 'already worn: no swap')
Cast.hooks.preCast('Ignite Blood Rk. II', 9, 'DPS', {})
assert(mq.cmds[1] == '/nomodkey /itemnotify in pack2 3 leftmouseup', 'pick from the bag: ' .. tostring(mq.cmds[1]))
assert(mq.cmds[2] == '/nomodkey /itemnotify legs leftmouseup', 'seat in legs: ' .. tostring(mq.cmds[2]))
assert(mq.cmds[3] == '/nomodkey /itemnotify in pack2 3 leftmouseup', 'old pants back: ' .. tostring(mq.cmds[3]))
assert(worn.legs == FIRE and bags['pack2:3'] == POISON and cursor == nil, 'fire pants on, poison pants in the bag')
assert(count('/exchange') == 0, 'never /exchange')

-- 5: a loose item in a top-level pack slot
bags = { ['pack3:0'] = POISON }
mq.cmds = {}
Cast.hooks.preCast('Chaos Venom', 9, 'DPS', {})
assert(mq.cmds[1] == '/nomodkey /itemnotify pack3 leftmouseup', 'loose pack item: ' .. tostring(mq.cmds[1]))
assert(worn.legs == POISON, 'poison pants on')

-- 6: skips - cursor busy, casting, pet focus swap, missing, worn elsewhere
local entry = { spell = 'Ignite Blood', item = FIRE, slot = 'legs' }
cursor = 'a gem'
assert(FS:swapFor('Ignite Blood', entry) == 'busy', 'cursor busy')
cursor = nil
World.set(mq, 'Me.Casting.ID', 5)
assert(FS:swapFor('Ignite Blood', entry) == 'busy', 'casting')
World.set(mq, 'Me.Casting.ID', 0)
package.loaded['modules.pet'] = { focusSwapped = '' }
assert(FS:swapFor('Ignite Blood', entry) == 'petfocus', 'pet focus swap in progress')
package.loaded['modules.pet'] = nil
bags = {}
assert(FS:swapFor('Ignite Blood', entry) == 'missing', 'item not carried')
worn.ears = FIRE
assert(FS:swapFor('Ignite Blood', entry) == 'elsewhere', 'worn in another slot stays')
worn.ears = nil

-- 7: a refused swap: item stays out, cursor cleared back, item blocked, rebuild without it
bags = { ['pack2:3'] = FIRE }
refuse = true
mq.cmds = {}
local before = scan.inventories
assert(FS:swapFor('Ignite Blood', entry) == 'failed', 'refused')
refuse = false
assert(cursor == nil and bags['pack2:3'] == FIRE, 'item put back in its bag slot')
assert(FS.blocked[FIRE], 'blocked for the session')
pass()
assert(scan.inventories == before + 1 and FS.entries['ignite blood'] == nil, 'rebuilt without the blocked item')

-- 8: an error inside the swap never reaches the cast
local savedSwap = FS.swapFor
FS.swapFor = function() error('boom') end
FS.entries['chaos venom'] = { spell = 'Chaos Venom', item = POISON, slot = 'legs' }
assert(pcall(Cast.hooks.preCast, 'Chaos Venom', 9, 'DPS', {}), 'preCast swallows swap errors')
FS.swapFor = savedSwap

-- 9: stop clears the map and turns the hook into a no-op
FS.Binds['/focusswap'](FS, 'stop')
assert(next(FS.entries) == nil, 'stop clears the map')
mq.cmds = {}
Cast.hooks.preCast('Chaos Venom', 9, 'DPS', {})
assert(count('/itemnotify') == 0, 'stopped: no swap')
local n = scan.inventories
pass(6000)
assert(scan.inventories == n, 'stopped: no rebuilds')

-- 10: dump runs
FS.stopped = false
pass()
assert(pcall(FS.dump, FS), 'dump runs')

-- 11: the map key ignores case and rank, as the macro's FocusMap.Find does
FS.blocked = {}
FS.Binds['/focusswap'](FS, 'rebuild')
pass()
worn.legs = FIRE
bags = { ['pack2:3'] = POISON }
mq.cmds = {}
Cast.hooks.preCast('chaos venom Rk. III', 9, 'DPS', {})
assert(worn.legs == POISON, 'lower-case rank-suffixed cast name swaps: ' .. table.concat(mq.cmds, ';'))

print('focusswap_module_test OK')
