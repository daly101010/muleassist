-- focusswap/ini.lua — pure readers for the muleassist character INI: the [DPS] spell names in list
-- order, and [FocusSwap] weight overrides. No mq dependency.
local M = {}

function M.parse(text)
    local out, cur = {}, nil
    for line in ((text or '') .. '\n'):gmatch('([^\r\n]*)\r?\n') do
        local sec = line:match('^%s*%[(.-)%]%s*$')
        if sec then
            out[sec] = out[sec] or {}
            cur = out[sec]
        elseif cur then
            local k, v = line:match('^%s*([^=;]-)%s*=%s*(.-)%s*$')
            if k and k ~= '' then cur[k] = v end
        end
    end
    return out
end

-- DPS1..DPS<DPSSize> (every DPS<n> up to the highest when DPSSize is missing): the spell part before
-- the first '|', as written in the INI. The macro rewrites this to the spell's rank name before it
-- reaches CastWhat (Spell_Rk_Check), and scan.lua keys the map on that RankName, falling back to this
-- INI text only when the spell has no rank.
function M.dpsSpells(sections)
    local dps = sections.DPS or {}
    local size = tonumber(dps.DPSSize)
    if not size then
        size = 0
        for k in pairs(dps) do
            local n = tonumber(k:match('^DPS(%d+)$'))
            if n and n > size then size = n end
        end
    end
    local out, seen = {}, {}
    for i = 1, size do
        local v = dps['DPS' .. i]
        local name = v and v:match('^([^|]*)')
        name = name and name:match('^%s*(.-)%s*$')
        if name and name ~= '' and name ~= 'NULL' and not seen[name] then
            seen[name] = true
            out[#out + 1] = name
        end
    end
    return out
end

-- defaults overlaid with [FocusSwap] Weight<SPA>=<number>; the defaults table is not changed
function M.weights(sections, defaults)
    local w = {}
    for spa, v in pairs(defaults or {}) do w[spa] = v end
    for k, v in pairs(sections.FocusSwap or {}) do
        local spa = tonumber(k:match('^Weight(%d+)$'))
        local n = tonumber(v)
        if spa and n then w[spa] = n end
    end
    return w
end

return M
