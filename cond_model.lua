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

-- Ordered subject catalog. `expr` is the literal Lua TLO fragment (matched as plain text).
cond_model.SUBJECTS = {
  { key='target_hp',   label='Target HP %',     expr='mq.TLO.Target.PctHPs()',       ops=NUM_OPS,  value='number' },
  { key='my_hp',       label='My HP %',         expr='mq.TLO.Me.PctHPs()',           ops=NUM_OPS,  value='number' },
  { key='my_mana',     label='My Mana %',       expr='mq.TLO.Me.PctMana()',          ops=NUM_OPS,  value='number' },
  { key='my_end',      label='My Endurance %',  expr='mq.TLO.Me.PctEndurance()',     ops=NUM_OPS,  value='number' },
  { key='target_dist', label='Target distance', expr='mq.TLO.Target.Distance3D()',   ops=NUM_OPS,  value='number' },
  { key='group_size',  label='Group size',      expr='mq.TLO.Group.Members()',       ops=NUM_OPS,  value='number' },
  { key='xtargets',    label='XTarget count',   expr='mq.TLO.Me.XTarget()',          ops=NUM_OPS,  value='number' },
  { key='target_named',label='Target is named', expr='mq.TLO.Target.Named()',        ops=BOOL_OPS, value='bool'   },
  { key='combat',      label='Combat state',    expr='mq.TLO.Me.CombatState()',      ops=BOOL_OPS, value='string' },
  -- buff subjects are special-cased (CachedBuff[NAME]); see parse/emit below
}

local function by_key(k)
  for _, s in ipairs(cond_model.SUBJECTS) do if s.key == k then return s end end
end

local function trim(s) return (s:gsub('^%s*(.-)%s*$', '%1')) end
local function starts_with(s, p) return s:sub(1, #p) == p end

-- Try to parse one clause "<subject-expr> <op> <value>" into a row. Returns row or nil.
local function parse_clause(c)
  c = trim(c)
  -- buff has/missing: mq.TLO.Target.CachedBuff[NAME]() <op> nil
  local name, op = c:match('^mq%.TLO%.Target%.CachedBuff%[(.-)%]%(%)%s*([~=]=)%s*nil$')
  if name then
    if op == '~=' then return { key='target_has_buff',     value=name } end
    if op == '==' then return { key='target_missing_buff', value=name } end
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
  -- Reject legacy ${...}, top-level `or`, and *grouping* parens. Note: TLO call parens
  -- are always empty '()', so strip those first; any '(' or ')' left is a grouping paren
  -- (e.g. "(x and y)") we can't model -> raw.
  local no_calls = s:gsub('%(%)', '')
  if s:find('${', 1, true) or no_calls:find('[()]') or s:find('%sor%s') then
    return { mode='raw', raw=str }
  end
  local rows = {}
  -- split on top-level " and " (no parens here, so plain split is safe)
  for clause in (s .. ' and '):gmatch('(.-)%s+and%s+') do
    local row = parse_clause(clause)
    if not row then return { mode='raw', raw=str } end
    rows[#rows + 1] = row
  end
  return { mode='rows', rows=rows }
end

local function emit_clause(row)
  if row.key == 'target_has_buff' then
    return 'mq.TLO.Target.CachedBuff[' .. (row.value or '') .. ']() ~= nil'
  elseif row.key == 'target_missing_buff' then
    return 'mq.TLO.Target.CachedBuff[' .. (row.value or '') .. ']() == nil'
  end
  local subj = by_key(row.key)
  if not subj then return nil end
  local val = row.value or ''
  if subj.value == 'string' then val = "'" .. val .. "'" end   -- quote string compares
  return subj.expr .. ' ' .. (row.op or '==') .. ' ' .. val
end

function cond_model.emit(rows)
  local parts = {}
  for _, r in ipairs(rows) do
    local c = emit_clause(r)
    if c then parts[#parts + 1] = c end
  end
  return table.concat(parts, ' and ')
end

return cond_model
