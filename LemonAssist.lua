--[[
Monitors MA's target based on AssistName and keeps it populated in XTarget 1
v0.3
AssistName is now only updating within about 150 feet which is causing lots of problems if the aggresive action is taken outside of that
2nd mode that adds ToT if it's a killable npc
v0.4 
Fixed modes and other bugs
]]
local mq = require('mq')
local Write = require('Write')
Write.prefix = function() return string.format('\aw[%s] [\a-rLemonAssist\aw]\at ', mq.TLO.Time()) end
Write.loglevel = 'Info'

local assID = 0
local assName = "Lemons"
local target = 0
local numSlots = mq.TLO.Me.XTargetSlots()
xtarTable = {}
local mode = 1


--Check if the AssID is still valid
local checkAssID = function ()
    if assName ~= mq.TLO.Spawn(assID).CleanName() then
        return false else return true
        --assID = mq.TLO.Spawn("pc"..assName).ID()
        --Write.Info("\ay Reseting Assist ID to "..assID.." "..assName)
    end
end
    
--Create the table of existing XTarget IDs (in game only matches by name) Starts at end
local getXTarID = function()
    for i= numSlots,1,-1 do
        if mq.TLO.Me.XTarget(i).ID() then xtarTable[i] = mq.TLO.Me.XTarget(i).ID() 
        else xtarTable[i] = 0 end
    end
end

--Return spawn name from ID.
IDtoSpawn = function(id)
    if id == 0 then return 0 end
    return mq.TLO.Spawn(id)()
end

--Return clean name from ID.
IDtoCN = function(id)
    if id == 0 then return 0 end
    return mq.TLO.Spawn(id).CleanName()
end

--See what the AssistID is of the tank 
local detectAssistID = function()
    Write.Debug("Mode %s",mode)
    if mode == 1 then
        Write.Debug("%s %s",mq.TLO.Spawn(assID).AssistName() ~= nil,mq.TLO.Spawn(assID).AssistName() ~= "")
        if mq.TLO.Spawn(assID).AssistName() ~= nil and mq.TLO.Spawn(assID).AssistName() ~= "" then
            Write.Debug(string.format("Checking if assID has an AssistName %s %s %s",mq.TLO.Spawn(mq.TLO.Spawn(assID).AssistName()).ID(),mq.TLO.Spawn(mq.TLO.Spawn(assID).AssistName()).Type() == "NPC",mq.TLO.Spawn(assID).AssistName()))
            if mq.TLO.Spawn(mq.TLO.Spawn(assID).AssistName()).ID() and mq.TLO.Spawn(mq.TLO.Spawn(assID).AssistName()).Type() == "NPC" then 
                target = mq.TLO.Spawn(mq.TLO.Spawn(assID).AssistName()).ID() else target = 0
            end
        end
    elseif mode == 2 then
        if mq.TLO.Spawn(assID).Distance() < 150  and mq.TLO.Me.XTarget() == 0 then
            if mq.TLO.Target.ID() ~= assID then mq.cmdf("/target id %d",assID) end
            mq.delay(1000, function () return mq.TLO.Target.ID() == assID end )
            local ToT = mq.TLO.Me.TargetOfTarget.ID()
            --Write.Debug(string.format("Is added %s with %s and type %s %s", mq.TLO.Me.XTarget(ToT)(), not mq.TLO.Me.XTarget(ToT)(),mq.TLO.Spawn(ToT).Type(),mq.TLO.Spawn(ToT).Type() == "NPC"))
            if not mq.TLO.Me.XTarget(ToT)() and mq.TLO.Spawn(ToT).Type() == "NPC" then
                Write.Info(string.format("\aySetting \ao %s \ay to slot 1",ToT))
                if mq.TLO.Target.ID() ~= ToT then mq.cmdf("/target id %d",ToT) end
                mq.delay(1500, function () return mq.TLO.Target.ID() == ToT end )
                mq.cmdf('/xtarget add')
                mq.delay(10000, function () return mq.TLO.Me.XTarget() ~= 0 end)
            end
        end
    end
end
local function PlayerDesignatedSlot(slotnumber)
    --Trying to guess if it's a slot a player designated
    local isPlayerDesignated = false
    local TargetType = mq.TLO.Me.XTarget(slotnumber).TargetType()
    --if TargetType == "Specific PC" then isPlayerDesignated = true end --Added specific player to a slot
    if TargetType ~= "Auto Hater" and TargetType ~= "Specific NPC" then isPlayerDesignated = true end --Auto Hater and specific NPCs shouldn't be player designated
    return isPlayerDesignated
end

--Clear XTarget entries that have no AssistName (May have been added by mistake)This may cause some issues for mezzed stuff?
clearXTar = function()
    local numSlots = mq.TLO.Me.XTargetSlots()
    for i= numSlots,1,-1 do
        local XT = mq.TLO.Me.XTarget(i)
        local XTi = mq.TLO.Me.XTarget(i).ID()
        local XTt = mq.TLO.Me.XTarget(i).TargetType() --The type of XTarget slot, not the type of creature
        --Write.Debug(string.format("|%s| |%s| |%s| |%s|",i,XT,XTi,XTt))
        if XTi ~= 0 then
            --Write.Debug("XTi not 0")
	
            if (not XT.AssistName() and XT.ID() ~= 0 and not PlayerDesignatedSlot(i)) or (XT.Type() == "Corpse" and XT.TargetType() == "Specific NPC") or (XT.Master.ID() ~= 0) then 
                mq.cmdf('/xtarget set %i autohater',i)
                if not XT.AssistName() then Write.Info(string.format("\ayRemoving XTarget \ao %s \aysince it is \ao %s",i,XT.AssistName())) end
                mq.delay(5000, function() return XT.TargetType() == "Auto Hater" end)
            end
        else 
            --Write.Debug(string.format("2nd: %s %s |%s| |%s|",i,XT,XTi,XTt))
            if XTt == "UNKNOWN" then
                mq.cmdf('/xtarget set %i autohater',i)
                Write.Info(string.format("Broken XTarget detected. Attempting to fix slot %s",i))
                mq.delay(5000, function() return XT.TargetType() == "Auto Hater" end)
                
            end
        end
    end
end

--Add the AssistID to XTarget if it's not there. Uses the first empty slot or slot 1
local setXAssist = function()
    --Write.Debug(string.format("Checking for stale repeat names %s",mq.TLO.Spawn(target).AssistName()))
    if mq.TLO.Spawn(target).AssistName() == "" or target == 0 then return end --Respawns that have the same name which will get added even if they have no agro. 
    local tarDist = mq.TLO.Spawn(target).Distance()
    local foundOpenSlot = false
    for i=1,numSlots,1 do
        Write.Debug(string.format("Checking for valid entry i:%s PlayerDesig:%s NoIDinSlot:%s targetExists:%s TargNotOnXT:%s Not1:%s on target %s %s",i,PlayerDesignatedSlot(i),xtarTable[i] == 0,target ~= 0,not mq.TLO.Me.XTarget(IDtoCN(target))(),i ~= 1,target, IDtoCN(target)))
        if not PlayerDesignatedSlot(i) and xtarTable[i] == 0 and target ~= 0 and not mq.TLO.Me.XTarget(IDtoCN(target))() then --Xtarget slot open, we have a target, it's not elsewhere on my xtarget and this isn't the first slot
            Write.Debug(string.format("Distance is %s and type is %s which is %s",tarDist,mq.TLO.Me.XTarget(i).Type(),mq.TLO.Me.XTarget(i).Type() == "NPC"))
            if tarDist and tarDist <= 200  and mq.TLO.Spawn(target).Type() == "NPC" then
                Write.Info(string.format("\aySetting \ao %s \ay to slot %s",IDtoSpawn(target),i))
                mq.cmdf('/xtarget set %i %s', i, IDtoSpawn(target))
                mq.delay(5000, function () return mq.TLO.Me.XTarget(IDtoCN(target))() end )
                foundOpenSlot = true
                break
            end
            return
        end
    end
    if not foundOpenSlot and target ~= 0 then
        if not mq.TLO.Me.XTarget(IDtoCN(target))() then
            if tarDist and tarDist <= 200  and mq.TLO.Spawn(target).Type() == "NPC" then
                mq.cmdf('/xtarget set 1 %s',IDtoSpawn(target)) 
                Write.Error(string.format("\aySetting \ao %s \ay to default slot 1 since you have no open slots",IDtoSpawn(target)))
                mq.delay(5000, function () return mq.TLO.Me.XTarget(IDtoCN(target))() end )
            end
        end
    end
end

--Command function to set the Assist to watch as your target or the MainAssistID. /lassist will default to muleassist mac MTID or your current target. /lassist name
local lassist = function(idd)
    if not idd then id = "0" else id = idd end
    if id == "debug" then 
        Write.Info(string.format("Assist Target is %s, assName is %s, assID is %s %s, .AssistName is %s",target,assName,assID,mq.TLO.Spawn(assID)(),mq.TLO.Spawn(assID).AssistName()))
        return
    end
    if id == "mode1" then mode = 1 Write.Info("Mode now set to 1 (normal AssistName adding") return end
    if id == "mode2" then mode = 2 Write.Info("Mode now set to 2 (Adding ToT of MA to slot 1 always") return end
    Write.Debug(string.format("Passed in %s %s %s", id, mq.TLO.Spawn(id).ID(), mq.TLO.Spawn(id)))
    if mq.TLO.Spawn(id).ID() ~= 0 then 
        assID = mq.TLO.Spawn(id).ID() 
        assName = mq.TLO.Spawn(assID).CleanName()
        --Write.Info("1")
        if assID and assName then Write.Info(string.format("\ayAssisting MA \ao %s %s",assID,assName)) end
    elseif mq.TLO.Macro() == "muleassist.mac" then
        assID = mq.TLO.Macro.Variable('MainAssistID')()
        assName = mq.TLO.Spawn(assID).CleanName()
        --Write.Info("2")
        if assID and assName then Write.Info(string.format("\ayAssisting MA macro \ao %s %s",assID,assName)) end
    else
        if mq.TLO.Target.Type() ~= "NPC" then 
            assID = mq.TLO.Target.ID() 
            assName = mq.TLO.Spawn(assID).CleanName()
        -- Write.Info("3")
            if assID and assName then Write.Info(string.format("\ayAssisting target MA \ao %s %s",assID,assName)) end  
        end
    end
end

--Create the /LASSIST command
mq.bind('/lassist', lassist)

--The loop
lassist()
while not checkAssID() do
    Write.Info(string.format("\ay No Assist ID. Use \"/lassist AssistName\" ID:%s Name:%s",assID,assName))
    mq.delay(5000, function () return mq.TLO.Me.XTarget(IDtoCN(target))() end )
    lassist()
end
while true do
    getXTarID()
    if mq.TLO.Me.ID() ~= assID then
        detectAssistID()
        setXAssist()
    end
    mq.delay(1500)
    clearXTar()
    checkAssID()
end
