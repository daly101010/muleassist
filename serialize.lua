-- muleassist/serialize.lua
-- Canonical translation between MuleAssist INI list entries and structured tables.
-- Pure Lua, no mq. Shared by the bot (buff.setup) and the config UI.
local serialize = {}

local function trim(s) return (s:gsub('^%s+', ''):gsub('%s+$', '')) end

-- Split on '|' into all fields (trailing empties dropped only at emit time).
local function pipe_split(s)
  local out = {}
  for f in (s .. '|'):gmatch('([^|]*)|') do out[#out + 1] = f end
  return out
end

-- Parse the OOG token list (after the 'OOG:' marker) into a structured table.
local function parse_oog(list)
  local oog = { names = {}, xtargets = {} }
  for tok in (list .. ','):gmatch('([^,]*),') do
    tok = trim(tok)
    if tok ~= '' then
      local low = tok:lower()
      if low == 'raid' then oog.raid = true
      elseif low == 'fellowship' then oog.fellowship = true
      elseif low:sub(1, 5) == 'range' then oog.range = tonumber(tok:sub(6))
      elseif low:sub(1, 7) == 'xtarget' then oog.xtargets[#oog.xtargets + 1] = tonumber(tok:sub(8))
      else oog.names[#oog.names + 1] = tok end
    end
  end
  return oog
end

-- Emit the OOG token list in canonical order: raid, fellowship, range, xtargets, names...
local function emit_oog(oog)
  local toks = {}
  if oog.raid then toks[#toks + 1] = 'raid' end
  if oog.fellowship then toks[#toks + 1] = 'fellowship' end
  if oog.range then toks[#toks + 1] = 'range' .. oog.range end
  for _, x in ipairs(oog.xtargets or {}) do toks[#toks + 1] = 'xtarget' .. x end
  for _, n in ipairs(oog.names or {}) do
    if n ~= '' then toks[#toks + 1] = n end   -- skip blank UI rows
  end
  return table.concat(toks, ',')
end

-- raw: full INI value (may include OOG). cond: sibling BuffsCond value or nil.
function serialize.parse_buff(raw, cond)
  raw = raw or ''
  local e = { cond = cond, raw = raw }

  -- Pull off the OOG suffix first (only when the explicit marker is present).
  local main = raw
  local s = raw:find('[Oo][Oo][Gg]:')
  if s then
    local colon = raw:find(':', s, true)
    e.oog = parse_oog(raw:sub(colon + 1))
    main = raw:sub(1, s - 1):gsub('|%s*$', '')   -- drop the trailing '|' before OOG:
  end

  local f = pipe_split(main)
  local name = trim(f[1] or '')
  local prefix
  for _, p in ipairs({ 'item', 'command', 'summoned' }) do
    if name:sub(1, #p + 1):lower() == p .. ':' then prefix = p; name = trim(name:sub(#p + 2)) end
  end
  e.name  = name
  e.prefix = prefix
  e.tag   = trim(f[2] or '')
  e.part3 = trim(f[3] or '')
  e.part4 = trim(f[4] or '')
  e.part5 = trim(f[5] or '')

  -- Dual + part4 subtype normalization (matches buff.setup / macro @6744).
  if e.tag == 'Dual' then
    if     e.part4 == 'MA'     then e.tag = 'DualMA'
    elseif e.part4 == 'melee'  then e.tag = 'DualMelee'
    elseif e.part4 == 'caster' then e.tag = 'DualCaster'
    elseif e.part4 == 'class'  then e.tag = 'DualClass'
    elseif e.part4 == 'mgb'    then e.tag = 'DualMgb' end
  end

  e.is_dual = e.tag:sub(1, 4) == 'Dual'
  e.check_name = (e.is_dual and e.part3 ~= '') and e.part3 or e.name
  local tl = e.tag:lower()
  -- Class list lives in part3 for the bare `class` tag, in part5 for DualClass. Derive
  -- class_list WITHOUT mutating the pipe fields so buff_to_string round-trips on disk.
  if tl:find('caster') then e.archetype = 'caster'
  elseif tl:find('melee') then e.archetype = 'melee'
  elseif tl == 'class' then e.archetype = 'class'; e.class_list = e.part3
  elseif tl == 'dualclass' then e.archetype = 'class'; e.class_list = e.part5 end
  e.mgb = tl:sub(-3) == 'mgb'
  return e
end

-- Inverse of parse_buff. Returns the raw INI value (cond is stored separately).
function serialize.buff_to_string(e)
  -- Recover the textual tag: DualX -> "Dual" with part4 carrying the subtype.
  local tag, part4 = e.tag, e.part4
  if tag == 'DualMA' then tag, part4 = 'Dual', 'MA'
  elseif tag == 'DualMelee' then tag, part4 = 'Dual', 'melee'
  elseif tag == 'DualCaster' then tag, part4 = 'Dual', 'caster'
  elseif tag == 'DualClass' then tag, part4 = 'Dual', 'class'
  elseif tag == 'DualMgb' then tag, part4 = 'Dual', 'mgb' end

  local name = (e.prefix and (e.prefix .. ':') or '') .. (e.name or '')
  local fields = { name, tag or '', e.part3 or '', part4 or '', e.part5 or '' }
  -- Drop trailing empty fields for a canonical, minimal string.
  while #fields > 1 and fields[#fields] == '' do fields[#fields] = nil end
  local out = table.concat(fields, '|')

  if e.oog then
    local toks = emit_oog(e.oog)
    if toks ~= '' then out = out .. '|OOG:' .. toks end
  end
  return out
end

-- Heal entry: name|pct|tag  (pct = args[2], tag = args[3]). cond stored separately.
function serialize.parse_heal(raw, cond)
  raw = raw or ''
  local f = pipe_split(raw)
  return {
    name = trim(f[1] or ''),
    pct  = tonumber(trim(f[2] or '')) or 0,
    tag  = trim(f[3] or ''),
    cond = cond,
    raw  = raw,
  }
end

function serialize.heal_to_string(e)
  local fields = { e.name or '', tostring(e.pct or 0), e.tag or '' }
  while #fields > 1 and fields[#fields] == '' do fields[#fields] = nil end
  return table.concat(fields, '|')
end

return serialize
