-- muleassist/cond_model.lua
-- Pure (no mq) model for the hybrid condition builder. Parses an `and`-chain of native
-- mq.TLO clauses into editable rows, and emits rows back to a Lua condition string. Anything
-- it can't model (or / parens / ${} / unknown subject) returns {mode='raw'} for the raw box.
local cond_model = {}

-- Operators are ordered longest-first so multi-char ops win during prefix matching
-- ('>=' must be tried before '>', '<=' before '<'). Without this, parse_clause would
-- match '>' on input '>= 40' and yield op='>' value='= 40'.
local NUM_OPS  = { '<=', '>=', '==', '~=', '<', '>' }
local BOOL_OPS = { '==', '~=' }

cond_model.OP_LABELS = {
  ['<'] = 'is below',
  ['>'] = 'is above',
  ['<='] = 'is at most',
  ['>='] = 'is at least',
  ['=='] = 'is',
  ['~='] = 'is not',
}

cond_model.LOGIC_LABELS = {
  and_ = 'and',
  or_ = 'or',
}

-- Ordered subject catalog. `expr` is the literal Lua TLO fragment (matched as plain text).
cond_model.SUBJECTS = {
  { key='target_hp',   label='Target HP',       expr='mq.TLO.Target.PctHPs()',       ops=NUM_OPS,  value='number' },
  { key='target_mana', label='Target mana',     expr='mq.TLO.Target.PctMana()',      ops=NUM_OPS,  value='number' },
  { key='target_id',   label='Target ID',       expr='mq.TLO.Target.ID()',           ops=NUM_OPS,  value='number' },
  { key='my_hp',       label='My HP',           expr='mq.TLO.Me.PctHPs()',           ops=NUM_OPS,  value='number' },
  { key='my_current_hp', label='My current HP', expr='mq.TLO.Me.CurrentHPs()',        ops=NUM_OPS,  value='number' },
  { key='my_mana',     label='My mana',         expr='mq.TLO.Me.PctMana()',          ops=NUM_OPS,  value='number' },
  { key='my_end',      label='My endurance',    expr='mq.TLO.Me.PctEndurance()',     ops=NUM_OPS,  value='number' },
  { key='target_dist', label='Target distance', expr='mq.TLO.Target.Distance3D()',   ops=NUM_OPS,  value='number' },
  { key='target_height', label='Target height', expr='mq.TLO.Target.Height()',       ops=NUM_OPS,  value='number' },
  { key='target_aggro',label='Target aggro',    expr='mq.TLO.Target.PctAggro()',     ops=NUM_OPS,  value='number' },
  { key='target_level',label='Target level',    expr='mq.TLO.Target.Level()',        ops=NUM_OPS,  value='number' },
  { key='target_beneficial', label='Target beneficial ID', expr='mq.TLO.Target.Beneficial.ID()', ops=NUM_OPS, value='number' },
  { key='target_aggro_holder', label='Target aggro holder ID', expr='mq.TLO.Target.AggroHolder.ID()', ops=NUM_OPS, value='number' },
  { key='target_slowed',label='Target slowed',  expr='mq.TLO.Target.Slowed.ID()',    ops=NUM_OPS,  value='number' },
  { key='target_rooted',label='Target rooted',  expr='mq.TLO.Target.Rooted.ID()',     ops=NUM_OPS,  value='number' },
  { key='target_mezzed',label='Target mezzed',  expr='mq.TLO.Target.Mezzed.ID()',     ops=NUM_OPS,  value='number' },
  { key='target_snared',label='Target snared',  expr='mq.TLO.Target.Snared.ID()',     ops=NUM_OPS,  value='number' },
  { key='target_tashed',label='Target tashed',  expr='mq.TLO.Target.Tashed.ID()',     ops=NUM_OPS,  value='number' },
  { key='target_maloed',label='Target maloed',  expr='mq.TLO.Target.Maloed.ID()',     ops=NUM_OPS,  value='number' },
  { key='group_size',  label='Group size',      expr='mq.TLO.Group.Members()',       ops=NUM_OPS,  value='number' },
  { key='raid_members', label='Raid members',   expr='mq.TLO.Raid.Members()',        ops=NUM_OPS,  value='number' },
  { key='group_injured_80', label='Group injured <80%', expr='mq.TLO.Group.Injured(80)()', ops=NUM_OPS, value='number' },
  { key='group_injured_75', label='Group injured <75%', expr='mq.TLO.Group.Injured(75)()', ops=NUM_OPS, value='number' },
  { key='group_injured_60', label='Group injured <60%', expr='mq.TLO.Group.Injured(60)()', ops=NUM_OPS, value='number' },
  { key='group_injured_50', label='Group injured <50%', expr='mq.TLO.Group.Injured(50)()', ops=NUM_OPS, value='number' },
  { key='group_low_mana_80', label='Group mana <80%', expr='mq.TLO.Group.LowMana(80)()', ops=NUM_OPS, value='number' },
  { key='group_low_mana_75', label='Group mana <75%', expr='mq.TLO.Group.LowMana(75)()', ops=NUM_OPS, value='number' },
  { key='group_low_mana_50', label='Group mana <50%', expr='mq.TLO.Group.LowMana(50)()', ops=NUM_OPS, value='number' },
  { key='xtargets',    label='XTarget count',   expr='mq.TLO.Me.XTarget()',          ops=NUM_OPS,  value='number' },
  { key='nearby_npcs_30', label='Nearby NPCs within 30', expr="mq.TLO.SpawnCount('npc radius 30 targetable')()", ops=NUM_OPS, value='number' },
  { key='nearby_npcs_50', label='Nearby NPCs within 50', expr="mq.TLO.SpawnCount('npc radius 50 targetable')()", ops=NUM_OPS, value='number' },
  { key='nearby_npcs_100', label='Nearby NPCs within 100', expr="mq.TLO.SpawnCount('npc radius 100 targetable')()", ops=NUM_OPS, value='number' },
  { key='active_disc', label='Active disc ID',   expr='mq.TLO.Me.ActiveDisc.ID()',    ops=NUM_OPS,  value='number' },
  { key='aa_points',   label='AA points',        expr='mq.TLO.Me.AAPoints()',         ops=NUM_OPS,  value='number' },
  { key='pet_id',      label='Pet exists',       expr='mq.TLO.Me.Pet.ID()',           ops=NUM_OPS,  value='number' },
  { key='pet_hp',      label='Pet HP',           expr='mq.TLO.Me.Pet.PctHPs()',       ops=NUM_OPS,  value='number' },
  { key='pet_dist',    label='Pet distance',     expr='mq.TLO.Me.Pet.Distance()',     ops=NUM_OPS,  value='number' },
  { key='pet_height',  label='Pet height',       expr='mq.TLO.Me.Pet.Height()',       ops=NUM_OPS,  value='number' },
  { key='target_named',label='Target is named', expr='mq.TLO.Target.Named()',        ops=BOOL_OPS, value='bool'   },
  { key='target_aggressive', label='Target aggressive', expr='mq.TLO.Target.Aggressive()', ops=BOOL_OPS, value='bool' },
  { key='target_buffs_populated', label='Target buffs populated', expr='mq.TLO.Target.BuffsPopulated()', ops=BOOL_OPS, value='bool' },
  { key='can_mount',   label='Can mount',        expr='mq.TLO.Me.CanMount()',         ops=BOOL_OPS, value='bool' },
  { key='me_combat',   label='Me combat',        expr='mq.TLO.Me.Combat()',           ops=BOOL_OPS, value='bool' },
  { key='target_type', label='Target type',      expr='mq.TLO.Target.Type()',         ops=BOOL_OPS, value='string' },
  { key='me_state',    label='My state',         expr='mq.TLO.Me.State()',            ops=BOOL_OPS, value='string' },
  { key='combat',      label='Combat state',    expr='mq.TLO.Me.CombatState()',      ops=BOOL_OPS, value='string' },
  -- buff/song subjects are special-cased (Buff[NAME]/Song[NAME]/CachedBuff[NAME]); see parse/emit below
}

local function by_key(k)
  for _, s in ipairs(cond_model.SUBJECTS) do if s.key == k then return s end end
end

local function trim(s) return (s:gsub('^%s*(.-)%s*$', '%1')) end
local function starts_with(s, p) return s:sub(1, #p) == p end
local function quote_arg(s) return string.format('%q', tostring(s or '')) end

local NATURAL = {
  target_hp = { subject='Target HP', suffix='%' },
  target_mana = { subject='Target mana', suffix='%' },
  target_id = { subject='Target ID' },
  my_hp = { subject='My HP', suffix='%' },
  my_current_hp = { subject='My current HP' },
  my_mana = { subject='My mana', suffix='%' },
  my_end = { subject='My endurance', suffix='%' },
  target_dist = { subject='Target distance' },
  target_height = { subject='Target height' },
  target_aggro = { subject='Target aggro', suffix='%' },
  target_level = { subject='Target level' },
  target_beneficial = { subject='Target beneficial buff ID' },
  target_aggro_holder = { subject='Target aggro holder ID' },
  group_size = { subject='Group size' },
  raid_members = { subject='Raid members' },
  xtargets = { subject='XTarget count' },
  active_disc = { subject='Active discipline ID' },
  aa_points = { subject='AA points' },
  pet_id = { subject='Pet ID' },
  pet_hp = { subject='Pet HP', suffix='%' },
  pet_dist = { subject='Pet distance' },
  pet_height = { subject='Pet height' },
  can_mount = { subject='I can mount' },
  me_combat = { subject='I am in combat' },
  target_type = { subject='Target type' },
  me_state = { subject='My state' },
  combat = { subject='My combat state' },
}

local EFFECT_FLAGS = {
  target_slowed = 'slowed',
  target_rooted = 'rooted',
  target_mezzed = 'mezzed',
  target_snared = 'snared',
  target_tashed = 'tashed',
  target_maloed = 'maloed',
  target_named = 'named',
  target_aggressive = 'aggressive',
  target_buffs_populated = 'buffs populated',
}

local GROUP_THRESHOLDS = {
  group_injured_80 = { metric='HP', threshold='80%' },
  group_injured_75 = { metric='HP', threshold='75%' },
  group_injured_60 = { metric='HP', threshold='60%' },
  group_injured_50 = { metric='HP', threshold='50%' },
  group_low_mana_80 = { metric='mana', threshold='80%' },
  group_low_mana_75 = { metric='mana', threshold='75%' },
  group_low_mana_50 = { metric='mana', threshold='50%' },
}

local SPAWN_RADIUS = {
  nearby_npcs_30 = '30',
  nearby_npcs_50 = '50',
  nearby_npcs_100 = '100',
}

cond_model.SPECIAL_KEYS = {
  target_has_buff = true,
  target_missing_buff = true,
  me_has_buff = true,
  me_missing_buff = true,
  me_has_song = true,
  me_missing_song = true,
  pet_has_buff = true,
  pet_missing_buff = true,
}

cond_model.FLAG_KEYS = {
  target_targeting_me = true,
  target_not_targeting_me = true,
}

cond_model.EFFECT_KEYS = {
  target_slowed = true,
  target_rooted = true,
  target_mezzed = true,
  target_snared = true,
  target_tashed = true,
  target_maloed = true,
  target_named = true,
  target_aggressive = true,
  target_buffs_populated = true,
  can_mount = true,
  me_combat = true,
}

cond_model.PRESETS = {
  { label='Target is NPC', rows={{ key='target_type', op='==', value='NPC' }} },
  { label='Target is named', rows={{ key='target_named', op='==', value='true' }} },
  { label='I have mana above 80%', rows={{ key='my_mana', op='>', value='80' }} },
  { label='I have mana above 50%', rows={{ key='my_mana', op='>', value='50' }} },
  { label='At least 3 group members below 80% HP', rows={{ key='group_injured_80', op='>=', value='3' }} },
  { label='Target is missing slow', rows={{ key='target_slowed', op='==', value='0' }} },
  { label='Target is missing tash', rows={{ key='target_tashed', op='==', value='0' }} },
  { label='Target is missing malo', rows={{ key='target_maloed', op='==', value='0' }} },
  { label='Target is not targeting me', rows={{ key='target_not_targeting_me' }} },
  { label='Pet needs help below 50%', rows={{ key='pet_id', op='>', value='0' }, { key='pet_hp', op='<', value='50' }} },
}

local function value_text(row, suffix)
  local v = tostring(row.value or '')
  if suffix and v ~= '' then return v .. suffix end
  return v
end

local function effect_state(row)
  local value = tonumber(row.value)
  if row.op == '==' and value == 0 then return false end
  if row.op == '==' and value and value ~= 0 then return true end
  if (row.op == '~=' and value == 0) or (row.op == '>' and value == 0) then return true end
  if row.op == '==' and tostring(row.value) == 'true' then return true end
  if row.op == '==' and tostring(row.value) == 'false' then return false end
  return nil
end

local function count_phrase(op, value)
  local v = tostring(value or '')
  if op == '>=' then return 'At least ' .. v end
  if op == '>' then return 'More than ' .. v end
  if op == '<=' then return 'At most ' .. v end
  if op == '<' then return 'Fewer than ' .. v end
  if op == '==' then return v end
  if op == '~=' then return 'Not ' .. v end
  return cond_model.operator_label(op) .. ' ' .. v
end

local function numeric_expr(token)
  local maps = {
    ['Me.PctMana'] = 'mq.TLO.Me.PctMana()',
    ['Me.ManaPct'] = 'mq.TLO.Me.PctMana()',
    ['Me.PctHPs'] = 'mq.TLO.Me.PctHPs()',
    ['Me.CurrentHPs'] = 'mq.TLO.Me.CurrentHPs()',
    ['Target.PctHPs'] = 'mq.TLO.Target.PctHPs()',
    ['Target.PctMana'] = 'mq.TLO.Target.PctMana()',
    ['Target.PctAggro'] = 'mq.TLO.Target.PctAggro()',
    ['Target.Level'] = 'mq.TLO.Target.Level()',
    ['Target.Distance'] = 'mq.TLO.Target.Distance3D()',
    ['Target.ID'] = 'mq.TLO.Target.ID()',
    ['Me.Pet.ID'] = 'mq.TLO.Me.Pet.ID()',
    ['Target.Beneficial.ID'] = 'mq.TLO.Target.Beneficial.ID()',
    ['Target.Slowed.ID'] = 'mq.TLO.Target.Slowed.ID()',
    ['Target.Rooted.ID'] = 'mq.TLO.Target.Rooted.ID()',
    ['Target.Mezzed.ID'] = 'mq.TLO.Target.Mezzed.ID()',
    ['Target.Snared.ID'] = 'mq.TLO.Target.Snared.ID()',
    ['Target.Tashed.ID'] = 'mq.TLO.Target.Tashed.ID()',
    ['Target.Maloed.ID'] = 'mq.TLO.Target.Maloed.ID()',
    ['Me.XTarget'] = 'mq.TLO.Me.XTarget()',
  }
  if maps[token] then return maps[token] end
  local injured = token:match('^Group%.Injured%[(%d+)%]$')
  if injured then return 'mq.TLO.Group.Injured(' .. injured .. ')()' end
  local low_mana = token:match('^Group%.LowMana%[(%d+)%]$')
  if low_mana then return 'mq.TLO.Group.LowMana(' .. low_mana .. ')()' end
  return nil
end

local function legacy_bool_expr(token, negated)
  local eq_name = token:match('^Target%.Type%.Equal%[(.-)%]$')
  if eq_name then
    local op = negated and '~=' or '=='
    return 'mq.TLO.Target.Type() ' .. op .. ' ' .. quote_arg(eq_name)
  end
  eq_name = token:match('^Me%.State%.Equal%[(.-)%]$')
  if eq_name then
    local op = negated and '~=' or '=='
    return 'mq.TLO.Me.State() ' .. op .. ' ' .. quote_arg(eq_name)
  end
  eq_name = token:match('^Me%.CombatState%.Equal%[(.-)%]$')
  if eq_name then
    local op = negated and '~=' or '=='
    return 'mq.TLO.Me.CombatState() ' .. op .. ' ' .. quote_arg(eq_name)
  end
  if token == 'Me.Combat' then
    return 'mq.TLO.Me.Combat() == ' .. (negated and 'false' or 'true')
  end
  if token == 'Target.Named' then
    return 'mq.TLO.Target.Named() == ' .. (negated and 'false' or 'true')
  end
  local buff = token:match('^Me%.Buff%[(.-)%]%.ID$')
  if buff then
    return 'mq.TLO.Me.Buff(' .. quote_arg(buff) .. ')() ' .. (negated and '==' or '~=') .. ' nil'
  end
  local pet_buff = token:match('^Me%.Pet%.Buff%[(.-)%]$')
  if pet_buff then
    return 'mq.TLO.Me.PetBuff(' .. quote_arg(pet_buff) .. ')() ' .. (negated and '==' or '~=') .. ' nil'
  end
  if token == 'Me.TargetOfTarget.Name.Equal[${Me}]'
      or token == 'Me.TargetOfTarget.CleanName.Equal[${Me}]' then
    return 'mq.TLO.Me.TargetOfTarget.ID() ' .. (negated and '~=' or '==') .. ' mq.TLO.Me.ID()'
  end
  if token == 'Me.TargetOfTarget.Name.NotEqual[${Me}]'
      or token == 'Me.TargetOfTarget.CleanName.NotEqual[${Me}]' then
    return 'mq.TLO.Me.TargetOfTarget.ID() ' .. (negated and '==' or '~=') .. ' mq.TLO.Me.ID()'
  end
  local expr = numeric_expr(token)
  if expr then return expr .. (negated and ' == 0' or ' > 0') end
  return nil
end

local function convert_legacy(str)
  local s = tostring(str or '')
  s = s:gsub('%s*&&%s*', ' and ')
  s = s:gsub('%s*||%s*', ' or ')
  s = s:gsub('%${Me%.TargetOfTarget%.Name%.Equal%[%${Me}%]}', 'mq.TLO.Me.TargetOfTarget.ID() == mq.TLO.Me.ID()')
  s = s:gsub('%${Me%.TargetOfTarget%.CleanName%.Equal%[%${Me}%]}', 'mq.TLO.Me.TargetOfTarget.ID() == mq.TLO.Me.ID()')
  s = s:gsub('%${Me%.TargetOfTarget%.Name%.NotEqual%[%${Me}%]}', 'mq.TLO.Me.TargetOfTarget.ID() ~= mq.TLO.Me.ID()')
  s = s:gsub('%${Me%.TargetOfTarget%.CleanName%.NotEqual%[%${Me}%]}', 'mq.TLO.Me.TargetOfTarget.ID() ~= mq.TLO.Me.ID()')

  s = s:gsub('!%${([^}]+)}', function(token)
    return legacy_bool_expr(token, true) or ('!${' .. token .. '}')
  end)

  s = s:gsub('%${([^}]+)}%s*([<>~=]=)%s*([%w%._%-]+)', function(token, op, value)
    local expr = numeric_expr(token)
    if expr then return expr .. ' ' .. op .. ' ' .. value end
    return '${' .. token .. '} ' .. op .. ' ' .. value
  end)

  s = s:gsub('%${([^}]+)}%s*([<>])%s*([%w%._%-]+)', function(token, op, value)
    local expr = numeric_expr(token)
    if expr then return expr .. ' ' .. op .. ' ' .. value end
    return '${' .. token .. '} ' .. op .. ' ' .. value
  end)

  s = s:gsub('%${([^}]+)}', function(token)
    local bool_expr = legacy_bool_expr(token, false)
    if bool_expr then return bool_expr end
    local expr = numeric_expr(token)
    if expr then return expr end
    return '${' .. token .. '}'
  end)

  if s:find('${', 1, true) or s:find('!', 1, true) then return nil end
  return s
end

local function split_clauses(s)
  local clauses, logic = {}, {}
  local pos = 1
  while pos <= #s do
    local a1, b1 = s:find('%s+and%s+', pos)
    local a2, b2 = s:find('%s+or%s+', pos)
    local a, b, op
    if a1 and (not a2 or a1 < a2) then
      a, b, op = a1, b1, 'and'
    elseif a2 then
      a, b, op = a2, b2, 'or'
    end
    if not a then
      clauses[#clauses + 1] = trim(s:sub(pos))
      break
    end
    clauses[#clauses + 1] = trim(s:sub(pos, a - 1))
    logic[#clauses] = op
    pos = b + 1
  end
  return clauses, logic
end

-- Try to parse one clause "<subject-expr> <op> <value>" into a row. Returns row or nil.
local function parse_clause(c)
  c = trim(c)
  -- buff has/missing: mq.TLO.Target.CachedBuff[NAME]() <op> nil
  local name, op = c:match('^mq%.TLO%.Target%.CachedBuff%[(.-)%]%(%)%s*([~=]=)%s*nil$')
  if not name then
    name, op = c:match('^mq%.TLO%.Target%.CachedBuff%([\"\'](.-)[\"\']%)%(%)%s*([~=]=)%s*nil$')
  end
  if name then
    if op == '~=' then return { key='target_has_buff',     value=name } end
    if op == '==' then return { key='target_missing_buff', value=name } end
  end
  name, op = c:match('^mq%.TLO%.Me%.Buff%[(.-)%]%(%)%s*([~=]=)%s*nil$')
  if not name then
    name, op = c:match('^mq%.TLO%.Me%.Buff%([\"\'](.-)[\"\']%)%(%)%s*([~=]=)%s*nil$')
  end
  if name then
    if op == '~=' then return { key='me_has_buff',     value=name } end
    if op == '==' then return { key='me_missing_buff', value=name } end
  end
  name, op = c:match('^mq%.TLO%.Me%.Song%[(.-)%]%(%)%s*([~=]=)%s*nil$')
  if not name then
    name, op = c:match('^mq%.TLO%.Me%.Song%([\"\'](.-)[\"\']%)%(%)%s*([~=]=)%s*nil$')
  end
  if name then
    if op == '~=' then return { key='me_has_song',     value=name } end
    if op == '==' then return { key='me_missing_song', value=name } end
  end
  name, op = c:match('^mq%.TLO%.Me%.PetBuff%[(.-)%]%(%)%s*([~=]=)%s*nil$')
  if not name then
    name, op = c:match('^mq%.TLO%.Me%.PetBuff%([\"\'](.-)[\"\']%)%(%)%s*([~=]=)%s*nil$')
  end
  if name then
    if op == '~=' then return { key='pet_has_buff',     value=name } end
    if op == '==' then return { key='pet_missing_buff', value=name } end
  end
  op = c:match('^mq%.TLO%.Me%.TargetOfTarget%.ID%(%)%s*([~=]=)%s*mq%.TLO%.Me%.ID%(%)$')
  if op then
    if op == '==' then return { key='target_targeting_me' } end
    if op == '~=' then return { key='target_not_targeting_me' } end
  end
  -- catalog subjects: literal-prefix match on expr (exprs contain ()/[] -> not patterns)
  for _, subj in ipairs(cond_model.SUBJECTS) do
    if starts_with(c, subj.expr) then
      local rest = trim(c:sub(#subj.expr + 1))
      for _, o in ipairs(subj.ops) do
        if starts_with(rest, o) then
          local val = trim(rest:sub(#o + 1))
          -- string values may be quoted: == 'COMBAT'
          local sq = val:match("^'(.*)'$") or val:match('^"(.*)"$')
          return { key=subj.key, op=o, value = sq or val }
        end
      end
    end
  end
  return nil
end

function cond_model.parse(str)
  local s = trim(str or '')
  if s == '' then return { mode='rows', rows={} } end
  if s:find('${', 1, true) then
    local converted = convert_legacy(s)
    if not converted then return { mode='raw', raw=str } end
    s = converted
  end
  -- Reject unresolved legacy ${...} and *grouping* parens. Note: TLO call parens
  -- are always empty '()', so strip those first; any '(' or ')' left is a grouping paren
  -- (e.g. "(x and y)") we can't model -> raw.
  local no_calls = s
    :gsub('%.Injured%(%d+%)%(%)', '.Injured')
    :gsub('%.LowMana%(%d+%)%(%)', '.LowMana')
    :gsub('%.SpawnCount%([\"\'].-[\"\']%)%(%)', '.SpawnCount')
    :gsub('%.CachedBuff%([\"\'].-[\"\']%)%(%)', '.CachedBuff')
    :gsub('%.Buff%([\"\'].-[\"\']%)%(%)', '.Buff')
    :gsub('%.Song%([\"\'].-[\"\']%)%(%)', '.Song')
    :gsub('%.PetBuff%([\"\'].-[\"\']%)%(%)', '.PetBuff')
    :gsub('%(%)', '')
  if s:find('${', 1, true) or no_calls:find('[()]') then
    return { mode='raw', raw=str }
  end
  local rows = {}
  local clauses, logic = split_clauses(s)
  for _, clause in ipairs(clauses) do
    local row = parse_clause(clause)
    if not row then return { mode='raw', raw=str } end
    rows[#rows + 1] = row
  end
  return { mode='rows', rows=rows, logic=logic, normalized=s }
end

local function emit_clause(row)
  if row.key == 'target_has_buff' then
    return 'mq.TLO.Target.CachedBuff(' .. quote_arg(row.value) .. ')() ~= nil'
  elseif row.key == 'target_missing_buff' then
    return 'mq.TLO.Target.CachedBuff(' .. quote_arg(row.value) .. ')() == nil'
  elseif row.key == 'me_has_buff' then
    return 'mq.TLO.Me.Buff(' .. quote_arg(row.value) .. ')() ~= nil'
  elseif row.key == 'me_missing_buff' then
    return 'mq.TLO.Me.Buff(' .. quote_arg(row.value) .. ')() == nil'
  elseif row.key == 'me_has_song' then
    return 'mq.TLO.Me.Song(' .. quote_arg(row.value) .. ')() ~= nil'
  elseif row.key == 'me_missing_song' then
    return 'mq.TLO.Me.Song(' .. quote_arg(row.value) .. ')() == nil'
  elseif row.key == 'pet_has_buff' then
    return 'mq.TLO.Me.PetBuff(' .. quote_arg(row.value) .. ')() ~= nil'
  elseif row.key == 'pet_missing_buff' then
    return 'mq.TLO.Me.PetBuff(' .. quote_arg(row.value) .. ')() == nil'
  elseif row.key == 'target_targeting_me' then
    return 'mq.TLO.Me.TargetOfTarget.ID() == mq.TLO.Me.ID()'
  elseif row.key == 'target_not_targeting_me' then
    return 'mq.TLO.Me.TargetOfTarget.ID() ~= mq.TLO.Me.ID()'
  end
  local subj = by_key(row.key)
  if not subj then return nil end
  local val = row.value or ''
  if subj.value == 'string' then val = quote_arg(val) end
  return subj.expr .. ' ' .. (row.op or '==') .. ' ' .. val
end

function cond_model.emit(rows, logic)
  local parts = {}
  for i, r in ipairs(rows or {}) do
    local c = emit_clause(r)
    if c then
      if #parts > 0 then parts[#parts + 1] = (logic and logic[i - 1]) or 'and' end
      parts[#parts + 1] = c
    end
  end
  return table.concat(parts, ' ')
end

function cond_model.operator_label(op)
  return cond_model.OP_LABELS[op] or tostring(op or 'is')
end

function cond_model.subject_label(key)
  local subj = by_key(key)
  return (subj and subj.label) or key
end

function cond_model.is_special_key(key) return cond_model.SPECIAL_KEYS[key] == true end
function cond_model.is_flag_key(key) return cond_model.FLAG_KEYS[key] == true end
function cond_model.is_effect_key(key) return cond_model.EFFECT_KEYS[key] == true end

function cond_model.effect_state(row)
  return effect_state(row)
end

function cond_model.set_effect_state(row, present)
  if not row then return end
  if row.value == 'true' or row.value == 'false' then
    row.op = '=='
    row.value = present and 'true' or 'false'
  else
    row.op = '=='
    row.value = present and '1' or '0'
  end
end

function cond_model.default_row()
  return { key='target_hp', op='<', value='100' }
end

function cond_model.default_row_for_key(key)
  if cond_model.SPECIAL_KEYS[key] then return { key=key, value='' } end
  if cond_model.FLAG_KEYS[key] then return { key=key } end
  if cond_model.EFFECT_KEYS[key] then
    local present = key == 'target_named' or key == 'target_aggressive'
        or key == 'target_buffs_populated' or key == 'can_mount' or key == 'me_combat'
    local value = present and '1' or '0'
    if key == 'target_named' or key == 'target_aggressive'
        or key == 'target_buffs_populated' or key == 'can_mount' or key == 'me_combat' then
      value = present and 'true' or 'false'
    end
    return { key=key, op='==', value=value }
  end
  local subj = by_key(key)
  if subj then return { key=key, op=subj.ops[1], value=subj.value == 'string' and '' or '0' } end
  return { key=key }
end

local function clone_rows(rows)
  local out = {}
  for i, r in ipairs(rows or {}) do
    out[i] = { key=r.key, op=r.op, value=r.value }
  end
  return out
end

local function clone_list(items)
  local out = {}
  for i, item in ipairs(items or {}) do out[i] = item end
  return out
end

function cond_model.preset_rows(index)
  local preset = cond_model.PRESETS[index]
  if not preset then return nil end
  return clone_rows(preset.rows), clone_list(preset.logic)
end

function cond_model.describe_row(row)
  if not row then return '' end
  local key = row.key

  if key == 'target_has_buff' then
    return 'Target has ' .. tostring(row.value or '')
  elseif key == 'target_missing_buff' then
    return 'Target is missing ' .. tostring(row.value or '')
  elseif key == 'me_has_buff' then
    return 'I have ' .. tostring(row.value or '')
  elseif key == 'me_missing_buff' then
    return 'I am missing ' .. tostring(row.value or '')
  elseif key == 'me_has_song' then
    return 'I have song ' .. tostring(row.value or '')
  elseif key == 'me_missing_song' then
    return 'I am missing song ' .. tostring(row.value or '')
  elseif key == 'pet_has_buff' then
    return 'Pet has ' .. tostring(row.value or '')
  elseif key == 'pet_missing_buff' then
    return 'Pet is missing ' .. tostring(row.value or '')
  elseif key == 'target_targeting_me' then
    return 'Target is targeting me'
  elseif key == 'target_not_targeting_me' then
    return 'Target is not targeting me'
  end

  local group = GROUP_THRESHOLDS[key]
  if group then
    return string.format('%s group members are below %s %s',
      count_phrase(row.op, row.value), group.threshold, group.metric)
  end

  local radius = SPAWN_RADIUS[key]
  if radius then
    return string.format('%s NPCs are within %s', count_phrase(row.op, row.value), radius)
  end

  local effect = EFFECT_FLAGS[key]
  if effect then
    local state = effect_state(row)
    if state == true then return 'Target is ' .. effect end
    if state == false then return 'Target is not ' .. effect end
  end

  local natural = NATURAL[key]
  if natural then
    if natural.subject == 'I am in combat' and row.op == '==' then
      return row.value == 'true' and 'I am in combat' or 'I am not in combat'
    end
    if natural.subject == 'I can mount' and row.op == '==' then
      return row.value == 'true' and 'I can mount' or 'I cannot mount'
    end
    if key == 'target_type' and row.op == '==' then
      return 'Target is ' .. tostring(row.value or '')
    end
    return natural.subject .. ' ' .. cond_model.operator_label(row.op) .. ' ' .. value_text(row, natural.suffix)
  end

  return cond_model.subject_label(key) .. ' ' .. cond_model.operator_label(row.op) .. ' ' .. value_text(row)
end

function cond_model.describe(rows, logic)
  local parts = {}
  for i, row in ipairs(rows or {}) do
    local text = cond_model.describe_row(row)
    if text ~= '' then
      if #parts > 0 then parts[#parts + 1] = cond_model.LOGIC_LABELS[((logic and logic[i - 1]) or 'and') .. '_'] or 'and' end
      parts[#parts + 1] = text
    end
  end
  if #parts == 0 then return 'Always' end
  return table.concat(parts, ' ')
end

return cond_model
