-- muleassist/config.lua  (pure: no require('mq') in the parse path)
-- Reads MuleAssist_<Server>_<Char>.ini into Lua tables; preserves the on-disk format.
local config = {}

local LIST_DEFS = {
  dps       = { prefix='DPS',       cond='DPSCond',       size='DPSSize',       section='DPS'  },
  heals     = { prefix='Heals',     cond='HealsCond',     size='HealsSize',     section='Heals'},
  buffs     = { prefix='Buffs',     cond='BuffsCond',     size='BuffsSize',     section='Buffs'},
  burn      = { prefix='Burn',      cond=nil,             size='BurnSize',      section='Burn' },
  ohshit    = { prefix='OhShit',    cond='OhShitCond',    size='OhShitSize',    section='OhShit'},
  aggro     = { prefix='Aggro',     cond='AggroCond',     size='AggroSize',     section='Aggro'},
  petbuffs  = { prefix='PetBuffs',  cond=nil,             size='PetBuffsSize',  section='Pet'  },
  bandolier = { prefix='Bandolier', cond='BandolierCond', size='BandolierSize', section='Bandolier'},
  gom       = { prefix='GoM',       cond='GoMCond',       size='GoMSize',       section='GoM'  },
  ae        = { prefix='AE',        cond='AECond',        size='AESize',        section='AE'   },
  cures     = { prefix='Cures',     cond='CuresCond',     size='CuresSize',     section='Cures'},
  charm     = { prefix='Charm',     cond=nil,             size='CharmSize',     section='Charm'},
}

local function trim(s) return (s:gsub('^%s*(.-)%s*$', '%1')) end

local function parse_file(path)
  local fh = io.open(path, 'r')
  if not fh then return nil, 'cannot open '..tostring(path) end
  local sections, cur = {}, nil
  for line in fh:lines() do
    line = line:gsub('\r$', '')
    local header = line:match('^%s*%[(.+)%]%s*$')
    if header then
      cur = header; sections[cur] = sections[cur] or {}
    elseif cur then
      local k, v = line:match('^%s*([^=]-)%s*=%s*(.-)%s*$')
      if k and k ~= '' then sections[cur][k] = v end
    end
  end
  fh:close()
  return sections
end

local function split_pipe(s)
  local spell, param = s:match('^(.-)%s*|%s*(.*)$')
  if spell then return trim(spell), trim(param) end
  return trim(s), nil
end

-- All pipe-delimited fields, trimmed (the macro's .Arg[n,|] access).
local function split_args(s)
  local out = {}
  for field in (s .. '|'):gmatch('([^|]*)|') do out[#out + 1] = trim(field) end
  return out
end

local cfg_mt = {}
cfg_mt.__index = cfg_mt
function cfg_mt:get(section, key, dflt)
  local s = self.sections[section]
  local v = s and s[key]
  if v == nil or v == '' then return dflt end
  return v
end
function cfg_mt:num(section, key, dflt)
  local v = self:get(section, key, nil)
  return tonumber(v) or dflt
end
function cfg_mt:bool(section, key, dflt)
  local v = self:get(section, key, nil)
  if v == nil then return dflt end
  v = tostring(v):upper()
  return v == '1' or v == 'TRUE' or v == 'ON' or v == 'YES'
end
function cfg_mt:list(name)
  local def = LIST_DEFS[name]; assert(def, 'unknown list '..tostring(name))
  if self._lists[name] then return self._lists[name] end
  local out = {}
  local size = self:num(def.section, def.size, 0)
  -- Respect an explicit Size as the cap: entries beyond it are disabled (matches the macro,
  -- which loops 1..Section.Size). Fall back to scanning 50 only when Size is unset/0.
  local maxn = (size > 0) and size or 50
  for i = 1, maxn do
    local raw = self:get(def.section, def.prefix..i, nil)
    if raw and trim(raw) ~= '' and trim(raw):upper() ~= 'NULL' then
      local spell, param = split_pipe(raw)
      local condstr = def.cond and self:get(def.section, def.cond..i, nil) or nil
      out[#out+1] = { spell=spell, param=param, args=split_args(raw), cond=condstr, raw=raw, index=i }
    end
  end
  self._lists[name] = out
  return out
end

function config.load(path)
  local sections, err = parse_file(path)
  if not sections then return nil, err end
  return setmetatable({ path=path, sections=sections, _lists={} }, cfg_mt)
end

local function default_sections(opts)
  opts = opts or {}
  local raw_role = opts.role and tostring(opts.role) or ''
  local role = (raw_role ~= '' and raw_role:lower() ~= 'none') and raw_role or 'Assist'
  local class = opts.class and opts.class ~= '' and opts.class or 'Unknown'
  local level = tonumber(opts.level) or 0
  return {
    General = {
      Role = role,
      MainAssist = opts.main_assist or '',
      CharInfo = string.format('%s|%d|GOLD', class, level),
      CampRadius = 60,
      CampRadiusExceed = 400,
      ReturnToCamp = 0,
      ReturnToCampAccuracy = 10,
      ChaseAssist = 0,
      ChaseDistance = 25,
      MedOn = 1,
      MedStart = 20,
      SitToMed = 1,
      ConditionsOn = 1,
      BuffWhileChasing = 1,
      MiscGem = 8,
      MiscGemLW = 0,
      MiscGemRemem = 1,
      GemStuckAbility = 'NULL',
      EQBCOn = 0,
      DanNetOn = 0,
      LootOn = 0,
      TwistOn = 0,
      TwistHold = 0,
    },
    Melee = {
      AssistAt = 95,
      MeleeOn = 0,
      MeleeDistance = 30,
      FaceMobOn = 1,
      StickHow = 'snaproll rear',
      TargetSwitchingOn = 0,
      ManualTargetMode = 0,
      TankAllMobs = 0,
      MeleeTwistOn = 0,
    },
    DPS = { DPSOn = 0, DPSSize = 0, DPSCOn = 1, DPSInterval = 2, DPSSkip = 1, DebuffAllOn = 0 },
    Heals = { HealsOn = 0, HealsSize = 0, HealsCOn = 1, AutoRezOn = 0, AutoRezWith = 'NULL', HealGroupPetsOn = 0, InterruptHeals = 100, XTarHeal = 0 },
    Buffs = { BuffsOn = 0, BuffsSize = 0, BuffsCOn = 1, CheckBuffsTimer = 10, RebuffOn = 1, PowerSource = 'NULL' },
    Burn = { BurnAllNamed = 0, BurnCOn = 0, BurnSize = 0, UseTribute = 0, BurnText = 'Burn this' },
    Mez = { MezOn = 0, MezRadius = 50, MezMinLevel = 0, MezMaxLevel = 200, MezStopHPs = 80, MezSpell = 'NULL', MezAESpell = 'NULL|0' },
    AE = { AEOn = 0, AERadius = 50, AESize = 0 },
    OhShit = { OhShitOn = 0, OhShitSize = 0, OhShitCOn = 1 },
    Pet = { PetOn = 0, PetSpell = 'NULL', PetBuffsOn = 0, PetBuffsSize = 0, PetCombatOn = 0, PetAssistAt = 95, PetHoldOn = 1, PetShrinkOn = 0, PetShrinkSpell = 'Tiny Companion' },
    Charm = { CharmOn = 0, CharmSize = 0, CharmStunOn = 1, CharmRetashOn = 1, CharmAutoOn = 0, CharmMaxFails = 3 },
    Pull = { PullWith = 'Melee', MaxRadius = 350, MaxZRange = 50, PullWait = 5, PullCond = 'TRUE', PullLevel = '0|0', ChainPull = 0, ChainPullHP = 90, ChainPullPause = '0' },
    Aggro = { AggroOn = 0, AggroSize = 0, AggroCOn = 1 },
    Bandolier = { BandolierOn = 0, BandolierSize = 0, BandolierCOn = 1, BandolierPull = 'NULL' },
    Cures = { CuresOn = 0, CuresSize = 0 },
    GoM = { GoMOn = 0, GoMSize = 0, GoMCOn = 1 },
    Merc = { MercOn = 0, MercAssistAt = 100, AutoRevive = 0 },
    AFKTools = { AFKToolsOn = 0, AFKGMAction = 1, AFKPCRadius = 500, BeepOnNamed = 0, CampOnDeath = 0, ClickBacktoCamp = 0 },
    GMail = { GMailOn = 0, GMailSize = 0 },
    SpellSet = { LoadSpellSet = 2, SpellSetName = 'MuleAssist' },
    MySpells = {},
    AutoClass = { AutoClassOn = 1, Family = 'Live', Mode = 'Default', SuggestOnly = 1, FillEmptyMySpells = 1, FillEmptyLists = 1 },
    AutoClassCache = { Family = 'Live', Class = '', Level = tostring(level), Mode = 'Default', LastScan = '', GemCount = 0 },
  }
end

function config.default(opts)
  return setmetatable({ path = opts and opts.path or nil, sections = default_sections(opts), _lists = {} }, cfg_mt)
end

function config.create_default(path, opts)
  opts = opts or {}
  opts.path = path
  local cfg = config.default(opts)
  local ok, err = config.save(cfg)
  if not ok then return nil, err end
  return cfg
end

-- Build the INI filename(s). Returns primary and (optional) legacy _<level> filename.
function config.locate(server, char, level)
  local base = string.format('MuleAssist_%s_%s', server, char)
  local legacy = level and (string.format('MuleAssist_%s_%s_%d', server, char, level) .. '.ini') or nil
  return base .. '.ini', legacy
end

function config.save(cfg)
  local fh, err = io.open(cfg.path, 'w'); if not fh then return false, err end
  -- stable order: sections then keys (sorted) to keep diffs readable
  local secnames = {}
  for k in pairs(cfg.sections) do secnames[#secnames+1] = k end
  table.sort(secnames)
  for _, sec in ipairs(secnames) do
    fh:write('['..sec..']\n')
    local keys = {}
    for k in pairs(cfg.sections[sec]) do keys[#keys+1] = k end
    table.sort(keys)
    for _, k in ipairs(keys) do fh:write(k..'='..tostring(cfg.sections[sec][k])..'\n') end
    fh:write('\n')
  end
  fh:close(); return true
end

return config
