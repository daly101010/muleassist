local mq = require('mq')
local globals = require('muleassist.ui.globals')

local utils = {}

-- Helper functions
utils.printf = function(...)
    print(string.format(...))
end

utils.Split = function(input, sep, limit, bRegexp)
    assert(sep ~= '')
    assert(limit == nil or limit >= 1)

    local aRecord = {}

    if input:len() > 0 then
        local bPlain = not bRegexp
        limit = limit or -1

        local nField, nStart = 1, 1
        local nFirst,nLast = input:find(sep, nStart, bPlain)
        while nFirst and limit ~= 0 do
            aRecord[nField] = input:sub(nStart, nFirst-1)
            nField = nField+1
            nStart = nLast+1
            nFirst,nLast = input:find(sep, nStart, bPlain)
            limit = limit-1
        end
        aRecord[nField] = input:sub(nStart)
    end

    return aRecord
end

utils.ReadRawINIFile = function()
    local f = io.open(mq.configDir..'/'..globals.INIFile, 'r')
    local contents = f:read('*a')
    io.close(f)
    return contents
end

utils.WriteRawINIFile = function(contents)
    local f = io.open(mq.configDir..'/'..globals.INIFile, 'w')
    f:write(contents)
    io.close(f)
end

utils.FileExists = function(path)
    local f = io.open(path, "r")
    if f ~= nil then io.close(f) return true else return false end
end

utils.CopyFile = function(source, dest)
    local f = io.open(source, 'r')
    local contents = f:read('*a')
    io.close(f)
    f = io.open(dest, 'w')
    f:write(contents)
    io.close(f)
end

utils.FindINIFile = function()
    if globals.CurrentSchema == 'ma' then
        if utils.FileExists(mq.configDir..'/'..globals.Schema['INI_PATTERNS']['nolevel']:format(globals.MyServer, globals.MyName)) then
            return globals.Schema['INI_PATTERNS']['nolevel']:format(globals.MyServer, globals.MyName)
        elseif utils.FileExists(mq.configDir..'/'..globals.Schema['INI_PATTERNS']['level']:format(globals.MyServer, globals.MyName, globals.MyLevel)) then
            return globals.Schema['INI_PATTERNS']['level']:format(globals.MyServer, globals.MyName, globals.MyLevel)
        else
            local fileLevel = globals.MyLevel-1
            repeat
                local fileName = globals.Schema['INI_PATTERNS']['level']:format(globals.MyServer, globals.MyName, fileLevel)
                if utils.FileExists(mq.configDir..'/'..fileName) then
                    local targetFileName = globals.Schema['INI_PATTERNS']['level']:format(globals.MyServer, globals.MyName, globals.MyLevel)
                    utils.CopyFile(mq.configDir..'/'..fileName, mq.configDir..'/'..targetFileName)
                    utils.printf('Copying %s to %s', fileName, targetFileName)
                    return targetFileName
                end
                fileLevel = fileLevel-1
            until fileLevel == globals.MyLevel-10
        end
    elseif globals.CurrentSchema == 'ka' then
        if utils.FileExists(mq.configDir..'/'..globals.Schema['INI_PATTERNS']['nolevel']:format(globals.MyName)) then
            return globals.Schema['INI_PATTERNS']['nolevel']:format(globals.MyName)
        end
    end
end

utils.HelpMarker = function(desc)
    ImGui.TextDisabled('(?)')
    if ImGui.IsItemHovered() then
        ImGui.BeginTooltip()
        ImGui.PushTextWrapPos(ImGui.GetFontSize() * 35.0)
        ImGui.Text('%s', desc)
        ImGui.PopTextWrapPos()
        ImGui.EndTooltip()
    end
end

-- convert INI 0/1 to true/false for ImGui checkboxes
utils.InitCheckBoxValue = function(value)
    if value then
        if type(value) == 'boolean' then return value end
        if type(value) == 'number' then return value ~= 0 end
        if type(value) == 'string' and value:upper() == 'TRUE' then return true else return false end
    else
        return false
    end
end

return utils
