-- muleassist/state.lua
-- Runtime state built from config. Replaces the macro's ~300 outer-scope variables.
local state = {}

function state.new(cfg)
  local st = { cfg = cfg, running = true }

  st.role = cfg:get('General', 'Role', 'Assist')

  st.flags = {
    pet_on    = cfg:bool('Pet',    'PetOn',        false),
    buffs_on  = cfg:bool('Buffs',  'BuffsOn',      false),
    heals_on  = cfg:bool('Heals',  'HealsOn',      false),
    dps_on    = cfg:bool('DPS',    'DPSOn',        false),
    melee_on  = cfg:bool('Melee',  'MeleeOn',      false),
    mez_on    = cfg:bool('Mez',    'MezOn',        false),
    charm_on  = cfg:bool('General','CharmOn',      false),
    med_on    = cfg:bool('General','MedOn',        false),
    return_to_camp = cfg:bool('General', 'ReturnToCamp', false),
    eqbc_on   = cfg:bool('General','EQBCOn',       false),
    dannet_on = cfg:bool('General','DanNetOn',     false),
  }

  st.flags.buff_mode   = false
  st.flags.zombie_mode = false

  st.timers = {} -- name -> deadline; populated by modules at runtime

  -- Optional callbacks wired by later phases (nil = skip): oh_shit, custom_func,
  -- write_debuffs, etc.
  st.hooks = {}
  -- Combat state (Phase 4a). Runtime fields (aggro_target_id, my_target_id, combat_start,
  -- pulled, chasing) are read defensively by heal/buff/rez; combat.tick populates them.
  st.combat = {
    -- config
    role          = (cfg:get('General', 'Role', 'Assist') or 'Assist'),
    assist_at     = cfg:num('Melee', 'AssistAt', 95),
    melee_on      = cfg:bool('Melee', 'MeleeOn', false),
    melee_dist    = cfg:num('Melee', 'MeleeDistance', 25),
    stick_how     = cfg:get('Melee', 'StickHow', '!frontangle 12'),
    tank_stick    = cfg:get('Melee', 'TankStickHow', '!front'),  -- tanks always hold the front
    face_on       = cfg:bool('Melee', 'FaceMobOn', true),
    dps_on        = cfg:bool('DPS', 'DPSOn', false),
    dps_interval  = cfg:num('DPS', 'DPSInterval', 1),
    dps_cond_on   = cfg:bool('General', 'ConditionsOn', true) and cfg:bool('DPS', 'DPSCOn', true),
    assist_outside= cfg:bool('General', 'AssistOutside', false),
    pet_assist_at = cfg:num('Pet', 'PetAssistAt', 95),
    pet_combat_on = cfg:bool('Pet', 'PetCombatOn', false),
    aggro_on      = cfg:bool('Aggro', 'AggroOn', false),
    burn_all_named= cfg:bool('Burn', 'BurnAllNamed', false),
    -- runtime
    aggro_target_id = nil,
    hostile_count   = 0,
    mob_count       = 0,
    my_target_id    = nil,
    my_target_name  = nil,
    combat_start    = nil,
    attacking       = nil,
    pulled          = nil,
    chasing         = nil,
    xtslot          = 1,
    dps_timers      = {},   -- [slot_index][target_id] = os.clock() deadline
    entries         = {},   -- categorized DPS list (combat.setup)
    debuffs         = {},   -- DPS entries with Arg2>=101 (combat.setup)
    aggro           = {},   -- parsed Aggro list (combat.setup)
    burn            = {},
    burning         = false,
    named_check     = nil,  -- runtime: already burned this named
  }

  st.heal = {
    mode         = cfg:num('Heals', 'HealsOn', 0),      -- 0 off,1 all,2 group-no-MA,3 MA+self
    single       = {}, group = {},                       -- populated by heal.setup
    timers       = {}, group_timers = {}, pet_timers = {},
    single_point = 0,                                    -- max single heal %, computed in setup
    xtar         = cfg:get('Heals', 'XTarHeal', nil),    -- pipe list of XTarget slot numbers
    group_pets   = cfg:bool('Heals', 'HealGroupPetsOn', false),
    interrupt    = cfg:num('Heals', 'InterruptHeals', 100),
    duration_mod = cfg:num('General', 'DurationMod', 1),
    cond_on      = cfg:bool('General', 'ConditionsOn', true) and cfg:bool('Heals', 'HealsCOn', true),
  }

  st.rez = {
    auto          = cfg:num('Heals', 'AutoRezOn', 0),     -- 0 off, 1 always(no-aggro), 2 after-combat
    with          = cfg:get('Heals', 'AutoRezWith', nil), -- spell/AA/item name
    radius        = 150,                                   -- macro RezRadius const
    battle_timers = {},                                    -- [groupSlot] = os.clock() deadline
    ooc_timers    = {},                                    -- [corpseSpawnID] = os.clock() deadline
    mount_on      = cfg:bool('General', 'MountOn', true),  -- CastMount deferred to Phase 5
  }

  st.buff = {
    check_secs    = cfg:num('Buffs', 'CheckBuffsTimer', 10),  -- ReadBuffsTimer throttle
    while_chasing = cfg:bool('General', 'BuffWhileChasing', true),
    duration_mod  = cfg:num('General', 'DurationMod', 1),
    cond_on       = cfg:bool('General', 'ConditionsOn', true)
                    and cfg:bool('Buffs', 'BuffsCOn', true),
    entries       = {},   -- categorized by buff.setup
    timers        = {},   -- [entry_index][who] = os.clock() deadline (who: member idx, 7=MA, 0=self)
    oog_timers    = {},   -- [spawnID] = os.clock() deadline (OOG dedup; replaces the ini)
    read_deadline = 0,    -- os.clock() deadline for the whole-loop throttle
  }

  st.pet = {
    buffs_on       = cfg:bool('Pet', 'PetBuffsOn',  false),
    shrink_on      = cfg:bool('Pet', 'PetShrinkOn', false),
    shrink_spell   = cfg:get('Pet', 'PetShrinkSpell', 'Tiny Companion'),
    check_secs     = 60,   -- PetBuffCheck throttle
    check_deadline = 0,
    entries        = {},   -- set by petbuff.setup
  }

  st.main_assist    = cfg:get('General', 'MainAssist', nil)
  st.main_assist_id = 0

  st.camp = {
    x = nil, y = nil, z = nil,
    radius = cfg:num('General', 'CampRadius',       60),
    exceed = cfg:num('General', 'CampRadiusExceed', 400),
  }

  st.move = {
    return_to_camp = cfg:bool('General', 'ReturnToCamp', false),
    return_accuracy= cfg:num('General', 'ReturnToCampAccuracy', 10),
    chase_assist   = cfg:bool('General', 'ChaseAssist', false),
    chase_distance = cfg:num('General', 'ChaseDistance', 25),
    chase_name     = nil,   -- defaults to MA at setup; a bind can change it later
  }

  st.pull = {
    with        = cfg:get('Pull', 'PullWith', 'Melee'),
    max_radius  = cfg:num('Pull', 'MaxRadius', 350),
    max_z       = cfg:num('Pull', 'MaxZRange', 50),
    wait        = cfg:num('Pull', 'PullWait', 5),
    cond        = cfg:get('Pull', 'PullCond', nil),
    mobs        = cfg:get('Pull', 'MobsToPull', 'All'),
    namedsfirst = cfg:bool('Pull', 'PullNamedsFirst', false),
    level_raw   = cfg:get('Pull', 'PullLevel', '0|0'),
    melee_dist  = cfg:num('Melee', 'MeleeDistance', 25),
    -- 5b-2 features
    chain       = cfg:num('Pull', 'ChainPull', 0),
    chain_hp    = cfg:num('Pull', 'ChainPullHP', 90),
    chain_pause = cfg:get('Pull', 'ChainPullPause', '0'),     -- "activeMin|pauseMin" or "0"
    use_calm    = cfg:bool('Pull', 'UseCalm', false),
    calm_with   = cfg:get('Pull', 'CalmWith', 'Harmony'),
    calm_radius = cfg:num('Pull', 'CalmRadius', 50),
    arc_width   = cfg:num('Pull', 'PullArcWidth', 0),
    grab_dead   = cfg:bool('Pull', 'GrabDeadGroupMembers', false),
    mobs_sec    = cfg:get('Pull', 'MobsToPullSecondary', nil),
    -- resolved by pull.setup
    range = 15, range_type = 'Melee', pull_min = 1, pull_max = 200,
    mob_list = nil, mob_list_sec = nil,
    arc_lside = 0, arc_rside = 0,
    move_use = 'nav', path_wp_count = 0,
    -- runtime
    state = 'idle', target_id = nil, abort_deadline = 0, wait_until = 0, attempts = 0,
    chain_hold = false, chain_active_until = 0, chain_pause_until = 0,
    dragging = 0,
  }
  -- Puller travels out to MaxRadius; don't let the camp leash abort it (macro @5583).
  if st.pull.max_radius + 1 > st.camp.exceed then st.camp.exceed = st.pull.max_radius + 1 end

  st.med = {
    on         = cfg:bool('General', 'MedOn', false),  -- meditate when idle/out of combat
    start      = cfg:num('General', 'MedStart', 90),   -- sit when a med stat drops below this %
    sit_to_med = cfg:bool('General', 'SitToMed', false), -- also sit between casts IN combat
                                                         -- (non-melee chars only: healers/casters)
    medding    = false,                                 -- runtime: currently sitting to recover
  }

  st.lists = {
    dps       = cfg:list('dps'),
    heals     = cfg:list('heals'),
    buffs     = cfg:list('buffs'),
    burn      = cfg:list('burn'),
    ohshit    = cfg:list('ohshit'),
    aggro     = cfg:list('aggro'),
    petbuffs  = cfg:list('petbuffs'),
    bandolier = cfg:list('bandolier'),
    gom       = cfg:list('gom'),
    ae        = cfg:list('ae'),
    cures     = cfg:list('cures'),
  }

  return st
end

return state
