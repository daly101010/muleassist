-- Canonical class capability check for Healing Intelligence.

local M = {}

local SUPPORTED = {
    CLR = true,
    DRU = true,
    SHM = true,
    PAL = true,
    CLERIC = true,
    DRUID = true,
    SHAMAN = true,
    PALADIN = true,
}

--- Return whether a class name or short name is supported by Healing Intelligence.
---@param className any
---@return boolean
function M.isSupported(className)
    local normalized = tostring(className or ''):match('^%s*(.-)%s*$'):upper()
    return SUPPORTED[normalized] == true
end

return M
