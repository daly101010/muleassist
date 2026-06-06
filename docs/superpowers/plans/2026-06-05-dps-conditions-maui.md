# DPS Editor + Native Conditions + Condition Builder — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Native `mq.TLO` Lua conditions (dual-mode), a shared hybrid condition builder, the DebuffAll feature in combat, a DPS serializer, and a structured DPS editor in MAUI.

**Architecture:** `cond.eval` gains a native Lua path (sandboxed, cached `load`) beside the legacy `${}` path. `cond_model.lua` (pure) parses/emits `and`-chains for a builder widget. `serialize.parse_dps`/`dps_to_string` become the single source of truth for the DPS grammar; `combat.lua` consumes them and gains DebuffAll. UI adds `DrawStructuredDPS` + `DrawConditionBuilder`.

**Tech Stack:** Lua 5.1 / LuaJIT, MacroQuest `mq`, Dear ImGui (MQ binding), existing `muleassist` modules.

**Spec:** `docs/superpowers/specs/2026-06-05-dps-conditions-maui-design.md`

**Test note:** No offline Lua runtime — tests run in-game via `/lua run muleassist/tests/run`. "Run the test" = run that in-game and read the printed result. `cond_model.lua` and `serialize.lua` are pure (no `mq`); `cond.lua` native eval needs a live client.

---

## File Structure

- **Modify** `cond.lua` — add native dual-mode `eval` + compiled-chunk cache + sandbox ENV.
- **Create** `cond_model.lua` — pure subject catalog + `parse`/`emit` for builder rows.
- **Modify** `serialize.lua` — add `parse_dps`/`dps_to_string`.
- **Modify** `combat.lua` — consume `serialize.parse_dps`; add DebuffAll (`debuff_all` bucket + `debuff_all_tick`).
- **Modify** `state.lua` — `st.combat.debuff_all`, `st.combat.debuff_all_on`.
- **Modify** `init.lua` — call `combat.debuff_all_tick` in the combat slot.
- **Modify** `ui/init.lua` — `DrawConditionBuilder`, `DrawStructuredDPS`, wire both in.
- **Create/Modify tests** — `test_cond` (extend), `test_cond_model` (new), `test_serialize` (extend), `test_combat` (extend); register `test_cond_model` in `run.lua`.

---

## Task 1: cond.lua native dual-mode eval

**Files:**
- Modify: `cond.lua`
- Test: `tests/test_cond.lua`

- [ ] **Step 1: Add native-eval tests to `tests/test_cond.lua`**

Insert before `print('test_cond: PASS')`:

```lua
  -- Native mq.TLO Lua conditions (no ${} -> Lua path)
  assert(cond.eval('1 < 2') == true, 'native 1<2 true')
  assert(cond.eval('2 < 1') == false, 'native 2<1 false')
  assert(cond.eval('mq.TLO.Me.Level() > 0') == true, 'native Me.Level()>0 true')
  assert(cond.eval('mq.TLO.Me.PctMana() >= 0 and mq.TLO.Me.PctHPs() >= 0') == true,
    'native and-chain true')
  -- Malformed Lua must fail safe (false, no throw)
  assert(cond.eval('this is not lua ((') == false, 'malformed native -> false')
  -- Legacy ${} still works
  assert(cond.eval('${Me.Level} > 0') == true, 'legacy ${} still evaluates')
  -- Cache: second eval of the same native string reuses the compiled chunk
  assert(cond.eval('3 < 4') == true and cond.eval('3 < 4') == true, 'cached native re-eval')
```

- [ ] **Step 2: Run tests; expect failure** — `/lua run muleassist/tests/run` → `test_cond` FAIL (native `mq.TLO...` currently goes through `${If[...]}` and won't parse as MQ).

- [ ] **Step 3: Rewrite `cond.lua`**

```lua
-- muleassist/cond.lua
-- Evaluate condition strings against the live client. DUAL-MODE:
--   * strings containing "${" use the legacy MQ parser (mq.parse '${If[...]}')
--   * everything else is a native Lua expression evaluated with mq in scope
--     (e.g. "mq.TLO.Target.PctHPs() < 70 and mq.TLO.Me.PctMana() >= 40")
-- Native chunks are compiled once and cached (conditions evaluate every tick).
local mq    = require('mq')
local Write = require('muleassist.Write')
local cond  = {}

-- mq.parse a string containing ${...} tokens, returning the expanded string.
function cond.expand(str)
  if not str or str == '' then return '' end
  return mq.parse(str)
end

-- Sandbox for native conditions: pure reads only (no os/io/load/_G).
local ENV = {
  mq = mq, math = math, string = string,
  tonumber = tonumber, tostring = tostring, ipairs = ipairs, pairs = pairs,
}

local chunk_cache = {}    -- [exprString] = compiled function | false (compile failed)
local logged_err  = {}    -- dedupe error spam by string

local function native_eval(s)
  local fn = chunk_cache[s]
  if fn == nil then
    local compiled, err = load('return (' .. s .. ')', '@cond', 't', ENV)
    if not compiled then
      chunk_cache[s] = false
      if not logged_err[s] then Write.Error('cond compile failed: %s (%s)', s, tostring(err)); logged_err[s] = true end
      return false
    end
    chunk_cache[s] = compiled
    fn = compiled
  elseif fn == false then
    return false
  end
  local ok, res = pcall(fn)
  if not ok then
    if not logged_err[s] then Write.Error('cond runtime error: %s (%s)', s, tostring(res)); logged_err[s] = true end
    return false
  end
  return not not res
end

-- Evaluate a boolean condition string. Empty/NULL/TRUE => true; FALSE => false.
function cond.eval(str)
  if not str then return true end
  local s = str:gsub('^%s*(.-)%s*$', '%1')
  if s == '' then return true end
  local up = s:upper()
  if up == 'TRUE' or up == 'NULL' then return true end
  if up == 'FALSE' then return false end
  if s:find('${', 1, true) then
    return mq.parse('${If[' .. s .. ',1,0]}') == '1'   -- legacy path
  end
  return native_eval(s)                                  -- native Lua path
end

return cond
```

- [ ] **Step 4: Run tests; expect pass** — `test_cond: PASS`, `ALL TESTS PASS`.

- [ ] **Step 5: Commit**

```bash
git add cond.lua tests/test_cond.lua
git commit -m "feat(cond): native mq.TLO Lua conditions (dual-mode, cached, sandboxed)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 2: cond_model.lua (pure parse/emit + subject catalog)

**Files:**
- Create: `cond_model.lua`
- Create: `tests/test_cond_model.lua`
- Modify: `tests/run.lua`

- [ ] **Step 1: Create `tests/test_cond_model.lua`**

```lua
-- muleassist/tests/test_cond_model.lua  (pure; no mq)
local cm = require('muleassist.cond_model')

local t = {}
function t.run()
  -- and-chain of known subjects -> rows
  local p = cm.parse('mq.TLO.Target.PctHPs() < 70 and mq.TLO.Me.PctMana() >= 40')
  assert(p.mode == 'rows', 'and-chain parses to rows')
  assert(#p.rows == 2, 'two rows')
  assert(p.rows[1].key == 'target_hp' and p.rows[1].op == '<' and p.rows[1].value == '70',
    'row1 target_hp < 70')
  assert(p.rows[2].key == 'my_mana' and p.rows[2].op == '>=' and p.rows[2].value == '40',
    'row2 my_mana >= 40')

  -- buff has/missing
  local b = cm.parse('mq.TLO.Target.CachedBuff[Slow]() ~= nil')
  assert(b.mode == 'rows' and b.rows[1].key == 'target_has_buff' and b.rows[1].value == 'Slow',
    'has-buff row')
  local m = cm.parse('mq.TLO.Target.CachedBuff[Snare]() == nil')
  assert(m.rows[1].key == 'target_missing_buff' and m.rows[1].value == 'Snare', 'missing-buff row')

  -- or / parens / ${} / unknown -> raw
  assert(cm.parse('a or b').mode == 'raw', 'or -> raw')
  assert(cm.parse('(x and y)').mode == 'raw', 'parens -> raw')
  assert(cm.parse('${Me.Level} > 0').mode == 'raw', 'legacy ${} -> raw')
  assert(cm.parse('mq.TLO.Foo.Bar() < 5').mode == 'raw', 'unknown subject -> raw')

  -- emit round-trips
  local rows = { { key='target_hp', op='<', value='70' }, { key='my_mana', op='>=', value='40' } }
  local s = cm.emit(rows)
  assert(s == 'mq.TLO.Target.PctHPs() < 70 and mq.TLO.Me.PctMana() >= 40', 'emit format: '..s)
  local rp = cm.parse(s)
  assert(rp.mode == 'rows' and #rp.rows == 2 and rp.rows[1].key == 'target_hp', 'emit/parse round-trip')

  -- empty
  assert(cm.parse('').mode == 'rows' and #cm.parse('').rows == 0, 'empty -> zero rows')

  print('test_cond_model: PASS')
  return true
end
return t
```

- [ ] **Step 2: Register in `tests/run.lua`** — add `'muleassist.tests.test_cond_model',` to the `mods` list.

- [ ] **Step 3: Run tests; expect failure** — `LOAD FAIL ... module 'muleassist.cond_model' not found`.

- [ ] **Step 4: Create `cond_model.lua`**

```lua
-- muleassist/cond_model.lua
-- Pure (no mq) model for the hybrid condition builder. Parses an `and`-chain of native
-- mq.TLO clauses into editable rows, and emits rows back to a Lua condition string. Anything
-- it can't model (or / parens / ${} / unknown subject) returns {mode='raw'} for the raw box.
local cond_model = {}

local NUM_OPS  = { '<', '<=', '>', '>=', '==', '~=' }
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
  if s:find('${', 1, true) or s:find('[()]') or s:find('%sor%s') then
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
```

- [ ] **Step 5: Run tests; expect pass** — `test_cond_model: PASS`.

- [ ] **Step 6: Commit**

```bash
git add cond_model.lua tests/test_cond_model.lua tests/run.lua
git commit -m "feat(cond_model): pure parse/emit + subject catalog for condition builder

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 3: serialize.parse_dps / dps_to_string

**Files:**
- Modify: `serialize.lua`
- Test: `tests/test_serialize.lua`

- [ ] **Step 1: Add DPS round-trip tests to `tests/test_serialize.lua`**

Insert before the suite's `print(... PASS)`:

```lua
  -- DPS grammar
  local d1 = serialize.parse_dps('Ice Comet|95', nil)
  assert(d1.spell == 'Ice Comet' and d1.part2 == 95 and d1.target == 'Mob'
    and d1.persistent == false and d1.once == false and d1.if_tag == nil, 'plain DD')
  assert(d1.hp_pct == 95 and d1.is_debuff == false, 'legacy aliases on plain DD')

  local d2 = serialize.parse_dps('Fierce Eye|100|Me', nil)
  assert(d2.target == 'Me', 'self target')

  local d3 = serialize.parse_dps('Malo|101|debuffall', nil)
  assert(d3.target == 'debuffall' and d3.persistent == true and d3.is_debuff == true, 'debuffall + persistent')

  -- arg-shift: keyword in arg3
  local d4 = serialize.parse_dps('Cripple|95|notif|Cripple', nil)
  assert(d4.if_tag == 'notif' and d4.if_spell == 'Cripple' and d4.target == 'Mob', 'arg-shift notif')
  assert(d4.cond_tag == 'notif' and d4.cond_spell == 'Cripple', 'legacy cond_tag/cond_spell aliases')

  -- non-shift: target then keyword
  local d5 = serialize.parse_dps('Spell|95|MA|if|Slow', nil)
  assert(d5.target == 'MA' and d5.if_tag == 'if' and d5.if_spell == 'Slow', 'target + if')

  -- once
  local d6 = serialize.parse_dps('Disc|95|once', nil)
  assert(d6.once == true, 'once substring')

  -- round-trip
  for _, raw in ipairs({ 'Ice Comet|95', 'Fierce Eye|100|Me', 'Malo|101|debuffall',
                         'Spell|95|MA|if|Slow' }) do
    local e = serialize.parse_dps(raw, nil)
    local out = serialize.dps_to_string(e)
    local e2 = serialize.parse_dps(out, nil)
    assert(e2.spell == e.spell and e2.part2 == e.part2 and e2.target == e.target
      and e2.if_tag == e.if_tag and e2.if_spell == e.if_spell,
      'dps round-trip for '..raw..' -> '..out)
  end
```

- [ ] **Step 2: Run tests; expect failure** — `attempt to call field 'parse_dps' (a nil value)`.

- [ ] **Step 3: Add to `serialize.lua`** (before the final `return serialize`)

```lua
-- DPS entry: spell | part2 | part3 | part4 | part5  (CombatCast @3167-3185).
-- part2: 1-100 mob-HP% gate; >=101 persistent (no timer reset on switch).
-- part3: target (Me/Feign/MA/debuffall) or, if it is an if/notif keyword, the arg-shift form.
-- part4/part5: if|notif|ifme|notifme + spell.  "once" substring on part3 => cast-once.
local DPS_KEYWORDS = { ['if']=true, ['notif']=true, ['ifme']=true, ['notifme']=true }

function serialize.parse_dps(raw, cond)
  local a = split_args(raw or '')         -- pipe split (same helper buffs/heals use)
  local spell = trim(a[1] or '')
  local part2 = tonumber(trim(a[2] or '')) or 0
  local target, if_tag, if_spell
  local a3 = trim(a[3] or '')
  if DPS_KEYWORDS[a3] then
    if_tag, if_spell, target = a3, trim(a[4] or ''), (trim(a[5] or '') ~= '' and trim(a[5])) or 'Mob'
  else
    target  = (a3 ~= '' and a3) or 'Mob'
    if_tag  = (DPS_KEYWORDS[trim(a[4] or '')] and trim(a[4])) or nil
    if_spell= if_tag and trim(a[5] or '') or nil
  end
  local once = a3:lower():find('once', 1, true) ~= nil
  local persistent = part2 >= 101
  return {
    spell = spell, part2 = part2, persistent = persistent, target = target,
    once = once, if_tag = if_tag, if_spell = if_spell, cond = cond, raw = raw, index = nil,
    -- legacy aliases consumed by combat.lua (don't remove)
    hp_pct = part2, is_debuff = persistent, cond_tag = if_tag, cond_spell = if_spell,
  }
end

-- Inverse. Canonical (non-shifted) order: spell|part2|target|if_tag|if_spell. Drops trailing empties.
function serialize.dps_to_string(e)
  local fields = { e.spell or '', tostring(e.part2 or 0), e.target or 'Mob',
                   e.if_tag or '', e.if_spell or '' }
  while #fields > 2 and (fields[#fields] == '' or fields[#fields] == 'Mob') do
    if fields[#fields] == 'Mob' and #fields ~= 3 then break end   -- keep target slot if tags follow
    fields[#fields] = nil
  end
  return table.concat(fields, '|')
end
```

(If `split_args`/`trim` are file-locals not in scope where you insert, place the additions in the same scope as `parse_heal`/`heal_to_string`, which use them.)

- [ ] **Step 4: Run tests; expect pass** — `test_serialize: PASS`.

- [ ] **Step 5: Commit**

```bash
git add serialize.lua tests/test_serialize.lua
git commit -m "feat(serialize): parse_dps/dps_to_string with arg-shift + legacy aliases

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 4: combat.lua consumes serialize.parse_dps + DebuffAll

**Files:**
- Modify: `state.lua`, `combat.lua`, `init.lua`
- Test: `tests/test_combat.lua`, `tests/test_state.lua`

- [ ] **Step 1: Add runtime fields in `state.lua`**

In `apply_config`'s `st.combat` block add:
```lua
  c.debuff_all_on = cfg:num('DPS', 'DebuffAllOn', 0)
```
In `state.new`'s combat runtime block add `c.debuff_all = {}` next to `c.debuffs = {}`.

- [ ] **Step 2: Add combat assertions to `tests/test_combat.lua`**

Where the fixture DPS list is set up, add a `debuffall` entry and assert bucketing. Append before that suite's PASS print:
```lua
  -- debuffall entries are bucketed separately from single-target dps/debuffs
  local seen_da = false
  for _, e in ipairs(st.combat.debuff_all or {}) do if e.target == 'debuffall' then seen_da = true end end
  assert(type(st.combat.debuff_all) == 'table', 'combat.debuff_all is a table')
  -- (seen_da depends on fixture having a debuffall entry; see Step 3 fixture note)
```
And in `tests/test_state.lua` after the combat asserts add:
```lua
  assert(type(st.combat.debuff_all) == 'table', 'combat.debuff_all runtime table')
  assert(st.combat.debuff_all_on == 0, 'DebuffAllOn default 0')
```

- [ ] **Step 3: Refactor `combat.setup` (in `combat.lua`)**

Delete the private `local function parse_dps(e) ... end` (lines ~39-56). Add `local serialize = require('muleassist.serialize')` to the requires. Replace the DPS-loop in `combat.setup`:
```lua
  local dps, debuffs, debuff_all = {}, {}, {}
  for _, e in ipairs(st.lists.dps) do
    local entry = serialize.parse_dps(e.raw, e.cond)
    entry.index = e.index
    if entry.spell ~= '' and entry.spell:lower() ~= 'null' then
      if entry.target == 'debuffall' then debuff_all[#debuff_all + 1] = entry
      elseif entry.is_debuff then debuffs[#debuffs + 1] = entry
      else dps[#dps + 1] = entry end
    end
  end
  st.combat.entries = dps
  st.combat.debuffs = debuffs
  st.combat.debuff_all = debuff_all
```
Update the `Write.Info` count line to include `#debuff_all`.

- [ ] **Step 4: Add `combat.debuff_all_tick` (in `combat.lua`)**

```lua
-- DebuffAll (DoDebuffStuff @10651): apply each `debuffall` entry to every XTarget auto-hater
-- NPC in melee range + LOS that lacks it. DebuffAllOn 1 = skip if already on; 2 = also force.
function combat.debuff_all_tick(st)
  local c = st.combat
  if (c.debuff_all_on or 0) == 0 or #c.debuff_all == 0 then return end
  if (c.mob_count or 0) == 0 then return end
  local force = c.debuff_all_on == 2
  local melee = c.melee_dist or 25
  for i = 1, 13 do
    local xt = mq.TLO.Me.XTarget(i)
    local id = xt.ID() or 0
    if id > 0 and (xt.TargetType() or '') == 'Auto Hater' and (xt.Type() or '') == 'NPC' then
      local sp = mq.TLO.Spawn(id)
      if (sp.Distance() or 9999) < melee and mqbool(sp.LineOfSight()) then
        for _, e in ipairs(c.debuff_all) do
          local has = mq.TLO.Spawn(id).CachedBuff(e.spell).ID() ~= nil
          if (force or not has) and spell_ready(e.spell) and ready(st, e.index, id)
             and cond_pass(st, e, id) then
            if cast.cast(e.spell, 'debuffall', id) == 'CAST_SUCCESS' then
              arm(st, e.index, id, math.max(mq.TLO.Spell(e.spell).Duration.TotalSeconds() or 0, c.dps_interval))
            end
          end
        end
      end
    end
  end
end
```
(Uses the same `mqbool`, `spell_ready`, `ready`, `arm`, `cond_pass` helpers the debuff/dps code already uses. If `arm`/`ready` are defined below this point, move the function after them.)

- [ ] **Step 5: Wire into the combat slot (`init.lua`)**

In the loop, immediately before `combat.tick(st)` add:
```lua
    combat.debuff_all_tick(st)
```

- [ ] **Step 6: Run tests; expect pass** — `test_combat`, `test_state` PASS (counts include debuff_all).

- [ ] **Step 7: Commit**

```bash
git add state.lua combat.lua init.lua tests/test_combat.lua tests/test_state.lua
git commit -m "feat(combat): consume serialize.parse_dps + DebuffAll (debuffall entries)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 5: DrawConditionBuilder widget (UI)

**Files:**
- Modify: `ui/init.lua`

No unit test (ImGui). Verified in-game. `cond_model` carries the logic coverage.

- [ ] **Step 1: Require cond_model + add the widget**

After the existing requires in `ui/init.lua` add `local cond_model = require('muleassist.cond_model')`. Add this function before `DrawProperty` (so it's in scope for the structured editors):

```lua
-- Shared hybrid condition editor. Returns the (possibly edited) condition string.
local condRawMode = {}   -- [idbase] = true  (user forced raw)
local function DrawConditionBuilder(idbase, condString)
    condString = condString or ''
    local parsed = cond_model.parse(condString)
    local useRaw = condRawMode[idbase] or parsed.mode == 'raw'

    if useRaw then
        ImGui.PushItemWidth(350)
        local newRaw = ImGui.InputText('Condition (raw)##raw'..idbase, condString)
        ImGui.PopItemWidth()
        if condString:find('${', 1, true) then
            ImGui.SameLine(); utils.HelpMarker('Legacy ${} condition - evaluated as-is.')
        end
        if ImGui.SmallButton('Try builder##tb'..idbase) then
            condRawMode[idbase] = nil
            if cond_model.parse(newRaw).mode == 'raw' then condRawMode[idbase] = true end
        end
        return newRaw
    end

    -- builder rows
    local rows = parsed.rows
    for ri, row in ipairs(rows) do
        ImGui.PushID(idbase..'r'..ri)
        -- subject combo
        local subj = nil
        for _, s in ipairs(cond_model.SUBJECTS) do if s.key == row.key then subj = s end end
        local label = subj and subj.label or row.key
        if ImGui.BeginCombo('##subj', label) then
            for _, s in ipairs(cond_model.SUBJECTS) do
                if ImGui.Selectable(s.label, s.key == row.key) then row.key = s.key; row.op = s.ops[1] end
            end
            -- buff subjects
            if ImGui.Selectable('Target has buff', row.key=='target_has_buff') then row.key='target_has_buff'; row.op=nil end
            if ImGui.Selectable('Target missing buff', row.key=='target_missing_buff') then row.key='target_missing_buff'; row.op=nil end
            ImGui.EndCombo()
        end
        ImGui.SameLine()
        if row.key == 'target_has_buff' or row.key == 'target_missing_buff' then
            ImGui.PushItemWidth(160)
            row.value = ImGui.InputText('##bval', row.value or '')
            ImGui.PopItemWidth()
        else
            local ops = (subj and subj.ops) or {'<','<=','>','>=','==','~='}
            ImGui.PushItemWidth(60)
            if ImGui.BeginCombo('##op', row.op or ops[1]) then
                for _, o in ipairs(ops) do if ImGui.Selectable(o, o == row.op) then row.op = o end end
                ImGui.EndCombo()
            end
            ImGui.PopItemWidth()
            ImGui.SameLine(); ImGui.PushItemWidth(120)
            row.value = ImGui.InputText('##val', row.value or '')
            ImGui.PopItemWidth()
        end
        ImGui.SameLine()
        if ImGui.SmallButton('x') then table.remove(rows, ri) end
        ImGui.PopID()
    end
    if ImGui.SmallButton('+ condition##add'..idbase) then
        rows[#rows+1] = { key='target_hp', op='<', value='100' }
    end
    ImGui.SameLine()
    if ImGui.SmallButton('raw##forceraw'..idbase) then condRawMode[idbase] = true end

    return cond_model.emit(rows)
end
```

- [ ] **Step 2: Wire it into the condition fields**

In `DrawStructuredBuff` and `DrawStructuredHeal`, replace the existing raw condition `ImGui.InputText('Condition##cond'..valueKey, e.cond or '')` line with:
```lua
        e.cond = DrawConditionBuilder(sectionName..valueKey, e.cond or '')
```
In the generic `DrawSelectedListItem` condition branch (the `DrawKeyAndInputText('Conditions: ', ...)` call) replace it with:
```lua
        globals.Config[sectionName][valueCondKey] =
          DrawConditionBuilder(sectionName..valueKey..'gen', globals.Config[sectionName][valueCondKey] or '')
```

- [ ] **Step 3: In-game verification** — `/lua run muleassist/ui`: open a Buffs/Heals/DPS entry; a condition like `mq.TLO.Target.PctHPs() < 70` shows builder rows; editing rows updates the stored string; an `or`/`${}` condition shows the raw box with the legacy note; "+ condition"/"x"/"raw"/"Try builder" all work; Save writes the expected string.

- [ ] **Step 4: Commit**

```bash
git add ui/init.lua
git commit -m "feat(ui): shared hybrid DrawConditionBuilder wired into all condition fields

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 6: DrawStructuredDPS (UI)

**Files:**
- Modify: `ui/init.lua`

- [ ] **Step 1: Add `DrawStructuredDPS`** (near `DrawStructuredBuff`/`DrawStructuredHeal`)

```lua
local DPS_TARGETS = { 'Mob', 'Me', 'Feign', 'MA', 'debuffall' }
local DPS_IFTAGS  = { '(none)', 'if', 'notif', 'ifme', 'notifme' }

local function DrawStructuredDPS(sectionName, valueKey, value)
    local cfg = globals.Config[sectionName]
    local idx = selectedListItem[2]
    local raw = cfg[valueKey]
    if raw == nil or raw == 'NULL' then raw = '' end
    local e = serialize.parse_dps(raw, cfg[valueKey..'Cond'] or cfg['DPSCond'..idx])

    -- spell
    e.spell = DrawKeyAndInputText('Spell/AA/Disc/Item: ', '##sp'..sectionName..valueKey, e.spell, value['Tooltip'])

    -- persistent toggle changes what part2 means
    local persistent = e.persistent
    persistent = ImGui.Checkbox('Persistent debuff (>=101)##pers'..valueKey, persistent)
    if persistent then
        ImGui.SameLine()
        ImGui.PushItemWidth(120)
        local v = ImGui.InputInt('recast tag##p2'..valueKey, (e.part2 >= 101) and e.part2 or 101)
        if v < 101 then v = 101 end
        e.part2 = v
        ImGui.PopItemWidth()
    else
        ImGui.PushItemWidth(120)
        local v = ImGui.InputInt('cast at mob HP%% <=##p2'..valueKey, (e.part2 <= 100) and e.part2 or 100)
        if v < 0 then v = 0 elseif v > 100 then v = 100 end
        e.part2 = v
        ImGui.PopItemWidth()
    end

    -- target dropdown
    if ImGui.BeginCombo('Target##tgt'..valueKey, e.target) then
        for _, tg in ipairs(DPS_TARGETS) do
            if ImGui.Selectable(tg, tg == e.target) then e.target = tg end
        end
        ImGui.EndCombo()
    end
    if e.target == 'debuffall' then
        ImGui.SameLine(); utils.HelpMarker('Debuffs every mob on XTarget (needs DebuffAllOn).')
    end

    e.once = ImGui.Checkbox('Cast once (no recast while up)##once'..valueKey, e.once)

    -- if/notif conditional row
    local curTag = e.if_tag or '(none)'
    if ImGui.BeginCombo('Only cast##iftag'..valueKey, curTag) then
        for _, tg in ipairs(DPS_IFTAGS) do
            if ImGui.Selectable(tg, tg == curTag) then e.if_tag = (tg ~= '(none)') and tg or nil end
        end
        ImGui.EndCombo()
    end
    if e.if_tag then
        ImGui.SameLine(); ImGui.PushItemWidth(180)
        e.if_spell = ImGui.InputText('spell##ifsp'..valueKey, e.if_spell or '')
        ImGui.PopItemWidth()
    end

    -- general condition (builder)
    local condKey = 'DPSCond'..idx
    globals.Config[sectionName][condKey] =
      DrawConditionBuilder(sectionName..valueKey..'dps', globals.Config[sectionName][condKey] or '')

    -- write back the structured fields
    cfg[valueKey] = serialize.dps_to_string(e)
end
```

- [ ] **Step 2: Route the DPS section to it in `DrawSelectedListItem`**

Where `DrawSelectedListItem` dispatches to `DrawStructuredBuff`/`DrawStructuredHeal` by section, add a branch:
```lua
    elseif sectionName == 'DPS' then
        DrawStructuredDPS(sectionName, key..selectedListItem[2], value)
```
(match the exact `valueKey` convention the buff/heal branches use — `key..selectedListItem[2]`).

- [ ] **Step 3: In-game verification** — `/lua run muleassist/ui`: select a DPS entry; fields populate from the pipe string; toggling "Persistent" switches the HP%/recast field and writes `>=101`; target `debuffall` round-trips; `if/notif` + spell writes the arg-shifted string; the condition builder works; Save produces a correct `spell|part2|target|if|spell` line.

- [ ] **Step 4: Commit**

```bash
git add ui/init.lua
git commit -m "feat(ui): DrawStructuredDPS structured editor for the DPS section

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Self-Review

**Spec coverage:**
- A1 cond.eval dual-mode → Task 1. A2 cond_model → Task 2. A3 DrawConditionBuilder → Task 5.
- B1 DebuffAll → Task 4. B2 serialize.parse_dps + combat refactor → Tasks 3, 4. B3 DrawStructuredDPS → Task 6.
- Error handling (cond fail-safe false, parse never throws, parse_dps tolerant) → Tasks 1, 2, 3.
- Testing for each pure module → Tasks 1–4. UI in-game → Tasks 5, 6.

**Type/name consistency:** `cond.eval`, `cond_model.parse/emit/SUBJECTS`, row shape `{key,op,value}`, `serialize.parse_dps/dps_to_string`, entry fields (`spell/part2/persistent/target/once/if_tag/if_spell` + legacy aliases `hp_pct/is_debuff/cond_tag/cond_spell`), `st.combat.debuff_all/debuff_all_on`, `combat.debuff_all_tick`, `DrawConditionBuilder`, `DrawStructuredDPS` — used identically across tasks.

**Build order:** 1 → 2 → 3 → 4 → 5 → 6. Track A (1,2,5) and Track B (3,4,6) can interleave; 6 depends on 3+5; 5 depends on 2.

**Out of scope (per spec):** converting existing `${}` configs; OR/parenthesized builder rows; TLO autocomplete.
