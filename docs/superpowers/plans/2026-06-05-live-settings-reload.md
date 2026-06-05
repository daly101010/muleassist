# Live Settings Reload Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Edit a setting in MAUI (or hand-edit the INI) and have it apply to the running bot immediately and persist to disk — no restart.

**Architecture:** Split `state.new` into a re-runnable `state.apply_config` (config-derived fields, mutated in place) plus one-time runtime init. A new `settings.reapply` re-reads the INI and re-runs every module `setup`. A `/mareload` bind and the embedded MAUI panel both trigger it via a `st.pending_reapply` flag consumed in the main loop. MAUI is embedded in the bot process (shared Lua state, no IPC); per-field edits debounce ~750 ms → flush INI → reapply.

**Tech Stack:** Lua 5.1 / LuaJIT, MacroQuest `mq` API, Dear ImGui (MQ binding), LIP (INI), existing `muleassist` modules.

**Spec:** `docs/superpowers/specs/2026-06-05-live-settings-reload-design.md`

**Test note:** This project has no offline Lua runtime — tests run in-game via `/lua run muleassist/tests/run`. "Run the test" steps mean: in-game, run that command and read the printed result. Pure-logic tests (state, settings, diff) still go through the same harness.

---

## File Structure

- **Modify** `state.lua` — split into `state.apply_config(st, cfg)` (re-runnable) + `state.new(cfg)` (calls apply_config, then runtime init).
- **Create** `settings.lua` — `settings.reapply(st)`: reload INI, apply_config, re-run setups; pcall-guarded.
- **Modify** `init.lua` — `require` settings; `/mareload` bind; consume `st.pending_reapply` each tick; lazy `/maui` mount of the embedded UI.
- **Create** `ui/diff.lua` — pure change-detection + debouncer (unit-testable).
- **Modify** `ui/init.lua` — become a module: `M.mount(opts)`, `M.toggle()`, standalone runner guarded behind `_G.MULEASSIST_EMBED`; wire diff/debounce → `Save()` → `opts.on_apply`.
- **Modify** `tests/test_state.lua` — assert `apply_config` idempotency + runtime preservation.
- **Create** `tests/test_settings.lua`, `tests/test_diff.lua`; register both in `tests/run.lua`.

---

## Task 1: Split state into apply_config + runtime init

**Files:**
- Modify: `state.lua` (full rewrite of `state.new`)
- Test: `tests/test_state.lua`

- [ ] **Step 1: Add idempotency/preservation assertions to test_state**

Insert before `print('test_state: PASS')` in `tests/test_state.lua`:

```lua
  -- apply_config is re-runnable: picks up edits, preserves runtime fields
  st.camp.x = 111
  st.pull.state = 'outbound'
  st.combat.aggro_target_id = 999
  cfg.sections['Melee'] = cfg.sections['Melee'] or {}
  cfg.sections['Melee']['AssistAt'] = '77'
  state.apply_config(st, cfg)
  assert(st.combat.assist_at == 77, 'apply_config picks up edited AssistAt')
  assert(st.camp.x == 111, 'apply_config preserves camp.x (runtime)')
  assert(st.pull.state == 'outbound', 'apply_config preserves pull.state (runtime)')
  assert(st.combat.aggro_target_id == 999, 'apply_config preserves combat runtime')
```

- [ ] **Step 2: Run tests; expect failure**

Run (in-game): `/lua run muleassist/tests/run`
Expected: `FAIL muleassist.tests.test_state` — `attempt to call field 'apply_config' (a nil value)`.

- [ ] **Step 3: Rewrite `state.lua`**

Replace the entire body of `function state.new(cfg) ... end` (and add `state.apply_config`) so the file reads:

```lua
-- muleassist/state.lua
-- Runtime state built from config. Replaces the macro's ~300 outer-scope variables.
-- apply_config (re-runnable) sets every config-derived field IN PLACE so /mareload and
-- the embedded UI can re-apply edits without orphaning the loop/binds' st reference or
-- wiping runtime (camp, pull/combat state machines, timers).
local state = {}

-- Re-runnable: (re)assign every config-derived field on st. Never touches runtime fields.
function state.apply_config(st, cfg)
  st.cfg  = cfg
  st.role = cfg:get('General', 'Role', 'Assist')

  st.flags = st.flags or {}
  local f = st.flags
  f.pet_on    = cfg:bool('Pet',     'PetOn',        false)
  f.buffs_on  = cfg:bool('Buffs',   'BuffsOn',      false)
  f.heals_on  = cfg:bool('Heals',   'HealsOn',      false)
  f.dps_on    = cfg:bool('DPS',     'DPSOn',        false)
  f.melee_on  = cfg:bool('Melee',   'MeleeOn',      false)
  f.mez_on    = cfg:bool('Mez',     'MezOn',        false)
  f.charm_on  = cfg:bool('General', 'CharmOn',      false)
  f.med_on    = cfg:bool('General', 'MedOn',        false)
  f.return_to_camp = cfg:bool('General', 'ReturnToCamp', false)
  f.eqbc_on   = cfg:bool('General', 'EQBCOn',       false)
  f.dannet_on = cfg:bool('General', 'DanNetOn',     false)

  st.combat = st.combat or {}
  local c = st.combat
  c.role           = (cfg:get('General', 'Role', 'Assist') or 'Assist')
  c.assist_at      = cfg:num('Melee', 'AssistAt', 95)
  c.melee_on       = cfg:bool('Melee', 'MeleeOn', false)
  c.melee_dist     = cfg:num('Melee', 'MeleeDistance', 25)
  c.stick_how      = cfg:get('Melee', 'StickHow', '!frontangle 12')
  c.tank_stick     = cfg:get('Melee', 'TankStickHow', '!front')
  c.face_on        = cfg:bool('Melee', 'FaceMobOn', true)
  c.dps_on         = cfg:bool('DPS', 'DPSOn', false)
  c.dps_interval   = cfg:num('DPS', 'DPSInterval', 1)
  c.dps_cond_on    = cfg:bool('General', 'ConditionsOn', true) and cfg:bool('DPS', 'DPSCOn', true)
  c.assist_outside = cfg:bool('General', 'AssistOutside', false)
  c.pet_assist_at  = cfg:num('Pet', 'PetAssistAt', 95)
  c.pet_combat_on  = cfg:bool('Pet', 'PetCombatOn', false)
  c.aggro_on       = cfg:bool('Aggro', 'AggroOn', false)
  c.burn_all_named = cfg:bool('Burn', 'BurnAllNamed', false)

  st.heal = st.heal or {}
  local h = st.heal
  h.mode         = cfg:num('Heals', 'HealsOn', 0)
  h.xtar         = cfg:get('Heals', 'XTarHeal', nil)
  h.group_pets   = cfg:bool('Heals', 'HealGroupPetsOn', false)
  h.interrupt    = cfg:num('Heals', 'InterruptHeals', 100)
  h.duration_mod = cfg:num('General', 'DurationMod', 1)
  h.cond_on      = cfg:bool('General', 'ConditionsOn', true) and cfg:bool('Heals', 'HealsCOn', true)

  st.rez = st.rez or {}
  st.rez.auto     = cfg:num('Heals', 'AutoRezOn', 0)
  st.rez.with     = cfg:get('Heals', 'AutoRezWith', nil)
  st.rez.mount_on = cfg:bool('General', 'MountOn', true)

  st.buff = st.buff or {}
  local b = st.buff
  b.check_secs    = cfg:num('Buffs', 'CheckBuffsTimer', 10)
  b.while_chasing = cfg:bool('General', 'BuffWhileChasing', true)
  b.duration_mod  = cfg:num('General', 'DurationMod', 1)
  b.cond_on       = cfg:bool('General', 'ConditionsOn', true) and cfg:bool('Buffs', 'BuffsCOn', true)

  st.pet = st.pet or {}
  st.pet.buffs_on     = cfg:bool('Pet', 'PetBuffsOn', false)
  st.pet.shrink_on    = cfg:bool('Pet', 'PetShrinkOn', false)
  st.pet.shrink_spell = cfg:get('Pet', 'PetShrinkSpell', 'Tiny Companion')
  st.pet.check_secs   = 60

  -- cfg MainAssist wins, but keep an arg/auto-derived value if cfg is empty
  st.main_assist = cfg:get('General', 'MainAssist', nil) or st.main_assist

  st.camp = st.camp or {}
  st.camp.radius = cfg:num('General', 'CampRadius', 60)
  st.camp.exceed = cfg:num('General', 'CampRadiusExceed', 400)

  st.move = st.move or {}
  local m = st.move
  m.return_to_camp  = cfg:bool('General', 'ReturnToCamp', false)
  m.return_accuracy = cfg:num('General', 'ReturnToCampAccuracy', 10)
  m.chase_assist    = cfg:bool('General', 'ChaseAssist', false)
  m.chase_distance  = cfg:num('General', 'ChaseDistance', 25)

  st.med = st.med or {}
  st.med.on         = cfg:bool('General', 'MedOn', false)
  st.med.start      = cfg:num('General', 'MedStart', 90)
  st.med.sit_to_med = cfg:bool('General', 'SitToMed', false)

  st.pull = st.pull or {}
  local pl = st.pull
  pl.with        = cfg:get('Pull', 'PullWith', 'Melee')
  pl.max_radius  = cfg:num('Pull', 'MaxRadius', 350)
  pl.max_z       = cfg:num('Pull', 'MaxZRange', 50)
  pl.wait        = cfg:num('Pull', 'PullWait', 5)
  pl.cond        = cfg:get('Pull', 'PullCond', nil)
  pl.mobs        = cfg:get('Pull', 'MobsToPull', 'All')
  pl.namedsfirst = cfg:bool('Pull', 'PullNamedsFirst', false)
  pl.level_raw   = cfg:get('Pull', 'PullLevel', '0|0')
  pl.melee_dist  = cfg:num('Melee', 'MeleeDistance', 25)
  pl.chain       = cfg:num('Pull', 'ChainPull', 0)
  pl.chain_hp    = cfg:num('Pull', 'ChainPullHP', 90)
  pl.chain_pause = cfg:get('Pull', 'ChainPullPause', '0')
  pl.use_calm    = cfg:bool('Pull', 'UseCalm', false)
  pl.calm_with   = cfg:get('Pull', 'CalmWith', 'Harmony')
  pl.calm_radius = cfg:num('Pull', 'CalmRadius', 50)
  pl.arc_width   = cfg:num('Pull', 'PullArcWidth', 0)
  pl.grab_dead   = cfg:bool('Pull', 'GrabDeadGroupMembers', false)
  pl.mobs_sec    = cfg:get('Pull', 'MobsToPullSecondary', nil)
  -- camp leash must cover the pull radius (re-applied here so a live radius edit sticks)
  if pl.max_radius + 1 > st.camp.exceed then st.camp.exceed = pl.max_radius + 1 end

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
end

function state.new(cfg)
  local st = { running = true, hooks = {}, timers = {} }
  state.apply_config(st, cfg)

  -- runtime-only fields (set once; survive every apply_config/reapply)
  st.flags.buff_mode   = false
  st.flags.zombie_mode = false

  local c = st.combat
  c.aggro_target_id = nil; c.hostile_count = 0; c.mob_count = 0
  c.my_target_id = nil; c.my_target_name = nil; c.combat_start = nil
  c.attacking = nil; c.pulled = nil; c.chasing = nil; c.xtslot = 1
  c.dps_timers = {}; c.entries = {}; c.debuffs = {}; c.aggro = {}
  c.burn = {}; c.burning = false; c.named_check = nil

  local h = st.heal
  h.single = {}; h.group = {}
  h.timers = {}; h.group_timers = {}; h.pet_timers = {}
  h.single_point = 0

  st.rez.radius = 150; st.rez.battle_timers = {}; st.rez.ooc_timers = {}

  st.buff.entries = {}; st.buff.timers = {}; st.buff.oog_timers = {}; st.buff.read_deadline = 0

  st.pet.check_deadline = 0; st.pet.entries = {}

  st.main_assist_id = 0

  st.camp.x = nil; st.camp.y = nil; st.camp.z = nil

  st.move.chase_name = nil

  st.med.medding = false

  local pl = st.pull
  pl.range = 15; pl.range_type = 'Melee'; pl.pull_min = 1; pl.pull_max = 200
  pl.mob_list = nil; pl.mob_list_sec = nil
  pl.arc_lside = 0; pl.arc_rside = 0; pl.move_use = 'nav'; pl.path_wp_count = 0
  pl.state = 'idle'; pl.target_id = nil; pl.abort_deadline = 0; pl.wait_until = 0; pl.attempts = 0
  pl.chain_hold = false; pl.chain_active_until = 0; pl.chain_pause_until = 0; pl.dragging = 0

  st.pending_reapply = false   -- set by /mareload or the UI; consumed in init.lua's loop

  return st
end

return state
```

- [ ] **Step 4: Run tests; expect pass**

Run (in-game): `/lua run muleassist/tests/run`
Expected: `test_state: PASS` and `ALL TESTS PASS` (all other suites unchanged).

- [ ] **Step 5: Commit**

```bash
git add state.lua tests/test_state.lua
git commit -m "refactor(state): split apply_config (re-runnable) from runtime init

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 2: settings.reapply

**Files:**
- Create: `settings.lua`
- Create: `tests/test_settings.lua`
- Modify: `tests/run.lua`

- [ ] **Step 1: Create `tests/test_settings.lua`**

```lua
-- muleassist/tests/test_settings.lua  (runs in-game; setups call mq.TLO)
local config   = require('muleassist.config')
local state    = require('muleassist.state')
local settings = require('muleassist.settings')

local here = debug.getinfo(1, 'S').source:sub(2):gsub('[^/\\]+$', '')
local FIXTURE = here .. 'fixtures/sample.ini'

local t = {}
function t.run()
  local cfg = config.load(FIXTURE)
  assert(cfg, 'config.load returned nil for ' .. FIXTURE)
  local st = state.new(cfg)

  -- plant runtime sentinels that must survive a reapply
  st.camp.x, st.camp.y, st.camp.z = 10, 20, 30
  st.pull.state = 'outbound'; st.pull.target_id = 4242
  st.combat.combat_start = 12345

  local ok = settings.reapply(st)
  assert(ok, 'settings.reapply returned true')

  assert(st.camp.x == 10, 'reapply preserved camp.x')
  assert(st.pull.state == 'outbound', 'reapply preserved pull.state')
  assert(st.pull.target_id == 4242, 'reapply preserved pull.target_id')
  assert(st.combat.combat_start == 12345, 'reapply preserved combat runtime')

  assert(type(st.combat.entries) == 'table', 'combat entries rebuilt')
  assert(type(st.buff.entries) == 'table', 'buff entries rebuilt')
  assert(type(st.heal.single) == 'table', 'heal single rebuilt')

  print('test_settings: PASS')
  return true
end
return t
```

- [ ] **Step 2: Register the suite in `tests/run.lua`**

Add `'muleassist.tests.test_settings',` to the `mods` list (after `test_combat`).

- [ ] **Step 3: Run tests; expect failure**

Run (in-game): `/lua run muleassist/tests/run`
Expected: `LOAD FAIL muleassist.tests.test_settings: ...module 'muleassist.settings' not found`.

- [ ] **Step 4: Create `settings.lua`**

```lua
-- muleassist/settings.lua
-- Live config reload: re-read the INI from disk and re-derive all config-driven state in
-- place, then rebuild each module's entries. Used by /mareload and the embedded MAUI panel.
-- pcall-guarded: on any failure the running config is left untouched (reapply is a no-op).
local config  = require('muleassist.config')
local state   = require('muleassist.state')
local Write   = require('muleassist.Write')
local cast    = require('muleassist.cast')
local heal    = require('muleassist.heal')
local buff    = require('muleassist.buff')
local petbuff = require('muleassist.petbuff')
local combat  = require('muleassist.combat')
local pull    = require('muleassist.pull')

local settings = {}

function settings.reapply(st)
  local path = st.cfg and st.cfg.path
  if not path then Write.Error('settings.reapply: no config path on st'); return false end

  local cfg, err = config.load(path)
  if not cfg then Write.Error('settings.reapply: load failed (%s)', tostring(err)); return false end

  local ok, e = pcall(function()
    state.apply_config(st, cfg)
    -- cast scratch-gem config (mirrors init.lua startup)
    cast.misc_gem          = cfg:num('General', 'MiscGem',      8)
    cast.misc_gem_lw       = cfg:num('General', 'MiscGemLW',    0)
    cast.misc_gem_remem    = cfg:num('General', 'MiscGemRemem', 1)
    cast.gem_stuck_ability = cfg:get('General', 'GemStuckAbility', nil)
    heal.setup(st); buff.setup(st); petbuff.setup(st); combat.setup(st); pull.setup(st)
  end)
  if not ok then Write.Error('settings.reapply: %s', tostring(e)); return false end

  Write.Info('Settings reloaded from %s', path)
  return true
end

return settings
```

- [ ] **Step 5: Run tests; expect pass**

Run (in-game): `/lua run muleassist/tests/run`
Expected: `test_settings: PASS` and `ALL TESTS PASS`.

- [ ] **Step 6: Commit**

```bash
git add settings.lua tests/test_settings.lua tests/run.lua
git commit -m "feat(settings): settings.reapply — reload INI + re-run setups in place

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 3: /mareload bind + loop consumption

**Files:**
- Modify: `init.lua`

- [ ] **Step 1: Require the settings module**

In `init.lua`, after `local pull   = require('muleassist.pull')`, add:

```lua
local settings = require('muleassist.settings')
```

- [ ] **Step 2: Add the `/mareload` bind**

After the `mq.bind('/macamphere', ...)` line, add:

```lua
  mq.bind('/mareload', function() st.pending_reapply = true end)
```

- [ ] **Step 3: Consume the flag at the top of the loop**

In the `while st.running do` body, immediately after `mq.doevents()`, add:

```lua
    if st.pending_reapply then
      st.pending_reapply = false
      settings.reapply(st)
    end
```

- [ ] **Step 4: In-game verification**

1. `/lua run muleassist/init Assist` (or your role).
2. Hand-edit the INI (e.g. change `AssistAt`), save.
3. `/mareload`.
Expected: console prints `[INFO] Settings reloaded from ...`; new `AssistAt` takes effect (verify by behavior or a temporary `/echo`), and the bot keeps running (camp/pull state intact).

- [ ] **Step 5: Commit**

```bash
git add init.lua
git commit -m "feat(init): /mareload bind + pending_reapply consumed in main loop

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 4: Pure diff + debounce helper

**Files:**
- Create: `ui/diff.lua`
- Create: `tests/test_diff.lua`
- Modify: `tests/run.lua`

- [ ] **Step 1: Create `tests/test_diff.lua`**

```lua
-- muleassist/tests/test_diff.lua  (pure; no mq/ImGui)
local diff = require('muleassist.ui.diff')

local t = {}
function t.run()
  assert(diff.changed({A={x=1}}, {A={x=2}}),  'value change detected')
  assert(not diff.changed({A={x=1}}, {A={x=1}}), 'identical -> no change')
  assert(diff.changed({A={x=1}}, {A={}}),     'missing key detected')
  assert(diff.changed({A={x=1}}, {}),         'missing section detected')
  assert(not diff.changed({}, {}),            'empty -> no change')

  local d = diff.debouncer(0.75)
  d:touch(100.0)
  assert(not d:due(100.5), 'not due before delay')
  assert(d:due(100.8),     'due after delay elapses')
  assert(not d:due(100.9), 'fires exactly once per touch')

  print('test_diff: PASS')
  return true
end
return t
```

- [ ] **Step 2: Register in `tests/run.lua`**

Add `'muleassist.tests.test_diff',` to the `mods` list.

- [ ] **Step 3: Run tests; expect failure**

Run (in-game): `/lua run muleassist/tests/run`
Expected: `LOAD FAIL muleassist.tests.test_diff: ...module 'muleassist.ui.diff' not found`.

- [ ] **Step 4: Create `ui/diff.lua`**

```lua
-- muleassist/ui/diff.lua
-- Pure helpers for the live-apply bridge: detect config changes and debounce flushes.
-- No mq/ImGui dependency so it is unit-testable through tests/run.
local diff = {}

local function oneway(a, b)
  for sec, keys in pairs(a) do
    if type(keys) == 'table' then
      local bk = b[sec]
      if type(bk) ~= 'table' then return true end
      for k, v in pairs(keys) do
        if bk[k] ~= v then return true end
      end
    end
  end
  return false
end

-- True if any leaf value differs between two {section = {key = scalar}} tables.
function diff.changed(a, b)
  return oneway(a, b) or oneway(b, a)
end

-- Shallow 2-level copy (sufficient for the config table: section -> key -> scalar).
function diff.snapshot(cfg)
  local out = {}
  for sec, keys in pairs(cfg) do
    if type(keys) == 'table' then
      local t = {}
      for k, v in pairs(keys) do t[k] = v end
      out[sec] = t
    else
      out[sec] = keys
    end
  end
  return out
end

-- Debouncer: due() returns true once, `delay` seconds after the last touch(now).
function diff.debouncer(delay)
  return {
    delay = delay,
    fire_at = nil,
    touch = function(self, now) self.fire_at = now + self.delay end,
    due = function(self, now)
      if self.fire_at and now >= self.fire_at then self.fire_at = nil; return true end
      return false
    end,
  }
end

return diff
```

- [ ] **Step 5: Run tests; expect pass**

Run (in-game): `/lua run muleassist/tests/run`
Expected: `test_diff: PASS` and `ALL TESTS PASS`.

- [ ] **Step 6: Commit**

```bash
git add ui/diff.lua tests/test_diff.lua tests/run.lua
git commit -m "feat(ui): pure diff + debouncer helper for live-apply bridge

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 5: Make ui/init.lua an embeddable module

**Files:**
- Modify: `ui/init.lua`

No unit test (ImGui). Verified in Task 6 in-game. Each step is a precise edit.

- [ ] **Step 1: Declare the module table and require diff**

Near the top of `ui/init.lua`, just after `local serialize = require('muleassist.serialize')` (line ~16), add:

```lua
local diff = require('muleassist.ui.diff')

local M = {}                 -- module export (mount/toggle for embedding)
local apply_opts = nil       -- set by M.mount; holds on_apply callback
local cfg_snapshot = nil     -- last-applied snapshot of globals.Config
local apply_db = diff.debouncer(0.75)
local trees_built = false
```

- [ ] **Step 2: Add the live-apply step to the draw function**

At the very end of the `MAUI` draw function — immediately before its closing `end` (the `MAUI` function ends right after `if used_theme then pop_styles() end` / `ImGui.End()` block at line ~1523) — insert:

```lua
    -- Live-apply bridge: when embedded, debounce config edits -> flush INI -> reapply.
    if apply_opts and globals.Config then
        local now = os.clock()
        if not cfg_snapshot then cfg_snapshot = diff.snapshot(globals.Config) end
        if diff.changed(globals.Config, cfg_snapshot) then
            cfg_snapshot = diff.snapshot(globals.Config)
            apply_db:touch(now)
        end
        if apply_db:due(now) then
            local ok = pcall(Save)             -- flush globals.Config -> bot INI (LIP)
            if ok and apply_opts.on_apply then apply_opts.on_apply() end
        end
    end
```

Note: `Save` is the existing local function defined at line ~98. This insertion is below it, so it is in scope.

- [ ] **Step 3: Wrap the standalone runner in a function**

Find the bottom-of-file runner block. Change the section that currently begins at the
INI-load comment (`-- Load INI into table as well as raw content`, line ~1568) through the
end of the `while not terminate do ... end` loop (line ~1605) by wrapping it in a function
and guarding it. Replace:

```lua
-- Load INI into table as well as raw content
globals.INIFile = globals.MAUI_Config['INIFile'] or utils.FindINIFile()
```

...down through the final...

```lua
    tloCache:clean()
    mq.delay(20)
end
```

...with:

```lua
local function load_bot_ini()
    globals.INIFile = globals.MAUI_Config['INIFile'] or utils.FindINIFile()
    if globals.INIFile and utils.FileExists(mq.configDir..'/'..globals.INIFile) then
        globals.Config = LIP.load(mq.configDir..'/'..globals.INIFile)
        globals.INIFileContents = utils.ReadRawINIFile()
        globals.INILoadError = ''
    else
        globals.INIFile = globals.Schema['INI_PATTERNS']['level']:format(globals.MyServer, globals.MyName, globals.MyLevel)
        globals.Config = {}
    end
end

local function build_trees()
    if trees_built then return end
    InitSpellTree(); InitAATree(); InitDiscTree()
    trees_built = true
end

-- Embed entry: host the panel inside another script (the bot). No keep-alive loop.
function M.mount(opts)
    apply_opts = opts or {}
    load_bot_ini()
    cfg_snapshot = diff.snapshot(globals.Config)
    open = true
    mq.imgui.init(apply_opts.window or 'MuleAssist', function()
        build_trees()
        MAUI()
    end)
end

function M.toggle() open = not open end
function M.show()   open = true  end

-- Standalone entry: original /lua run muleassist/ui behavior (own loop + binds).
function M.run_standalone()
    load_bot_ini()
    mq.bind('/maui', BindMaui)
    mq.event('NewSpellMemmed', '#*#You have finished scribing #1#.', NewSpellMemmed)
    mq.imgui.init('MuleAssist', MAUI)

    local init_done = false
    while not terminate do
        CheckGameState()
        mq.doevents()
        if not init_done then
            InitSpellTree(); InitAATree(); InitDiscTree()
            init_done = true
        end
        if memspell then
            local rankname = mq.TLO.Spell(memspell).RankName()
            mq.cmdf('/memspell %s "%s"', memgem, rankname)
            mq.delay('3s', function() return mq.TLO.Me.Gem(memgem)() and mq.TLO.Me.Gem(memgem).Name() == rankname end)
            mq.TLO.Window('SpellBookWnd').DoClose()
            memspell = nil
            memgem = 0
        end
        tloCache:clean()
        mq.delay(20)
    end
end

if not _G.MULEASSIST_EMBED then
    M.run_standalone()
end

return M
```

- [ ] **Step 4: Verify standalone still works (regression)**

Run (in-game): `/lua run muleassist/ui`
Expected: MAUI window opens exactly as before; `/maui show|hide|stop` works; editing values + the normal Save path still writes the INI. (No bot running yet, so no live apply — that is Task 6.)

- [ ] **Step 5: Commit**

```bash
git add ui/init.lua
git commit -m "refactor(ui): make ui/init.lua an embeddable module (mount/toggle)

Standalone runner guarded behind _G.MULEASSIST_EMBED; adds debounced live-apply
bridge (diff -> Save -> on_apply) used when mounted by the bot.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 6: Bot lazy-mounts the embedded panel on /maui

**Files:**
- Modify: `init.lua`

- [ ] **Step 1: Add the lazy-mount `/maui` bind**

In `init.lua`, after the `/mareload` bind added in Task 3, add:

```lua
  local ui_mod = nil
  mq.bind('/maui', function()
    if not ui_mod then
      _G.MULEASSIST_EMBED = true
      local ok, mod = pcall(require, 'muleassist.ui.init')
      if not ok then Write.Error('MAUI load failed: %s', tostring(mod)); return end
      ui_mod = mod
      ui_mod.mount{ window = 'MuleAssist', on_apply = function() st.pending_reapply = true end }
      return                       -- mount() opens the window
    end
    ui_mod.toggle()
  end)
```

(`Write` is already required at the top of `init.lua`.)

- [ ] **Step 2: In-game verification — the headline feature**

1. `/lua run muleassist/init <role>`.
2. `/maui` — the MAUI panel opens inside the bot.
3. Toggle a setting (e.g. flip `MeleeOn`, or change `AssistAt`).
4. Wait ~1 second (debounce).
Expected: console prints `[INFO] Settings reloaded from ...`; the bot's behavior reflects the change immediately; the INI on disk shows the new value; bot keeps running with camp/pull/combat state intact. `/maui` again hides the panel.

- [ ] **Step 3: In-game verification — typo safety**

1. With the panel open, type an invalid value into a numeric/spell field mid-edit.
Expected: after debounce, if it produces a load/apply error the console logs `[ERROR] settings.reapply: ...` and the bot keeps its previous good config and does not crash. Correcting the field re-applies cleanly.

- [ ] **Step 4: Commit**

```bash
git add init.lua
git commit -m "feat(init): /maui lazy-mounts embedded panel; edits live-apply to running bot

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Self-Review

**Spec coverage:**
- Re-runnable apply + runtime preservation → Task 1.
- `settings.reapply` (reload + setups, pcall-guarded, no-op on failure) → Task 2.
- `/mareload` + loop consumption (work out of bind callback) → Task 3.
- Diff + debounce pure helper, unit-tested → Task 4.
- MAUI embedding (mount/toggle, standalone guard, debounced flush→apply) → Task 5.
- Bot `/maui` lazy-mount + `on_apply`→`pending_reapply` → Task 6.
- Error handling (pcall, keep last-good) → Task 2 + Task 6 Step 3.
- Edge cases (role change, list edits, runtime preservation) → covered by apply_config/setups design; runtime preservation asserted in Tasks 1–2.
- Standalone UI unchanged → Task 5 Step 4 regression.

**Out of scope (per spec):** actors IPC, file watcher, per-key targeted re-derive.

**Type/name consistency:** `state.apply_config(st, cfg)`, `state.new(cfg)`, `settings.reapply(st)`, `st.pending_reapply`, `diff.changed/snapshot/debouncer`, `M.mount/toggle/show/run_standalone`, `_G.MULEASSIST_EMBED`, `apply_opts.on_apply`, `apply_opts.window` — used identically across tasks.
