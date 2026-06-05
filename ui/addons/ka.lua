-- Stop, don't look at this! Just some WIP stuff, nothing to see here.
--- @type Mq
local mq = require('mq')
local globals = require('muleassist.ui.globals')
local utils = require('muleassist.ui.utils')
local LIP = require('muleassist.ui.lib.LIP')

local function DrawRawINIEditTab()
    if ImGui.IsItemHovered() and ImGui.IsMouseReleased(0) then
        if utils.FileExists(mq.configDir..'/'..globals.INIFile) then
            globals.INIFileContents = utils.ReadRawINIFile()
        end
    end
    if ImGui.Button('Refresh Raw INI##rawini') then
        if utils.FileExists(mq.configDir..'/'..globals.INIFile) then
            globals.INIFileContents = utils.ReadRawINIFile()
        end
    end
    ImGui.SameLine()
    if ImGui.Button('Save Raw INI##rawini') then
        utils.WriteRawINIFile(globals.INIFileContents)
        globals.Config = LIP.load(mq.configDir..'/'..globals.INIFile)
    end
    local x,y = ImGui.GetContentRegionAvail()
    globals.INIFileContents,_ = ImGui.InputTextMultiline("##rawinput", globals.INIFileContents or '', x-15, y-15, ImGuiInputTextFlags.None)
end

-- Define this down here since the functions need to be defined first
local customSections = {
    ['Raw INI']=DrawRawINIEditTab,
}

return customSections
