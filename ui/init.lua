local mq = require('mq')
require('ImGui')

-- LFS must be downloaded from the luarocks server before anything can work
-- so do that first. This will open a dialog prompting to download lfs.dll
-- if not already present.
-- Include helper function so we can give user friendly messages
local PackageMan = require('mq.PackageMan')
PackageMan.Require('luafilesystem', 'lfs', 'Failed to install or load lfs.dll. Check the FAQ at https://www.redguides.com/community/resources/maui-muleassist-ui.2207/field?field=faq')

local LIP = require('muleassist.ui.lib.LIP')
local globals = require('muleassist.ui.globals')
local utils = require('muleassist.ui.utils')
local filedialog = require('muleassist.ui.lib.imguifiledialog')
local cache = require('muleassist.ui.lib.cache')
local serialize = require('muleassist.serialize')
local cond_model = require('muleassist.cond_model')
local diff = require('muleassist.ui.diff')

local M = {}                 -- module export (mount/toggle for embedding)
local apply_opts = nil       -- set by M.mount; holds on_apply callback
local cfg_snapshot = nil     -- last-applied snapshot of globals.Config
local apply_db = diff.debouncer(0.75)
local trees_built = false

globals.CurrentSchema = 'ma'
globals.Schema = require('muleassist.ui.schemas.'..globals.CurrentSchema)

-- Animations for drawing spell/item icons
local animSpellIcons = mq.FindTextureAnimation('A_SpellIcons')
local animItems = mq.FindTextureAnimation('A_DragItem')
-- Blue and yellow icon border textures
local animBlueWndPieces = mq.FindTextureAnimation('BlueIconBackground')
animBlueWndPieces:SetTextureCell(1)
local animYellowWndPieces = mq.FindTextureAnimation('YellowIconBackground')
animYellowWndPieces:SetTextureCell(1)
local animRedWndPieces = mq.FindTextureAnimation('RedIconBackground')
animRedWndPieces:SetTextureCell(1)

-- UI State
local open = true
local shouldDrawUI = true
local terminate = false
local initialRun = true
local leftPanelDefaultWidth = 150
local leftPanelWidth = 150

local selectedListItem = {nil, 0} -- {key, index}
local selectedUpgrade = nil
local selectedSection = 'General' -- Left hand menu selected item

local tloCache = cache:new(300, 300)

globals.MyServer = mq.TLO.EverQuest.Server()
globals.MyName = mq.TLO.Me.CleanName()
globals.MyLevel = mq.TLO.Me.Level()
globals.MyClass = mq.TLO.Me.Class.ShortName():lower()

globals.MAUI_INI = ('%s/%s_%s.ini'):format(mq.configDir, globals.MyServer, globals.MyName)
local maui_ini_key = 'MAUI'
if utils.FileExists(globals.MAUI_INI) then
    globals.MAUI_Config = LIP.load(globals.MAUI_INI, false)
end
if not globals.MAUI_Config or not globals.MAUI_Config[maui_ini_key] or not globals.MAUI_Config[maui_ini_key]['StartCommand'] then
    globals.MAUI_Config = {[maui_ini_key] = {['StartCommand'] = globals.Schema['StartCommands'][1],}}
end

local selected_start_command = nil
for _,startcommand in ipairs(globals.Schema['StartCommands']) do
    if startcommand == globals.MAUI_Config[maui_ini_key]['StartCommand'] then
        selected_start_command = startcommand
    end
end
if not selected_start_command then
    if globals.MAUI_Config[maui_ini_key]['StartCommand'] then
        selected_start_command = 'custom'
    else
        selected_start_command = globals.Schema['StartCommands'][1]
    end
end

-- Storage for spell/AA/disc picker
local spells, altAbilities, discs = {categories={}},{types={}},{categories={}}
local aatypes = {'General','Archtype','Class','Special','Focus','Merc'}

local useRankNames = false

local TABLE_FLAGS = bit32.bor(ImGuiTableFlags.Hideable, ImGuiTableFlags.RowBg, ImGuiTableFlags.ScrollY, ImGuiTableFlags.BordersOuter)

--local customSections = require('ma.addons.'..globals.CurrentSchema)
local ok, customSections = pcall(require, 'muleassist.ui.addons.'..globals.CurrentSchema)
if not ok then customSections = nil end

local function SaveMAUIConfig()
    -- Reload the maui.ini before saving to try and prevent writing stale data
    local tmpStartCommand = globals.MAUI_Config[maui_ini_key]['StartCommand']
    if utils.FileExists(globals.MAUI_INI) then
        globals.MAUI_Config = LIP.load(globals.MAUI_INI, false)
    else
        globals.MAUI_Config = {}
    end
    globals.MAUI_Config[maui_ini_key] = {['StartCommand'] = tmpStartCommand, ['INIFile'] = globals.INIFile}
    LIP.save_simple(globals.MAUI_INI, globals.MAUI_Config)
end

local function Save()
    -- Set "NULL" string values to nil so they aren't saved
    for sectionName,sectionProperties in pairs(globals.Config) do
        for key,value in pairs(sectionProperties) do
            if value == 'NULL' then
                -- Replace and XYZCond#=FALSE with nil as well if no corresponding XYZ# value
                local word = string.match(key, '[^%d]+')
                local number = string.match(key, '%d+')
                if number then
                    globals.Config[sectionName][word..'Cond'..number] = nil
                end
                globals.Config[sectionName][key] = nil
            end
        end
    end
    if globals.INIFile:sub(-string.len('.ini')) ~= '.ini' then
        globals.INIFile = globals.INIFile .. '.ini'
    end
    LIP.save(mq.configDir..'/'..globals.INIFile, globals.Config, globals.Schema)
    SaveMAUIConfig()
end

-- Sort spells by level
local SpellSorter = function(a, b)
    -- spell level is in spell[1], name in spell[2]
    if a[1] < b[1] then
        return false
    elseif b[1] < a[1] then
        return true
    else
        return false
    end
end

local function AddSpellToMap(spell)
    local cat = spell.Category()
    local subcat = spell.Subcategory()
    if not spells[cat] then
        spells[cat] = {subcategories={}}
        table.insert(spells.categories, cat)
    end
    if not spells[cat][subcat] then
        spells[cat][subcat] = {}
        table.insert(spells[cat].subcategories, subcat)
    end
    --if spell.Level() >= globals.MyLevel-30 then
        local name = spell.Name():gsub(' Rk%..*', '')
        table.insert(spells[cat][subcat], {spell.Level(), name, spell.Name()})
    --end
end

local function SortMap(map)
    -- sort categories and subcategories alphabetically, spells by level
    table.sort(map.categories)
    for category,subcategories in pairs(map) do
        if category ~= 'categories' then
            table.sort(map[category].subcategories)
            for subcategory,subcatspells in pairs(subcategories) do
                if subcategory ~= 'subcategories' then
                    table.sort(subcatspells, SpellSorter)
                end
            end
        end
    end
end

-- Ability menu initializers
local function InitSpellTree()
    -- Build spell tree for picking spells
    for spellIter=1,1120 do
        local spell = mq.TLO.Me.Book(spellIter)
        if spell() then
            AddSpellToMap(spell)
        end
    end
    SortMap(spells)
end

local function AddAAToMap(aa)
    local type = aatypes[aa.Type()]
    if not altAbilities[type] then
        altAbilities[type] = {}
        table.insert(altAbilities.types, type)
    end
    table.insert(altAbilities[type], {aa.Name(),aa.Spell.Name()})
end

local function InitAATree()
    -- TODO: what's the right way to loop through activated abilities?
    for aaIter=1,10000 do
        local aa = mq.TLO.Me.AltAbility(aaIter)
        if aa.Spell() then
            AddAAToMap(aa)
        end
    end
    for _,type in ipairs(altAbilities.types) do
        if altAbilities[type] then
            table.sort(altAbilities[type], function(a,b) return a[1] < b[1] end)
        end
    end
end

local function AddDiscToMap(disc)
    local cat = disc.Category()
    local subcat = disc.Subcategory()
    if not discs[cat] then
        discs[cat] = {subcategories={}}
        table.insert(discs.categories, cat)
    end
    if not discs[cat][subcat] then
        discs[cat][subcat] = {}
        table.insert(discs[cat].subcategories, subcat)
    end
    local name = disc.Name():gsub(' Rk%..*', '')
    table.insert(discs[cat][subcat], {disc.Level(), name, disc.Name()})
end

local function InitDiscTree()
    local discIter = 1
    repeat
        local disc = mq.TLO.Me.CombatAbility(discIter)
        if disc() then
            AddDiscToMap(disc)
        end
        discIter = discIter + 1
    until mq.TLO.Me.CombatAbility(discIter)() == nil
    SortMap(discs)
end

--Given some spell data input, determine whether a better spell with the same inputs exists
local function GetSpellUpgrade(targetType, subCat, numEffects, minLevel)
    local max = 0
    local max2 = 0
    local maxName = ''
    local maxLevel = 0
    for i=1,1120 do
        local valid = true
        local spell = mq.TLO.Me.Book(i)
        if not spell.ID() then
            valid = false
        elseif spell.Subcategory() ~= subCat then
            valid = false
        elseif spell.TargetType() ~= targetType then
            valid = false
        elseif spell.NumEffects() ~= numEffects then
            valid = false
        elseif spell.Level() <= minLevel then
            valid = false
        end
        if valid then
            -- TODO: several trigger spells i don't think this would handle properly...
            -- 470 == trigger best in spell group
            -- 374 == trigger spell
            -- 340 == chance spell
            if spell.HasSPA(470)() or spell.HasSPA(374)() or spell.HasSPA(340)() then
                for eIdx=1,spell.NumEffects() do
                    if spell.Trigger(eIdx)() then
                        for SPAIdx=1,spell.Trigger(eIdx).NumEffects() do
                            if spell.Trigger(eIdx).Base(SPAIdx)() < -1 then
                                if spell.Trigger(eIdx).Base(SPAIdx)() < max then
                                    max = spell.Trigger(eIdx).Base(SPAIdx)()
                                    maxName = spell.Name():gsub(' Rk%..*', '')
                                end
                            else
                                if spell.Trigger(eIdx).Base(SPAIdx)() > max then
                                    max = spell.Trigger(eIdx).Base(SPAIdx)()
                                    maxName = spell.Name():gsub(' Rk%..*', '')
                                end
                            end
                        end
                    end
                end
                -- TODO: this won't handle spells whos trigger SPA is just the illusion portion
            else
                for SPAIdx=1,spell.NumEffects() do
                    --print(string.format('[%s] .Base: %d, Base2: %d, Max: %d', spell.Name(), spell.Base(SPAIdx)(), spell.Base2(SPAIdx)(), spell.Max(SPAIdx)()))
                    if spell.Base(SPAIdx)() < -1 then
                        if spell.Base(SPAIdx)() < max then
                            max = spell.Base(SPAIdx)()
                            maxName = spell.Name():gsub(' Rk%..*', '')
                        elseif spell.Base2(SPAIdx)() ~= 0 and spell.Base2(SPAIdx)() > max2 then
                            max2 = spell.Base2(SPAIdx)()
                            maxName = spell.Name():gsub(' Rk%..*', '')
                        end
                    else
                        if spell.Base(SPAIdx)() > max then
                            max = spell.Base(SPAIdx)()
                            maxName = spell.Name():gsub(' Rk%..*', '')
                        elseif spell.Base2(SPAIdx)() ~= 0 and spell.Base2(SPAIdx)() > max2 then
                            max2 = spell.Base2(SPAIdx)()
                            maxName = spell.Name():gsub(' Rk%..*', '')
                        end
                    end
                end
            end
        end
    end
    return maxName
end

-- ImGui functions

-- Color spell names in spell picker similar to the spell bar context menus
local function SetSpellTextColor(spell)
    local target = tloCache:get(spell..'.targettype', function() return mq.TLO.Spell(spell).TargetType() end)
    if target == 'Single' or target == 'Line of Sight' or target == 'Undead' then
        ImGui.PushStyleColor(ImGuiCol.Text, 1, 0, 0, 1)
    elseif target == 'Self' then
        ImGui.PushStyleColor(ImGuiCol.Text, 1, 1, 0, 1)
    elseif target == 'Group v2' or target == 'Group v1' or target == 'AE PC v2' then
        ImGui.PushStyleColor(ImGuiCol.Text, 1, 0, 1, 1)
    elseif target == 'Beam' then
        ImGui.PushStyleColor(ImGuiCol.Text, 0, 1, 1, 1)
    elseif target == 'Targeted AE' then
        ImGui.PushStyleColor(ImGuiCol.Text, 1, 0.5, 0, 1)
    elseif target == 'PB AE' then
        ImGui.PushStyleColor(ImGuiCol.Text, 0, 0.5, 1, 1)
    elseif target == 'Pet' then
        ImGui.PushStyleColor(ImGuiCol.Text, 1, 0, 0, 1)
    elseif target == 'Pet2' then
        ImGui.PushStyleColor(ImGuiCol.Text, 1, 0, 0, 1)
    elseif target == 'Free Target' then
        ImGui.PushStyleColor(ImGuiCol.Text, 0, 1, 0, 1)
    else
        ImGui.PushStyleColor(ImGuiCol.Text, 1, 1, 1, 1)
    end
end

local memspell = nil
local memgem = 0
-- Recreate the spell bar context menu
-- sectionName+key+index defines where to store the result
-- selectedIdx is used to clear spell upgrade input incase of updating over an existing entry
local function DrawSpellPicker(sectionName, key, index)
    if not globals.Config[sectionName][key..index] then
        globals.Config[sectionName][key..index] = ''
    end
    local valueParts = nil
    if type(globals.Config[sectionName][key..index]) == "string" then
        valueParts = utils.Split(globals.Config[sectionName][key..index],'|',1)
    elseif type(globals.Config[sectionName][key..index]) == "number" then
        valueParts = {tostring(globals.Config[sectionName][key..index])}
    end
    -- Right click context menu popup on list buttons
    if ImGui.BeginPopupContextItem('##rcmenu'..sectionName..key..index) then
        -- Top level 'Spells' menu item
        if #spells.categories > 0 then
            if ImGui.BeginMenu('Spells##rcmenu'..sectionName..key) then
                for _,category in ipairs(spells.categories) do
                    -- Spell Subcategories submenu
                    if ImGui.BeginMenu(category..'##rcmenu'..sectionName..key..category) then
                        for _,subcategory in ipairs(spells[category].subcategories) do
                            -- Subcategory Spell menu
                            local menuHeight = -1
                            if #spells[category][subcategory] > 25 then
                                menuHeight = ImGui.GetTextLineHeight()*25
                            end
                            ImGui.SetNextWindowSize(250, menuHeight)
                            if #spells[category][subcategory] > 0 and ImGui.BeginMenu(subcategory..'##'..sectionName..key..subcategory) then
                                for _,spell in ipairs(spells[category][subcategory]) do
                                    -- spell[1]=level, spell[2]=name
                                    SetSpellTextColor(spell[2])
                                    if ImGui.MenuItem(spell[1]..' - '..spell[2]..'##'..sectionName..key..subcategory) then
                                        if useRankNames then
                                            valueParts[1] = spell[3]
                                        else
                                            valueParts[1] = spell[2]
                                        end
                                        selectedUpgrade = nil
                                    end
                                    ImGui.PopStyleColor()
                                end
                                ImGui.EndMenu()
                            end
                        end
                        ImGui.EndMenu()
                    end
                end
                ImGui.EndMenu()
            end
        end
        -- Top level 'AAs' menu item
        if sectionName ~= 'MySpells' and #altAbilities.types > 0 then
            if ImGui.BeginMenu('Alt Abilities##rcmenu'..sectionName..key) then
                for _,type in ipairs(aatypes) do
                    if altAbilities[type] then
                        local menuHeight = -1
                        if #altAbilities[type] > 25 then
                            menuHeight = ImGui.GetTextLineHeight()*25
                        end
                        ImGui.SetNextWindowSize(250, menuHeight)
                        if ImGui.BeginMenu(type..'##aamenu'..sectionName..key..type) then
                            for _,altAbility in ipairs(altAbilities[type]) do
                                SetSpellTextColor(altAbility[2])
                                if ImGui.MenuItem(altAbility[1]..'##aa'..sectionName..key) then
                                    valueParts[1] = altAbility[1]
                                end
                                ImGui.PopStyleColor()
                            end
                            ImGui.EndMenu()
                        end
                    end
                end
                ImGui.EndMenu()
            end
        end
        -- Top level 'Discs' menu item
        if sectionName ~= 'MySpells' and #discs.categories > 0 then
            if ImGui.BeginMenu('Combat Abilities##rcmenu'..sectionName..key) then
                for _,category in ipairs(discs.categories) do
                    -- Spell Subcategories submenu
                    if ImGui.BeginMenu(category..'##rcmenu'..sectionName..key..category) then
                        for _,subcategory in ipairs(discs[category].subcategories) do
                            -- Subcategory Spell menu
                            local menuHeight = -1
                            if #discs[category][subcategory] > 25 then
                                menuHeight = ImGui.GetTextLineHeight()*25
                            end
                            ImGui.SetNextWindowSize(250, menuHeight)
                            if #discs[category][subcategory] > 0 and ImGui.BeginMenu(subcategory..'##'..sectionName..key..subcategory) then
                                for _,disc in ipairs(discs[category][subcategory]) do
                                    -- spell[1]=level, spell[2]=name
                                    SetSpellTextColor(disc[2])
                                    if ImGui.MenuItem(disc[1]..' - '..disc[2]..'##'..sectionName..key..subcategory) then
                                        valueParts[1] = disc[2]
                                        selectedUpgrade = nil
                                    end
                                    ImGui.PopStyleColor()
                                end
                                ImGui.EndMenu()
                            end
                        end
                        ImGui.EndMenu()
                    end
                end
                ImGui.EndMenu()
            end
        end
        if valueParts[1] then
            local rankname = tloCache:get(valueParts[1]..'.rankname', function() return mq.TLO.Spell(valueParts[1]).RankName() end)
            if rankname then
                local bookidx = tloCache:get('book.'..rankname, function() return mq.TLO.Me.Book(rankname)() end)
                if bookidx then
                    if ImGui.MenuItem('Memorize Spell') then
                        for i=1,13 do
                            if not mq.TLO.Me.Gem(i)() then
                                memspell = valueParts[1]
                                memgem = i
                                break
                            end
                        end
                    end
                end
            end
        end
        ImGui.EndPopup()
    end
    globals.Config[sectionName][key..index] = table.concat(valueParts, '|')
    if globals.Config[sectionName][key..index] == '|' then
        globals.Config[sectionName][key..index] = 'NULL'
    end
end

local function DrawSelectedSpellUpgradeButton(spell)
    local upgradeValue = nil
    -- Avoid finding the upgrade more than once
    if not selectedUpgrade then
        selectedUpgrade = GetSpellUpgrade(spell.TargetType(), spell.Subcategory(), spell.NumEffects(), spell.Level())
    end
    -- Upgrade found? display the upgrade button
    if selectedUpgrade ~= '' and selectedUpgrade ~= spell.Name() then
        if ImGui.Button('Upgrade Available - '..selectedUpgrade) then
            upgradeValue = selectedUpgrade
            selectedUpgrade = nil
        end
    end
    return upgradeValue
end

local function DrawSelectedSpellDowngradeButton(spell)
    local upgradeValue = nil
    -- Avoid finding the upgrade more than once
    if not selectedUpgrade then
        selectedUpgrade = GetSpellUpgrade(spell.TargetType(), spell.Subcategory(), spell.NumEffects(), 0)
    end
    -- Upgrade found? display the upgrade button
    if selectedUpgrade ~= '' and selectedUpgrade ~= spell.Name() then
        if ImGui.Button('Downgrade Available - '..selectedUpgrade) then
            upgradeValue = selectedUpgrade
            selectedUpgrade = nil
        end
    end
    return upgradeValue
end

local function CheckInputType(key, value, typestring, inputtype)
    if type(value) ~= typestring then
        utils.printf('\arWARNING [%s]: %s value is not a %s: type=%s value=%s\a-x', key, inputtype, typestring, type(value), tostring(value))
    end
end

local function DrawKeyAndInputText(keyText, label, value, helpText)
    ImGui.PushStyleColor(ImGuiCol.Text, 1, 1, 0, 1)
    ImGui.Text(keyText)
    ImGui.PopStyleColor()
    ImGui.SameLine()
    utils.HelpMarker(helpText)
    ImGui.SameLine()
    ImGui.SetCursorPosX(175)
    -- the first part, spell/item/disc name, /command, etc
    CheckInputType(label, value, 'string', 'InputText')
    return ImGui.InputText(label, tostring(value))
end

-- Draw the value and condition of the selected list item
-- Buff tags presented in the structured editor (normalized form used by serialize/the bot).
local BUFF_TAGS = { '', 'Me', 'MA', '!MA', '!ME', 'caster', 'Melee', 'class',
  'Dual', 'DualMA', 'DualMelee', 'DualCaster', 'DualClass', 'DualMgb', 'mgb',
  'Aura', 'Mana', 'Managroup', 'Endgroup', 'End', 'Summon', 'Once', 'Remove' }
local BUFF_PREFIXES = { '(none)', 'item', 'command', 'summoned' }
local HEAL_TAGS = { '', 'MA', 'Me', '!MA', 'pet', '!pet', 'Mob', 'Tap', 'xtar' }

-- Persistent per-entry working structs. The structured editors mutate these across frames
-- (immediate mode) instead of re-parsing the INI string every frame, which would wipe
-- transient UI state (an enabled-but-empty OOG, a freshly-added blank name row, etc.).
-- We re-parse only when the underlying raw value changed from outside our own writes.
local buffEdit = {}  -- [valueKey] = { entry = <parsed buff>, srcRaw = <string we last wrote> }
local healEdit = {}  -- [valueKey] = { entry = <parsed heal>, srcRaw = <string we last wrote> }

-- Live PC names for the OOG "add from nearby" picker: group + raid + nearby PCs.
local function live_pc_names()
  local seen, out = {}, {}
  local me = mq.TLO.Me.CleanName()
  local function add(n) if n and n ~= '' and n ~= me and not seen[n] then seen[n] = true; out[#out+1] = n end end
  for i = 1, (tonumber(mq.TLO.Group()) or 0) do add(mq.TLO.Group.Member(i).CleanName()) end
  for i = 1, (tonumber(mq.TLO.Raid.Members()) or 0) do add(mq.TLO.Raid.Member(i).CleanName()) end
  local cnt = tonumber(mq.TLO.SpawnCount('pc radius 200')()) or 0
  for i = 1, math.min(cnt, 50) do add(mq.TLO.NearestSpawn(i .. ',pc radius 200').CleanName()) end
  return out
end

-- OOG builder: renders flags + name rows for a NON-NIL `oog` table, mutating it in place.
-- The enable checkbox lives in the caller (persistent working struct).
local function DrawOOGBuilder(idbase, oog)
  oog.names = oog.names or {}
  oog.xtargets = oog.xtargets or {}

  oog.raid = ImGui.Checkbox('Raid##oog'..idbase, oog.raid or false)
  ImGui.SameLine()
  oog.fellowship = ImGui.Checkbox('Fellowship##oog'..idbase, oog.fellowship or false)

  local hasRange = oog.range ~= nil
  hasRange = ImGui.Checkbox('Range##oog'..idbase, hasRange)
  if hasRange then
    ImGui.SameLine(); ImGui.PushItemWidth(80)
    oog.range = ImGui.InputInt('radius##oog'..idbase, oog.range or 100)
    if oog.range < 1 then oog.range = 1 end
    ImGui.PopItemWidth()
  else
    oog.range = nil
  end

  -- Named targets: one editable row each, with a remove button.
  ImGui.Text('Characters:')
  local removeIdx
  for i, nm in ipairs(oog.names) do
    ImGui.PushItemWidth(180)
    oog.names[i] = ImGui.InputText('##oogname'..idbase..i, nm)
    ImGui.PopItemWidth()
    ImGui.SameLine()
    if ImGui.SmallButton('x##oogdel'..idbase..i) then removeIdx = i end
  end
  if removeIdx then table.remove(oog.names, removeIdx) end
  if ImGui.SmallButton('+ Add name##oogadd'..idbase) then oog.names[#oog.names+1] = '' end
  ImGui.SameLine()
  -- Live picker: choose a nearby/group/raid PC to append.
  if ImGui.BeginCombo('##oogpick'..idbase, 'Add nearby...') then
    for _, n in ipairs(live_pc_names()) do
      if ImGui.Selectable(n..'##oogpick'..idbase) then oog.names[#oog.names+1] = n end
    end
    ImGui.EndCombo()
  end
  return oog
end

-- Shared hybrid condition editor. Returns the (possibly edited) condition string.
local condRawMode = {}   -- [idbase] = true  (user forced raw)
local function DrawConditionBuilder(idbase, condString)
    condString = condString or ''
    if condString == 'NULL' then condString = '' end   -- stored 'no condition' sentinel
    local parsed = cond_model.parse(condString)
    local useRaw = condRawMode[idbase] or parsed.mode == 'raw'

    if useRaw then
        ImGui.PushItemWidth(350)
        local newRaw = ImGui.InputText('Condition (raw)##raw'..idbase, condString)
        ImGui.PopItemWidth()
        if condString:find('${', 1, true) then
            ImGui.SameLine(); utils.HelpMarker('Legacy ${} condition - evaluated as-is.')
        end
        if ImGui.SmallButton('Try builder##tb'..idbase) then
            condRawMode[idbase] = nil
            if cond_model.parse(newRaw).mode == 'raw' then condRawMode[idbase] = true end
        end
        return newRaw
    end

    local rows = parsed.rows
    for ri, row in ipairs(rows) do
        ImGui.PushID(idbase..'r'..ri)
        local subj = nil
        for _, s in ipairs(cond_model.SUBJECTS) do if s.key == row.key then subj = s end end
        local label = subj and subj.label or row.key
        if ImGui.BeginCombo('##subj', label) then
            for _, s in ipairs(cond_model.SUBJECTS) do
                if ImGui.Selectable(s.label, s.key == row.key) then row.key = s.key; row.op = s.ops[1] end
            end
            if ImGui.Selectable('Target has buff', row.key=='target_has_buff') then row.key='target_has_buff'; row.op=nil end
            if ImGui.Selectable('Target missing buff', row.key=='target_missing_buff') then row.key='target_missing_buff'; row.op=nil end
            ImGui.EndCombo()
        end
        ImGui.SameLine()
        if row.key == 'target_has_buff' or row.key == 'target_missing_buff' then
            ImGui.PushItemWidth(160)
            row.value = ImGui.InputText('##bval', row.value or '')
            ImGui.PopItemWidth()
        else
            local ops = (subj and subj.ops) or {'<','<=','>','>=','==','~='}
            ImGui.PushItemWidth(60)
            if ImGui.BeginCombo('##op', row.op or ops[1]) then
                for _, o in ipairs(ops) do if ImGui.Selectable(o, o == row.op) then row.op = o end end
                ImGui.EndCombo()
            end
            ImGui.PopItemWidth()
            ImGui.SameLine(); ImGui.PushItemWidth(120)
            row.value = ImGui.InputText('##val', row.value or '')
            ImGui.PopItemWidth()
        end
        ImGui.SameLine()
        if ImGui.SmallButton('x') then table.remove(rows, ri) end
        ImGui.PopID()
    end
    if ImGui.SmallButton('+ condition##add'..idbase) then
        rows[#rows+1] = { key='target_hp', op='<', value='100' }
    end
    ImGui.SameLine()
    if ImGui.SmallButton('raw##forceraw'..idbase) then condRawMode[idbase] = true end

    return cond_model.emit(rows)
end

-- Structured editor for a Buffs entry. Replaces the raw Name|Options fields.
local function DrawStructuredBuff(sectionName, valueKey, value)
  local cfg = globals.Config[sectionName]
  local raw = cfg[valueKey]
  if raw == nil or raw == 'NULL' then raw = '' end
  local idx = valueKey:match('(%d+)$') or ''
  local condKey = sectionName .. 'Cond' .. idx
  local condRaw = cfg[condKey]
  if condRaw == 'NULL' then condRaw = nil end

  -- Use the persistent working struct; re-parse only if the raw changed outside our writes.
  local cur = buffEdit[valueKey]
  if not cur or cur.srcRaw ~= raw then
    cur = { entry = serialize.parse_buff(raw, condRaw), srcRaw = raw }
    buffEdit[valueKey] = cur
  end
  local e = cur.entry

  ImGui.PushStyleColor(ImGuiCol.Text, 0, 1, 1, 1)
  ImGui.Text(valueKey); ImGui.PopStyleColor()

  -- Name + prefix
  ImGui.PushItemWidth(120)
  local prefIdx = 1
  for i, p in ipairs(BUFF_PREFIXES) do if e.prefix == p then prefIdx = i end end
  if ImGui.BeginCombo('##pref'..valueKey, BUFF_PREFIXES[prefIdx]) then
    for i, p in ipairs(BUFF_PREFIXES) do
      if ImGui.Selectable(p..'##pref'..valueKey, i == prefIdx) then
        e.prefix = (p == '(none)') and nil or p
      end
    end
    ImGui.EndCombo()
  end
  ImGui.PopItemWidth()
  ImGui.SameLine()
  ImGui.PushItemWidth(260)
  e.name = ImGui.InputText('Name##name'..valueKey, e.name or '')
  if e.name:find('|') then e.name = e.name:match('[^|]+') or e.name end
  ImGui.PopItemWidth()

  -- Tag
  ImGui.PushItemWidth(160)
  if ImGui.BeginCombo('Tag##tag'..valueKey, e.tag ~= '' and e.tag or '(plain)') then
    for _, tg in ipairs(BUFF_TAGS) do
      if ImGui.Selectable((tg ~= '' and tg or '(plain)')..'##tag'..valueKey, tg == e.tag) then
        e.tag = tg
      end
    end
    ImGui.EndCombo()
  end
  ImGui.PopItemWidth()
  utils.HelpMarker(value['OptionsTooltip'] or '')

  -- Tag-dependent fields with friendly labels.
  local isDual = e.tag:sub(1,4) == 'Dual'
  if isDual then
    ImGui.PushItemWidth(260)
    e.part3 = ImGui.InputText('Single-target form##p3'..valueKey, e.part3 or '')
    ImGui.PopItemWidth()
  end
  if e.tag == 'class' then
    ImGui.PushItemWidth(260)
    e.part3 = ImGui.InputText('Classes (e.g. WAR,PAL)##p3'..valueKey, e.part3 or '')
    ImGui.PopItemWidth()
  elseif e.tag == 'DualClass' then
    ImGui.PushItemWidth(260)
    e.part5 = ImGui.InputText('Classes (e.g. WAR,PAL)##p5'..valueKey, e.part5 or '')
    ImGui.PopItemWidth()
  elseif e.tag == 'End' then
    ImGui.PushItemWidth(100)
    e.part3 = ImGui.InputText('Endurance %##p3'..valueKey, e.part3 or '')
    e.part4 = ImGui.InputText('Min HP %##p4'..valueKey, e.part4 or '')
    ImGui.PopItemWidth()
  elseif e.tag == 'Summon' then
    ImGui.PushItemWidth(200)
    e.part3 = ImGui.InputText('Item to summon##p3'..valueKey, e.part3 or '')
    e.part4 = ImGui.InputText('Keep count##p4'..valueKey, e.part4 or '')
    ImGui.PopItemWidth()
  elseif e.tag == 'Mana' or e.tag == 'Managroup' or e.tag == 'Endgroup' then
    ImGui.PushItemWidth(100)
    e.part3 = ImGui.InputText('Trigger %##p3'..valueKey, e.part3 or '')
    if e.tag == 'Mana' then e.part4 = ImGui.InputText('Min HP %##p4'..valueKey, e.part4 or '') end
    ImGui.PopItemWidth()
  end

  -- OOG builder (enable state held in the persistent working struct so it doesn't revert).
  local oogOn = ImGui.Checkbox('Out-of-group targets##oog'..valueKey, e.oog ~= nil)
  if oogOn then
    e.oog = e.oog or { names = {}, xtargets = {} }
    DrawOOGBuilder(valueKey, e.oog)
  else
    e.oog = nil
  end

  -- Condition
  if value['Conditions'] then
    local c = DrawConditionBuilder(sectionName..valueKey..'b', e.cond or '')
    e.cond = (c ~= '') and c or nil
    utils.HelpMarker(value['CondTooltip'] or '')
  end

  -- Serialize back; remember our own output so we don't re-parse it next frame (which would
  -- discard transient UI state like an empty name row or enabled-empty OOG).
  local out = (e.name and e.name ~= '') and serialize.buff_to_string(e) or ''
  cfg[valueKey] = out
  cur.srcRaw = out
  cfg[condKey] = e.cond or 'NULL'
end

-- Structured editor for a Heals entry: name | pct | tag (+ condition).
local function DrawStructuredHeal(sectionName, valueKey, value)
  local cfg = globals.Config[sectionName]
  local raw = cfg[valueKey]
  if raw == nil or raw == 'NULL' then raw = '' end
  local idx = valueKey:match('(%d+)$') or ''
  local condKey = sectionName .. 'Cond' .. idx
  local condRaw = cfg[condKey]
  if condRaw == 'NULL' then condRaw = nil end

  local cur = healEdit[valueKey]
  if not cur or cur.srcRaw ~= raw then
    cur = { entry = serialize.parse_heal(raw, condRaw), srcRaw = raw }
    healEdit[valueKey] = cur
  end
  local e = cur.entry

  ImGui.PushStyleColor(ImGuiCol.Text, 0, 1, 1, 1)
  ImGui.Text(valueKey); ImGui.PopStyleColor()

  ImGui.PushItemWidth(260)
  e.name = ImGui.InputText('Spell/Item/AA##name'..valueKey, e.name or '')
  if e.name:find('|') then e.name = e.name:match('[^|]+') or e.name end
  ImGui.PopItemWidth()
  utils.HelpMarker(value['Tooltip'] or '')

  ImGui.PushItemWidth(120)
  e.pct = ImGui.InputInt('Cast at HP %##pct'..valueKey, e.pct or 0)
  if e.pct < 0 then e.pct = 0 elseif e.pct > 100 then e.pct = 100 end
  ImGui.PopItemWidth()

  ImGui.PushItemWidth(160)
  if ImGui.BeginCombo('Tag##tag'..valueKey, e.tag ~= '' and e.tag or '(any)') then
    for _, tg in ipairs(HEAL_TAGS) do
      if ImGui.Selectable((tg ~= '' and tg or '(any)')..'##tag'..valueKey, tg == e.tag) then
        e.tag = tg
      end
    end
    ImGui.EndCombo()
  end
  ImGui.PopItemWidth()
  utils.HelpMarker(value['OptionsTooltip'] or '')

  if value['Conditions'] then
    local c = DrawConditionBuilder(sectionName..valueKey..'h', e.cond or '')
    e.cond = (c ~= '') and c or nil
    utils.HelpMarker(value['CondTooltip'] or '')
  end

  local out = (e.name and e.name ~= '') and serialize.heal_to_string(e) or ''
  cfg[valueKey] = out
  cur.srcRaw = out
  cfg[condKey] = e.cond or 'NULL'
end

local function DrawSelectedListItem(sectionName, key, value)
    local valueKey = key..selectedListItem[2]
    if sectionName == 'Buffs' then
        ImGui.Separator()
        DrawStructuredBuff(sectionName, valueKey, value)
        ImGui.Separator()
        return
    elseif sectionName == 'Heals' then
        ImGui.Separator()
        DrawStructuredHeal(sectionName, valueKey, value)
        ImGui.Separator()
        return
    end
    -- make sure values not nil so imgui inputs don't barf
    if globals.Config[sectionName][valueKey] == nil then
        globals.Config[sectionName][valueKey] = 'NULL'
    end
    -- split the value so we can update spell name and stuff after the | individually
    local valueParts = utils.Split(globals.Config[sectionName][valueKey], '|', 1)
    -- the first part, spell/item/disc name, /command, etc
    if not valueParts[1] then valueParts[1] = '' end
    -- the rest of the stuff after the first |, classes, percents, oog, etc
    if not valueParts[2] then valueParts[2] = '' end

    ImGui.Separator()
    ImGui.PushStyleColor(ImGuiCol.Text, 0, 1, 1, 1)
    ImGui.Text(string.format('%s%d', key, selectedListItem[2]))
    ImGui.PopStyleColor()
    valueParts[1] = DrawKeyAndInputText('Name: ', '##'..sectionName..valueKey, valueParts[1], value['Tooltip'])
    -- prevent | in the ability name field, or else things get ugly in the options field
    if valueParts[1]:find('|') then valueParts[1] = valueParts[1]:match('[^|]+') end
    valueParts[2] = DrawKeyAndInputText('Options: ', '##'..sectionName..valueKey..'options', valueParts[2], value['OptionsTooltip'])
    if value['Conditions'] then
        local valueCondKey = key..'Cond'..selectedListItem[2]
        if globals.Config[sectionName][valueCondKey] == nil then
            globals.Config[sectionName][valueCondKey] = 'NULL'
        end
        globals.Config[sectionName][valueCondKey] =
          DrawConditionBuilder(sectionName..valueKey..'gen', globals.Config[sectionName][valueCondKey] or '')
    end
    local spell = tloCache:get(valueParts[1], function() return mq.TLO.Spell(valueParts[1]) end)
    if mq.TLO.Me.Book(spell.RankName())() then
        local upgradeResult = DrawSelectedSpellUpgradeButton(spell)
        if upgradeResult then valueParts[1] = upgradeResult end
    elseif spell then
        local upgradeResult = DrawSelectedSpellDowngradeButton(spell)
        if upgradeResult then valueParts[1] = upgradeResult end
    end
    if valueParts[1] and string.len(valueParts[1]) > 0 then
        globals.Config[sectionName][valueKey] = valueParts[1]
        if valueParts[2] and string.len(valueParts[2]) > 0 then
            globals.Config[sectionName][valueKey] = globals.Config[sectionName][valueKey]..'|'..valueParts[2]:gsub('|$','')
        end
    else
        globals.Config[sectionName][valueKey] = ''
    end
    ImGui.Separator()
end

local function DrawPlainListButton(sectionName, key, listIdx, iconSize)
    -- INI value is set to non-spell/item
    if ImGui.Button(listIdx..'##'..sectionName..key, iconSize[1], iconSize[2]) then
        if type(listIdx) == 'number' then
            if mq.TLO.CursorAttachment.Type() == 'ITEM' then
                globals.Config[sectionName][key..listIdx] = mq.TLO.CursorAttachment.Item.Name()
            elseif mq.TLO.CursorAttachment.Type() == 'SPELL_GEM' then
                globals.Config[sectionName][key..listIdx] = mq.TLO.CursorAttachment.Spell.Name()
            else
                selectedListItem = {key, listIdx}
                selectedUpgrade = nil
            end
        else
            if mq.TLO.CursorAttachment.Type() == 'ITEM' then
                globals.Config[sectionName][key] = mq.TLO.CursorAttachment.Item.Name()
            elseif mq.TLO.CursorAttachment.Type() == 'SPELL_GEM' then
                globals.Config[sectionName][key] = mq.TLO.CursorAttachment.Spell.Name()
            end
        end
    elseif type(listIdx) == 'number' then
        if not mq.TLO.Cursor() and ImGui.BeginDragDropSource() then
            ImGui.SetDragDropPayload("ListBtn", listIdx)
            ImGui.Button(listIdx..'##'..sectionName..key, iconSize[1], iconSize[2])
            ImGui.EndDragDropSource()
        end
    end
end

local function DrawTooltip(text)
    if ImGui.IsItemHovered() and text and string.len(text) > 0 then
        ImGui.BeginTooltip()
        ImGui.PushTextWrapPos(ImGui.GetFontSize() * 35.0)
        ImGui.Text(text)
        ImGui.PopTextWrapPos()
        ImGui.EndTooltip()
    end
end

local function CharacterHasThing(iniValue)
    local valid = false
    if not iniValue then
        -- count unset INI entry as valid
        valid = true
    elseif tloCache:get('invalid.'..iniValue) then
        valid = false
    else
        local rankname = tloCache:get(iniValue..'.rankname', function() return mq.TLO.Spell(iniValue).RankName() end)
        if rankname then
            if tloCache:get('book.'..rankname, function() return mq.TLO.Me.Book(rankname)() end) then
                valid = true
            elseif tloCache:get('aa.'..iniValue, function() return mq.TLO.Me.AltAbility(iniValue)() end) then
                valid = true
            elseif tloCache:get('disc.'..rankname, function() return mq.TLO.Me.CombatAbility(rankname)() end) then
                valid = true
            end
        elseif tloCache:get('item.'..iniValue, function() return mq.TLO.FindItem(iniValue)() end) then
            valid = true
        elseif iniValue:find('command:') or iniValue:find('${') then
            valid = true
        elseif tloCache:get('ability.'..iniValue, function() return mq.TLO.Me.Ability(iniValue)() end) then
            valid = true
        else
            tloCache:get('invalid.'..iniValue, function() return 1 end)
            valid = false
        end
    end
    return valid
end

local function DrawSpellIconOrButton(sectionName, key, index)
    local iniValue = nil
    if globals.Config[sectionName][key..index] and globals.Config[sectionName][key..index] ~= 'NULL' then
        if type(globals.Config[sectionName][key..index]) == "string" then
            iniValue = utils.Split(globals.Config[sectionName][key..index],'|',1)[1]
        elseif type(globals.Config[sectionName][key..index]) == "number" then
            iniValue = tostring(globals.Config[sectionName][key..index])
        end
    end
    local charHasAbility = CharacterHasThing(iniValue)
    local iconSize = {30,30} -- default icon size
    if type(index) == 'number' then
        local x,y = ImGui.GetCursorPos()
        if not charHasAbility then
            ImGui.DrawTextureAnimation(animRedWndPieces, iconSize[1], iconSize[2])
            ImGui.SetCursorPosX(x+2)
            ImGui.SetCursorPosY(y+2)
            iconSize = {26,26}
        end
    end
    if iniValue then
        -- Use first part of INI value as spell or item name to lookup icon
        if tloCache:get('invalid.'..iniValue) then
            DrawPlainListButton(sectionName, key, index, iconSize)
        elseif tloCache:get(iniValue..'.name', function() return mq.TLO.Spell(iniValue)() end) then
            -- Need to create a group for drag/drop to work, doesn't seem to work with just the texture animation?
            ImGui.BeginGroup()
            local x,y = ImGui.GetCursorPos()
            ImGui.Button('##'..index..sectionName..key, iconSize[1], iconSize[2])
            ImGui.SetCursorPosX(x)
            ImGui.SetCursorPosY(y)
            local spellIcon = tloCache:get(iniValue..'.spellicon', function() return mq.TLO.Spell(iniValue).SpellIcon() end)
            animSpellIcons:SetTextureCell(spellIcon)
            ImGui.DrawTextureAnimation(animSpellIcons, iconSize[1], iconSize[2])
            ImGui.EndGroup()
        elseif tloCache:get('item.'..iniValue, function() return mq.TLO.FindItem(iniValue)() end) then
            -- Need to create a group for drag/drop to work, doesn't seem to work with just the texture animation?
            ImGui.BeginGroup()
            local x,y = ImGui.GetCursorPos()
            ImGui.Button('##'..index..sectionName..key, iconSize[1], iconSize[2])
            ImGui.SetCursorPosX(x)
            ImGui.SetCursorPosY(y)
            local itemIcon = tloCache:get('itemicon.'..iniValue, function() return mq.TLO.FindItem(iniValue).Icon() end)
            animItems:SetTextureCell(itemIcon-500)
            ImGui.DrawTextureAnimation(animItems, iconSize[1], iconSize[2])
            ImGui.EndGroup()
        else
            DrawPlainListButton(sectionName, key, index, iconSize)
        end
        DrawTooltip(iniValue)
        -- Handle clicks on spell icon animations that aren't buttons
        if ImGui.BeginDragDropTarget() then
            local payload = ImGui.AcceptDragDropPayload("ListBtn")
            if payload ~= nil then
                local num = payload.Data;
                -- swap the list entries
                globals.Config[sectionName][key..index], globals.Config[sectionName][key..num] = globals.Config[sectionName][key..num], globals.Config[sectionName][key..index]
                globals.Config[sectionName][key..'Cond'..index], globals.Config[sectionName][key..'Cond'..num] = globals.Config[sectionName][key..'Cond'..num], globals.Config[sectionName][key..'Cond'..index]
            end
            ImGui.EndDragDropTarget()
        elseif ImGui.IsItemHovered() and ImGui.IsMouseReleased(0) and type(index) == 'number' then
            if mq.TLO.CursorAttachment.Type() == 'ITEM' then
                globals.Config[sectionName][key..index] = mq.TLO.CursorAttachment.Item.Name()
            elseif mq.TLO.CursorAttachment.Type() == 'SPELL_GEM' then
                globals.Config[sectionName][key..index] = mq.TLO.CursorAttachment.Spell.Name()
            else
                selectedListItem = {key, index}
                selectedUpgrade = nil
            end
        elseif ImGui.IsItemHovered() and ImGui.IsMouseDown(ImGuiMouseButton.Left) and type(index) == 'number' then
            if not mq.TLO.Cursor() and ImGui.BeginDragDropSource() then
                ImGui.SetDragDropPayload("ListBtn", index)
                ImGui.Button(index..'##'..sectionName..key, iconSize[1], iconSize[2])
                ImGui.EndDragDropSource()
            end
        end
        -- Spell picker context menu on right click button
        DrawSpellPicker(sectionName, key, index)
    else
        -- No INI value assigned yet for this key
        DrawPlainListButton(sectionName, key, index, iconSize)
        DrawSpellPicker(sectionName, key, index)
        if ImGui.BeginDragDropTarget() then
            local payload = ImGui.AcceptDragDropPayload("ListBtn")
            if payload ~= nil then
                local num = payload.Data;
                -- swap the list entries
                globals.Config[sectionName][key..index], globals.Config[sectionName][key..num] = globals.Config[sectionName][key..num], globals.Config[sectionName][key..index]
                globals.Config[sectionName][key..'Cond'..index], globals.Config[sectionName][key..'Cond'..num] = globals.Config[sectionName][key..'Cond'..num], globals.Config[sectionName][key..'Cond'..index]
            end
            ImGui.EndDragDropTarget()
        end
    end
end

-- Draw 0..N buttons based on value of XYZSize input
local function DrawList(sectionName, key, value)
    ImGui.PushStyleColor(ImGuiCol.Text, 1, 1, 0, 1)
    ImGui.Text(key..'Size: ')
    ImGui.PopStyleColor()
    ImGui.SameLine()
    utils.HelpMarker(value['SizeTooltip'])
    ImGui.SameLine()
    ImGui.PushItemWidth(100)
    local size = globals.Config[sectionName][key..'Size']
    if size == nil or type(size) ~= 'number' then
        CheckInputType(key..'Size', size, 'number', 'InputInt')
        size = 0
    end
    ImGui.SetCursorPosX(175)
    -- Set size of list and check boundaries
    size = ImGui.InputInt('##sizeinput'..sectionName..key, size)
    if size < 0 then
        size = 0
    elseif size > value['Max'] then
        size = value['Max']
    end
    ImGui.PopItemWidth()
    local xOffset,yOffset = ImGui.GetCursorPos()
    local avail = ImGui.GetContentRegionAvail()
    local iconsPerRow = math.floor(avail/38)
    if iconsPerRow == 0 then iconsPerRow = 1 end
    for i=1,size do
        local offsetMod = math.floor((i-1)/iconsPerRow)
        ImGui.SetCursorPosY(yOffset+(36*offsetMod))
        DrawSpellIconOrButton(sectionName, key, i)
        if i%iconsPerRow ~= 0 and i < size then
            -- Some silliness instead of sameline due to the offset changes for red frames around missing abilities in list items
            -- Just let it be
            ImGui.SetCursorPosX(xOffset+(30*(i%iconsPerRow))+(6*(i%iconsPerRow)))
            ImGui.SetCursorPosY(yOffset)
        end
    end
    ImGui.SetCursorPosY(yOffset+38*(math.floor((size-1)/iconsPerRow)+1))
    -- Submit a zero-size item so EndChild can grow boundaries after SetCursorPos
    ImGui.Dummy(0, 0)
    globals.Config[sectionName][key..'Size'] = size
end

local function DrawMultiPartProperty(sectionName, key, value)
    -- TODO: what's a nice clean way to represent values which are multiple parts? 
    -- Currently just using this experimentally with RezAcceptOn
    local parts = utils.Split(globals.Config[sectionName][key], '|',1)
    for partIdx,part in ipairs(value['Parts']) do
        if part['Type'] == 'SWITCH' then
            ImGui.Text(part['Name']..': ')
            ImGui.SameLine()
            local value = utils.InitCheckBoxValue(tonumber(parts[partIdx]))
            CheckInputType(key, value, 'boolean', 'Checkbox')
            parts[partIdx] = ImGui.Checkbox('##'..key, value)
            if parts[partIdx] then parts[partIdx] = '1' else parts[partIdx] = '0' end
        elseif part['Type'] == 'NUMBER' then
            if not parts[partIdx] or parts[partIdx] == 'NULL' then parts[partIdx] = 0 end
            ImGui.Text(part['Name']..': ')
            ImGui.SameLine()
            ImGui.PushItemWidth(100)
            local value = tonumber(parts[partIdx])
            CheckInputType(key, value, 'number', 'InputInt')
            parts[partIdx] = ImGui.InputInt('##'..sectionName..key..partIdx, value)
            ImGui.PopItemWidth()
            if part['Min'] and parts[partIdx] < part['Min'] then
                parts[partIdx] = part['Min']
            elseif part['Max'] and parts[partIdx] > part['Max'] then
                parts[partIdx] = part['Max']
            end
            parts[partIdx] = tostring(parts[partIdx])
        end
        globals.Config[sectionName][key] = table.concat(parts, '|')
        if partIdx == 1 then
            ImGui.SameLine()
        end
    end
end

-- Draw a generic section key/value property
local function DrawProperty(sectionName, key, value)
    ImGui.PushStyleColor(ImGuiCol.Text, 1, 1, 0, 1)
    ImGui.Text(key..': ')
    ImGui.PopStyleColor()
    ImGui.SameLine()
    utils.HelpMarker(value['Tooltip'])
    ImGui.SameLine()
    if globals.Config[sectionName][key] == nil then
        globals.Config[sectionName][key] = 'NULL'
    end
    ImGui.SetCursorPosX(175)
    if value['Type'] == 'SWITCH' then
        local initialValue = utils.InitCheckBoxValue(globals.Config[sectionName][key])
        CheckInputType(key, initialValue, 'boolean', 'Checkbox')
        globals.Config[sectionName][key] = ImGui.Checkbox('##'..key, initialValue)
    elseif value['Type'] == 'SPELL' then
        DrawSpellIconOrButton(sectionName, key, '')
        ImGui.SameLine()
        ImGui.PushItemWidth(350)
        local initialValue = globals.Config[sectionName][key]
        CheckInputType(key, initialValue, 'string', 'InputText')
        globals.Config[sectionName][key] = ImGui.InputText('##textinput'..sectionName..key, tostring(initialValue))
        ImGui.PopItemWidth()
    elseif value['Type'] == 'NUMBER' then
        local initialValue = globals.Config[sectionName][key]
        if not initialValue or initialValue == 'NULL' or type(initialValue) ~= 'number' then
            CheckInputType(key, initialValue, 'number', 'InputInt')
            initialValue = 0
        end
        ImGui.PushItemWidth(350)
        globals.Config[sectionName][key] = ImGui.InputInt('##'..sectionName..key, initialValue)
        ImGui.PopItemWidth()
        if value['Min'] and globals.Config[sectionName][key] < value['Min'] then
            globals.Config[sectionName][key] = value['Min']
        elseif value['Max'] and globals.Config[sectionName][key] > value['Max'] then
            globals.Config[sectionName][key] = value['Max']
        end
    elseif value['Type'] == 'STRING' then
        ImGui.PushItemWidth(350)
        local initialValue = tostring(globals.Config[sectionName][key])
        CheckInputType(key, initialValue, 'string', 'InputText')
        globals.Config[sectionName][key] = ImGui.InputText('##'..sectionName..key, initialValue)
        ImGui.PopItemWidth()
    elseif value['Type'] == 'MULTIPART' then
        DrawMultiPartProperty(sectionName, key, value)
    end
end

-- Draw main On/Off switches for an INI section
local function DrawSectionControlSwitches(sectionName, sectionProperties)
    if sectionProperties['On'] then
        if sectionProperties['On']['Type'] == 'SWITCH' then
            local value = utils.InitCheckBoxValue(globals.Config[sectionName][sectionName..'On'])
            CheckInputType(sectionName..'On', value, 'boolean', 'Checkbox')
            globals.Config[sectionName][sectionName..'On'] = ImGui.Checkbox(sectionName..'On', value)
        elseif sectionProperties['On']['Type'] == 'NUMBER' then
            -- Type=NUMBER control switch mostly a special case for DPS section only
            if not globals.Config[sectionName][sectionName..'On'] then globals.Config[sectionName][sectionName..'On'] = 0 end
            ImGui.PushItemWidth(100)
            globals.Config[sectionName][sectionName..'On'] = ImGui.InputInt(sectionName..'On', globals.Config[sectionName][sectionName..'On'])
            ImGui.PopItemWidth()
            if sectionProperties['On']['Min'] and globals.Config[sectionName][sectionName..'On'] < sectionProperties['On']['Min'] then
                globals.Config[sectionName][sectionName..'On'] = sectionProperties['On']['Min']
            elseif sectionProperties['On']['Max'] and globals.Config[sectionName][sectionName..'On'] > sectionProperties['On']['Max'] then
                globals.Config[sectionName][sectionName..'On'] = sectionProperties['On']['Max']
            end
        end
        if sectionProperties['COn'] then ImGui.SameLine() end
    end
    if sectionProperties['COn'] then
        globals.Config[sectionName][sectionName..'COn'] = ImGui.Checkbox(sectionName..'COn', utils.InitCheckBoxValue(globals.Config[sectionName][sectionName..'COn']))
    end
    ImGui.Separator()
end

local function DrawSpellsGemList(spellSection)
    local _,yOffset = ImGui.GetCursorPos()
    local avail = ImGui.GetContentRegionAvail()
    local iconsPerRow = math.floor(avail/36)
    if iconsPerRow == 0 then iconsPerRow = 1 end
    for i=1,13 do
        local offsetMod = math.floor((i-1)/iconsPerRow)
        ImGui.SetCursorPosY(yOffset+(34*offsetMod))
        DrawSpellIconOrButton(spellSection, 'Gem', i)
        if i%iconsPerRow ~= 0 and i < 13 then
            ImGui.SameLine()
        end
    end
    -- in case a spell gem was left clicked, don't mark it as selected so we don't enter the selected item drill-down
    selectedListItem = {nil, 0}
    selectedUpgrade = nil
end

local function DrawSpells(spellSection)
    ImGui.TextColored(1, 1, 0, 1, spellSection)
    if globals.Config[spellSection] then
        DrawSpellsGemList(spellSection)
    end
    if ImGui.Button('Update from spell bar') then
        if not globals.Config[spellSection] then globals.Config[spellSection] = {} end
        for i=1,13 do
            globals.Config[spellSection]['Gem'..i] = mq.TLO.Me.Gem(i).Name()
        end
        Save()
        globals.INIFileContents = utils.ReadRawINIFile()
    end
    ImGui.SameLine()
    if ImGui.Button('Mem Spells') then
        mq.cmdf('/memmyspells %s', globals.INIFile)
    end
end

-- Draw an INI section tab
local function DrawSection(sectionName, sectionProperties)
    if sectionName == 'Buffs' then
        useRankNames = true
    end
    if not globals.Config[sectionName] then
        globals.Config[sectionName] = {}
    end
    -- Draw main section control switches first
    if sectionProperties['Controls'] then
        DrawSectionControlSwitches(sectionName, sectionProperties['Controls'])
    end
    if ImGui.BeginChild('SectionProperties') then
        if sectionName == 'SpellSet' then
            -- special case for SpellSet tab to draw save spell set button (MA)
            DrawSpells('MySpells')
        elseif sectionName == 'Spells' then
            -- special case for Spells tab (KA)
            DrawSpells('Spells')
            -- Generic properties last
            for key,value in pairs(sectionProperties['Properties']) do
                if value['Type'] ~= 'LIST' then
                    DrawProperty(sectionName, key, value)
                end
            end
        end
        if selectedListItem[1] then
            if ImGui.Button('Back to List') then
                selectedListItem = {nil, 0}
                selectedUpgrade = nil
            else
                DrawSpellIconOrButton(sectionName, selectedListItem[1], selectedListItem[2])
                DrawSelectedListItem(sectionName, selectedListItem[1], sectionProperties['Properties'][selectedListItem[1]])
            end
        else
            -- Draw List properties before general properties
            for key,value in pairs(sectionProperties['Properties']) do
                if value['Type'] == 'LIST' then
                    DrawList(sectionName, key, value)
                end
            end
            -- Generic properties last
            for key,value in pairs(sectionProperties['Properties']) do
                if value['Type'] ~= 'LIST' then
                    DrawProperty(sectionName, key, value)
                end
            end
        end
    end
    if sectionName == 'Buffs' then
        useRankNames = false
    end
    ImGui.EndChild()
end

local function DrawSplitter(thickness, size0, min_size0)
    local x,y = ImGui.GetCursorPos()
    local delta = 0
    ImGui.SetCursorPosX(x + size0)

    ImGui.PushStyleColor(ImGuiCol.Button, 0, 0, 0, 0)
    ImGui.PushStyleColor(ImGuiCol.ButtonActive, 0, 0, 0, 0)
    ImGui.PushStyleColor(ImGuiCol.ButtonHovered, 0.6, 0.6, 0.6, 0.1)
    ImGui.Button('##splitter', thickness, -1)
    ImGui.PopStyleColor(3)

    ImGui.SetItemAllowOverlap()

    if ImGui.IsItemActive() then
        delta,_ = ImGui.GetMouseDragDelta()

        if delta < min_size0 - size0 then
            delta = min_size0 - size0
        end
        if delta > 200 - size0 then
            delta = 200 - size0
        end

        size0 = size0 + delta
        leftPanelWidth = size0
    else
        leftPanelDefaultWidth = leftPanelWidth
    end
    ImGui.SetCursorPosX(x)
    ImGui.SetCursorPosY(y)
end

local function LeftPaneWindow()
    local x,y = ImGui.GetContentRegionAvail()
    if ImGui.BeginChild("left", leftPanelWidth, y-1, ImGuiChildFlags.Border) then
        if ImGui.BeginTable('SelectSectionTable', 1, TABLE_FLAGS, 0, 0, 0.0) then
            ImGui.TableSetupColumn('Section Name',     0,   -1.0, 1)
            ImGui.TableSetupScrollFreeze(0, 1) -- Make row always visible
            ImGui.TableHeadersRow()

            for _,sectionName in ipairs(globals.Schema.Sections) do
                if globals.Schema[sectionName] and (not globals.Schema[sectionName].Classes or globals.Schema[sectionName].Classes[globals.MyClass]) then
                    ImGui.TableNextRow()
                    ImGui.TableNextColumn()
                    local popStyleColor = false
                    if globals.Schema[sectionName]['Controls'] and globals.Schema[sectionName]['Controls']['On'] then
                        if not globals.Config[sectionName] or not globals.Config[sectionName][sectionName..'On'] or globals.Config[sectionName][sectionName..'On'] == 0 then
                            ImGui.PushStyleColor(ImGuiCol.Text, 1, 0, 0, 1)
                        else
                            ImGui.PushStyleColor(ImGuiCol.Text, 0, 1, 0, 1)
                        end
                        popStyleColor = true
                    end
                    local sel = ImGui.Selectable(sectionName, selectedSection == sectionName)
                    if sel and selectedSection ~= sectionName then
                        selectedListItem = {nil,0}
                        selectedSection = sectionName
                    end
                    if popStyleColor then ImGui.PopStyleColor() end
                end
            end
            ImGui.Separator()
            ImGui.Separator()
            for section,_ in pairs(customSections) do
                ImGui.TableNextRow()
                ImGui.TableNextColumn()
                if ImGui.Selectable(section, selectedSection == section) then
                    selectedSection = section
                end
            end
            ImGui.EndTable()
        end
    end
    ImGui.EndChild()
end

local function RightPaneWindow()
    local x,y = ImGui.GetContentRegionAvail()
    if ImGui.BeginChild("right", x, y-1, ImGuiChildFlags.Border) then
        if customSections[selectedSection] then
            customSections[selectedSection]()
        else
            DrawSection(selectedSection, globals.Schema[selectedSection])
        end
    end
    ImGui.EndChild()
end

local function DrawWindowPanels()
    DrawSplitter(8, leftPanelDefaultWidth, 75)
    ImGui.PushStyleVar(ImGuiStyleVar.WindowPadding, 2, 2)
    LeftPaneWindow()
    ImGui.SameLine()
    RightPaneWindow()
    ImGui.PopStyleVar()
end

local function SetSchemaVars(selectedSchema)
    local ok, schemaMod = pcall(require, 'muleassist.ui.schemas.'..selectedSchema)
    if not ok then print('Error loading schema for: '..selectedSchema) return false end
    ok, addonMod = pcall(require, 'addons.'..selectedSchema)
    if not ok then print('Error loading schema for: '..selectedSchema) return false end

    customSections = addonMod
    globals.Schema = schemaMod
    globals.CurrentSchema = selectedSchema
    globals.INIFile = utils.FindINIFile()
    selectedSection = 'General'
    if globals.INIFile and utils.FileExists(mq.configDir..'/'..globals.INIFile) then
        globals.Config = LIP.load(mq.configDir..'/'..globals.INIFile)
        globals.INIFileContents = utils.ReadRawINIFile()
        globals.INILoadError = ''
    else
        globals.INIFile = ''
        globals.Config = {}
    end
    return true
end

local function DrawComboBox(label, resultvar, options)
    if ImGui.BeginCombo(label, resultvar) then
        for i,j in pairs(options) do
            if ImGui.Selectable(j, j == resultvar) then
                resultvar = j
            end
        end
        ImGui.EndCombo()
    end
    return resultvar
end

local radioValue = 1
local function DrawWindowHeaderSettings()
    if #globals.Schemas > 1 then
        for idx, schema_kind in ipairs(globals.Schemas) do
            radioValue,_ = ImGui.RadioButton(schema_kind, radioValue, idx)
            ImGui.SameLine()
        end
        if globals.CurrentSchema ~= globals.Schemas[radioValue] then
            if not SetSchemaVars(globals.Schemas[radioValue]) then
                radioValue = 1
            end
        end
        ImGui.NewLine()
        ImGui.Separator()
    end

    ImGui.Text('INI File: ')
    ImGui.SameLine()
    ImGui.SetCursorPosX(120)
    ImGui.PushItemWidth(350)
    globals.INIFile,_ = ImGui.InputText('##INIInput', globals.INIFile)
    ImGui.SameLine()
    if ImGui.Button('Choose...') then
        filedialog.set_file_selector_open(true)
    end
    ImGui.SameLine()
    if ImGui.Button('Save INI') then
        Save()
        globals.INIFileContents = utils.ReadRawINIFile()
    end
    ImGui.SameLine()
    if ImGui.Button('Reload INI') then
        if globals.INIFile:sub(-string.len('.ini')) ~= '.ini' then
            globals.INIFile = globals.INIFile .. '.ini'
        end
        if utils.FileExists(mq.configDir..'/'..globals.INIFile) then
            globals.Config = LIP.load(mq.configDir..'/'..globals.INIFile)
            globals.INILoadError = ''
        else
            globals.INILoadError = ('INI File %s/%s does not exist!'):format(mq.configDir, globals.INIFile)
        end
    end

    if filedialog.is_file_selector_open() then
        filedialog.draw_file_selector(mq.configDir, '.ini')
    end
    if not filedialog.is_file_selector_open() and filedialog.get_filename() ~= '' then
        globals.INIFile = filedialog.get_filename()
        globals.Config = LIP.load(mq.configDir..'/'..globals.INIFile)
        globals.INILoadError = ''
        filedialog:reset_filename()
    end

    if globals.INILoadError ~= '' then
        ImGui.TextColored(1,0,0,1,globals.INILoadError)
    end

    local match_found = false
    for _,startcommand in ipairs(globals.Schema['StartCommands']) do
        if startcommand == globals.MAUI_Config[maui_ini_key]['StartCommand'] then
            selected_start_command = startcommand
            match_found = true
            break
        end
    end
    if not match_found then
        if globals.MAUI_Config[maui_ini_key]['StartCommand'] then
            selected_start_command = 'custom'
        else
            selected_start_command = globals.Schema['StartCommands'][1]
        end
    end

    ImGui.Separator()
    ImGui.Text('Start Command: ')
    ImGui.SameLine()
    ImGui.SetCursorPosX(120)
    ImGui.PushItemWidth(190)
    selected_start_command = DrawComboBox('##StartCommands', selected_start_command, globals.Schema['StartCommands'])
    ImGui.SameLine()
    ImGui.PushItemWidth(300)
    if selected_start_command == 'custom' then
        globals.MAUI_Config[maui_ini_key]['StartCommand'],_ = ImGui.InputText('##StartCommand', globals.MAUI_Config[maui_ini_key]['StartCommand'])
    else
        globals.MAUI_Config[maui_ini_key]['StartCommand'],_ = ImGui.InputText('##StartCommand', selected_start_command)
    end
    --ImGui.SameLine()
    ImGui.Text('Status: ')
    ImGui.SameLine()
    ImGui.SetCursorPosX(120)
    if not mq.TLO.Macro() or mq.TLO.Macro.Name() ~= 'muleassist.mac' then
        ImGui.TextColored(1, 0, 0, 1, 'STOPPED')
        ImGui.SameLine()
        if ImGui.Button('Start Macro') then
            mq.cmd(globals.MAUI_Config[maui_ini_key]['StartCommand'])
            SaveMAUIConfig()
        end
    elseif mq.TLO.Macro.Name() == 'muleassist.mac' then
        if mq.TLO.Macro.Paused() then
            ImGui.TextColored(1, 1, 0, 1, 'PAUSED')
            ImGui.SameLine()
            if ImGui.Button('End') then
                mq.cmd('/end')
            end
            ImGui.SameLine()
            if ImGui.Button('Resume') then
                mq.cmd('/mqp off')
            end
        else
            ImGui.TextColored(0, 1, 0, 1, 'RUNNING')
            ImGui.SameLine()
            if ImGui.Button('End') then
                mq.cmd('/end')
            end
            ImGui.SameLine()
            if ImGui.Button('Pause') then
                mq.cmd('/mqp on')
            end
        end
        ImGui.SameLine()
        ImGui.Text(string.format('Role: %s', mq.TLO.Macro.Variable('Role')()))
    end
    if globals.Config.error then
        ImGui.SameLine()
        ImGui.TextColored(1,0,0,1,globals.Config.error)
    end
    ImGui.Separator()
end

local function push_styles()
    ImGui.PushStyleColor(ImGuiCol.WindowBg, 0, 0, 0, .9)
    ImGui.PushStyleColor(ImGuiCol.TitleBg, .3, 0, 0, 1)
    ImGui.PushStyleColor(ImGuiCol.TitleBgActive, .5, 0, 0, 1)
    ImGui.PushStyleColor(ImGuiCol.FrameBg, .2, .2, .2, 1)
    ImGui.PushStyleColor(ImGuiCol.FrameBgHovered, .3, 0, 0, 1)
    ImGui.PushStyleColor(ImGuiCol.FrameBgActive, .3, 0, 0, 1)
    ImGui.PushStyleColor(ImGuiCol.Button, .5, 0, 0,1)
    ImGui.PushStyleColor(ImGuiCol.ButtonHovered, .6, 0, 0,1)
    ImGui.PushStyleColor(ImGuiCol.ButtonActive, .5, 0, 0,1)
    ImGui.PushStyleColor(ImGuiCol.PopupBg, .1,.1,.1,1)
    ImGui.PushStyleColor(ImGuiCol.TextDisabled, 1, 1, 1, 1)
    ImGui.PushStyleColor(ImGuiCol.CheckMark, .5, 0, 0, 1)
    ImGui.PushStyleColor(ImGuiCol.Separator, .4, 0, 0, 1)
end

local function pop_styles()
    ImGui.PopStyleColor(13)
end

local MAUI = function()
    if not open then return end
    local used_theme = false
    if globals.Theme == 'red' then
        push_styles()
        used_theme = true
    end
    open, shouldDrawUI = ImGui.Begin('MAUI (v'..globals.Version..')###MuleAssist', open)
    if shouldDrawUI then
        -- these appear to be the numbers for the window on first use... probably shouldn't rely on them.
        if initialRun then
            if ImGui.GetWindowHeight() == 38 and ImGui.GetWindowWidth() == 32 then
                ImGui.SetWindowSize(727,487)
            elseif ImGui.GetWindowHeight() == 500 and ImGui.GetWindowWidth() == 500 then
                ImGui.SetWindowSize(727,487)
            end
            initialRun = false
        end
        DrawWindowHeaderSettings()
        DrawWindowPanels()
    end
    ImGui.End()
    if used_theme then pop_styles() end
    -- Live-apply bridge: when embedded, debounce config edits -> flush INI -> reapply.
    if apply_opts and globals.Config then
        local now = os.clock()
        if not cfg_snapshot then cfg_snapshot = diff.snapshot(globals.Config) end
        if diff.changed(globals.Config, cfg_snapshot) then
            cfg_snapshot = diff.snapshot(globals.Config)
            apply_db:touch(now)
        end
        if apply_db:due(now) then
            local ok = pcall(Save)             -- flush globals.Config -> bot INI (LIP)
            if ok and apply_opts.on_apply then apply_opts.on_apply() end
        end
    end
end

local function CheckGameState()
    if mq.TLO.MacroQuest.GameState() ~= 'INGAME' then
        print('\arNot in game, stopping MAUI.\ax')
        open = false
        shouldDrawUI = false
        mq.imgui.destroy('MuleAssist')
        mq.exit()
    end
end

local function ShowHelp()
    print('\a-t[\ax\ayMAUI\ax\a-t]\ax Usage: /maui [show|hide|stop]')
end

local function BindMaui(args)
    if not args then
        ShowHelp()
    end
    local arglist = {args}
    if #arglist > 1 then
        ShowHelp()
    elseif arglist[1] == 'show' then
        open = true
    elseif arglist[1] == 'hide' then
        open = false
    elseif arglist[1] == 'stop' then
        open = false
        terminate = true
    end
end

local function NewSpellMemmed(line, spell)
    print(string.format('\a-t[\ax\ayMAUI\ax\a-t]\ax New spell memorized, updating spell list. \a-t(\ax\ay%s\ax\a-t)\ax', spell))
    -- Build spell tree for picking spells
    local spellNum = mq.TLO.Me.Book(spell)
    local spell = mq.TLO.Me.Book(spellNum)
    if spell() then
        AddSpellToMap(spell)
    end

    SortSpellMap()
end

local function load_bot_ini()
    globals.INIFile = globals.MAUI_Config['INIFile'] or utils.FindINIFile()
    if globals.INIFile and utils.FileExists(mq.configDir..'/'..globals.INIFile) then
        globals.Config = LIP.load(mq.configDir..'/'..globals.INIFile)
        globals.INIFileContents = utils.ReadRawINIFile()
        globals.INILoadError = ''
    else
        globals.INIFile = globals.Schema['INI_PATTERNS']['level']:format(globals.MyServer, globals.MyName, globals.MyLevel)
        globals.Config = {}
    end
end

local function build_trees()
    if trees_built then return end
    InitSpellTree(); InitAATree(); InitDiscTree()
    trees_built = true
end

-- Embed entry: host the panel inside another script (the bot). No keep-alive loop.
-- opts.ini_path (the bot's st.cfg.path) locks the editor to the exact file the bot
-- reloads, so live edits can't diverge to a different INI (e.g. a level-named variant).
function M.mount(opts)
    apply_opts = opts or {}
    if apply_opts.ini_path and apply_opts.ini_path ~= '' then
        globals.INIFile = apply_opts.ini_path:match('[^/\\]+$')   -- basename Save() writes
        globals.Config = utils.FileExists(apply_opts.ini_path)
            and LIP.load(apply_opts.ini_path) or {}
    else
        load_bot_ini()
    end
    cfg_snapshot = diff.snapshot(globals.Config or {})
    open = true
    -- Registration id MUST differ from the standalone's 'MuleAssist' or mq2lua's callback
    -- registry collides and crashes on unload (OnUnloadPlugin). Default to a bot-unique id.
    apply_opts.window = apply_opts.window or 'MuleAssistBot'
    mq.imgui.init(apply_opts.window, function()
        build_trees()
        MAUI()
    end)
end

function M.toggle() open = not open end
function M.show()   open = true  end

-- Tear down the registered ImGui callback. Call before the host script stops so mq2lua
-- doesn't try to invoke/free a callback into a dead Lua state on unload.
function M.unmount()
    open = false
    if apply_opts and apply_opts.window then pcall(mq.imgui.destroy, apply_opts.window) end
end

-- Standalone entry: original /lua run muleassist/ui behavior (own loop + binds).
function M.run_standalone()
    load_bot_ini()
    mq.bind('/maui', BindMaui)
    mq.event('NewSpellMemmed', '#*#You have finished scribing #1#.', NewSpellMemmed)
    mq.imgui.init('MuleAssist', MAUI)

    local init_done = false
    while not terminate do
        CheckGameState()
        mq.doevents()
        if not init_done then
            InitSpellTree(); InitAATree(); InitDiscTree()
            init_done = true
        end
        if memspell then
            local rankname = mq.TLO.Spell(memspell).RankName()
            mq.cmdf('/memspell %s "%s"', memgem, rankname)
            mq.delay('3s', function() return mq.TLO.Me.Gem(memgem)() and mq.TLO.Me.Gem(memgem).Name() == rankname end)
            mq.TLO.Window('SpellBookWnd').DoClose()
            memspell = nil
            memgem = 0
        end
        tloCache:clean()
        mq.delay(20)
    end
end

if not _G.MULEASSIST_EMBED then
    M.run_standalone()
end

return M
