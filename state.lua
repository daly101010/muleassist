-- muleassist/state.lua
-- Runtime state built from config. Replaces the macro's ~300 outer-scope variables.
-- apply_config (re-runnable) sets every config-derived field IN PLACE so /mareload and
-- the embedded UI can re-apply edits without orphaning the loop/binds' st reference or
-- wiping runtime (camp, pull/combat state machines, timers).
local state = {}

-- Re-runnable: (re)assign every config-derived field on st. Never touches runtime fields.
function state.apply_config(st, cfg)
  st.cfg  = cfg
  st.role = cfg:get('General', 'Role', 'Assist')

  st.flags = st.flags or {}
  local f = st.flags
  f.pet_on    = cfg:bool('Pet',     'PetOn',        false)
  f.buffs_on  = cfg:bool('Buffs',   'BuffsOn',      false)
  f.heals_on  = cfg:bool('Heals',   'HealsOn',      false)
  f.dps_on    = cfg:bool('DPS',     'DPSOn',        false)
  f.melee_on  = cfg:bool('Melee',   'MeleeOn',      false)
  f.mez_on    = cfg:bool('Mez',     'MezOn',        false)
  f.charm_on  = cfg:bool('General', 'CharmOn',      false)
  f.med_on    = cfg:bool('General', 'MedOn',        false)
  f.return_to_camp = cfg:bool('General', 'ReturnToCamp', false)
  f.eqbc_on   = cfg:bool('General', 'EQBCOn',       false)
  f.dannet_on = cfg:bool('General', 'DanNetOn',     false)

  st.combat = st.combat or {}
  local c = st.combat
  c.role           = (cfg:get('General', 'Role', 'Assist') or 'Assist')
  c.assist_at      = cfg:num('Melee', 'AssistAt', 95)
  c.melee_on       = cfg:bool('Melee', 'MeleeOn', false)
  c.melee_dist     = cfg:num('Melee', 'MeleeDistance', 25)
  c.stick_how      = cfg:get('Melee', 'StickHow', '!frontangle 12')
  c.tank_stick     = cfg:get('Melee', 'TankStickHow', '!front')
  c.face_on        = cfg:bool('Melee', 'FaceMobOn', true)
  c.dps_on         = cfg:bool('DPS', 'DPSOn', false)
  c.dps_interval   = cfg:num('DPS', 'DPSInterval', 1)
  c.dps_cond_on    = cfg:bool('General', 'ConditionsOn', true) and cfg:bool('DPS', 'DPSCOn', true)
  c.assist_outside = cfg:bool('General', 'AssistOutside', false)
  c.pet_assist_at  = cfg:num('Pet', 'PetAssistAt', 95)
  c.pet_combat_on  = cfg:bool('Pet', 'PetCombatOn', false)
  c.aggro_on       = cfg:bool('Aggro', 'AggroOn', false)
  c.burn_all_named = cfg:bool('Burn', 'BurnAllNamed', false)

  st.heal = st.heal or {}
  local h = st.heal
  h.mode         = cfg:num('Heals', 'HealsOn', 0)
  h.xtar         = cfg:get('Heals', 'XTarHeal', nil)
  h.group_pets   = cfg:bool('Heals', 'HealGroupPetsOn', false)
  h.interrupt    = cfg:num('Heals', 'InterruptHeals', 100)
  h.duration_mod = cfg:num('General', 'DurationMod', 1)
  h.cond_on      = cfg:bool('General', 'ConditionsOn', true) and cfg:bool('Heals', 'HealsCOn', true)

  st.rez = st.rez or {}
  st.rez.auto     = cfg:num('Heals', 'AutoRezOn', 0)
  st.rez.with     = cfg:get('Heals', 'AutoRezWith', nil)
  st.rez.mount_on = cfg:bool('General', 'MountOn', true)

  st.buff = st.buff or {}
  local b = st.buff
  b.check_secs    = cfg:num('Buffs', 'CheckBuffsTimer', 10)
  b.while_chasing = cfg:bool('General', 'BuffWhileChasing', true)
  b.duration_mod  = cfg:num('General', 'DurationMod', 1)
  b.cond_on       = cfg:bool('General', 'ConditionsOn', true) and cfg:bool('Buffs', 'BuffsCOn', true)

  st.pet = st.pet or {}
  st.pet.buffs_on     = cfg:bool('Pet', 'PetBuffsOn', false)
  st.pet.shrink_on    = cfg:bool('Pet', 'PetShrinkOn', false)
  st.pet.shrink_spell = cfg:get('Pet', 'PetShrinkSpell', 'Tiny Companion')
  st.pet.check_secs   = 60

  -- cfg MainAssist wins, but keep an arg/auto-derived value if cfg is empty
  st.main_assist = cfg:get('General', 'MainAssist', nil) or st.main_assist

  st.camp = st.camp or {}
  st.camp.radius = cfg:num('General', 'CampRadius', 60)
  st.camp.exceed = cfg:num('General', 'CampRadiusExceed', 400)

  st.move = st.move or {}
  local m = st.move
  m.return_to_camp  = cfg:bool('General', 'ReturnToCamp', false)
  m.return_accuracy = cfg:num('General', 'ReturnToCampAccuracy', 10)
  m.chase_assist    = cfg:bool('General', 'ChaseAssist', false)
  m.chase_distance  = cfg:num('General', 'ChaseDistance', 25)

  st.med = st.med or {}
  st.med.on         = cfg:bool('General', 'MedOn', false)
  st.med.start      = cfg:num('General', 'MedStart', 90)
  st.med.sit_to_med = cfg:bool('General', 'SitToMed', false)

  st.pull = st.pull or {}
  local pl = st.pull
  pl.with        = cfg:get('Pull', 'PullWith', 'Melee')
  pl.max_radius  = cfg:num('Pull', 'MaxRadius', 350)
  pl.max_z       = cfg:num('Pull', 'MaxZRange', 50)
  pl.wait        = cfg:num('Pull', 'PullWait', 5)
  pl.cond        = cfg:get('Pull', 'PullCond', nil)
  pl.mobs        = cfg:get('Pull', 'MobsToPull', 'All')
  pl.namedsfirst = cfg:bool('Pull', 'PullNamedsFirst', false)
  pl.level_raw   = cfg:get('Pull', 'PullLevel', '0|0')
  pl.melee_dist  = cfg:num('Melee', 'MeleeDistance', 25)
  pl.chain       = cfg:num('Pull', 'ChainPull', 0)
  pl.chain_hp    = cfg:num('Pull', 'ChainPullHP', 90)
  pl.chain_pause = cfg:get('Pull', 'ChainPullPause', '0')
  pl.use_calm    = cfg:bool('Pull', 'UseCalm', false)
  pl.calm_with   = cfg:get('Pull', 'CalmWith', 'Harmony')
  pl.calm_radius = cfg:num('Pull', 'CalmRadius', 50)
  pl.arc_width   = cfg:num('Pull', 'PullArcWidth', 0)
  pl.grab_dead   = cfg:bool('Pull', 'GrabDeadGroupMembers', false)
  pl.mobs_sec    = cfg:get('Pull', 'MobsToPullSecondary', nil)
  -- camp leash must cover the pull radius (re-applied here so a live radius edit sticks)
  if pl.max_radius + 1 > st.camp.exceed then st.camp.exceed = pl.max_radius + 1 end

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
end

function state.new(cfg)
  local st = { running = true, hooks = {}, timers = {} }
  state.apply_config(st, cfg)

  -- runtime-only fields (set once; survive every apply_config/reapply)
  st.flags.buff_mode   = false
  st.flags.zombie_mode = false

  local c = st.combat
  c.aggro_target_id = nil; c.hostile_count = 0; c.mob_count = 0
  c.my_target_id = nil; c.my_target_name = nil; c.combat_start = nil
  c.attacking = nil; c.pulled = nil; c.chasing = nil; c.xtslot = 1
  c.dps_timers = {}; c.entries = {}; c.debuffs = {}; c.aggro = {}
  c.burn = {}; c.burning = false; c.named_check = nil

  local h = st.heal
  h.single = {}; h.group = {}
  h.timers = {}; h.group_timers = {}; h.pet_timers = {}
  h.single_point = 0

  st.rez.radius = 150; st.rez.battle_timers = {}; st.rez.ooc_timers = {}

  st.buff.entries = {}; st.buff.timers = {}; st.buff.oog_timers = {}; st.buff.read_deadline = 0

  st.pet.check_deadline = 0; st.pet.entries = {}

  st.main_assist_id = 0

  st.camp.x = nil; st.camp.y = nil; st.camp.z = nil

  st.move.chase_name = nil

  st.med.medding = false

  local pl = st.pull
  pl.range = 15; pl.range_type = 'Melee'; pl.pull_min = 1; pl.pull_max = 200
  pl.mob_list = nil; pl.mob_list_sec = nil
  pl.arc_lside = 0; pl.arc_rside = 0; pl.move_use = 'nav'; pl.path_wp_count = 0
  pl.state = 'idle'; pl.target_id = nil; pl.abort_deadline = 0; pl.wait_until = 0; pl.attempts = 0
  pl.chain_hold = false; pl.chain_active_until = 0; pl.chain_pause_until = 0; pl.dragging = 0

  st.pending_reapply = false   -- set by /mareload or the UI; consumed in init.lua's loop

  return st
end

return state
