-- necrobrain/dpslist.lua — the necro's own muleassist [DPS] list, enriched with
-- spell attributes from the TLO so the ranker can score it.
local mq = require('mq')
local M = {}

function M.parseIni(text)
    local inDps, size = false, nil
    local spells, conds = {}, {}
    for line in (text .. '\n'):gmatch('([^\r\n]*)\r?\n') do
        local sec = line:match('^%[(.-)%]%s*$')
        if sec then inDps = (sec == 'DPS')
        elseif inDps then
            local k, v = line:match('^([%w]+)=(.*)$')
            if k == 'DPSSize' then size = tonumber(v)
            elseif k then
                local n = k:match('^DPSCond(%d+)$')
                if n then conds[tonumber(n)] = v
                else
                    n = k:match('^DPS(%d+)$')
                    if n then spells[tonumber(n)] = v end
                end
            end
        end
    end
    local out = {}
    for i = 1, (size or #spells) do
        local v = spells[i]
        if v and v ~= '' then
            local spell, opts = v:match('^([^|]+)|?(.*)$')
            out[#out + 1] = { index = i, spell = spell, opts = opts or '', cond = conds[i] or 'TRUE' }
        end
    end
    return out
end

local function num(v) return tonumber(v) or 0 end
-- Optional TLO members (older fakes and some builds lack them): 0 / nil instead of an error.
local function tloNum(obj, field)
    local ok, v = pcall(function() return obj[field]() end)
    return ok and tonumber(v) or 0
end
local function tloStr(obj, field)
    local ok, v = pcall(function() return obj[field]() end)
    if ok and v ~= nil and tostring(v) ~= '' and tostring(v) ~= 'NULL' then return tostring(v) end
    return nil
end

local HEALTH_TRANSFER_SPA = 509
local NAMED_ONLY_REUSE_SEC = 300

function M.enrich(raw)
    if not raw or not raw.spell then return nil, 'malformed DPS line' end
    if (raw.opts or ''):find('debuffall', 1, true) then return nil, 'debuffall' end
    -- |util = the macro casts this line by its own pct/cond rules and the SmartDPS gate
    -- ignores it (Mind Wrack, snares); the brain must never rank or pick it.
    for tag in (raw.opts or ''):gmatch('[^|]+') do
        if tag:lower() == 'util' then return nil, 'util' end
    end
    -- |Me, |Feign and |MA lines are never held for a pick by the macro's live gate, which reads the
    -- tag where CombatCast fills DPSPart3 (the field after a |NN above 0, or the 5th field when that
    -- one is if/ifme/notif/notifme): ranking one would publish a pick no line can take.
    local f = {}
    for part in (raw.opts or ''):gmatch('[^|]+') do f[#f + 1] = part end
    local part3 = ((tonumber((f[1] or ''):match('^(%d+)')) or 0) > 0 and f[2]) or ''
    local p3 = part3:lower()
    if p3 == 'if' or p3 == 'ifme' or p3 == 'notif' or p3 == 'notifme' then part3 = f[4] or '' end
    p3 = part3:lower()
    if p3 == 'me' or p3 == 'feign' or p3 == 'ma' then return nil, part3 end
    -- A line names either a spell or an activated AA (the mac's CastWhat handles both).
    -- "Life Burn" is an AA whose spells are "Life Burn I/II", so the Spell TLO misses it.
    local sp = mq.TLO.Spell(raw.spell)
    local aa = nil
    if not sp or not sp() then
        local cand = mq.TLO.Me.AltAbility(raw.spell)
        if cand and cand() and cand.ID() then
            aa = cand
            sp = cand.Spell
        end
    end
    if not sp or not sp() then return nil, 'unknown to Spell TLO' end
    local numEffects = num(sp.NumEffects())
    if numEffects == 0 then numEffects = 12 end
    local base1, hpFraction
    for i = 1, math.min(12, numEffects) do
        local attribI = num(sp.Attrib(i)())
        local baseI = num(sp.Base(i)())
        if attribI == 0 and baseI < 0 then base1 = baseI; break end
        -- SPA 509 (health transfer): base is tenths of a percent of the caster's
        -- CURRENT HP dealt as unresistable damage - valued at decision time
        if attribI == HEALTH_TRANSFER_SPA and baseI > 0 then hpFraction = baseI / 1000; break end
    end
    if not base1 and not hpFraction then return nil, 'no direct damage slot' end   -- not a direct-HP damage spell
    local durSec = num(sp.Duration.TotalSeconds())
    local e = {
        index = raw.index, spell = raw.spell, cond = raw.cond,
        mana = num(sp.Mana()), castSec = num(sp.MyCastTime()) / 1000,
        recastSec = num(sp.RecastTime()) / 1000,
        durSec = durSec, isDot = durSec > 0, base = base1 and -base1 or nil,
        hpFraction = hpFraction,
        resistType = tostring(sp.ResistType() or 'unresistable'):lower(),
        undeadOnly = tostring(sp.TargetType() or '') == 'Undead',
        -- |NN option = cast only when the mob is at or below NN% (the mac's own rule)
        maxPct = tonumber(tostring(raw.opts or ''):match('^(%d+)')) or 100,
        -- spell level: Gift of Mana only frees spells at or under its level cap
        level = tloNum(sp, 'Level'),
        -- the name this character has memorized (Rk. II/III); the gem check looks it up
        rankName = (not aa) and tloStr(sp, 'RankName') or nil,
        -- the macro's DPSPart3 tag (once, spam, ...), which sets its recast timer after a cast
        tag = (p3 ~= '') and p3 or nil,
    }
    if hpFraction then e.isDot = false end
    if aa then
        -- recastSec is caster time between casts (burn-mode divisor); the AA's reuse
        -- timer is a readiness gate (init checks AltAbilityReady), not caster time.
        e.isAA, e.recastSec, e.reuseSec = true, 1.5, num(aa.ReuseTime())
        e.mana = 0
        -- anything that comes back slower than a pull cycle is a burst for nameds
        e.namedOnly = e.reuseSec >= NAMED_ONLY_REUSE_SEC
    end
    if raw.spell == 'Demand for Blood' then e.synergy = 'power' end
    return e
end

-- Resist types of the lines that could land on this mob, for the ranker's whole-list fallback gate
-- (it feeds resisted spells only when every one of these is resisted). Left out: undead-only lines off
-- an undead, named-only lines off a named, spells not memorized (opts.mem[spell] == false), AAs on
-- cooldown (opts.aaReady(spell) false), and an unresistable line (Life Burn) that is not usable in
-- this very decision (opts.usable) - a Life Burn the ranker will not pick must not hold the fallback
-- shut. An INI condition that is false, or a DoT still running, still counts: that line lands later
-- (the 2026-09-14 hold on Curse of Mortality was its DoT still running).
-- A line that cannot land inside the mob's remaining life (opts.ttdSecs: a cast that outlasts it, a
-- DoT that fits fewer than two ticks) does not count either: holding for it would idle the fight.
-- opts: { targetUndead, named, mem, aaReady = fn(spell) -> bool, usable = { [spell] = true }, ttdSecs }
function M.resistTypes(entries, opts)
    opts = opts or {}
    local ttd = tonumber(opts.ttdSecs)
    local out, seen = {}, {}
    for _, e in ipairs(entries or {}) do
        local rt = e.hpFraction and 'unresistable' or e.resistType
        local cast = tonumber(e.castSec) or 0
        local tooLate = ttd ~= nil and (ttd < cast + 1
            or (e.isDot and math.floor(math.max(0, ttd - cast) / 6) < 2))
        local skip = tooLate or (e.undeadOnly and not opts.targetUndead)
            or (e.namedOnly and not opts.named)
            or (opts.mem ~= nil and opts.mem[e.spell] == false)
            or (e.isAA and opts.aaReady ~= nil and not opts.aaReady(e.spell))
            or (rt == 'unresistable' and opts.usable ~= nil and not opts.usable[e.spell])
        if not skip and rt and not seen[rt] then
            seen[rt] = true
            out[#out + 1] = rt
        end
    end
    return out
end

function M.load(path)
    local fh = io.open(path, 'r')
    if not fh then return {}, 'cannot open ' .. tostring(path) end
    local text = fh:read('*a'); fh:close()
    local out, skipped, seen = {}, {}, {}
    for _, raw in ipairs(M.parseIni(text)) do
        local e, reason = M.enrich(raw)
        if e and seen[e.spell] then
            skipped[#skipped + 1] = string.format('%s (duplicate of DPS%d)', e.spell, seen[e.spell])
        elseif e then
            seen[e.spell] = e.index
            out[#out + 1] = e
        else
            skipped[#skipped + 1] = string.format('%s (%s)', tostring(raw.spell), tostring(reason))
        end
    end
    return out, nil, skipped
end

return M
