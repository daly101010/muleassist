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
  -- size can be 0 while entries exist; scan up to max(size, 50)
  local maxn = math.max(size, 50)
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
