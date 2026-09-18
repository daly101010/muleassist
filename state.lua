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
  c.tank_all_mobs  = cfg:bool('Melee', 'TankAllMobs', false)
  c.burn_all_named = cfg:bool('Burn', 'BurnAllNamed', false)
  c.debuff_all_on = cfg:num('DPS', 'DebuffAllOn', 0)
  c.target_switching_on = cfg:bool('Melee', 'TargetSwitchingOn', false)
  c.manual_target_mode  = cfg:bool('Melee', 'ManualTargetMode', false)

  st.heal = st.heal or {}
  local h = st.heal
  h.mode         = cfg:num('Heals', 'HealsOn', 0)
  h.xtar         = cfg:get('Heals', 'XTarHeal', nil)
  h.group_pets   = cfg:bool('Heals', 'HealGroupPetsOn', false)
  h.interrupt    = cfg:num('Heals', 'InterruptHeals', 100)
  h.duration_mod = cfg:num('General', 'DurationMod', 1)
  h.cond_on      = cfg:bool('General', 'ConditionsOn', true) and cfg:bool('Heals', 'HealsCOn', true)
  h.cures_on     = cfg:num('Cures', 'CuresOn', 0)
  h.cure_cond_on = cfg:bool('General', 'ConditionsOn', true)

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
  st.pet.on           = cfg:bool('Pet', 'PetOn', false)          -- summon/maintain a pet
  st.pet.spell        = cfg:get('Pet', 'PetSpell', nil)
  st.pet.hold         = cfg:get('Pet', 'PetHold', 'hold')        -- /pet <hold> on
  st.pet.hold_on      = cfg:bool('Pet', 'PetHoldOn', true)
  st.pet.taunt_on     = cfg:bool('Pet', 'PetTauntOn', false)

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

  st.afk = st.afk or {}
  local afk = st.afk
  afk.on                 = cfg:num('AFKTools', 'AFKToolsOn', 0)
  afk.gm_action          = cfg:num('AFKTools', 'AFKGMAction', 1)
  afk.pc_radius          = cfg:num('AFKTools', 'AFKPCRadius', 500)
  afk.camp_on_death      = cfg:bool('AFKTools', 'CampOnDeath', false)
  afk.click_back_to_camp = cfg:bool('AFKTools', 'ClickBacktoCamp', false)
  afk.beep_on_named      = cfg:bool('AFKTools', 'BeepOnNamed', false)

  st.bard = st.bard or {}
  local brd = st.bard
  brd.twist_on       = cfg:bool('General', 'TwistOn', false)
  brd.twist_med      = cfg:get('General', 'TwistMed', nil)
  brd.twist_what     = cfg:get('General', 'TwistWhat', nil)
  brd.twist_hold     = cfg:bool('General', 'TwistHold', false)
  brd.melee_on       = cfg:num('Melee', 'MeleeTwistOn', 0)
  brd.melee_what     = cfg:get('Melee', 'MeleeTwistWhat', nil)
  brd.pull_twist_on  = cfg:bool('Pull', 'PullTwistOn', false)

  st.merc = st.merc or {}
  local mc = st.merc
  mc.on          = cfg:bool('Merc', 'MercOn', false)
  mc.assist_at   = cfg:num('Merc', 'MercAssistAt', 100)
  mc.auto_revive = cfg:bool('Merc', 'AutoRevive', false)

  st.loot = st.loot or {}
  st.loot.on = cfg:bool('General', 'LootOn', false)

  st.spellset = st.spellset or {}
  st.spellset.load = cfg:num('SpellSet', 'LoadSpellSet', 0)
  st.spellset.name = cfg:get('SpellSet', 'SpellSetName', 'MuleAssist')

  st.autoclass = st.autoclass or {}
  st.autoclass.on = cfg:bool('AutoClass', 'AutoClassOn', true)
  st.autoclass.family = cfg:get('AutoClass', 'Family', 'Live')
  st.autoclass.mode = cfg:get('AutoClass', 'Mode', 'Default')
  st.autoclass.suggest_only = cfg:bool('AutoClass', 'SuggestOnly', true)
  st.autoclass.fill_empty = cfg:bool('AutoClass', 'FillEmptyMySpells', true)
  st.autoclass.fill_lists = cfg:bool('AutoClass', 'FillEmptyLists', true)
  st.autoclass.class = cfg:get('AutoClassCache', 'Class', nil)
  st.autoclass.level = cfg:num('AutoClassCache', 'Level', 0)

  st.my_spells = st.my_spells or {}
  for i = 1, 13 do
    local v = cfg:get('MySpells', 'Gem' .. i, nil)
    st.my_spells[i] = (v and v ~= '' and tostring(v):upper() ~= 'NULL') and v or nil
  end

  st.mez = st.mez or {}
  local mz = st.mez
  mz.on         = cfg:num('Mez', 'MezOn', 0)        -- 0 off, 1 AE+single, 2 single, 3 AE
  mz.radius     = cfg:num('Mez', 'MezRadius', 50)
  mz.stop_hp    = cfg:num('Mez', 'MezStopHPs', 80)  -- skip mobs already below this %
  mz.min_level  = cfg:num('Mez', 'MezMinLevel', 0)
  mz.max_level  = cfg:num('Mez', 'MezMaxLevel', 200)
  mz.spell      = cfg:get('Mez', 'MezSpell', nil)
  mz.ae_raw     = cfg:get('Mez', 'MezAESpell', nil) -- "spell|count"
  mz.mod        = cfg:num('Mez', 'MezMod', 0)
  mz.move_los   = cfg:bool('General', 'MoveCloserIfNoLOS', false)
  mz.immune_raw = cfg:get('Mez', 'MezImmune', nil)
  if mz.max_level == 0 then mz.max_level = 200 end

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
    charm     = cfg:list('charm'),
  }

  st.charm = st.charm or {}
  local ch = st.charm
  ch.on          = cfg:bool('Charm', 'CharmOn', false)  -- macro stores CharmOn in [Charm]
  ch.stun_on     = cfg:bool('Charm', 'CharmStunOn', true)
  ch.retash_on   = cfg:bool('Charm', 'CharmRetashOn', true)
  ch.auto_on     = cfg:bool('Charm', 'CharmAutoOn', false)
  ch.max_fails   = cfg:num('Charm', 'CharmMaxFails', 3)
  ch.donot_raw   = cfg:get('Charm', 'CharmDoNotList', nil)
  ch.donot_class_raw = cfg:get('Charm', 'CharmDoNotClass', nil)
end

function state.new(cfg)
  local st = { running = true, hooks = {}, timers = {} }
  state.apply_config(st, cfg)

  -- runtime-only fields (set once; survive every apply_config/reapply)
  st.flags.buff_mode   = false
  st.flags.zombie_mode = false
  st.flags.afk_hold    = false

  local c = st.combat
  c.aggro_target_id = nil; c.hostile_count = 0; c.mob_count = 0; c.passive_mob_count = 0
  c.my_target_id = nil; c.my_target_name = nil; c.combat_start = nil
  c.attacking = nil; c.pulled = nil; c.chasing = nil; c.xtslot = 1
  c.called_target_id = 0
  c.wrangle_hold_target_id = 0; c.wrangle_hold_until = 0
  c.dps_timers = {}; c.entries = {}; c.debuffs = {}; c.aggro = {}
  c.burn = {}; c.burning = false; c.named_check = nil
  c.debuff_all = {}

  local h = st.heal
  h.single = {}; h.group = {}
  h.timers = {}; h.group_timers = {}; h.pet_timers = {}
  h.cures = {}; h.cure_timers = {}; h.group_debuffs = {}
  h.single_point = 0

  st.rez.radius = 150; st.rez.battle_timers = {}; st.rez.ooc_timers = {}

  st.buff.entries = {}; st.buff.timers = {}; st.buff.oog_timers = {}; st.buff.read_deadline = 0
  st.buff.peer_buffs_by_name = {}; st.buff.peer_buffs_by_id = {}; st.buff.peer_actor_misses = {}
  st.buff.next_broadcast = 0

  st.pet.check_secs = 60; st.pet.check_deadline = 0; st.pet.entries = {}
  st.pet.summon_until = 0     -- os.clock() throttle between failed summon attempts
  st.pet.taunt_set    = false -- taunt enabled for the current pet (reset when pet changes)
  st.pet.last_pet_id  = 0     -- detect a new pet so we re-apply taunt

  st.main_assist_id = 0

  st.camp.x = nil; st.camp.y = nil; st.camp.z = nil

  st.move.chase_name = nil

  st.med.medding = false

  st.afk.holding = false
  st.afk.last_alert = 0
  st.afk.last_named_alert = 0

  st.bard.current_twist = nil
  st.bard.twisting = false

  st.merc.assisting = 0
  st.merc.in_group = false
  st.merc.name = nil

  st.loot.last_check = 0

  st.autoclass_rt = { queue = {}, startup_done = false }

  -- charm runtime (config-derived fields set by apply_config; survive reapply)
  st.charm.list       = nil  -- parsed by charm.setup: { {spell,min,max,mana}, ... }
  st.charm.donot      = nil  -- name-substring list (charm.setup)
  st.charm.donot_class= nil  -- short-name set (charm.setup)
  st.charm.max_affect = 0    -- highest mob level any configured charm can affect (charm.setup)
  st.charm.spell      = nil  -- chosen charm spell (charm.select_spell)
  st.charm.pet_id     = 0    -- the mob we are charming / our charm pet
  st.charm.fail_count = 0    -- consecutive failed charms -> recovery

  -- mez runtime (config-derived fields set by apply_config; these survive reapply)
  st.mez.array      = {}     -- list of { id, level, name, timer (os.clock deadline), count }
  st.mez.ae_until   = 0      -- os.clock() deadline before the next AE mez
  st.mez.ae_spell   = nil    -- resolved by mez.setup from ae_raw
  st.mez.ae_count   = 0      -- AE trigger threshold from ae_raw arg2
  st.mez.immune     = nil    -- name-set parsed by mez.setup
  st.mez.immune_ids = {}     -- [spawnID]=true, learned at cast time (Phase 7 events)

  local pl = st.pull
  pl.range = 15; pl.range_type = 'Melee'; pl.pull_min = 1; pl.pull_max = 200
  pl.mob_list = nil; pl.mob_list_sec = nil
  pl.arc_lside = 0; pl.arc_rside = 0; pl.move_use = 'nav'; pl.path_wp_count = 0
  pl.state = 'idle'; pl.target_id = nil; pl.abort_deadline = 0; pl.wait_until = 0; pl.attempts = 0
  pl.chain_hold = false; pl.chain_active_until = 0; pl.chain_pause_until = 0; pl.dragging = 0

  st.pending_reapply = false   -- set by /mareload or the UI; consumed in init.lua's loop
  st.pending_ui_reload = false -- set when code writes the INI while embedded MAUI is open

  return st
end

return state
