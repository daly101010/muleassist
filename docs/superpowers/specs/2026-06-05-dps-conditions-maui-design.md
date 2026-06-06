# DPS Editor + Native Conditions + Condition Builder — Design

**Date:** 2026-06-05
**Status:** Approved (brainstorming) — ready for implementation plan
**Goal:** Make DPS structurally editable in MAUI (no hand-typed pipe grammar), switch the
condition system from legacy `${...}` strings to native `mq.TLO.x` Lua expressions
(dual-mode for back-compat), and give every condition field a hybrid builder so users don't
need to know the syntax.

---

## Background / current state

- **DPS in MAUI** renders through the generic plain-list editor (`DrawList` →
  `DrawSelectedListItem`): Name + a raw "Options" pipe field + a raw condition box. No
  DPS-aware structured editor. The real grammar (arg-shift, `≥101` persistent, `debuffall`,
  `once`, `if/notif`) is invisible and footgun-prone.
- **`serialize.lua`** covers buff + heal only. The DPS grammar lives read-only in a private
  `combat.parse_dps`. No `serialize.parse_dps`.
- **Conditions** everywhere are raw `${...}` MQ-TLO strings; `cond.eval` runs them via
  `mq.parse('${If[<cond>,1,0]}')`. No builder.
- **DebuffAll** (`debuffall` Part3 keyword, `DoDebuffStuff`/`DebuffCast`, `DebuffAllOn`) is
  NOT ported into `combat.lua`; our combat only knows `part2 ≥ 101 ⇒ persistent`.

### DPS grammar reference (verified against the macro)

`Part1 | Part2 | Part3 | Part4 | Part5`
- **Part1** — spell / AA / disc (CombatAbility) / skill (Ability) / item clicky /
  `command:/foo`.
- **Part2** — number. `1–100` = mob-HP%% gate (`DPSAt`: cast while `targetHP%% ≤ Part2`).
  `≥101` = **persistent** flag (`DPSTimerReset` @4229 won't reset these on target switch).
  Global `DPSSkip` (default 1) skips below that HP%%.
- **Part3** — target/mode: `Me`/`Feign` (self), `MA` (main assist), `debuffall` (DebuffAll
  feature), `once` substring (cast-once), else the mob.
- **Part4/Part5** — conditional gate `if|notif|ifme|notifme` + spell. `if/notif` check the
  TARGET's CachedBuff; `ifme/notifme` check MY buff/song. **Arg-shift** (@3170): if `Arg3`
  is one of those keywords, keyword→Part4, its spell→Part5, target→Arg5.
- **Global modes:** `DPSOn` 0 off / 1 normal (respect Part2 HP gate) / 2 ignore HP gate;
  `DPSSkip`; `DPSInterval` (default 2s, per-spell timer for 0-duration + `spam`-tagged);
  `DPSCOn` (apply conditions).

---

## Architecture

Two independently-shippable tracks.

### Track A — Conditions

**A1. `cond.eval(str)` dual-mode (refactor `cond.lua`)**
- Empty / `NULL` / `TRUE` → true; `FALSE` → false (unchanged).
- Contains `${` → **legacy path** (current `mq.parse('${If[' .. s .. ',1,0]}') == '1'`).
- Otherwise → **native path**:
  - Compile once via `load('return (' .. s .. ')', '@cond', 't', ENV)`, **cache** the chunk
    keyed by the string (conditions evaluate every tick; recompiling each call is
    unacceptable).
  - `ENV` is a curated sandbox table: `{ mq = mq, math = math, string = string,
    tonumber = tonumber, tostring = tostring, ipairs = ipairs, pairs = pairs }`. No `os`,
    `io`, `load`, `_G`. Conditions are pure reads.
  - Run under `pcall`; on compile or runtime error log once (dedupe by string) via
    `Write.Error` and return false.
  - Coerce result to boolean (`not not result`).
- `cond.expand` (legacy `mq.parse`) stays for any `${}` text expansion callers.

**A2. `cond_model.lua` (pure, no mq) — the builder's brain**
- `cond_model.SUBJECTS` — ordered catalog. Each entry:
  `{ key, label, expr, ops = {'<','<=','>','>=','==','~='}, value = 'number'|'string'|'bool' }`
  where `expr` is the Lua TLO fragment, e.g.:
  - `target_hp`   → `mq.TLO.Target.PctHPs()`            (number)
  - `my_hp`       → `mq.TLO.Me.PctHPs()`                (number)
  - `my_mana`     → `mq.TLO.Me.PctMana()`              (number)
  - `my_end`      → `mq.TLO.Me.PctEndurance()`         (number)
  - `target_dist` → `mq.TLO.Target.Distance3D()`       (number)
  - `target_named`→ `mq.TLO.Target.Named()`            (bool; ops `==`,`~=`)
  - `combat`      → `mq.TLO.Me.CombatState()`           (string; e.g. == 'COMBAT')
  - `group_size`  → `mq.TLO.Group.Members()`            (number)
  - `xtargets`    → `mq.TLO.Me.XTarget()`               (number)
  - buff checks emit a function-style clause (see below).
- `cond_model.parse(str)`:
  - Split on top-level ` and ` (no parens / no `or` / no `${`). If any of those appear →
    `{mode='raw', raw=str}`.
  - Each clause matched by **literal-prefix comparison** against each catalog `expr`, NOT a
    Lua pattern — the exprs contain `()`/`[]` which are pattern-magic. Strip the matched
    `expr` prefix, then parse the remaining `<op> <value>` (op from a fixed set, value
    trimmed). All clauses must resolve to a catalog subject → `{mode='rows', rows={...}}`.
    Any non-match → raw.
  - Buff clauses: recognize `mq.TLO.Target.CachedBuff[NAME]() ~= nil` (has) and `== nil`
    (missing) → rows `{key='target_has_buff'|'target_missing_buff', value=NAME}`.
- `cond_model.emit(rows)` → clauses joined by ` and `, each built from the subject `expr`,
  op, and value (numbers bare, strings quoted, buff subjects expand to the CachedBuff form).
- Round-trip invariant: `parse(emit(rows)).rows` deep-equals `rows`.

**A3. `DrawConditionBuilder(idbase, condString) → newCondString` (UI, in `ui/init.lua`)**
- Call `cond_model.parse`. If `rows`: render one row per clause — subject combo, op combo
  (from the subject's `ops`), value widget (InputInt / InputText / bool combo) — plus
  add/remove-row buttons and a "⚙ raw" toggle. Re-`emit` to the returned string each frame.
- If `raw`: show a single InputText (the raw box), with a note if it's a legacy `${...}`
  string ("legacy condition — evaluated as-is"). A "try builder" button re-parses.
- Replaces the raw condition InputText in `DrawStructuredBuff`, `DrawStructuredHeal`,
  `DrawStructuredDPS`, and the generic `DrawSelectedListItem` condition field.

### Track B — DPS

**B1. DebuffAll in `combat.lua`** (so the editor's `debuffall` mode reflects real behavior)
- `combat.setup`: split DPS entries with `target == 'debuffall'` into `st.combat.debuff_all`
  (separate from the `persistent`/`≥101` bucket). Read `DebuffAllOn` (`[DPS]`, 0/1/2) into
  `st.combat.debuff_all_on`.
- `combat.debuff_all_tick(st)` (ports `DoDebuffStuff` @10651 / `DebuffCast`): for each
  XTarget auto-hater NPC, apply each `debuffall` entry the mob lacks (CachedBuff check),
  per-spell throttled (DPSInterval), gated on `debuff_all_on`. Mode 2 = re-apply more
  aggressively (port the `DebuffAllOn==2` branch). Called from the combat slot before the
  single-target DPS rotation, only when `mob_count > 0`.

**B2. `serialize.parse_dps(raw, cond)` / `serialize.dps_to_string(e)`**
- Entry shape:
  `{ spell, part2 (number), persistent (part2≥101), target ('Mob'|'Me'|'Feign'|'MA'|'debuffall'),
     once (bool), if_tag ('if'|'notif'|'ifme'|'notifme'|nil), if_spell, cond, raw, index }`.
- `parse_dps` reproduces the arg-shift exactly (if `args[3]` ∈ keywords →
  `if_tag=args[3], if_spell=args[4], target=args[5] or 'Mob'`; else
  `target=args[3] or 'Mob', if_tag=args[4], if_spell=args[5]`), the `once` substring on
  Part3, and `persistent = part2 >= 101`.
- `dps_to_string` is the inverse, emitting the canonical (non-shifted) order
  `spell|part2|target|if_tag|if_spell`, dropping trailing empties, preserving `once`.
- Round-trip invariant on representative entries (plain, self+ifme, MA, debuffall,
  if/notif follow-up, persistent).
- **Refactor `combat.lua`** to delete its private `parse_dps` and consume
  `serialize.parse_dps` (mirrors the Stage-A buff refactor). Existing `test_combat` stays
  green.

**B3. `DrawStructuredDPS` (UI)** — mirrors `DrawStructuredBuff/Heal`, wired into
`DrawSelectedListItem` for `DPS`:
- spell picker · target dropdown (`Mob/Me/Feign/MA/debuffall`) · Part2 field labeled
  "cast at mob HP%% ≤" with a **"persistent debuff (≥101)" toggle** that switches its meaning
  · `once` checkbox · a **conditional row** (`if/notif/ifme/notifme` dropdown + spell picker,
  distinct from the general condition) · then `DrawConditionBuilder` for the general
  condition. Writes back via `serialize.dps_to_string` + the sibling `DPSCond`.

## Error handling
- Native cond compile/runtime errors → logged once per unique string, evaluate to false
  (fail-safe: a broken condition never fires a cast).
- `cond_model.parse` never throws on malformed input — worst case returns `{mode='raw'}`.
- `serialize.parse_dps` tolerates short/empty arg lists (missing parts → nil/defaults).

## Testing (offline harness, `tests/run`)
- `test_cond` (extend): legacy `${}` true/false unchanged; native `mq.TLO.Me.PctMana() > 0`
  truthy; `FALSE`/`TRUE`/empty; malformed Lua → false (no throw); second eval of same string
  hits the cache (assert chunk identity or a counter).
- `test_cond_model` (new): and-chain → rows; `or`/parens/`${}`/unknown subject → raw; buff
  has/missing clauses; `emit(parse(x))` round-trip.
- `test_serialize` (extend): `parse_dps`/`dps_to_string` round-trip for all six modes.
- `test_combat` (extend): `debuffall` entries land in `st.combat.debuff_all`;
  `combat.setup` still reports correct dps/debuff counts after the `serialize.parse_dps`
  refactor.
- UI (`DrawStructuredDPS`, `DrawConditionBuilder`): in-game verification — the pure
  `cond_model` carries the logic coverage.

## Build order
1. A1 cond.lua native dual-mode (+ test_cond)
2. A2 cond_model.lua (+ test_cond_model)
3. B1 DebuffAll in combat (+ test_combat)
4. B2 serialize.parse_dps + combat refactor (+ test_serialize)
5. B3/A3 UI widgets (DrawStructuredDPS, DrawConditionBuilder) — in-game

Tracks A (1,2,5-cond) and B (3,4,5-dps) can land independently.

## Out of scope
- Converting existing `${}` configs to Lua (dual-mode keeps them working as-is).
- OR / parenthesized condition rows in the builder (raw escape hatch handles them).
- A TLO autocomplete / full expression IDE (the subject catalog is curated, extensible).
