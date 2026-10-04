-- healing/config.lua
local mq = require('mq')
local lazy = require('smartheal.util.lazy_require')
local Paths = require('smartheal.util.paths')

-- Lazy-load Logger to avoid circular requires
local getLogger = lazy.once('smartheal.logger')

local M = {
    _version = "1.0",

    -- Enable/disable lives on Core.Settings.DoHeals — read it directly at
    -- tick time. This module used to carry a mirrored `enabled` field with
    -- a sk_healing.syncSettings bridge; both are gone.

    -- Thresholds
    emergencyPct = 25,
    minHealPct = 10,
    groupHealMinCount = 3,
    nearDeadMobPct = 10,  -- Mobs below this HP% are excluded from fight phase avg
    -- Character-specific minimum heal threshold:
    -- Compares deficit% vs (minHeal% of maxHP) * threshold
    -- E.g., if smallest heal is 10% of target's maxHP, need at least 7% deficit (at 70% threshold)
    -- This prevents overhealing when all available heals are too big for small deficits
    minHealThresholdPct = 70,

    -- Squishy handling
    squishyClasses = { WIZ = true, ENC = true, NEC = true, MAG = true },
    nonSquishyMinHealPct = 15,
    nonSquishyHotMinDeficitPct = 20,  -- Non-squishy HoT threshold matches base (20% deficit = 80% HP)
    lowPressureMinDeficitPct = 20,    -- During low pressure, wait for 20% deficit before direct heals
    lowPressureHotMinDeficitPct = 25, -- During low pressure, wait for 25% deficit before HoTs (more conservative)
    lowPressureMobCount = 1,
    -- Scoring weights
    -- Overheal penalty increased to properly penalize heals that are too big for the deficit
    -- ManaEff reduced in normal mode - right-sizing heals matters more than raw efficiency
    scoringPresets = {
        emergency = { coverage = 4.0, manaEff = 0.1, overheal = -0.5 },  -- Save the target, efficiency doesn't matter
        raidFight = { coverage = 3.0, manaEff = 0.3, overheal = -1.5 },  -- Named/raid mobs: favor throughput, tolerate overheal
        normal = { coverage = 2.0, manaEff = 0.5, overheal = -3.0 },     -- Balance coverage with minimal waste
        lowPressure = { coverage = 1.0, manaEff = 1.5, overheal = -4.0 }, -- Maximize efficiency, heavily penalize overheal
    },
    maxOverhealRatio = 2.0,
    overhealTolerancePct = 20,
    preferUnderheal = true,
    underhealMinCoveragePct = 80,
    critOverhealThreshold = 0.15,
    critOverhealPenalty = -2.0,
    smallHealPenalty = -1.0,

    -- Ducking
    duckEnabled = true,
    duckHotThreshold = 92,
    duckIncomingGraceMs = 900,
    considerIncomingHot = true,
    hotIncomingCoveragePct = 100,

    -- HoT behavior
    hotOpeningWindowSec = 5,
    -- HoTs start around 80% HP when sustained damage is detected
    hotEnabled = true,
    hotMinDps = 200,             -- Minimum DPS to target for HoT to be considered
    hotSupplementMinDps = 200,   -- Minimum DPS for HoT supplementation
    hotMinDeficitPct = 20,       -- Minimum deficit% for HoT (20% = 80% HP) - first response to sustained damage
    hotMaxDeficitPct = 35,       -- Max deficit% for HoT eligibility (direct heals take over below 65% HP)
    hotPreferUnderDps = 3000,
    hotMinDpsForNonTank = 500,
    hotOverrideDpsPct = 5,
    hotTypicalDuration = 36,
    hotLearnForce = false,
    hotLearnMaxDeficitPct = 10,
    hotLearnIntervalSec = 30,
    quickHealMaxPct = 15,
    quickHealsEmergencyOnly = true,
    -- Fast direct heals are a catch-up tool, not the routine efficiency winner.
    -- Outside an emergency they are only eligible when measured incoming DPS
    -- shows that the selected efficient heal cannot catch the target back up.
    fastHealMaxCastMs = 2000,
    fastHealMinDpsPct = 2,
    excludeCompleteHealFromEfficiency = true,
    hotMinCoverageRatio = 0.3,
    hotUselessRatio = 0.1,
    hotRefreshWindowPct = 0,
    hotTankOnly = true,
    hotCoverageMultiplier = 1.2,  -- HoT HPS must exceed DPS * this multiplier to be sufficient
    hotSafetyBufferSec = 8,       -- Seconds of buffer before danger threshold to allow HoT to work
    hotSupplementMinGapPct = 5,   -- Minimum gap % of maxHP before supplementing a HoT
    bigHotMinMobDps = 3000,
    bigHotMinXTargetCount = 4,
    bigHotXTargetRange = 100,
    bigHotWithPromisedMinDps = 6000,

    -- Promised heal behavior
    promisedEnabled = true,
    promisedMinDps = 500,
    promisedMinActiveMobs = 1,
    promisedDelaySeconds = 18,
    promisedSafetyFloorPct = 35,
    promisedSurvivalSafetyFloorPct = 55,
    promisedRolling = true,
    promisedDurationBuffer = 5,

    -- Combat assessment
    survivalModeDpsPct = 5,
    survivalModeTankFullPct = 90,
    fightPhaseStartingPct = 70,
    fightPhaseEndingPct = 25,
    fightPhaseEndingTTK = 20,
    hotMinFightDurationPct = 50,
    survivalModeMaxHotDuration = 12,
    -- High pressure detection
    highPressureMinMobs = 3,         -- Min active mobs for high pressure
    highPressureMinDps = 3000,       -- OR min total DPS for high pressure
    highPressureMobMultiplier = 3.0, -- Mob difficulty multiplier that triggers high pressure (impossible+ tier)

    -- Mob difficulty adjustments (from mob_assessor tiers)
    raidMobSurvivalDpsPctReduction = 2,   -- Lower survival threshold by this % for raid mobs
    raidMobPromisedFloorIncrease = 10,    -- Raise promised safety floor by this % for raid fights

    -- Adaptive throttle for raid fights (reduces aggressiveness if overhealing)
    throttleMinHeals = 5,           -- Min heals in fight before throttle can activate
    throttleOverhealPct = 40,       -- Overheal % threshold to start throttling
    throttleMaxLevel = 0.5,         -- Max throttle level (0-1, affects weight adjustments)
    -- TTK tracking
    ttkWindowSec = 5,                -- Window for tracking mob HP decline

    -- DPS tracking (dual-source: HP delta + log parsing)
    damageWindowSec = 6,         -- Window for averaging damage (matches design)
    hpDpsWeight = 0.4,           -- Weight for HP delta DPS
    logDpsWeight = 0.6,          -- Weight for log-parsed DPS
    burstStddevMultiplier = 1.5, -- Burst = mean + (stddev * this) (matches design)
    burstDpsScale = 1.5,
    useLogDps = true,
    dpsValidationLogMs = 5000,

    -- Damage Attribution settings
    combatTimeoutSec = 5,        -- Clear attribution cache after N seconds of no damage
    dpsWindowSec = 3,            -- Rolling window for DPS calculation
    dpsVarianceThreshold = 25,   -- Max variance% between log DPS and HP delta DPS to be "reliable"

    -- Pet healing
    healPetsEnabled = false,     -- Whether to include pets in healing targets
    breakInvisOOC = false,       -- Allow an OOC heal to break invisibility
    petHealMinPct = 40,          -- Minimum HP% to heal pets

    -- Self-healing (PAL off-tank use case)
    selfHealEnabled = false,     -- Whether to include selfHeal spells

    -- Learning
    learningWeight = 0.1,
    minSamplesForReliable = 10,

    -- Coordination
    incomingHealTimeoutSec = 3,  -- Reduced from 10 - heals should land within cast time
    defaultRemoteMaxHP = 100000, -- Estimate only; heal sizing treats this as unknown until Actor/DanNet reports a real value
    broadcastEnabled = true,

    -- Logging (file logging enabled by default for troubleshooting)
    fileLogging = true,        -- Write detailed logs to file for review
    fileLogLevel = 'info',     -- 'debug', 'info', 'warn', 'error'
    logCategories = {          -- Granular control over what gets logged
        targetSelection = true,   -- Who needs healing and why
        spellSelection = true,    -- What spell was chosen and scoring details
        spellScoring = true,      -- Individual spell scores for comparison
        ducking = true,           -- Spell ducking decisions
        incomingHeals = true,     -- Incoming heal coordination
        combatState = true,       -- Fight phase, survival mode, DPS tracking
        hotDecisions = true,      -- Proactive HoT logic
        supplement = true,        -- HoT supplement decisions (HoT vs DPS comparison)
        events = true,            -- Heal events (landed, HoT ticks, learning data)
        analytics = true,         -- Session statistics
        attribution = false,      -- Damage attribution (verbose, disabled by default)
        hotCoverage = true,       -- HoT vs direct heal decision logging
    },

    -- HoT Trust & Efficiency Settings
    hotCoverageLogLevel = 2,          -- 0=off, 1=summary, 2=detailed, 3=verbose

    -- Projection windows (seconds) for HoT trust calculation
    projectionWindowLow = 8,
    projectionWindowNormal = 6,
    projectionWindowHigh = 3,

    -- Heal thresholds by role and pressure (projected HP % to trigger direct heal)
    healThresholds = {
        tank    = { low = 50, normal = 60, high = 70 },
        healer  = { low = 60, normal = 70, high = 80 },
        dps     = { low = 55, normal = 65, high = 75 },
        squishy = { low = 65, normal = 75, high = 85 },
    },

    -- HoT application gates
    hotMinUsableTicks = 2,            -- Require at least 2 ticks to apply HoT
    hotSingleMobMinDpsRatio = 0.8,    -- Single-mob: DPS must be >= 80% of HoT HPS
    hotMultiMobMinDpsRatio = 0.3,     -- Multi-mob: DPS must be >= 30% of HoT HPS
    hotMaxOverhealRatio = 1.5,        -- Skip HoT if expected healing > damage × this

    -- Safety constraints (CRITICAL - see design constraints above)
    hotMinDpsForTrust = 100,          -- Min DPS required to trust HoT (prevents over-trust with bad data)
    hotTrustHardFloorPct = 35,        -- Below this HP%, BYPASS HoT trust entirely (safety backstop)

    -- Spells (user assigns)
    spells = {
        fast = {},
        small = {},
        medium = {},
        large = {},
        group = {},
        hot = {},
        hotLight = {},
        groupHot = {},
        promised = {},
        selfHeal = {},  -- Self-only heals (PAL SelfHeal line)
    },
}

-- Spell validation helpers
local function getSpell(spellName)
    local spell = mq.TLO.Spell(spellName)
    if spell and spell() then
        return spell
    end
    return nil
end

local function isKnownSpell(spellName)
    local me = mq.TLO.Me
    if not (me and me() and me.Book) then
        return true
    end

    local ok, known = pcall(function()
        local bookSpell = me.Book(spellName)
        return bookSpell and bookSpell() and true or false
    end)
    if not ok then
        return true
    end
    return known == true
end

local function normalizeText(value)
    if not value then
        return ''
    end
    if type(value) ~= 'string' then
        value = tostring(value)
    end
    return value:lower():gsub('%s+', ' '):gsub('^%s+', ''):gsub('%s+$', '')
end

local function isSingleTarget(targetType)
    local t = normalizeText(targetType)
    return t == 'single' or t:match('^single') ~= nil
end

local function isGroupV1(targetType)
    local t = normalizeText(targetType)
    return t:match('^group v1') ~= nil
end

local function isSelfTarget(targetType)
    local t = normalizeText(targetType)
    return t == 'self'
end

local function getCastTimeMs(spell)
    ---@diagnostic disable-next-line: undefined-field
    local mySpell = mq.TLO.Me.Spell(spell.Name())
    if mySpell and mySpell() then
        local myCastTime = tonumber(mySpell.MyCastTime())
        if myCastTime then
            return myCastTime
        end
    end
    local castTime = tonumber(spell.CastTime())
    if castTime then
        return castTime
    end
    return nil
end

-- Get spell level for sorting and merge placement.
local function getSpellLevel(spell)
    if not spell then return 0 end
    local level = spell.Level and spell.Level()
    return tonumber(level) or 0
end

local function hasSpellSPA(spell, spaId)
    if not spell or not spell.HasSPA then return false end
    local ok, value = pcall(function()
        local result = spell.HasSPA(spaId)
        return result and result() == true
    end)
    return ok and value == true
end

-- Older/TLP spell data does not consistently expose the newer textual
-- subcategories ("Quick Heal", "Duration Heals", etc.). Infer healing shape
-- from the actual HP SPAs and duration so classic spells such as Remedy and
-- Celestial Elixir are still discovered safely.
local function inferHealCategoryFromEffects(spell)
    if not spell then return nil end

    local spellType = normalizeText(spell.SpellType and spell.SpellType() or '')
    local beneficial = spellType ~= 'detrimental'
    if spell.Beneficial then
        local ok, value = pcall(function() return spell.Beneficial() end)
        if ok then beneficial = value == true end
    end
    if not beneficial then return nil end

    local hasDirectHP = hasSpellSPA(spell, 0)
    local hasHPOverTime = hasSpellSPA(spell, 79)
    if not hasDirectHP and not hasHPOverTime then return nil end

    local targetType = normalizeText(spell.TargetType and spell.TargetType() or '')
    local duration = tonumber(spell.Duration and spell.Duration() or 0) or 0
    local isDurationHeal = hasHPOverTime or duration > 0

    if isGroupV1(targetType) then
        return isDurationHeal and 'groupHot' or 'group'
    elseif isSelfTarget(targetType) then
        return 'selfHeal', getSpellLevel(spell)
    elseif isSingleTarget(targetType) then
        if isDurationHeal then
            return 'hot_single', tonumber(spell.Mana and spell.Mana() or 0) or 0
        end
        local castTimeMs = getCastTimeMs(spell)
        if castTimeMs and castTimeMs <= 2000 then
            return 'fast', getSpellLevel(spell)
        end
        return 'direct_single', getSpellLevel(spell)
    end

    return nil
end

function M.IsValidSpellForCategory(category, spellName)
    local spell = getSpell(spellName)
    if not spell then
        return false
    end
    if not isKnownSpell(spellName) then
        return false
    end

    local subcategory = normalizeText(spell.Subcategory())
    local targetType = normalizeText(spell.TargetType())
    local inferredCategory = inferHealCategoryFromEffects(spell)

    if category == 'selfHeal' then
        return ((subcategory == 'heals' or subcategory == 'quick heal') and isSelfTarget(targetType))
            or inferredCategory == 'selfHeal'
    elseif category == 'hot' or category == 'hotLight' then
        return (subcategory == 'duration heals' and isSingleTarget(targetType))
            or inferredCategory == 'hot_single'
    elseif category == 'groupHot' then
        return (subcategory == 'duration heals' and isGroupV1(targetType))
            or inferredCategory == 'groupHot'
    elseif category == 'group' then
        return (subcategory == 'heals' and isGroupV1(targetType))
            or inferredCategory == 'group'
    elseif category == 'promised' then
        return subcategory == 'delayed' and isSingleTarget(targetType)
    elseif category == 'fast' or category == 'small' or category == 'medium' or category == 'large' then
        if category == 'fast' then
            return (subcategory == 'quick heal' and isSingleTarget(targetType))
                or inferredCategory == 'fast'
        end
        if not isSingleTarget(targetType) then
            return false
        end
        if category == 'small' or category == 'medium' then
            return subcategory == 'heals' or subcategory == 'quick heal'
                or inferredCategory == 'direct_single' or inferredCategory == 'fast'
        end
        if subcategory ~= 'heals' and inferredCategory ~= 'direct_single' then
            return false
        end
        local castTimeMs = getCastTimeMs(spell)
        if not castTimeMs then
            return false
        end
        return castTimeMs > 2000
    end

    return true
end

function M.FilterSpells()
    if not M.spells then
        return
    end
    for category, spells in pairs(M.spells) do
        for i = #spells, 1, -1 do
            if not M.IsValidSpellForCategory(category, spells[i]) then
                table.remove(spells, i)
            end
        end
    end
end

function M.IsConfiguredSpell(spellName)
    if not M.spells or not spellName then
        return false
    end
    for _, spells in pairs(M.spells) do
        for _, name in ipairs(spells) do
            if name == spellName then
                return true
            end
        end
    end
    return false
end

function M.HasConfiguredSpells()
    for _, spells in pairs(M.spells or {}) do
        if type(spells) == 'table' and #spells > 0 then return true end
    end
    return false
end

-- Auto-assignment tracking
M.lastSpellBarScan = 0
M.spellBarScanInterval = 2.0  -- Rescan every 2 seconds

-- Categorize a healing spell (returns category or nil, plus level for sorting)
local function categorizeHealSpell(spellName)
    local spell = getSpell(spellName)
    if not spell then return nil end

    local subcategory = normalizeText(spell.Subcategory())
    local targetType = normalizeText(spell.TargetType())

    -- Check if it's a heal-related spell
    local isHealSpell = subcategory == 'heals' or subcategory == 'quick heal' or
                        subcategory == 'duration heals' or subcategory == 'delayed'
    if not isHealSpell then return nil end

    local singleTarget = isSingleTarget(targetType)
    local groupTarget = isGroupV1(targetType)

    -- Promised (delayed heals)
    if subcategory == 'delayed' and singleTarget then
        return 'promised'
    end

    -- Group HoT
    if subcategory == 'duration heals' and groupTarget then
        return 'groupHot'
    end

    -- Single target HoT - return marker for dynamic assignment
    if subcategory == 'duration heals' and singleTarget then
        -- Return marker with mana cost for sorting
        local manaCost = tonumber(spell.Mana()) or 0
        return 'hot_single', manaCost
    end

    -- Group direct heal
    if subcategory == 'heals' and groupTarget then
        return 'group'
    end

    -- Quick heal (fast/emergency)
    if subcategory == 'quick heal' and singleTarget then
        return 'fast'
    end

    -- Self-target heals (PAL SelfHeal line)
    local selfTarget = isSelfTarget(targetType)
    if (subcategory == 'heals' or subcategory == 'quick heal') and selfTarget then
        return 'selfHeal', getSpellLevel(spell)
    end

    -- Single target direct heals - return special marker for dynamic sizing by level
    if subcategory == 'heals' and singleTarget then
        return 'direct_single', getSpellLevel(spell)
    end

    return inferHealCategoryFromEffects(spell)
end

local function newEmptySpellAssignments()
    return {
        fast = {},
        small = {},
        medium = {},
        large = {},
        group = {},
        hot = {},
        hotLight = {},
        groupHot = {},
        promised = {},
        selfHeal = {},
    }
end

local function assignCollectedHealingSpells(directHeals, hotHeals)
    table.sort(directHeals, function(a, b) return a.level < b.level end)
    if #directHeals == 1 then
        table.insert(M.spells.medium, directHeals[1].name)
    elseif #directHeals == 2 then
        table.insert(M.spells.small, directHeals[1].name)
        table.insert(M.spells.large, directHeals[2].name)
    elseif #directHeals > 2 then
        table.insert(M.spells.small, directHeals[1].name)
        table.insert(M.spells.large, directHeals[#directHeals].name)
        for i = 2, #directHeals - 1 do
            table.insert(M.spells.medium, directHeals[i].name)
        end
    end

    table.sort(hotHeals, function(a, b) return a.manaCost < b.manaCost end)
    if #hotHeals == 1 then
        table.insert(M.spells.hot, hotHeals[1].name)
    elseif #hotHeals > 1 then
        table.insert(M.spells.hotLight, hotHeals[1].name)
        table.insert(M.spells.hot, hotHeals[#hotHeals].name)
        for i = 2, #hotHeals - 1 do
            table.insert(M.spells.hot, hotHeals[i].name)
        end
    end
end

local function collectHealingSpell(spellName, assigned, directHeals, hotHeals, sourceLabel)
    if not spellName or spellName == '' or assigned[spellName] then return false end

    local category, value = categorizeHealSpell(spellName)
    local log = getLogger()
    if log then
        log.debug('autoAssign', '%s: %s -> category=%s value=%s',
            tostring(sourceLabel or 'spell'), spellName, tostring(category), tostring(value))
    end

    if category == 'direct_single' then
        table.insert(directHeals, { name = spellName, level = value or 0 })
        assigned[spellName] = true
        return true
    elseif category == 'hot_single' then
        table.insert(hotHeals, { name = spellName, manaCost = value or 0 })
        assigned[spellName] = true
        return true
    elseif category and M.spells[category] then
        table.insert(M.spells[category], spellName)
        assigned[spellName] = category
        return true
    end

    return false
end

local function spellNameFromId(spellId)
    spellId = tonumber(spellId) or 0
    if spellId <= 0 then return nil end
    local spell = mq.TLO.Spell(spellId)
    if spell and spell() then
        return spell.Name and spell.Name() or nil
    end
    return nil
end

function M.autoAssignFromActiveSpellSet()
    local ok, Persistence = pcall(require, 'smartheal.util.spellset_persistence')
    if not ok or not Persistence then return false end

    if not Persistence.loaded and Persistence.load then
        Persistence.load()
    end

    local activeName = Persistence.activeSetName
    local spellSet = activeName and Persistence.spellSets and Persistence.spellSets[activeName] or nil
    if not spellSet or not spellSet.gems then return false end

    M.spells = newEmptySpellAssignments()

    local assigned = {}
    local directHeals = {}
    local hotHeals = {}
    local found = 0
    local slots = {}

    for slot in pairs(spellSet.gems) do
        table.insert(slots, tonumber(slot) or slot)
    end
    table.sort(slots, function(a, b)
        local na = tonumber(a)
        local nb = tonumber(b)
        if na and nb then return na < nb end
        return tostring(a) < tostring(b)
    end)

    for _, slot in ipairs(slots) do
        local gemConfig = spellSet.gems[slot]
        local spellName = gemConfig and spellNameFromId(gemConfig.spellId) or nil
        if collectHealingSpell(spellName, assigned, directHeals, hotHeals, 'Active spell set gem ' .. tostring(slot)) then
            found = found + 1
        end
    end

    assignCollectedHealingSpells(directHeals, hotHeals)
    M.FilterSpells()

    if not M.HasConfiguredSpells() then
        M.spells = newEmptySpellAssignments()
        return false
    end

    local log = getLogger()
    if log then
        log.info('config', 'Assigned healing spells from active spell set "%s" (%d candidate heal spell(s))',
            tostring(activeName), found)
    end
    return true
end

-- Scan spell bar and auto-assign healing spells to categories
function M.autoAssignFromSpellBar()
    local now = os.clock()
    if (now - M.lastSpellBarScan) < M.spellBarScanInterval then
        return false  -- Not time to scan yet
    end
    M.lastSpellBarScan = now

    local me = mq.TLO.Me
    if not me or not me() then return false end

    -- Clear existing assignments
    M.spells = {
        fast = {},
        small = {},
        medium = {},
        large = {},
        group = {},
        hot = {},
        hotLight = {},
        groupHot = {},
        promised = {},
        selfHeal = {},
    }

    -- Track which spells we've assigned to avoid duplicates
    local assigned = {}

    -- Collect direct single-target heals for dynamic sizing by level
    local directHeals = {}  -- { spellName, level }
    -- Collect single-target HoTs for dynamic assignment by mana cost
    local hotHeals = {}  -- { spellName, manaCost }

    -- Scan all gem slots
    local numGems = tonumber(me.NumGems()) or 13
    local scanLog = getLogger()
    if scanLog then scanLog.debug('autoAssign', 'Scanning %d gem slots...', numGems) end

    for gem = 1, numGems do
        local gemSpell = me.Gem(gem)
        if gemSpell and gemSpell() then
            local spellName = gemSpell.Name()
            if spellName and spellName ~= '' and not assigned[spellName] then
                local category, value = categorizeHealSpell(spellName)
                if scanLog then
                    scanLog.debug('autoAssign', 'Gem %d: %s -> category=%s value=%s',
                        gem, spellName, tostring(category), tostring(value))
                end
                if category == 'direct_single' then
                    -- Collect for dynamic sizing
                    table.insert(directHeals, { name = spellName, level = value or 0 })
                    assigned[spellName] = true  -- Mark as processed
                elseif category == 'hot_single' then
                    -- Collect HoTs for dynamic assignment
                    table.insert(hotHeals, { name = spellName, manaCost = value or 0 })
                    assigned[spellName] = true  -- Mark as processed
                elseif category and M.spells[category] then
                    table.insert(M.spells[category], spellName)
                    assigned[spellName] = category
                end
            end
        end
    end

    -- Dynamic sizing for direct single-target heals
    local log = getLogger()
    if log then
        log.debug('autoAssign', 'Direct Heal AutoAssign: Found %d direct heals', #directHeals)
        for i, h in ipairs(directHeals) do
            log.debug('autoAssign', 'Direct Heal AutoAssign:   %d. %s (level: %d)', i, h.name, h.level)
        end
    end

    if #directHeals > 0 then
        -- Sort by spell level (ascending: lowest level = smallest heal)
        table.sort(directHeals, function(a, b) return a.level < b.level end)

        if log then
            log.debug('autoAssign', 'Direct Heal AutoAssign: After sort:')
            for i, h in ipairs(directHeals) do
                log.debug('autoAssign', 'Direct Heal AutoAssign:   %d. %s (level: %d)', i, h.name, h.level)
            end
        end

        if #directHeals == 1 then
            -- One heal: assign to medium (versatile workhorse)
            table.insert(M.spells.medium, directHeals[1].name)
            if log then log.debug('autoAssign', 'Direct Heal AutoAssign: Single heal -> medium: %s', directHeals[1].name) end
        elseif #directHeals == 2 then
            -- Two heals: smallest → small, largest → large
            table.insert(M.spells.small, directHeals[1].name)
            table.insert(M.spells.large, directHeals[2].name)
            if log then
                log.debug('autoAssign', 'Direct Heal AutoAssign: Smallest -> small: %s', directHeals[1].name)
                log.debug('autoAssign', 'Direct Heal AutoAssign: Largest -> large: %s', directHeals[2].name)
            end
        else
            -- Three+ heals: smallest → small, largest → large, middle → medium
            table.insert(M.spells.small, directHeals[1].name)
            table.insert(M.spells.large, directHeals[#directHeals].name)
            if log then
                log.debug('autoAssign', 'Direct Heal AutoAssign: Smallest -> small: %s', directHeals[1].name)
                log.debug('autoAssign', 'Direct Heal AutoAssign: Largest -> large: %s', directHeals[#directHeals].name)
            end
            -- All middle heals go to medium
            for i = 2, #directHeals - 1 do
                table.insert(M.spells.medium, directHeals[i].name)
                if log then log.debug('autoAssign', 'Direct Heal AutoAssign: Middle -> medium: %s', directHeals[i].name) end
            end
        end
    end

    -- Dynamic assignment for single-target HoTs
    -- Lower mana cost = hotLight (efficient, for low DPS)
    -- Higher mana cost = hot (stronger, for high DPS)
    if #hotHeals > 0 then
        -- Debug: Show detected HoTs before sorting
        local log = getLogger()
        if log then
            for i, h in ipairs(hotHeals) do
                log.debug('autoAssign', 'HoT AutoAssign: Detected: %s (mana: %d)', h.name, h.manaCost)
            end
        end

        -- Sort by mana cost (ascending: lowest mana = light HoT)
        table.sort(hotHeals, function(a, b) return a.manaCost < b.manaCost end)

        -- Debug: Show after sorting
        if log then
            log.debug('autoAssign', 'HoT AutoAssign: After sort: %d HoTs found', #hotHeals)
            for i, h in ipairs(hotHeals) do
                log.debug('autoAssign', 'HoT AutoAssign:   %d. %s (mana: %d)', i, h.name, h.manaCost)
            end
        end

        if #hotHeals == 1 then
            -- Only one HoT: put in hot category (can be used for both situations)
            table.insert(M.spells.hot, hotHeals[1].name)
            if log then
                log.debug('autoAssign', 'HoT AutoAssign: Single HoT -> hot: %s', hotHeals[1].name)
            end
        else
            -- Multiple HoTs: cheapest -> hotLight, most expensive -> hot
            table.insert(M.spells.hotLight, hotHeals[1].name)
            table.insert(M.spells.hot, hotHeals[#hotHeals].name)
            if log then
                log.debug('autoAssign', 'HoT AutoAssign: Cheapest -> hotLight: %s', hotHeals[1].name)
                log.debug('autoAssign', 'HoT AutoAssign: Most expensive -> hot: %s', hotHeals[#hotHeals].name)
            end
            -- Any middle HoTs also go to hot (higher tier)
            for i = 2, #hotHeals - 1 do
                table.insert(M.spells.hot, hotHeals[i].name)
                if log then
                    log.debug('autoAssign', 'HoT AutoAssign: Middle -> hot: %s', hotHeals[i].name)
                end
            end
        end
    end

    return true  -- Scan completed
end

--- Merge valid healing spells from the current spell bar into the persisted
--- assignments without moving or removing anything already configured.
--- This is intentionally separate from autoAssignFromSpellBar(), whose
--- first-run behavior clears all categories before rebuilding them.
--- @return number added Number of newly configured spells.
--- @return table additions Array of { name = string, category = string }.
--- @return number scanned Number of occupied gem slots inspected.
--- @return boolean persisted Whether additions were saved successfully.
--- @return table observed Classification result for each occupied gem.
function M.mergeFromSpellBar()
    local me = mq.TLO.Me
    if not me or not me() then return 0, {}, 0, true, {} end

    M.spells = M.spells or newEmptySpellAssignments()
    for category in pairs(newEmptySpellAssignments()) do
        if type(M.spells[category]) ~= 'table' then
            M.spells[category] = {}
        end
    end

    -- A spell already assigned in any category is authoritative. Keep that
    -- category and only add names that do not exist anywhere in the profile.
    local assigned = {}
    for _, spells in pairs(M.spells) do
        if type(spells) == 'table' then
            for _, spellName in ipairs(spells) do
                assigned[normalizeText(spellName)] = true
            end
        end
    end

    local additions = {}
    local observed = {}
    local scanned = 0
    local numGems = tonumber(me.NumGems()) or 13

    for gem = 1, numGems do
        local gemSpell = me.Gem(gem)
        if gemSpell and gemSpell() then
            scanned = scanned + 1
            local spellName = gemSpell.Name and gemSpell.Name() or nil
            local key = normalizeText(spellName)
            if spellName and spellName ~= '' and assigned[key] then
                table.insert(observed, { name = spellName, status = 'configured' })
            elseif spellName and spellName ~= '' then
                local category = categorizeHealSpell(spellName)
                -- Dynamic markers are useful when building an empty profile.
                -- During a merge, conservative destinations avoid reshuffling
                -- the user's existing heal-size and HoT tier choices.
                if category == 'direct_single' then
                    category = 'medium'
                elseif category == 'hot_single' then
                    category = 'hot'
                end

                if category and M.spells[category]
                    and M.IsValidSpellForCategory(category, spellName) then
                    table.insert(M.spells[category], spellName)
                    assigned[key] = true
                    table.insert(additions, { name = spellName, category = category })
                    table.insert(observed, { name = spellName, status = 'added', category = category })
                else
                    table.insert(observed, { name = spellName, status = 'not_heal' })
                end
            end
        end
    end

    local persisted = true
    if #additions > 0 then
        persisted = M.save() == true
        local log = getLogger()
        if log then
            for _, addition in ipairs(additions) do
                log.info('config', 'Merged memorized heal: %s -> %s',
                    addition.name, addition.category)
            end
        end
    end

    return #additions, additions, scanned, persisted, observed
end

-- Get a summary of auto-assigned spells (for UI display)
function M.getAssignmentSummary()
    local summary = {}
    local categoryLabels = {
        fast = 'Quick (Emergency)',
        small = 'Small',
        medium = 'Medium',
        large = 'Big',
        group = 'Group Heal',
        hot = 'HoT (High DPS)',
        hotLight = 'HoT (Low DPS)',
        groupHot = 'Group HoT',
        promised = 'Promised',
        selfHeal = 'Self Heal',
    }
    local categoryOrder = { 'fast', 'small', 'medium', 'large', 'group', 'hot', 'hotLight', 'groupHot', 'promised', 'selfHeal' }

    for _, category in ipairs(categoryOrder) do
        local spells = M.spells[category]
        if spells and #spells > 0 then
            table.insert(summary, {
                category = category,
                label = categoryLabels[category] or category,
                spells = spells,
            })
        end
    end

    return summary
end

local function getConfigPath()
    return Paths.getHealingConfigPath()
end

local function serializeValue(v, indent)
    indent = indent or ''
    local t = type(v)
    if t == 'string' then
        return string.format('%q', v)
    elseif t == 'number' or t == 'boolean' then
        return tostring(v)
    elseif t == 'table' then
        local parts = {}
        for k, val in pairs(v) do
            local key
            if type(k) == 'string' then
                if k:match('^[%a_][%w_]*$') then
                    key = k
                else
                    key = string.format('[%q]', k)
                end
            else
                key = string.format('[%s]', tostring(k))
            end
            table.insert(parts, string.format('%s    %s = %s,', indent, key, serializeValue(val, indent .. '    ')))
        end
        if #parts == 0 then
            return '{}'
        end
        return '{\n' .. table.concat(parts, '\n') .. '\n' .. indent .. '}'
    end
    return 'nil'
end

function M.save()
    local log = getLogger()
    local path = getConfigPath()
    local snapshot = {}
    for k, v in pairs(M) do
        if type(v) ~= 'function' then
            snapshot[k] = v
        end
    end
    local content = 'return ' .. serializeValue(snapshot) .. '\n'
    local safeWrite = require('smartheal.util.safe_write')
    local ok, err = safeWrite(path, content)
    if not ok then
        if log then log.error('config', 'Failed to save config: %s', tostring(err)) end
        return false
    end
    if log then log.info('config', 'Config saved to %s', path) end
    -- Notify coordinated workers that their in-memory copy is stale. The
    -- receiver reloads from disk in its normal tick, never in an Actor callback.
    local ac = package.loaded['smartheal.util.actors_coordinator']
    if ac and ac.sendWorkerCommand then
        local lib = require('smartheal.util.sk_lib')
        local owner = lib.isActiveWorker('support') and 'support' or 'healing'
        pcall(ac.sendWorkerCommand, owner, 'reload_config', {
            revision = os.time(),
            character = mq.TLO.Me and mq.TLO.Me.CleanName and mq.TLO.Me.CleanName() or '',
            zone = mq.TLO.Zone and mq.TLO.Zone.ShortName and mq.TLO.Zone.ShortName() or '',
        }, { component = 'healing' })
    end
    return true
end

function M.GetConfigPath()
    return getConfigPath()
end

--- Emergency HP threshold, resolved with class overrides already applied by
--- applyClassDefaults (PAL gets 30, everyone else 25). Never returns nil —
--- callers can drop their old `or 25` fallbacks. This is intentionally
--- parameterless: it returns the running healer's threshold, which is the
--- correct choice for both "am I in an emergency" and "is this heal target
--- below my emergency line" checks.
function M.getEmergencyPct()
    return M.emergencyPct or 25
end

-- Class-specific default overrides (applied before user config)
local CLASS_DEFAULTS = {
    PAL = {
        emergencyPct = 30,       -- Slightly higher than CLR's 25 (off-healer needs headroom)
        groupHealMinCount = 2,   -- Aurora is PAL's strongest heal, use it more
        hotEnabled = false,      -- PAL has no HoTs
        selfHealEnabled = true,  -- PAL needs self-heal while tanking
        healPetsEnabled = false, -- Limited heal bandwidth
    },
}

function M.applyClassDefaults()
    local me = mq.TLO.Me
    if not me or not me() then
        local log = getLogger()
        if log then log.warn('config', 'applyClassDefaults: character not available yet, skipping') end
        return
    end
    local classShort = (me.Class and me.Class.ShortName and me.Class.ShortName() or ''):upper()
    local defaults = CLASS_DEFAULTS[classShort]
    if not defaults then return end
    local log = getLogger()
    for k, v in pairs(defaults) do
        if M[k] ~= nil then
            M[k] = v
        end
    end
    if log then log.info('config', 'Applied class defaults for %s', classShort) end
end

function M.load()
    local log = getLogger()

    -- Apply class defaults first, then user config overrides them
    M.applyClassDefaults()

    local path = getConfigPath()
    local file = io.open(path, 'r')
    if not file then
        if log then log.info('config', 'No config file found, using class defaults') end
        return
    end
    local content = file:read('*a')
    file:close()
    local fn, err = load(content, path, 't', {})
    if not fn then
        if log then log.error('config', 'Config load error: %s', err) end
        return
    end
    local ok, data = pcall(fn)
    if not ok or type(data) ~= 'table' then
        if log then log.error('config', 'Config parse error') end
        return
    end
    -- Merge loaded data into M (preserving structure)
    for k, v in pairs(data) do
        if k ~= '_version' and M[k] ~= nil then
            M[k] = v
        end
    end

    local beforeFilter = 0
    for _, spells in pairs(M.spells or {}) do
        beforeFilter = beforeFilter + #spells
    end
    M.FilterSpells()
    local afterFilter = 0
    for _, spells in pairs(M.spells or {}) do
        afterFilter = afterFilter + #spells
    end
    if afterFilter < beforeFilter and log then
        log.warn('config', 'Removed %d unavailable/invalid healing spell(s) from config',
            beforeFilter - afterFilter)
    end
    if afterFilter == 0 and M.autoAssignFromActiveSpellSet then
        local assignedFromSpellSet = M.autoAssignFromActiveSpellSet()
        if assignedFromSpellSet then
            M.save()
        elseif log then
            log.info('config', 'No configured heals and no valid healing spells found in active spell set')
        end
    end

    -- Migration: Force new scoring weights if using old defaults
    -- Old defaults had manaEff=1.0, overheal=-1.5 which favored overhealing
    local needsMigration = false
    if M.scoringPresets and M.scoringPresets.normal then
        local normal = M.scoringPresets.normal
        -- Detect old weights: manaEff >= 1.0 and overheal > -2.0
        if (normal.manaEff or 0) >= 1.0 and (normal.overheal or 0) > -2.0 then
            needsMigration = true
        end
    end

    if needsMigration then
        if log then log.warn('config', 'Migrating scoring weights to prefer underhealing over overhealing') end
        M.scoringPresets = {
            emergency = { coverage = 4.0, manaEff = 0.1, overheal = -0.5 },
            normal = { coverage = 2.0, manaEff = 0.5, overheal = -3.0 },
            lowPressure = { coverage = 1.0, manaEff = 1.5, overheal = -4.0 },
        }
        -- Also update HoT thresholds if they're old values
        if M.hotMinDeficitPct and M.hotMinDeficitPct < 15 then
            M.hotMinDeficitPct = 20
        end
        if M.hotMaxDeficitPct and M.hotMaxDeficitPct < 30 then
            M.hotMaxDeficitPct = 35
        end
        -- Save migrated config
        M.save()
    end

    if log then log.info('config', 'Config loaded from %s', path) end
end

return M
