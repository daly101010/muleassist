-- smartheal/util/paths.lua: where the forked SmartHeals engine keeps its files (replaces sidekick-next's
-- utils/paths.lua, which also carries SideKick migrations). Root config/MuleAssist. The heal profile and
-- learned data are imported once from config/SideKick-Next when the MuleAssist copy is missing or empty.
local mq = require('mq')
local Env = require('smartheal.env')

local M = {}

function M.normalize(path)
    return (tostring(path or ''):gsub('\\', '/'):gsub('/+', '/'))
end

local function join(base, child) return M.normalize(base .. '/' .. child) end

local function charInfo()
    local char = mq.TLO.Me.CleanName()
    if not char or char == '' then char = 'Character' end
    local server = mq.TLO.EverQuest.Server()
    if not server or server == '' then server = 'Server' end
    return tostring(char), (tostring(server):gsub(' ', '_'))
end

local function directoryExists(path, lfs)
    if lfs and lfs.attributes then
        local ok, mode = pcall(lfs.attributes, path, 'mode')
        if ok and mode == 'directory' then return true end
    end
    local ok, _, code = os.rename(path, path)
    -- Windows can return access denied for an existing protected directory.
    return ok == true or tonumber(code) == 13
end

function M.ensureDir(path)
    path = M.normalize(path):gsub('/+$', '')
    if path == '' then return false, 'empty_path' end

    local ok, lfs = pcall(require, 'lfs')
    if directoryExists(path, ok and lfs or nil) then return true end

    -- Try lfs first for cleaner creation (C call, no subprocess).
    if ok and lfs and lfs.mkdir then
        local drive, remainder = path:match('^(%a:)/(.*)$')
        local current
        if drive then
            current = drive .. '/'
        elseif path:sub(1, 2) == '//' then
            current = '//'
            remainder = path:sub(3)
        elseif path:sub(1, 1) == '/' then
            current = '/'
            remainder = path:sub(2)
        else
            current = ''
            remainder = path
        end
        for part in remainder:gmatch('[^/]+') do
            if current == '' then
                current = part
            elseif current == '//' then
                current = current .. part
            else
                current = current:gsub('/+$', '') .. '/' .. part
            end
            pcall(lfs.mkdir, current)
        end
    else
        -- Last resort: os.execute (spawns cmd.exe, can be slow with antivirus)
        os.execute('mkdir "' .. path .. '" >nul 2>nul')
    end

    -- Verify creation without a shared marker file. Every worker initializes
    -- concurrently, so a fixed probe filename creates an avoidable startup
    -- race between open/remove calls in separate Lua processes.
    if directoryExists(path, ok and lfs or nil) then return true end
    return false, 'directory_unavailable:' .. path
end

local function hasContent(path)
    local f = io.open(path, 'rb')
    if not f then return false end
    local size = f:seek('end')
    f:close()
    return (size or 0) > 0
end

--- Copy the SideKick-Next file once when ours is missing or empty; never written back.
local function importOnce(destination, source)
    if hasContent(destination) or not hasContent(source) then return end
    local f = io.open(source, 'rb')
    if not f then return end
    local content = f:read('a')
    f:close()
    require('smartheal.util.safe_write')(destination, content)
    Env.log('[SmartHeal] imported %s from SideKick-Next', destination:match('[^/]+$') or destination)
end

function M.getRootDir() return M.normalize(Env.rootDir()) end
function M.getHealingDir() return join(M.getRootDir(), 'healing') end
function M.getHealingLogDir() return join(M.getRootDir(), 'HealingLogs') end
function M.getLogsDir() return join(M.getRootDir(), 'logs') end

function M.getHealingConfigPath()
    local char, server = charInfo()
    M.ensureDir(M.getHealingDir())
    local path = string.format('%s/config_%s_%s.lua', M.getHealingDir(), server, char)
    importOnce(path, string.format('%s/healing/config_%s_%s.lua', M.normalize(Env.importRootDir()), server, char))
    return path
end

function M.getHealingDataPath()
    local char, server = charInfo()
    M.ensureDir(M.getHealingDir())
    local path = string.format('%s/data_%s_%s.lua', M.getHealingDir(), server, char)
    importOnce(path, string.format('%s/healing/data_%s_%s.lua', M.normalize(Env.importRootDir()), server, char))
    return path
end

function M.getMobAssessorPath()
    M.ensureDir(M.getHealingDir())
    return M.getHealingDir() .. '/mob_assessor.lua'
end

function M.getLogPath(category, date)
    local char, server = charInfo()
    local dir = join(M.getLogsDir(), tostring(category or 'debug'))
    M.ensureDir(dir)
    return string.format('%s/%s_%s_%s.log', dir, server, char, tostring(date or os.date('%Y-%m-%d')))
end

return M
