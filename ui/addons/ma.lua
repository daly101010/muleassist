--- @type Mq
local mq = require('mq')
local globals = require('muleassist.ui.globals')
local utils = require('muleassist.ui.utils')
local LIP = require('muleassist.ui.lib.LIP')

local TABLE_FLAGS = bit32.bor(ImGuiTableFlags.Hideable, ImGuiTableFlags.RowBg, ImGuiTableFlags.ScrollY, ImGuiTableFlags.BordersOuter)
local LEMONS_INFO_INI = mq.configDir..'/Lemons_Info.ini'
local MA_LISTS = {'FireMobs','ColdMobs','MagicMobs','PoisonMobs','DiseaseMobs','SlowMobs'}

local lemons_info = {}
local DEBUG = {all=false,dps=false,heal=false,buff=false,cast=false,combat=false,move=false,mez=false,pet=false,pull=false,chain=false,target=false}
local debugCaptureTime = '60'

local selectedDebug = 'all' -- debug dropdown menu selection
local selectedSharedList = nil -- shared lists table selected list
local selectedSharedListItem = nil -- shared lists list table selected entry

if utils.FileExists(LEMONS_INFO_INI) then
    lemons_info = LIP.load(LEMONS_INFO_INI, true)
end

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
        globals.INILoadError = ''
    end
    local x,y = ImGui.GetContentRegionAvail()
    globals.INIFileContents,_ = ImGui.InputTextMultiline("##rawinput", globals.INIFileContents or '', x-15, y-15, ImGuiInputTextFlags.None)
end

local function DrawListsTab()
    ImGui.PushTextWrapPos(ImGui.GetContentRegionAvail()-10)
    ImGui.TextColored(0, 1, 1, 1, "View shared list content from Lemons_Info.ini. To add entries, use the macro /addxyz commands and click reload.")
    ImGui.PopTextWrapPos()
    ImGui.Text('Select a list below to edit:')
    ImGui.SameLine()
    if ImGui.SmallButton('Save Lemons INI') then
        LIP.save(LEMONS_INFO_INI, lemons_info, globals.Schema)
    end
    ImGui.SameLine()
    if ImGui.SmallButton('Reload Lemons INI') then
        if utils.FileExists(LEMONS_INFO_INI) then
            lemons_info = LIP.load(LEMONS_INFO_INI, true)
        end
    end
    if ImGui.BeginTable('ListSelectionTable', 1, TABLE_FLAGS, 0, 150, 0.0) then
        ImGui.TableSetupColumn('List Name',     0,   -1.0, 1)
        ImGui.TableSetupScrollFreeze(0, 1) -- Make row always visible
        ImGui.TableHeadersRow()
        local clipper = ImGuiListClipper.new()
        clipper:Begin(#MA_LISTS)
        while clipper:Step() do
            for row_n = clipper.DisplayStart, clipper.DisplayEnd - 1, 1 do
                local clipName = MA_LISTS[row_n+1]
                ImGui.PushID(clipName)
                ImGui.TableNextRow()
                ImGui.TableNextColumn()
                local sel = ImGui.Selectable(clipName, selectedSharedList == clipName)
                if sel then
                    selectedSharedList = clipName
                end
                ImGui.PopID()
            end
        end
        ImGui.EndTable()
    end
    if selectedSharedList ~= nil then
        ImGui.TextColored(1, 1, 0, 1, selectedSharedList)
        ImGui.SameLine()
        ImGui.SetCursorPosX(100)
        ImGui.SameLine()
        if ImGui.SmallButton('Remove Selected') then
            lemons_info[selectedSharedList][selectedSharedListItem] = nil
        end
        if ImGui.BeginTable('SelectedListTable', 1, TABLE_FLAGS, 0, 0, 0.0) then
            ImGui.TableSetupColumn('Mob or Zone Short Name',     0,   -1.0, 1)
            ImGui.TableSetupScrollFreeze(0, 1) -- Make row always visible
            ImGui.TableHeadersRow()
            if lemons_info[selectedSharedList] then
                for key,_ in pairs(lemons_info[selectedSharedList]) do
                    ImGui.TableNextRow()
                    ImGui.TableNextColumn()
                    local sel = ImGui.Selectable(key, selectedSharedListItem == key)
                    if sel then
                        selectedSharedListItem = key
                    end
                end
            end
            ImGui.EndTable()
        end
    end
end

local function DrawDebugTab()
    local debuginput = ''
    for i,j in pairs(DEBUG) do
        if j then debuginput = debuginput..i end
    end
    if ImGui.BeginCombo('Debug Categories', debuginput) then
        for i,j in pairs(DEBUG) do
            DEBUG[i] = ImGui.Checkbox(i, j)
        end
        ImGui.EndCombo()
    end
    debugCaptureTime = ImGui.InputText('Debug Capture Time', debugCaptureTime)
    if selectedDebug then
        if ImGui.Button('Enable Debug') then
            debuginput = ''
            for i,j in pairs(DEBUG) do
                if j then debuginput = debuginput..i end
            end
            mq.cmdf('/writedebug %s %s', debuginput, debugCaptureTime)
        end
    end
end

local function ConvertListProperty(section, imported_config, section_name, prop_name, prop_config)
    local cond_found = false
    section[prop_name..'Size'] = imported_config[section_name][prop_name..'Size']
    for i=1,prop_config.Max do
        if imported_config[section_name][prop_name..tostring(i)] then
            local idx = tostring(i)
            local value = imported_config[section_name][prop_name..idx]
            -- Some ugly code to shuffle conditions around from KA's KConditions to the appropriate spots
            if value:lower():find('|cond') then
                local valueParts = utils.Split(value, '|')
                for _,part in ipairs(valueParts) do
                    if part:lower():find('cond') then
                        local condition = imported_config['KConditions'][part:lower()]
                        section[prop_name..'Cond'..idx] = condition
                        value,_ = value:gsub('|'..part, '')
                        cond_found = true
                    end
                end
            end
            section[prop_name..idx] = value
        end
    end
    if cond_found then
        -- If any values in the list had a condition, enable conditions for the section
        section[section_name..'COn'] = true
        for i=1,prop_config.Max do
            -- If any value in the list had no condition, default the condition to "TRUE"
            local idx = tostring(i)
            if section[prop_name..idx] and not section[prop_name..'Cond'..idx] then
                section[prop_name..'Cond'..idx] = "TRUE"
            end
        end
    else
        section[section_name..'COn'] = false
    end
end

local function ConvertINISection(imported_config, section_name)
    local section = {}
    if globals.Schema[section_name].Controls then
        for control_name, _ in pairs(globals.Schema[section_name].Controls) do
            if control_name ~= 'COn' then
                section[section_name..control_name] = imported_config[section_name][section_name..control_name]
            end
        end
    end
    for prop_name, prop_config in pairs(globals.Schema[section_name].Properties) do
        if prop_config.Type == 'LIST' then
            ConvertListProperty(section, imported_config, section_name, prop_name, prop_config)
        else
            if imported_config[section_name][prop_name] then
                section[prop_name] = imported_config[section_name][prop_name]
            end
        end
    end
    return section
end

local function PrepareConditions(imported_config)
    if imported_config['KConditions'] then
        for key,_ in pairs(imported_config['KConditions']) do
            if key:find('Cond') then
                imported_config['KConditions'][key:lower()] = imported_config['KConditions'][key]
            end
        end
    end
end

local function ConvertINI(imported_config)
    local ok = true
    local config = {}

    PrepareConditions(imported_config)
    for _,section_name in ipairs(globals.Schema.Sections) do
        if globals.Schema[section_name] and imported_config[section_name] then
            config[section_name] = ConvertINISection(imported_config, section_name)
        end
    end

    -- What sort of failure conditions might there be for importing an existing KA INI file?
    return ok, config
end

local ImportINIFile = ''
local ImportRan = false
local ImportMessage = ''
local ImportSucceeded = false
local function DrawImportKAINI()
    ImGui.Text('Enter the name of a KissAssist INI File to import... (Ex. KissAssist_Toonname.ini)')
    ImportINIFile = ImGui.InputText('Import INI File Name', ImportINIFile)
    if ImGui.Button('Import INI') then
        ImportRan = true
        if ImportINIFile:sub(-string.len('.ini')) ~= '.ini' then
            ImportINIFile = ImportINIFile .. '.ini'
        end
        if utils.FileExists(mq.configDir..'/'..ImportINIFile) then
            local imported_config = LIP.load(mq.configDir..'/'..ImportINIFile, false)
            print('Importing configuration from KA to MA using INI file: '..ImportINIFile)
            local ok, result = ConvertINI(imported_config)
            if ok then
                globals.Config = result
                ImportMessage = 'Import Succeeded! Run the macro once to initialize any remaining INI values, then reload the INI.'
                ImportSucceeded = true
            else
                print('Import failed!')
                ImportMessage = 'Import failed!'
                ImportSucceeded = false
            end
        else
            ImportSucceeded = false
            ImportMessage = 'Failure! File does not exist.'
        end
    end
    if ImportRan then
        if ImportSucceeded then
            ImGui.TextColored(0, 1, 0, 1, ImportMessage)
        else
            ImGui.TextColored(1, 0, 0, 1, ImportMessage)
        end
    end
end

local THEMES = {'default','red'}
local function DrawThemeMenu()
    ImGui.Text('Just for fun')
    if ImGui.BeginCombo('Themes', globals.Theme) then
        for _,j in pairs(THEMES) do
            if ImGui.Selectable(j, j == globals.Theme) then
                globals.Theme = j
            end
        end
        ImGui.EndCombo()
    end
end

-- Define this down here since the functions need to be defined first
local customSections = {
    ['Raw INI']=DrawRawINIEditTab,
    ['Shared Lists']=DrawListsTab,
    ['Debug']=DrawDebugTab,
    ['Import KA INI']=DrawImportKAINI,
    ['Theme']=DrawThemeMenu,
}

return customSections
