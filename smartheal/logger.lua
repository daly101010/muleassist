-- healing/logger.lua
local mq = require('mq')
local lazy = require('smartheal.util.lazy_require')
local getPaths = lazy('smartheal.util.paths')

local M = {}

local Config = nil
local _logFile = nil
local _logPath = nil
local _currentDate = nil
local _sessionId = nil

-- Throttling state for spell selection logs
local _lastSpellSelectionLog = {}  -- [targetName] = { tier, selected, pctHP, time }
local SPELL_SELECTION_THROTTLE_SEC = 5  -- Only log if same target+tier hasn't changed in N seconds

-- Log levels
local LEVELS = { debug = 1, info = 2, warn = 3, error = 4 }

function M.init(config)
    Config = config
    _sessionId = string.format('%s_%d', os.date('%H%M%S'), math.random(1000, 9999))
    M.ensureLogDir()
    M.rotate()
end

function M.ensureLogDir()
    local Paths = getPaths()
    local logDir = Paths and Paths.getHealingLogDir() or ((mq.configDir or 'config') .. '/MuleAssist/HealingLogs')
    _logPath = logDir
    if Paths and Paths.ensureDir then
        Paths.ensureDir(logDir)
    else
        os.execute('mkdir "' .. logDir .. '" 2>nul')
    end
end

function M.rotate()
    local today = os.date('%Y-%m-%d')
    if _currentDate == today and _logFile then return end

    if _logFile then
        _logFile:close()
    end

    _currentDate = today

    -- Get character and server name with pcall for safety
    local charName = 'Unknown'
    local ok, name = pcall(function() return mq.TLO.Me.CleanName() end)
    if ok and name then charName = name end

    local server = 'Unknown'
    ok, name = pcall(function() return mq.TLO.EverQuest.Server() end)
    if ok and name then server = name:gsub(' ', '_') end

    local filename = string.format('%s/%s_%s_%s.log', _logPath, server, charName, today)

    local err
    _logFile, err = io.open(filename, 'a')
    if _logFile then
        M.info('session', '=== Session %s started ===', _sessionId)
    elseif err then
        -- Log to console if file open fails
        print(string.format('[Healing Logger] Failed to open %s: %s', filename, err))
    end
end

local function shouldLog(level, category)
    if not Config then return false end
    if not Config.fileLogging then return false end

    local configLevel = LEVELS[Config.fileLogLevel or 'info'] or 2
    local msgLevel = LEVELS[level] or 2
    if msgLevel < configLevel then return false end

    if category and Config.logCategories then
        if Config.logCategories[category] == false then return false end
    end

    return true
end

local function write(level, category, fmt, ...)
    if not shouldLog(level, category) then return end

    M.rotate()  -- Ensure we have current log file
    if not _logFile then return end

    local timestamp = os.date('%H:%M:%S')
    -- Only use string.format if there are varargs, otherwise use fmt directly
    -- This avoids issues with % characters in pre-built strings
    local msg
    if select('#', ...) > 0 then
        local ok, result = pcall(string.format, fmt, ...)
        msg = ok and result or tostring(fmt)
    else
        msg = tostring(fmt)
    end
    local line = string.format('[%s][%s][%s] %s\n', timestamp, level:upper(), category or 'general', msg)

    _logFile:write(line)
    _logFile:flush()  -- Ensure immediate write for crash safety
end

function M.debug(category, fmt, ...) write('debug', category, fmt, ...) end
function M.info(category, fmt, ...) write('info', category, fmt, ...) end
function M.warn(category, fmt, ...) write('warn', category, fmt, ...) end
function M.error(category, fmt, ...) write('error', category, fmt, ...) end

-- Specialized logging functions for heal decisions

function M.logTargetSelection(targets, selected, reason)
    if not shouldLog('info', 'targetSelection') then return end

    local lines = { 'TARGET SELECTION:' }
    table.insert(lines, string.format('  Candidates: %d', #targets))
    for i, t in ipairs(targets) do
        if i <= 5 then  -- Top 5 only
                table.insert(lines, string.format('    %d. %s [%s] HP:%d%% MaxHP:%d/%s Deficit:%d Incoming:%d EffDeficit:%d',
                    i, t.name or '?', t.role or '?', t.pctHP or 0,
                    t.maxHP or 0, t.maxHPSource or '?', t.deficit or 0,
                    t.incomingTotal or 0, t.effectiveDeficit or 0))
            end
        end
    if selected then
        table.insert(lines, string.format('  SELECTED: %s - %s', selected.name or '?', reason or 'best candidate'))
    else
        table.insert(lines, string.format('  SELECTED: none - %s', reason or 'no valid target'))
    end

    write('info', 'targetSelection', table.concat(lines, '\n'))
end

function M.logSpellSelection(target, tier, spells, selected, score)
    if not shouldLog('info', 'spellSelection') then return end

    -- Throttle repeated "no spell selected" logs for same target at same HP
    local targetName = target.name or '?'
    local targetHP = target.pctHP or 0
    local cacheKey = targetName .. '|' .. (tier or '')
    local now = os.time()
    local lastLog = _lastSpellSelectionLog[cacheKey]

    if lastLog then
        local sameResult = (lastLog.selected == selected) and (lastLog.pctHP == targetHP)
        local recentlyLogged = (now - lastLog.time) < SPELL_SELECTION_THROTTLE_SEC
        if sameResult and recentlyLogged then
            return  -- Skip redundant log
        end
    end

    -- Update cache
    _lastSpellSelectionLog[cacheKey] = { selected = selected, pctHP = targetHP, time = now }

    local lines = { string.format('SPELL SELECTION for %s [%s tier]:', targetName, tier or '?') }
    table.insert(lines, string.format('  Target: HP:%d%% MaxHP:%d source:%s known:%s Deficit:%d EffDeficit:%d DPS:%.0f',
        targetHP, target.maxHP or 0, target.maxHPSource or 'unknown',
        tostring(target.maxHPKnown == true), target.deficit or 0,
        target.effectiveDeficit or 0, target.recentDps or 0))

    if spells and #spells > 0 then
        table.insert(lines, '  Candidates:')
        for i, s in ipairs(spells) do
            if i <= 8 then  -- Top 8 spells
                table.insert(lines, string.format('    %d. %s Score:%.2f Expected:%d Mana:%d Cast:%.1fs',
                    i, s.spell or s.name or '?', s.score or 0, s.expected or 0, s.mana or 0, (s.castTime or 0) / 1000))
            end
        end
    end

    if selected then
        table.insert(lines, string.format('  SELECTED: %s (score: %.2f)', selected, score or 0))
    else
        table.insert(lines, '  SELECTED: none - no suitable spell')
    end

    write('info', 'spellSelection', table.concat(lines, '\n'))
end

function M.logSpellScoring(spellName, target, components)
    if not shouldLog('debug', 'spellScoring') then return end

    write('debug', 'spellScoring',
        'SCORE %s for %s: coverage=%.2f manaEff=%.2f overheal=%.2f castPenalty=%.2f burstBonus=%.2f TOTAL=%.2f',
        spellName, target.name or '?',
        components.coverage or 0, components.manaEff or 0, components.overheal or 0,
        components.castPenalty or 0, components.burstBonus or 0, components.total or 0)
end

function M.logDuckDecision(spellName, targetName, reason, details)
    if not shouldLog('info', 'ducking') then return end

    write('info', 'ducking', 'DUCK %s on %s: %s | %s',
        spellName or '?', targetName or '?', reason or '?', details or '')
end

function M.logIncomingHeals(targetId, targetName, heals, total)
    if not shouldLog('debug', 'incomingHeals') then return end

    local healerList = {}
    for healerId, data in pairs(heals or {}) do
        table.insert(healerList, string.format('%s:%d', data.healerName or healerId, data.expectedAmount or 0))
    end

    write('debug', 'incomingHeals', 'INCOMING for %s [%d]: %s = %d total',
        targetName or '?', targetId or 0, table.concat(healerList, ', '), total or 0)
end

function M.logCombatState(state)
    if not shouldLog('debug', 'combatState') then return end

    -- Base combat state
    local baseMsg = string.format('COMBAT: phase=%s inCombat=%s survival=%s highPressure=%s mobs=%d avgMobHP=%d%% TTK=%.1fs tankDPS=%d%%',
        state.fightPhase or '?', tostring(state.inCombat), tostring(state.survivalMode), tostring(state.highPressure),
        state.activeMobCount or 0, state.avgMobHP or 0, state.estimatedTTK or 0, state.tankDpsPct or 0)

    -- Add mob difficulty info if fighting named/raid
    local mobInfo = ''
    if state.hasRaidMob or state.hasNamedMob then
        mobInfo = string.format(' | mob: tier=%s mult=%.1f raid=%s named=%s',
            state.mobDifficultyTier or 'normal', state.mobDpsMultiplier or 1.0,
            tostring(state.hasRaidMob), tostring(state.hasNamedMob))
    end

    -- Add throttle info if active
    local throttleInfo = ''
    if state.throttleLevel and state.throttleLevel > 0 then
        throttleInfo = string.format(' | throttle: level=%.2f overheal=%.1f%%',
            state.throttleLevel, state.fightOverhealPct or 0)
    end

    write('debug', 'combatState', baseMsg .. mobInfo .. throttleInfo)
end

function M.logHotDecision(targetName, spellName, shouldApply, reason)
    if not shouldLog('info', 'hotDecisions') then return end

    write('info', 'hotDecisions', 'HOT %s on %s: %s - %s',
        spellName or '?', targetName or '?', shouldApply and 'APPLY' or 'SKIP', reason or '?')
end

function M.logHealCast(spellName, targetName, tier, expected, isHoT)
    write('info', 'spellSelection', 'CAST %s on %s [%s] expected:%d isHoT:%s',
        spellName or '?', targetName or '?', tier or '?', expected or 0, tostring(isHoT))
end

function M.logHealLanded(spellName, targetName, amount, isCrit)
    write('info', 'spellSelection', 'LANDED %s on %s for %d%s',
        spellName or '?', targetName or '?', amount or 0, isCrit and ' (CRIT)' or '')
end

function M.logCoordinationEvent(eventType, details)
    if not shouldLog('debug', 'incomingHeals') then return end
    write('debug', 'incomingHeals', 'COORD %s: %s', eventType or '?', details or '')
end

function M.logSessionSummary(analytics)
    if not shouldLog('info', 'analytics') then return end
    if not analytics then return end  -- Guard against nil analytics

    local lines = { '=== SESSION SUMMARY ===' }
    table.insert(lines, string.format('Duration: %s', analytics.duration or '?'))
    table.insert(lines, string.format('Total Casts: %d', analytics.totalCasts or 0))
    table.insert(lines, string.format('Total Healed: %d', analytics.totalHealed or 0))
    table.insert(lines, string.format('Overheal%%: %.1f%%', analytics.overHealPct or 0))
    table.insert(lines, string.format('Ducked: %d (saved ~%d mana)', analytics.duckedCasts or 0, analytics.duckSavings or 0))
    table.insert(lines, string.format('Incoming Honored: %d', analytics.incomingHonored or 0))
    table.insert(lines, string.format('Incoming Expired: %d', analytics.incomingExpired or 0))

    write('info', 'analytics', table.concat(lines, '\n'))
end

function M.shutdown()
    if _logFile then
        M.info('session', '=== Session %s ended ===', _sessionId or '?')
        _logFile:close()
        _logFile = nil
    end
end

-- HoT Coverage decision logging with configurable verbosity
-- Level 0: off, 1: summary, 2: detailed, 3: verbose
function M.logHotCoverageDecision(targetName, analysis, decision, level)
    local configLevel = Config and Config.hotCoverageLogLevel or 2
    if configLevel == 0 then return end
    if not shouldLog('info', 'hotCoverage') then return end

    local a = analysis or {}
    local decisionText = decision or 'UNKNOWN'

    if configLevel == 1 then
        -- Summary: one line
        local line = string.format('%s: HoT %.0f%% coverage, projected %.0f%% %s %.0f%% threshold -> %s',
            targetName or '?',
            (a.coverageRatio or 0) * 100,
            a.projectedPct or 0,
            (a.projectedPct or 0) >= (a.threshold or 0) and '>=' or '<',
            a.threshold or 0,
            decisionText)
        write('info', 'hotCoverage', line)
        return
    end

    if configLevel == 2 then
        -- Detailed: multi-line with key values
        local lines = { string.format('HOT_DECISION %s:', targetName or '?') }
        table.insert(lines, string.format('  State: HP=%.0f%% DPS=%.0f HoT_HPS=%.0f coverage=%.0f%%',
            a.currentPct or 0, a.dps or 0, a.hotHps or 0, (a.coverageRatio or 0) * 100))
        table.insert(lines, string.format('  Projection: window=%.0fs projected=%.0f%% threshold=%.0f%% (%s/%s)',
            a.windowSec or 0, a.projectedPct or 0, a.threshold or 0, a.role or '?', a.pressure or '?'))
        table.insert(lines, string.format('  Decision: %s%s',
            decisionText,
            a.uncoveredGap and string.format(' (gap=%.0f HP)', a.uncoveredGap) or ''))
        write('info', 'hotCoverage', table.concat(lines, '\n'))
        return
    end

    -- Level 3: Verbose with full breakdown
    local lines = { string.format('HOT_DECISION %s:', targetName or '?') }
    table.insert(lines, string.format('  Target: HP=%.0f%% (%.0f/%.0f) deficit=%.0f role=%s',
        a.currentPct or 0, a.currentHP or 0, a.maxHP or 0, a.deficit or 0, a.role or '?'))
    table.insert(lines, string.format('  Pressure: %s (mobs=%d TTK=%.0fs survival=%s)',
        a.pressure or '?', a.mobCount or 0, a.ttk or 0, tostring(a.survivalMode or false)))

    -- Mob difficulty info
    if a.mobDifficulty then
        local md = a.mobDifficulty
        if md.hasRaidMob or md.hasNamedMob then
            table.insert(lines, string.format('  Mob Difficulty: tier=%s multiplier=%.1f raid=%s named=%s',
                md.tier or 'normal', md.multiplier or 1.0, tostring(md.hasRaidMob), tostring(md.hasNamedMob)))
        end
    end

    -- DPS Attribution breakdown
    table.insert(lines, string.format('  DPS Attribution: total=%.0f sources=%d',
        a.dps or 0, a.sourceCount or 0))
    if a.sources and #a.sources > 0 then
        for _, src in ipairs(a.sources) do
            local primary = src.isPrimary and ' (primary)' or ''
            table.insert(lines, string.format('    - "%s" @%.0f DPS%s', src.name or '?', src.dps or 0, primary))
        end
    end

    -- HoT info
    if a.hotSpell then
        table.insert(lines, string.format('  HoT Active: %s', a.hotSpell))
        table.insert(lines, string.format('    - ticks_remaining=%d tick_amount=%.0f HPS=%.0f',
            a.ticksRemaining or 0, a.tickAmount or 0, a.hotHps or 0))
        table.insert(lines, string.format('    - expires_in=%.0fs', a.hotRemainingSec or 0))
    else
        table.insert(lines, '  HoT Active: none')
    end

    -- Coverage calculation
    table.insert(lines, string.format('  Coverage: HoT_HPS/DPS = %.0f/%.0f = %.1f%%',
        a.hotHps or 0, a.dps or 0, (a.coverageRatio or 0) * 100))

    -- Projection breakdown
    table.insert(lines, string.format('  Projection: window=%.0fs (%s pressure, capped by TTK=%.0fs)',
        a.windowSec or 0, a.pressure or '?', a.ttk or 0))
    table.insert(lines, string.format('    - damage_in_window = %.0f x %.0fs = %.0f',
        a.dps or 0, a.windowSec or 0, a.damageInWindow or 0))
    table.insert(lines, string.format('    - healing_in_window = %.0f x %.0fs = %.0f',
        a.hotHps or 0, a.windowSec or 0, a.healingInWindow or 0))
    table.insert(lines, string.format('    - projected_HP = %.0f - %.0f + %.0f = %.0f (%.1f%%)',
        a.currentHP or 0, a.damageInWindow or 0, a.healingInWindow or 0,
        a.projectedHP or 0, a.projectedPct or 0))

    -- Threshold lookup
    table.insert(lines, string.format('  Threshold: %s + %s = %.0f%%',
        a.role or '?', a.pressure or '?', a.threshold or 0))

    -- Final decision
    table.insert(lines, string.format('  Decision: %s (%.1f%% %s %.0f%%)',
        decisionText,
        a.projectedPct or 0,
        (a.projectedPct or 0) >= (a.threshold or 0) and '>=' or '<',
        a.threshold or 0))

    if a.uncoveredGap and a.uncoveredGap > 0 then
        table.insert(lines, string.format('  Spell sizing: uncovered_gap = %.0f - %.0f = %.0f HP -> %s',
            a.damageInWindow or 0, a.healingInWindow or 0, a.uncoveredGap, a.recommendedSize or 'small heal'))
    end

    write('info', 'hotCoverage', table.concat(lines, '\n'))
end

-- Log HoT application decision (when deciding whether to cast a HoT)
function M.logHotApplicationDecision(targetName, analysis, decision, reason)
    local configLevel = Config and Config.hotCoverageLogLevel or 2
    if configLevel == 0 then return end
    if not shouldLog('info', 'hotCoverage') then return end

    local a = analysis or {}

    if configLevel == 1 then
        write('info', 'hotCoverage', string.format('HOT_APPLY %s: %s (%s)',
            targetName or '?', decision and 'YES' or 'NO', reason or '?'))
        return
    end

    local lines = { string.format('HOT_APPLICATION %s:', targetName or '?') }
    table.insert(lines, string.format('  TTK: %.0fs | HoT duration: %.0fs | Usable ticks: %d (min: %d)',
        a.ttk or 0, a.hotDuration or 0, a.usableTicks or 0, a.minUsableTicks or 2))
    table.insert(lines, string.format('  DPS: %.0f | HoT HPS: %.0f | Ratio: %.2f (need: %.2f for %s)',
        a.dps or 0, a.hotHps or 0, a.dpsRatio or 0, a.requiredRatio or 0, a.mobType or '?'))
    table.insert(lines, string.format('  Expected healing: %.0f | Expected damage: %.0f | Overheal ratio: %.2f',
        a.expectedHealing or 0, a.expectedDamage or 0, a.overhealRatio or 0))
    table.insert(lines, string.format('  Decision: %s (%s)', decision and 'APPLY_HOT' or 'SKIP_HOT', reason or '?'))

    write('info', 'hotCoverage', table.concat(lines, '\n'))
end

return M
