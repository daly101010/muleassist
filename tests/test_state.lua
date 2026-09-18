-- muleassist/tests/test_state.lua  (game-independent)
local config = require('muleassist.config')
local state  = require('muleassist.state')

local here = debug.getinfo(1, 'S').source:sub(2):gsub('[^/\\]+$', '')
local FIXTURE = here .. 'fixtures/sample.ini'

local t = {}
function t.run()
  local cfg = config.load(FIXTURE)
  assert(cfg, 'config.load returned nil for '..FIXTURE)
  local st = state.new(cfg)

  assert(st.role and st.role ~= '', 'role unset')
  assert(type(st.flags) == 'table', 'flags missing')
  assert(st.flags.pet_on == cfg:bool('Pet', 'PetOn', false), 'pet_on mismatch')
  assert(st.camp and st.camp.radius == cfg:num('General', 'CampRadius', 60), 'camp radius mismatch')
  assert(type(st.lists.dps) == 'table', 'dps list not attached')

  assert(type(st.heal) == 'table', 'st.heal missing')
  assert(st.heal.duration_mod ~= nil, 'duration_mod missing')
  assert(type(st.heal.timers) == 'table', 'heal.timers missing')
  assert(type(st.heal.cures) == 'table', 'heal.cures missing')
  assert(type(st.heal.cure_timers) == 'table', 'heal.cure_timers missing')
  assert(st.heal.cures_on == 0, 'CuresOn default from fixture should be 0')
  assert(type(st.hooks) == 'table', 'st.hooks missing')
  assert(type(st.combat) == 'table', 'st.combat missing')
  assert(st.flags.buff_mode == false, 'buff_mode default')

  assert(type(st.rez) == 'table', 'st.rez missing')
  assert(st.rez.radius == 150, 'rez radius const')
  assert(type(st.rez.battle_timers) == 'table', 'battle_timers missing')
  assert(type(st.rez.ooc_timers) == 'table', 'ooc_timers missing')

  assert(type(st.buff) == 'table', 'st.buff missing')
  assert(st.buff.check_secs == 10, 'default CheckBuffsTimer should be 10')
  assert(type(st.buff.entries) == 'table' and type(st.buff.timers) == 'table',
    'st.buff.entries/timers should be tables')

  assert(type(st.combat) == 'table', 'st.combat missing')
  assert(st.combat.assist_at == 95, 'default AssistAt 95')
  assert(type(st.combat.dps_timers) == 'table' and type(st.combat.entries) == 'table',
    'combat tables missing')
  assert(type(st.combat.aggro) == 'table' and type(st.combat.debuffs) == 'table',
    'combat aggro/debuffs tables missing')
  assert(st.combat.aggro_on == false, 'default AggroOn false')
  assert(st.combat.tank_all_mobs == false, 'TankAllMobs from fixture should be false')
  assert(type(st.combat.debuff_all) == 'table', 'combat.debuff_all runtime table')
  assert(st.combat.debuff_all_on == 0, 'DebuffAllOn default 0 (fixture)')
  assert(st.combat.target_switching_on == false, 'TargetSwitchingOn defaults false')
  assert(st.combat.manual_target_mode == false, 'ManualTargetMode defaults false')
  assert(st.combat.passive_mob_count == 0, 'passive_mob_count runtime default')

  assert(type(st.med) == 'table', 'st.med missing')
  assert(st.med.start == 20, 'MedStart from fixture (20)')

  assert(type(st.afk) == 'table', 'st.afk missing')
  assert(st.afk.on == 1, 'AFKToolsOn from fixture (1)')
  assert(st.afk.gm_action == 1, 'AFKGMAction from fixture (1)')
  assert(st.afk.pc_radius == 500, 'AFKPCRadius from fixture (500)')
  assert(st.flags.afk_hold == false, 'afk_hold runtime default')

  assert(type(st.bard) == 'table', 'st.bard missing')
  assert(st.bard.twist_on == false, 'TwistOn from fixture (0)')
  assert(st.bard.melee_on == 0, 'MeleeTwistOn default 0')
  assert(st.bard.twisting == false, 'bard twisting runtime default')

  assert(type(st.merc) == 'table', 'st.merc missing')
  assert(st.merc.on == false, 'MercOn from fixture (0)')
  assert(st.merc.assist_at == 92, 'MercAssistAt from fixture (92)')
  assert(st.merc.assisting == 0, 'merc assisting runtime default')

  assert(type(st.loot) == 'table', 'st.loot missing')
  assert(st.loot.on == false, 'LootOn from fixture (0)')

  assert(type(st.move) == 'table', 'st.move missing')
  assert(st.move.chase_distance == 25, 'default ChaseDistance 25')

  assert(type(st.pull) == 'table', 'st.pull missing')
  assert(st.pull.max_radius == 350, 'MaxRadius from fixture (350)')
  assert(st.pull.state == 'idle', 'pull starts idle')
  -- 5b-2 feature defaults (fixture lacks these keys)
  assert(st.pull.chain == 0, 'ChainPull defaults 0')
  assert(st.pull.chain_hp == 90, 'ChainPullHP defaults 90')
  assert(st.pull.arc_width == 0, 'PullArcWidth defaults 0')
  assert(st.pull.use_calm == false, 'UseCalm defaults false')
  assert(st.pull.grab_dead == true, 'GrabDeadGroupMembers from fixture (1)')
  assert(st.pull.move_use == 'nav', 'pull move_use defaults nav')
  assert(st.pull.dragging == 0, 'pull dragging starts 0')

  assert(type(st.mez) == 'table', 'st.mez missing')
  assert(st.mez.on == 0, 'MezOn from fixture (0)')
  assert(st.mez.radius == 50, 'MezRadius from fixture (50)')
  assert(type(st.mez.array) == 'table', 'mez array is a table')

  assert(st.pet.on == true, 'PetOn from fixture (1)')
  assert(st.pet.spell == 'Emissary of Thule', 'PetSpell from fixture')
  assert(st.pet.summon_until == 0, 'pet summon_until runtime init')

  assert(type(st.charm) == 'table', 'st.charm missing')
  assert(st.charm.on == false, 'CharmOn default false (fixture)')
  assert(st.charm.pet_id == 0, 'charm pet_id runtime init')
  assert(st.charm.fail_count == 0, 'charm fail_count runtime init')

  -- apply_config is re-runnable: picks up edits, preserves runtime fields
  st.camp.x = 111
  st.pull.state = 'outbound'
  st.combat.aggro_target_id = 999
  st.bard.current_twist = '1 2 3'
  cfg.sections['Melee'] = cfg.sections['Melee'] or {}
  cfg.sections['Melee']['AssistAt'] = '77'
  state.apply_config(st, cfg)
  assert(st.combat.assist_at == 77, 'apply_config picks up edited AssistAt')
  assert(st.camp.x == 111, 'apply_config preserves camp.x (runtime)')
  assert(st.pull.state == 'outbound', 'apply_config preserves pull.state (runtime)')
  assert(st.combat.aggro_target_id == 999, 'apply_config preserves combat runtime')
  assert(st.bard.current_twist == '1 2 3', 'apply_config preserves bard runtime')

  print('test_state: PASS')
  return true
end
return t
