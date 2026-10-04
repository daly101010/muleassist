-- File logging is always enabled; console output is opt-in for this session.
local M = {}

function M.new(path, output)
    local self = { console = false, lastError = nil, path = path }
    output = output or print
    function self.write(fmt, ...)
        local message = string.format(fmt, ...)
        local plain = message:gsub('\a%-?[%w]', '')
        local file, err = io.open(path, 'a')
        if file then
            local ok, writeErr = file:write(os.date('[%Y-%m-%d %H:%M:%S] '), '[necrobrain] ', plain, '\n')
            local closed, closeErr = file:close()
            self.lastError = (not ok and writeErr) or (not closed and closeErr) or nil
        else
            self.lastError = err
        end
        if self.console then output('\ay[necrobrain]\ax ' .. message) end
        return self.lastError == nil, self.lastError
    end
    return self
end

local default
local function instance()
    if not default then
        local mq = require('mq')
        local function safe(value)
            return tostring(value or 'unknown'):gsub('[^%w_.%-]', '_')
        end
        local server = mq.TLO.EverQuest.Server()
        local character = mq.TLO.Me.CleanName()
        default = M.new(string.format('%s/necrobrain_%s_%s.log', mq.configDir, safe(server), safe(character)))
    end
    return default
end

function M.write(...) return instance().write(...) end
function M.setConsole(enabled) instance().console = enabled == true end
function M.path() return instance().path end

return M
