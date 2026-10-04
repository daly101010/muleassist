-- lua tests/smartheal_fork_test.lua   (from lua/muleassist)
-- The forked SmartHeals engine (smartheal/): no sidekick-next module paths left, no ImGui; it loads and
-- initializes under the bot's mq stub; a read-only sensor tick never calls mq.delay; its files live under
-- config/MuleAssist and are imported once from config/SideKick-Next, which is never written.
package.path = './?.lua;./?/init.lua;' .. package.path
local Stub = require('tests.stub_mq')

local pass, fail = 0, 0
local function check(name, cond, detail)
    if cond then pass = pass + 1
    else fail = fail + 1; io.write('FAIL: ' .. name .. (detail ~= nil and (' -- ' .. tostring(detail)) or '') .. '\n') end
end
local function read(p) local f = io.open(p, 'rb') if not f then return nil end local s = f:read('a') f:close() return s end
local function write(p, s) local f = assert(io.open(p, 'wb')) f:write(s) f:close() end
local WIN = package.config:sub(1, 1) == '\\'
local function mkdir(p)
    if WIN then os.execute('mkdir "' .. p:gsub('/', '\\') .. '" 2>nul') else os.execute('mkdir -p "' .. p .. '"') end
end

-- 1: source scan
local FILES = { 'init', 'config', 'heal_selector', 'hot_analyzer', 'proactive', 'heal_tracker', 'persistence',
    'target_monitor', 'incoming_heals', 'combat_assessor', 'analytics', 'spell_events', 'damage_parser',
    'damage_attribution', 'mob_assessor', 'logger', 'env', 'util/lazy_require', 'util/safe_write', 'util/logger',
    'util/debug_log', 'util/named_detector', 'util/healer_classes', 'util/ma_bridge_state', 'util/paths',
    'util/sk_lib', 'util/core', 'util/actors_coordinator' }
for _, f in ipairs(FILES) do
    local src = read('smartheal/' .. f .. '.lua')
    check('exists: ' .. f, src ~= nil)
    if src then
        check('no sidekick-next module path: ' .. f, not src:find('sidekick%-next%.'))
        check('no ImGui / bit32: ' .. f, not src:find('ImGui') and not src:find('imgui') and not src:find('bit32'))
    end
end

-- 2: load, init, import, paths
local tmp = ((os.getenv('TEMP') or os.getenv('TMPDIR') or '/tmp'):gsub('\\', '/')) .. '/ma_smartheal_' .. os.time() .. '_' .. math.random(1000, 9999)
mkdir(tmp .. '/SideKick-Next/healing')
local PROFILE = 'return {\n  emergencyPct = 33,\n}\n'
local DATA = 'return {}\n'
write(tmp .. '/SideKick-Next/healing/config_srv_Bob.lua', PROFILE)
write(tmp .. '/SideKick-Next/healing/data_srv_Bob.lua', DATA)

local mq = Stub.new({
    Me = { CleanName = 'Bob', Name = 'Bob', ID = 1, Level = 65, PctHPs = 100, MaxHPs = 5000, CurrentHPs = 5000,
        PctMana = 100, CurrentMana = 5000, Moving = false, Casting = { ID = 0 }, Combat = false,
        Class = { ShortName = 'CLR', Name = 'Cleric' },
        Gem = { _ = function() return nil end }, Book = { _ = function() return nil end },
        XTarget = { _ = function() return nil end } },
    EverQuest = { Server = 'srv' },
    Zone = { ShortName = 'testzone', ID = 100 },
    Group = { Members = 0 },
    Spawn = { _ = function() return nil end },
    SpawnCount = { _ = function() return 0 end },
    Plugin = { _ = function() return nil end },
    Time = { MillisecondsSinceEpoch = 0 },
})
mq.configDir = tmp

local okLoad, Engine = pcall(require, 'smartheal')
check('engine loads', okLoad, Engine)
if okLoad then
    local total = tonumber(Engine.TOTAL_INIT_PHASES) or 5
    for p = 1, total do
        local ok, err = pcall(Engine.initPhased, p)
        check('init phase ' .. p, ok, err)
    end
    check('initialized', Engine.isInitialized and Engine.isInitialized())
    local imported = read(tmp .. '/MuleAssist/healing/config_srv_Bob.lua')
    check('profile imported from SideKick-Next', imported ~= nil and imported:find('emergencyPct') ~= nil, imported)
    check('profile applied', Engine.Config and tonumber(Engine.Config.emergencyPct) == 33, Engine.Config and Engine.Config.emergencyPct)
    check('SideKick-Next profile untouched', read(tmp .. '/SideKick-Next/healing/config_srv_Bob.lua') == PROFILE)

    mq.onDelay = function() error('mq.delay during a read-only tick') end
    local ok, err = pcall(Engine.tickSensors, { readOnly = true })
    check('read-only sensor tick runs without mq.delay', ok, err)
    mq.onDelay = nil
    pcall(Engine.shutdown)

    check('SideKick-Next data untouched', read(tmp .. '/SideKick-Next/healing/data_srv_Bob.lua') == DATA)
    check('no SideKick mob file', read(tmp .. '/SideKick/SideKick_MobAssessor.lua') == nil)
    check('no SideKick-Next mob file', read(tmp .. '/SideKick-Next/SideKick_MobAssessor.lua') == nil)

    local Paths = require('smartheal.util.paths')
    check('data path under MuleAssist', Paths.getHealingDataPath():find('/MuleAssist/healing/data_srv_Bob.lua', 1, true) ~= nil, Paths.getHealingDataPath())
    check('data imported', read(tmp .. '/MuleAssist/healing/data_srv_Bob.lua') ~= nil)
    check('log dir under MuleAssist', Paths.getHealingLogDir():find('/MuleAssist/HealingLogs', 1, true) ~= nil, Paths.getHealingLogDir())
    check('mob file under MuleAssist', Paths.getMobAssessorPath():find('/MuleAssist/healing/mob_assessor.lua', 1, true) ~= nil, Paths.getMobAssessorPath())
    -- an existing MuleAssist copy is never re-imported
    write(tmp .. '/SideKick-Next/healing/config_srv_Bob.lua', 'return { emergencyPct = 11 }\n')
    Paths.getHealingConfigPath()
    check('existing profile not re-imported', not (read(tmp .. '/MuleAssist/healing/config_srv_Bob.lua') or ''):find('= 11'))

    local Env = require('smartheal.env')
    check('tank gate off by default', not Env.isTank() and Env.settings().CombatMode == 'off')
    Env.setTank(function() return true end)
    check('tank gate from the bot', Env.isTank() and Env.settings().CombatMode == 'tank'
        and require('smartheal.util.sk_lib').getSettings().CombatMode == 'tank')
    Env.setTank(function() return false end)
    local co = Env.coordinator()
    check('coordinator stub', type(co.getRemoteCharacters()) == 'table' and co.isClaimWinner() == true and co.anythingElse() == nil)
    local won, winner = co.isHealClaimWinner(5, {})
    check('coordinator stub: isHealClaimWinner', won == true and winner == nil and co.getPullState() == nil and co.getTankState() == nil)

    -- the engine's own claim check, with broadcasting on, must win against the inert coordinator
    -- (a nil here would read as a lost claim and block every heal)
    local prevBroadcast = Engine.Config.broadcastEnabled
    Engine.Config.broadcastEnabled = true
    local okClaim, claim = pcall(Engine.isClaimWinner, { targetId = 5, tier = 'heal', spellName = 'Remedy' })
    Engine.Config.broadcastEnabled = prevBroadcast
    check('engine claim wins with broadcast on', okClaim and claim == true, claim)

    -- a destination that exists but is EMPTY is re-imported (data and profile)
    write(tmp .. '/MuleAssist/healing/data_srv_Bob.lua', '')
    Paths.getHealingDataPath()
    check('empty data file re-imported', (read(tmp .. '/MuleAssist/healing/data_srv_Bob.lua') or ''):find('return {}', 1, true) ~= nil)
    write(tmp .. '/MuleAssist/healing/config_srv_Bob.lua', '')
    Paths.getHealingConfigPath()
    check('empty profile re-imported', (read(tmp .. '/MuleAssist/healing/config_srv_Bob.lua') or ''):find('emergencyPct = 11', 1, true) ~= nil)
end

io.write(string.format('smartheal_fork_test: %d passed, %d failed\n', pass, fail))
os.exit(fail == 0 and 0 or 1)
