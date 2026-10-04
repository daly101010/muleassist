-- necrobrain/ttd.lua — time-to-death from HP% samples over a sliding window,
-- seeded from companion history when samples are thin. Pure (no mq).
--
-- Long-bias rule: this estimate feeds a gate where a SHORT estimate makes the
-- necromancer stop casting (the failure this module exists to prevent), while
-- a LONG estimate only wastes mana. Every ambiguous case below is resolved by
-- picking the interpretation that produces the LONGER estimate (or bails to
-- 'notdying'/'none' rather than guessing short).
--
-- Rate = the slower of two windows: a "full" window (all retained samples,
-- up to WINDOW_MS) and a "recent" window (samples within the last RECENT_MS
-- of the last sample). Using the slower of the two means a decline that is
-- decelerating (fast earlier, flat lately) reports the flatter recent rate
-- instead of the optimistic full-window average. If the recent window itself
-- is flat for FLAT_MS+, the mob is treated as not dying at all ('notdying'),
-- regardless of what the full window says.
--
-- The recent window may only lengthen a 'measured' estimate (by supplying a
-- slower rate than the full window) or declare the mob not dying; it can
-- never be the sole source of a measured rate — a valid full-window rate is
-- required before the recent rate is even consulted.
local M = {}
local WINDOW_MS, SAMPLE_MS, MIN_SPAN_MS, MIN_DECLINE = 20000, 1000, 3000, 0.5
local FLAT_MS = 9000
local RECENT_MS = 10000
local hist = {}  -- mobId -> { name, samples = { {pct, at} }, engagedAt, engagedPct }
-- A seed the mob has already outlived (alive this long past engagedAt + seed * engagedPct/100) was
-- wrong for this mob: it no longer caps the live estimate or stands in for a thin one.
M.OUTLIVED_SLACK_S = 2
-- History's average counts as this many session windows when both seed a mob name (never more than the
-- number of windows history actually holds).
M.SESSION_BLEND_K = 2
-- A gap this long between samples means the brain was not watching this mob (another target, parser
-- down): what happened meanwhile is unknown, so the window and the engagement clock start over.
M.UNWATCHED_MS = 10000

function M.reset(mobId) hist[mobId] = nil end

function M.observe(mobId, mobName, pct, nowMs)
    pct = tonumber(pct); if not pct then return end
    local h = hist[mobId]
    if not h or h.name ~= mobName then
        h = { name = mobName, samples = {} }
        hist[mobId] = h
    end
    -- Full HP = not engaged yet (or fully regenerated). Keep only THIS sample as the window:
    -- idle time at 100% never accumulates (so it can't read as flat 'notdying' or dilute the
    -- rate), but the last 100% sample still anchors the first real decline correctly.
    if pct >= 100 then
        h.samples = { { pct = pct, at = nowMs } }
        h.engagedAt, h.engagedPct = nil, nil
        return
    end
    local s = h.samples
    local last = s[#s]
    if last and (nowMs - last.at) > M.UNWATCHED_MS then
        s = {}; h.samples = s; last = nil
        h.engagedAt, h.engagedPct = nil, nil
    end
    if #s > 0 then
        local minPct = s[1].pct
        for i = 2, #s do if s[i].pct < minPct then minPct = s[i].pct end end
        if pct > minPct + 10 then
            s = {}; h.samples = s; last = nil   -- heal / reset: start over
            h.engagedAt, h.engagedPct = nil, nil
        end
    end
    -- Not engaged yet: a leading plateau below full HP (a tagged mob walking in, a mob parked before its
    -- fight, regenerating a little) is kept to its newest sample, like the 100% rule, so idle time
    -- neither reads as 'notdying' nor counts toward outliving the seed. The clock starts at the first
    -- drop below the plateau's top (a rise just raises the plateau); that last plateau sample (or the
    -- 100% anchor) anchors the first real rate.
    if not h.engagedAt then
        local top = nil
        for _, x in ipairs(s) do if not top or x.pct > top then top = x.pct end end
        if top == nil or (top - pct) < MIN_DECLINE then
            h.samples = { { pct = pct, at = nowMs } }
            return
        end
        h.engagedAt, h.engagedPct = nowMs, pct
    end
    if not last or (nowMs - last.at) >= SAMPLE_MS then
        s[#s + 1] = { pct = pct, at = nowMs }
    end
    while #s > 1 and (nowMs - s[1].at) > WINDOW_MS do table.remove(s, 1) end
end

function M.estimate(mobId, pct, historyRec)
    pct = tonumber(pct)
    if not pct then return nil, 'none' end
    if pct <= 0 then return 0, 'measured' end
    if pct >= 100 then
        -- untouched mob: only history can say anything
        local avgDur0 = historyRec and tonumber(historyRec.avgDur)
        if avgDur0 and avgDur0 > 0 then return avgDur0, 'history' end
        return nil, 'none'
    end

    local h = hist[mobId]
    local seed0 = historyRec and tonumber(historyRec.avgDur)
    local outlived = false
    if seed0 and seed0 > 0 and h and h.engagedAt and #h.samples > 0 then
        local elapsed = (h.samples[#h.samples].at - h.engagedAt) / 1000
        outlived = elapsed > seed0 * (h.engagedPct or 100) / 100 + M.OUTLIVED_SLACK_S
    end
    if h and #h.samples >= 2 then
        local samples = h.samples
        local first, last = samples[1], samples[#samples]

        local spanFull = (last.at - first.at) / 1000
        local declineFull = first.pct - last.pct
        local rateFullValid = spanFull >= (MIN_SPAN_MS / 1000) and declineFull >= MIN_DECLINE
        local rateFull = rateFullValid and (declineFull / spanFull) or nil

        -- recent window: first sample with at >= last.at - RECENT_MS .. last
        local recentFirst = last
        for i = 1, #samples do
            if samples[i].at >= last.at - RECENT_MS then
                recentFirst = samples[i]
                break
            end
        end
        local spanRecent = (last.at - recentFirst.at) / 1000
        local declineRecent = recentFirst.pct - last.pct

        -- recent window flat for FLAT_MS+ -> not dying, regardless of full window
        if spanRecent * 1000 >= FLAT_MS and declineRecent < MIN_DECLINE then
            return 999, 'notdying'
        end

        local rateRecentValid = spanRecent >= (MIN_SPAN_MS / 1000) and declineRecent >= MIN_DECLINE
        local rateRecent = rateRecentValid and (declineRecent / spanRecent) or nil

        -- Recent may only lower (lengthen) a rate the full window already
        -- validated; it is never used on its own to produce a measured rate.
        if rateFull then
            -- A seed built from real kills outranks a measurement with less than FLAT_MS of
            -- samples behind it: three seconds of tank burst read as a 24 s fight and bought
            -- a three-tick DoT on a 15 s mob. With no seed, a thin measurement is still better
            -- than nothing.
            local seed = historyRec and tonumber(historyRec.avgDur)
            if seed and seed > 0 and spanFull * 1000 < FLAT_MS and not outlived then
                return seed * pct / 100, 'history'
            end
            local rate = rateFull
            -- A MATURE recent window (>= FLAT_MS span, >= 3% decline) is the current truth and
            -- replaces the full-window rate outright: a mob that sat mezzed and is now being burned
            -- must not read as slow because of the idle half of the window. A thin recent window
            -- may still only lengthen the estimate.
            if rateRecent and spanRecent * 1000 >= FLAT_MS and declineRecent >= 3 then
                rate = rateRecent
            elseif rateRecent and rateRecent < rate then
                rate = rateRecent
            end
            local est = pct / rate
            -- With a seed from real kills of this mob, the live estimate may not wander beyond
            -- 0.5x..1.5x of the seed's remaining time: a 43 s reading on a mob whose kills average
            -- 17 s bought a DoT that landed one tick.
            if seed and seed > 0 then
                local rem = seed * pct / 100
                if est > rem * 1.5 and not outlived then est = rem * 1.5 end
                if est < rem * 0.5 then est = rem * 0.5 end
            end
            return est, 'measured'
        end

        if spanFull * 1000 >= FLAT_MS and declineFull < MIN_DECLINE then
            return 999, 'notdying'
        end
    end

    local avgDur = historyRec and tonumber(historyRec.avgDur)
    if avgDur and avgDur > 0 then
        -- a seed this mob has outlived is known short; no estimate is the long-safe answer
        if outlived then return nil, 'none' end
        return avgDur * pct / 100, 'history'
    end
    return nil, 'none'
end

-- The TTD seed for a mob name: this session's kill windows (sessionList, seconds) blended with
-- history's average, which counts as SESSION_BLEND_K windows, so one odd session window cannot
-- override 10-40 historical ones. No session windows = hrec unchanged.
function M.seedFrom(sessionList, hrec)
    if not (sessionList and #sessionList > 0) then return hrec end
    local sum, n = 0, #sessionList
    for _, w in ipairs(sessionList) do sum = sum + w end
    local avg = sum / n
    local histAvg = hrec and tonumber(hrec.avgDur)
    local source = 'session'
    if histAvg and histAvg > 0 then
        local k = math.min(M.SESSION_BLEND_K, tonumber(hrec.fights) or M.SESSION_BLEND_K)
        if k > 0 then
            avg = (sum + histAvg * k) / (n + k)
            source = 'session+history'
        end
    end
    local out = { avgDur = avg, lastDur = sessionList[n], fights = n, source = source }
    if hrec then out.maxHP, out.hpWeight = hrec.maxHP, hrec.hpWeight end
    return out
end

return M
