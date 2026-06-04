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
  -- write_debuffs, rez_check (Phase 2b), etc.
  st.hooks = {}
  -- Combat globals filled in Phase 4 (aggro_target_id, my_target_id, combat_start,
  -- pulled, ...). nil fields make heal.lua's combat branches no-op until then.
  st.combat = {}

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

  st.main_assist    = cfg:get('General', 'MainAssist', nil)
  st.main_assist_id = 0

  st.camp = {
    x = nil, y = nil, z = nil,
    radius = cfg:num('General', 'CampRadius',       60),
    exceed = cfg:num('General', 'CampRadiusExceed', 400),
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
