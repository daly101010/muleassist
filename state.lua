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

  st.timers = {} -- name -> deadline; populated by modules at runtime

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
