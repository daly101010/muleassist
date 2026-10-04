-- modules/report.lua: the reporting layer. /healreport (Bind_HealReport), the one-line HealStats rebuilt at
-- every fight end (HealReportOnEnd echoes it), and the 1 s status line (MAStatusTick) that MAUI observes
-- through ${MuleAssist.Status}. The counters live in core/stats.lua so every module can bump them.
local mq = require('mq')
local T = require('core.tlo')
local Config = require('core.config')
local Timers = require('core.timers')
local Stats = require('core.stats')
local State = require('core.state')
local Comms = require('core.comms')
local Log = require('core.log')

local M = { name = 'report' }

M.Settings = {
    scalars = {
        { section = 'Heals', key = 'HealReportOnEnd', type = 'int', default = 0 },
    },
}
M.cfg = {}

function M:LoadSettings()
    self.cfg = Config.load(self.Settings)
end

-- ------------------------------------------------------------- MAStatus (pure)
local function join(s, piece)
    if s == '' then return piece end
    return s .. ' | ' .. piece
end

--- The session toggles that are on, " | "-joined, "idle" when none (MAStatusTick).
function M.statusLine(S)
    local s = ''
    if S.raidModeOn then s = join(s, 'Raid') end
    if S.markAssistOn then s = join(s, 'Mark ' .. tostring(S.raidMarkNum or 1)) end
    if S.xtarTanks then
        local owned = S.xtarTankOwned or ''
        local n = 0
        if owned ~= '' then for _ in owned:gmatch('[^|]+') do n = n + 1 end end
        s = join(s, 'XTarTanks ' .. n)
    end
    if S.aggroPaused then s = join(s, 'Aggro paused') end
    if S.aeOn then s = join(s, 'AE') end
    if S.manualOn then s = join(s, 'Manual') end
    if S.manualMAOn then s = join(s, 'Follow') end
    if S.killOrderOn then s = join(s, 'KillOrder') end
    if S.getAwayOn then s = join(s, 'GetAway' .. (S.getAwayFollow and ' (following)' or '')) end
    if S.chaseAssist then
        local suffix = ''
        if S.chaseLeftBehind then suffix = ': left behind'
        elseif (S.chaseStuckTries or 0) > 0 then suffix = ': stuck' end
        s = join(s, 'Chase' .. suffix)
    end
    if S.buffMode then s = join(s, 'BuffMode') end
    if S.zombieMode then s = join(s, 'Zombie') end
    if (S.healTankMode or 'off') ~= 'off' then
        local who = tostring(S.healTank or '')
        local note = ''
        if S.healTankMode == 'auto' and who ~= S.mainAssist then note = ' (raid MA)'
        elseif who == S.mainAssist then note = ' (the MA)' end
        s = join(s, 'Tank ' .. who .. note)
    end
    if s == '' then s = 'idle' end
    return s
end

--- Runs every pass, paused or not (the macro's MAStatusTick ran in both loops): refresh State.status once a second.
function M:Tick()
    if not Timers.expired('report:status') then return end
    Timers.set('report:status', 1000)
    local s = M.statusLine(State)
    if s ~= State.status then State.status = s end
end

-- ------------------------------------------------------------- fight end
--- CombatReset's report hook: count the fight, rebuild HealStats, echo it with HealReportOnEnd=1.
function M:fightEnd()
    if not (State.healsOn or State.curesOn) then return end
    Stats.bump('fights')
    State.healStats = Stats.build(T.myName())
    if (self.cfg.HealReportOnEnd or 0) ~= 0 then print('\ag[HealReport]\ax ' .. State.healStats) end
end

function M:OnCombatEnd() self:fightEnd() end

-- ------------------------------------------------------------- /healreport
local function yesno(on, offText) if on then return '' end return offText end

--- The full report (Bind_HealReport with no argument). Returns the lines so tests can check them.
function M:fullReport()
    local h = Stats.hs
    local out = {}
    local function add(fmt, ...) out[#out + 1] = string.format(fmt, ...) end
    local t = Stats.elapsed()
    add('\ag[HealReport]\ax %s (%s) - %dm %ds, %d fights%s%s', T.myName(), T.myClass(), math.floor(t / 60), t % 60, h.fights,
        yesno(State.healsOn, ' (HealsOn=0)'), yesno(State.curesOn, ' (CuresOn=0)'))
    add('  Single heals: %d cast - tank %d, group %d, self %d, pet %d, out-of-group %d (taps %d, nuke-heals %d)',
        h.single, h.tank, h.groupT, h.self, h.pet, h.oog, h.tap, h.mob)
    add('  Interrupted: %d - target healed past the line %d, tap at full HP %d, nuke-heal with the tank up %d, heal on an NPC %d | nukes cut for a heal: %d',
        h.intHeal + h.intTap + h.intMob + h.intNPC, h.intHeal, h.intTap, h.intMob, h.intNPC, h.dpsCut)
    add('  Failed casts: %d%s', h.fail, h.failLast ~= '' and (' (last: ' .. h.failLast .. ')') or '')
    add('  Group heals: %d cast, withheld %d (2+ hurt in the zone but nobody in the heal\'s range)', h.group, h.groupRange)
    add('  Smart heals: %d cast, %d failed%s', h.smart, h.smartFail, yesno(State.smartHealsOn, ' (SmartHealsOn=0)'))
    add('  Cures: %d cast (%d group), targets held after a cure %d, not ready %d%s', h.cure, h.cureGroup, h.cureHeld, h.cureUnready,
        h.cureUnreadyLast ~= '' and (' (last: ' .. h.cureUnreadyLast .. ')') or '')
    add('  Skipped cast decisions: %d (/whynot lists the last 20)', h.skip)
    add('  Lowest seen: tank %s, anyone %s', h.tankLow < 100 and (h.tankLow .. '%') or 'never below 100%',
        h.lowPct < 100 and (h.lowName .. ' ' .. h.lowPct .. '%') or 'never below 100%')
    -- per line: the heals module publishes its parsed lines as State.healLines / State.groupHealLines ({name, pct})
    local byLine = {}
    for i, l in ipairs(State.healLines or {}) do
        local n = h.line[i] or 0
        if n > 0 then byLine[#byLine + 1] = string.format('%s|%s %d', l.name, tostring(l.pct or ''), n) end
    end
    for i, l in ipairs(State.groupHealLines or {}) do
        local n = h.gline[i] or 0
        if n > 0 then byLine[#byLine + 1] = string.format('%s|%s %d (group)', l.name, tostring(l.pct or ''), n) end
    end
    if #byLine > 0 then add('  By line: %s', table.concat(byLine, ' | ')) end
    add('  /healreport reset | bc (broadcast one line) | all (every box in the zone) - HealReportOnEnd=1 echoes one line per fight')
    return out
end

M.Binds = {
    ['/healreport'] = function(self, arg)
        arg = tostring(arg or ''):lower()
        if arg == 'reset' then
            Stats.reset()
            State.healStats = ''
            print('\ag[HealReport]\ax counters reset')
        elseif arg == 'all' then
            Comms.zone('/healreport bc')
        elseif arg == 'bc' then
            if not (State.healsOn or State.curesOn) then return end
            State.healStats = Stats.build(T.myName())
            Comms.say('g', '%s', State.healStats)
        else
            for _, l in ipairs(self:fullReport()) do print(l) end
        end
    end,
}

return M
