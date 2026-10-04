-- necrobrain/resist.lua — per-mob, per-element resist memory for the ranker's mobResist.
-- Blends this character's live outcomes on the mob (feed: claimed resists and landed casts,
-- inside a rolling window) with its history on the same mob (companion event rows) and a weak
-- prior, so a boss that eats one element is avoided after a few casts instead of being fed
-- the same resisted spell all fight. Pure (no mq).
local M = {}
M.PRIOR_RATE = 0.15       -- 1 - ranker DEFAULT_LAND
M.PRIOR_WEIGHT = 3        -- worth three casts: three straight resists reach AVOID_RESIST (0.50)
M.HIST_WEIGHT_MAX = 6     -- history never outweighs a handful of live casts
M.WINDOW_MS = 180000      -- live outcomes older than this drop out (debuffs change the picture)
M.MAX_SAMPLES = 20
M.BASE_CD_MS = 2500       -- refusal cooldown for one CAST_RESIST verdict
M.MAX_CD_MS = 20000

local Mem = {}
Mem.__index = Mem

function M.new() return setmetatable({ samples = {} }, Mem) end

local function key(mob, rtype)
    if type(mob) ~= 'string' or mob == '' or type(rtype) ~= 'string' or rtype == '' then return nil end
    rtype = rtype:lower()
    if rtype == 'unresistable' then return nil end
    return mob:lower() .. '|' .. rtype
end

function Mem:record(mob, rtype, resisted, now)
    local k = key(mob, rtype)
    if not k then return end
    local list = self.samples[k] or {}
    list[#list + 1] = { at = tonumber(now) or 0, resisted = resisted and true or false }
    while #list > M.MAX_SAMPLES do table.remove(list, 1) end
    self.samples[k] = list
end

-- Smoothed resist rate for my casts of this element on this mob, or nil with no evidence.
function Mem:rate(mob, rtype, now, histResists, histCasts)
    local k = key(mob, rtype)
    if not k then return nil end
    local n, r = 0, 0
    local list = self.samples[k]
    if list then
        local cutoff = (tonumber(now) or 0) - M.WINDOW_MS
        local i = 1
        while i <= #list do
            local s = list[i]
            if s.at < cutoff then
                table.remove(list, i)
            else
                n = n + 1
                if s.resisted then r = r + 1 end
                i = i + 1
            end
        end
    end
    local hc, hr = tonumber(histCasts) or 0, tonumber(histResists) or 0
    if hc > 0 then
        hr = math.min(math.max(hr, 0), hc)
        local w = math.min(hc, M.HIST_WEIGHT_MAX)
        n = n + w
        r = r + w * hr / hc
    end
    if n <= 0 then return nil end
    return (r + M.PRIOR_RATE * M.PRIOR_WEIGHT) / (n + M.PRIOR_WEIGHT)
end

-- Back-to-back CAST_RESIST verdicts on one spell/mob double the refusal cooldown each time.
function M.refusalCooldown(streak)
    local s = math.max(1, math.floor(tonumber(streak) or 1))
    return math.min(M.MAX_CD_MS, M.BASE_CD_MS * 2 ^ (s - 1))
end

return M
