-- muleassist (Lua): the port of muleassist.mac, module by module. See
-- muleassist/docs/superpowers/specs/2026-10-02-lua-port-design.md. Run: /lua run muleassist
local mq = require('mq')
-- /lua run muleassist [role] [main assist]: the macro's launch arguments (MALua's role buttons use them)
local launchArgs = { ... }

-- our modules are required as 'core.x' / 'modules.x' relative to this directory
local scriptDir = debug.getinfo(1, 'S').source:match('^@(.*)[/\\]') or '.'
package.path = scriptDir .. '/?.lua;' .. scriptDir .. '/?/init.lua;' .. package.path

local T = require('core.tlo')
local Log = require('core.log')
local Config = require('core.config')
local Spell = require('core.spell')
local Cast = require('core.cast')
Cast.captureMainCoroutine()   -- registrations (binds, events, mailboxes) are only safe from this coroutine
local Timers = require('core.timers')
local State = require('core.state')
local Modules = require('core.modules')
local Observe = require('core.observe')

local VERSION = '0.7 (step 7: pull)'
local LOOP_MS = 100

-- ------------------------------------------------------------- refuse to run beside the macro
if T.str(function() return mq.TLO.Macro.Name() end):lower():find('muleassist') then
    Log.error('muleassist.mac is running on this box - stop it first (/endmacro). Exiting.')
    return
end

-- ------------------------------------------------------------- settings
local server = T.str(function() return mq.TLO.EverQuest.Server() end)
Config.iniFile = Config.fileName(server, T.myName())
Config.condFile = Config.iniFile
Config.rankFn = Spell.rank
Config.zoneId = T.zoneId
-- one LoadSettings round from here to the modules' LoadSettings: the INI is parsed once (core.ini) and every
-- Config read in between answers from it, instead of ~470 mq.TLO.Ini reads
Config.beginRound()

local General = Config.load({
    scalars = {
        { section = 'General', key = 'Role', type = 'string', default = 'assist', rank = false },
        { section = 'General', key = 'DanNetOn', type = 'int', default = 1 },
        { section = 'General', key = 'ConditionsOn', type = 'int', default = 2 },
        { section = 'General', key = 'PostMortemLog', type = 'int', default = 1 },
    },
})
State.role = General.Role
-- launch arguments override the INI for this session, as /mac muleassist <role> <MA> [rmark N] did
local launch = require('core.launch').parse(launchArgs)
if launch.role then State.role = launch.role end
if launch.mainAssist then State.launchMainAssist = launch.mainAssist end
if launch.rmark then
    State.markAssistOn, State.raidMarkNum = true, launch.rmark
    Log.info('[Mark] on - GroupMark 1 > RaidMark %d > RaidMark 1', launch.rmark)
elseif launch.rmarkBad then
    Log.info('[Mark] rmark needs 1, 2 or 3 - mark assist stays off')
end
State.danNetOn = General.DanNetOn ~= 0
Config.conditionsOn = General.ConditionsOn
Log.pmOn = General.PostMortemLog ~= 0

-- ------------------------------------------------------------- modules (steps 1-7): the raid / mode ticks, then heals and cures, then the fight, as the macro's main loop: heals and cures go before combat, as the macro's main loop
-- combat goes before movement: its LoadSettings applies the role rules movement reads (State.roleDefaults)
Cast.LoadSettings()
Modules.register(require('modules.report'))
Modules.register(require('modules.raid'))
Modules.register(require('modules.modes'))
Modules.register(require('modules.misc'))
Modules.register(require('modules.smartheal'))  -- the SmartHeals engine: picks before heals casts them, same pass
Modules.register(require('modules.heals'))
Modules.register(require('modules.cures'))
Modules.register(require('modules.healagent'))  -- heal ledger (HealBrainOn): every box ships snapshots to the brain
Modules.register(require('modules.healbrain'))  -- heal ledger brain: the MA's box (Raid Heal Ledger window, /healbrain)
Modules.register(require('modules.rez'))
Modules.register(require('modules.healeraggro'))
Modules.register(require('modules.ohshit'))
Modules.register(require('modules.combat'))
Modules.register(require('modules.movement'))
Modules.register(require('modules.pet'))
Modules.register(require('modules.pull'))
Modules.register(require('modules.mez'))
Modules.register(require('modules.debuffs'))
Modules.register(require('modules.smartdps'))  -- SmartDPS (necrobrain in-process): picks for the dps rotation, Blade of Vesagran
Modules.register(require('modules.dps'))
Modules.register(require('modules.focusswap'))  -- FocusSwap: the planner, and the swap from Cast.hooks.preCast
Modules.register(require('modules.charm'))
Modules.register(require('modules.buffs'))
Modules.register(require('modules.beg'))
Modules.register(require('modules.med'))
Modules.register(require('modules.setvar'))  -- /changevarint, /togglevariable: the binds MacroQuest.ini [Aliases] route onto

-- ------------------------------------------------------------- the MuleAssist TLO (observed by peers / MAUI)
local tloOk = false
if mq.DataType and mq.DataType.new then
    local ok, err = pcall(function()
        local MAType = mq.DataType.new('MuleAssist', {
            Members = {
                Status = function(_, self) return 'string', State.status end,
                HealStats = function(_, self) return 'string', State.healStats end,
                Debuffs = function(_, self) return 'string', State.myDebuffs end,
                Role = function(_, self) return 'string', State.role end,
                MainAssist = function(_, self) return 'string', State.mainAssist end,
                Target = function(_, self) return 'int', State.myTargetId end,
                HealTank = function(_, self) return 'string', State.healTank end,
                Version = function(_, self) return 'string', VERSION end,
                Paused = function(_, self) return 'bool', State.paused end,
                -- the macro-variable view for MALua: ${MuleAssist.Var[KillOrderList]} etc.
                Var = function(name, self) return 'string', require('core.vars').get(name) end,
            },
            ToString = function() return 'MuleAssist ' .. VERSION end,
        })
        -- MQ requires a TLO function to take exactly one parameter (the [index]); zero fails registration
        mq.AddTopLevelObject('MuleAssist', function(_index) return MAType, State end)
    end)
    tloOk = ok
    if not ok then Log.warn('MuleAssist TLO not registered: %s', tostring(err)) end
end

-- ------------------------------------------------------------- binds
local running = true
mq.bind('/muleassist', function(cmd)
    cmd = tostring(cmd or ''):lower()
    if cmd == 'stop' or cmd == 'end' then running = false
    elseif cmd == 'pause' then State.paused = true Log.info('paused')
    elseif cmd == 'resume' or cmd == 'unpause' then State.paused = false Log.info('resumed')
    elseif cmd == 'reload' then
        Config.round(function() Cast.LoadSettings() Modules.execAll('LoadSettings') end)
        Log.info('settings reloaded')
    else
        Log.info('muleassist %s - role %s, %s, TLO %s. /muleassist pause|resume|reload|stop', VERSION, State.role, State.paused and 'paused' or 'running', tloOk and 'on' or 'off')
    end
end)
mq.bind('/whynot', function()
    local list = Log.whyNotList()
    if #list == 0 then Log.info('[WhyNot] nothing recorded yet') return end
    Log.info('[WhyNot] skipped casts, newest first:')
    for _, l in ipairs(list) do print('  ' .. l) end
end)
Modules.bindAll(mq)

-- ------------------------------------------------------------- boot
Cast.registerEvents()
Modules.execAll('Init')
Modules.execAll('LoadSettings')
Config.endRound()   -- later reads (binds, OnZone) go to the TLO again, so INI edits made since are seen
Modules.execAll('Boot')   -- one-time work that registers callbacks, on the main coroutine (SmartDPS, Vesagran)
Log.info('muleassist %s running (role %s, ini %s)', VERSION, State.role, Config.iniFile)
require('modules.misc'):onStart()
require('modules.misc'):loadSpellSet()
if T.num(function() return mq.TLO.Me.XTarget() end) == 0 then Log.warn('No Auto Hater slot on your Extended Target Window - set at least 1 slot to Auto.') end

local lastZone = T.zoneId()
local wasCombat = false
while running do
    mq.doevents()
    if require('modules.misc').stopRequested then running = false end
    local gs = T.str(function() return mq.TLO.MacroQuest.GameState() end)
    if gs ~= 'INGAME' then
        mq.delay(1000)
    else
        local zone = T.zoneId()
        if zone ~= lastZone then
            lastZone = zone
            Modules.execAll('OnZone')
        end
        local inCombat = T.inCombat()
        if inCombat and not wasCombat then Modules.execAll('OnCombatStart') end
        if not inCombat and wasCombat then Modules.execAll('OnCombatEnd') end
        wasCombat = inCombat
        Modules.execAll('Tick', { inCombat = inCombat })
        if not State.paused then
            Modules.execAll('GiveTime', { inCombat = inCombat })
        end
        mq.delay(LOOP_MS)
    end
end

Modules.execAll('Shutdown')
Observe.releaseAll()
mq.unbind('/muleassist')
mq.unbind('/whynot')
Log.info('muleassist stopped.')
