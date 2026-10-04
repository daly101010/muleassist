-- smartheal/env.lua: the one place the forked SmartHeals engine meets the Lua bot (spec
-- muleassist/docs/superpowers/specs/2026-10-02-luaport-smartheal-fork-design.md). The engine's SideKick
-- touch points (settings, the actors coordinator, file roots) resolve here.
local mq = require('mq')

local M = {}

M.ROOT = 'MuleAssist'            -- config/MuleAssist: profile, learned data, logs
M.IMPORT_ROOT = 'SideKick-Next'  -- read once to import, never written

local tankFn = function() return false end
local settings = { CombatMode = 'off' }

--- fn() -> true while this bot is a tank role (sidekick's CombatMode == 'tank' gate).
function M.setTank(fn) tankFn = fn or function() return false end end

function M.isTank()
    local ok, v = pcall(tankFn)
    return ok and v == true
end

--- The table the engine reads as sidekick's Core.Settings / sk_lib.getSettings().
function M.settings()
    settings.CombatMode = M.isTank() and 'tank' or 'off'
    return settings
end

function M.rootDir() return (mq.configDir or 'config') .. '/' .. M.ROOT end
function M.importRootDir() return (mq.configDir or 'config') .. '/' .. M.IMPORT_ROOT end

function M.log(fmt, ...)
    local ok, Log = pcall(require, 'core.log')
    if ok and Log and Log.info then Log.info(fmt, ...) else print(string.format(fmt, ...)) end
end

-- sidekick's actors coordinator, inert: no peers, every claim is ours, every other call is a no-op.
local noop = function() end
local coordinator = setmetatable({
    getRemoteCharacters = function() return {} end,
    getHoTStates = function() return {} end,
    isClaimWinner = function() return true end,
    -- every method whose return value the engine reads, explicit and neutral:
    isHealClaimWinner = function() return true, nil end,  -- init.lua M.isClaimWinner (won, winner)
    getPullState = function() return nil end,             -- init.lua pre-pull: nil -> scan locally
    getTankState = function() return nil end,             -- init.lua pre-pull: nil -> no remote tank
    publish = function() end,
    sendWorkerCommand = function() end,
}, { __index = function() return noop end })

function M.coordinator() return coordinator end

return M
