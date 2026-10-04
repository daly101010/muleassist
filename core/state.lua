-- core/state.lua: the shared runtime the macro kept in outer variables. One table, documented fields.
local M = {
    -- identity and roles
    role = 'assist',           -- [General] Role
    mainAssist = '',           -- MainAssist name
    mainAssistId = 0,
    mainAssistType = 'PC',
    healTank = '',             -- /raidtank: the heal tank (defaults to the MainAssist)
    healTankId = 0,
    healTankType = 'PC',
    healTankMode = 'off',      -- off | auto | <name>
    -- combat
    myTargetId = 0,            -- the mob we fight (MyTargetID)
    myTargetName = '',
    aggroTargetId = 0,         -- the mob the MA fights (AggroTargetID)
    aggroTargetId2 = 0,
    assistId = 0,              -- the MA's announced kill target (TANKING-> events)
    combatStart = false,
    attacking = false,
    mobCount = 0,
    meleeOn = false,           -- [Melee] MeleeOn after the role rules
    dpsOn = false,             -- [DPS] DPSOn after the role rules
    assistAt = 95,
    roleDefaults = {},         -- what the role forces on movement: returnToCamp, chaseAssist, campRadiusExceed
    meleeHit = false,          -- a GotHit event since the last reset
    namedCheck = false,        -- the named-burn check ran for this target
    pulled = false,            -- the puller brought this target in itself
    mezMobFlag = false,
    mezOn = false,             -- set by the mez module (step 5)
    mezImmuneNames = {},       -- lower-cased names the mez module learned are immune
    mobsToIgnore = {},         -- [General] MobsToIgnore names
    charmPetIds = {},          -- ids of charmed pets (charm module)
    manualMAAttack = false,    -- manual MA mode: the MA pressed attack on manualMATarget
    manualMATarget = 0,
    -- flags the fleet toggles (the status line lists the ones that are on)
    paused = false,
    buffMode = false,
    zombieMode = false,
    manualOn = false,
    manualMAOn = false,
    getAwayOn = false,
    getAwayFollow = false,
    raidModeOn = false,
    markAssistOn = false,
    raidMarkNum = 1,
    xtarTanks = false,
    xtarTankOwned = '',
    aggroPaused = false,
    aeOn = false,
    killOrderOn = false,
    chaseAssist = false,
    chaseLeftBehind = false,
    chaseStuckTries = 0,
    -- module On switches (set by each module's LoadSettings / bind)
    healsOn = false,
    autoRezOn = false,
    ohShitOn = false,
    curesOn = false,
    buffsOn = false,
    smartHealsOn = false,
    healBrainOn = false,
    -- life and pulls
    iAmDead = false,
    pulling = false,
    chainPull = 0,
    chainPullHold = 0,
    mountOn = true,            -- off for the pet-tank roles
    medding = false,           -- sitting to med (DoWeMed / GroupWatch / WaitForMedders)
    -- chase and camp (set by the movement module)
    chaseName = '',
    chaseDistance = 25,
    returnToCamp = false,
    campRadius = 30,
    killOrderTarget = 0,
    launchMainAssist = nil,    -- the MA named on the /lua run command line (overrides [General] MainAssist)
    -- pet and protection (set by the pet / combat modules)
    petOn = false,
    petAttackRange = 0,
    dpsPaused = false,
    markId = 0,
    mobsToProtect = {},
    mobsToPull = {}, mobsToPullSecondary = {},
    xtarHealLive = nil,        -- the XTarHeal slots in use (XTarTanks rewrites them)
    xtarHealBase = '0',
    -- camp
    campZone = 0, campX = 0, campY = 0, campZ = 0,
    -- heal lines (set by the heals module, read by cast/report)
    singleHealPoint = 0, singleHealPointMA = 0, singleHealPointRange = 200,
    -- the current single-heal cast kind for the interrupt rule: 'Heal' | 'Tap' | 'Mob'
    castTag = 'Heal',
    -- observed by peers / MAUI through the MuleAssist TLO
    status = 'idle',
    healStats = '',
    myDebuffs = '0',
    -- DanNet
    danNetOn = true,
}

--- Reset the per-fight fields (CombatReset).
function M.combatReset()
    M.myTargetId = 0
    M.combatStart = false
    M.attacking = false
end

return M
