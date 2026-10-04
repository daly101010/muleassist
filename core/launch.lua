-- core/launch.lua - the /lua run muleassist command line: <role> [MA] [rmark N],
-- as /mac muleassist took it. rmark N (1-3) turns mark assist on from launch;
-- the pair is pulled out first so N is never read as the role or the MA.
local M = {}

function M.parse(args)
    local out, rest = { role = nil, mainAssist = nil, rmark = nil, rmarkBad = false }, {}
    local i = 1
    while i <= #args do
        local a = tostring(args[i] or '')
        if a:lower() == 'rmark' then
            local n = tonumber(args[i + 1])
            if n and (n == 1 or n == 2 or n == 3) then out.rmark = n else out.rmarkBad = true end
            i = i + 2
        else
            rest[#rest + 1] = a
            i = i + 1
        end
    end
    if rest[1] and rest[1] ~= '' then out.role = rest[1]:lower() end
    if rest[2] and rest[2] ~= '' and rest[2]:upper() ~= 'NULL' then out.mainAssist = rest[2] end
    return out
end

return M
