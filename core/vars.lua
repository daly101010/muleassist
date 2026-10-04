-- core/vars.lua: the macro-variable view of the Lua bot, for MALua and other UIs.
-- ${MuleAssist.Var[Name]} answers the names muleassist.mac exposed as macro variables
-- (Macro.Variable[Name]) with the same value formats, so a UI ported from MAUI only swaps
-- the query: locally mq.TLO.MuleAssist.Var(name)(), over DanNet "MuleAssist.Var[Name]".
-- Unknown names answer nil (NULL), like an undeclared macro variable read through Macro.Variable.
local State = require('core.state')

local M = {}

local function flag(v) return v and '1' or '0' end
local function idList(set)
    local ids = {}
    for id in pairs(set or {}) do ids[#ids + 1] = tonumber(id) or 0 end
    table.sort(ids)
    if #ids == 0 then return '' end
    local out = {}
    for _, id in ipairs(ids) do out[#out + 1] = tostring(id) end
    return '|' .. table.concat(out, '|') .. '|'
end
local function mod(name) return package.loaded['modules.' .. name] end

--- muleassist.mac's KillOrderList format: '|' then 'id|' or '~name|' per entry ('|' when empty).
function M.killOrderList()
    local modes = mod('modes')
    local out = { '|' }
    for _, e in ipairs((modes and modes.ko and modes.ko.list) or {}) do
        if e.id then out[#out + 1] = tostring(e.id) .. '|'
        elseif e.name then out[#out + 1] = '~' .. e.name .. '|' end
    end
    return table.concat(out)
end

local VARS = {
    Role = function() return State.role end,
    MainAssist = function() return State.mainAssist end,
    MyTargetID = function() return tostring(State.myTargetId or 0) end,
    ChaseAssist = function() return flag(State.chaseAssist) end,
    ReturnToCamp = function() return flag(State.returnToCamp) end,
    ManualOn = function() return flag(State.manualOn) end,
    AggroPaused = function() return flag(State.aggroPaused) end,
    GetAwayOn = function() return flag(State.getAwayOn) end,
    KillOrderOn = function() return flag(State.killOrderOn) end,
    KillOrderTarget = function() return tostring(State.killOrderTarget or 0) end,
    KillOrderList = function() return M.killOrderList() end,
    KillOrderMaxDist = function()
        local modes = mod('modes')
        return tostring((modes and modes.cfg and modes.cfg.KillOrderMaxDist) or 300)
    end,
    MarkAssistOn = function() return flag(State.markAssistOn) end,
    RaidMarkNum = function() return tostring(State.raidMarkNum or 1) end,
    MezImmuneIDs = function() local mez = mod('mez') return idList(mez and mez.immuneIds) end,
    CharmSkipIDs = function() local mez = mod('mez') return idList(mez and mez.charmSkipIds) end,
    BuffMode = function() return flag(State.buffMode) end,
    ZombieMode = function() return flag(State.zombieMode) end,
}
M.names = {}
for k in pairs(VARS) do M.names[#M.names + 1] = k end
table.sort(M.names)

--- The value of a macro-variable name as a string, or nil when the name is unknown.
function M.get(name)
    local fn = VARS[tostring(name or '')]
    if not fn then return nil end
    local ok, v = pcall(fn)
    if not ok or v == nil then return nil end
    return tostring(v)
end

return M
