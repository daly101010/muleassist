# Live Settings Reload — Design

**Date:** 2026-06-05
**Status:** Approved (brainstorming) — ready for implementation plan
**Goal:** Edit a setting in MAUI and have it take effect on the running bot immediately
*and* be written to the INI — no restart, no Save button.

---

## Problem

Config is a one-way snapshot at launch:

- `config.load(path)` parses the INI once → `cfg`
- `state.new(cfg)` reads every setting + list into `st` once
- each module's `setup(st)` derives its entries (buff/heal/dps/aggro/pull range/arc) once
- the main loop and the four binds (`/maquit`, `/maburn`, `/macamp`, `/macamphere`)
  only ever read/flip `st.*` runtime fields — they never re-read `cfg`

So hand-editing the INI, or saving from the standalone MAUI, has **zero effect** on a
running bot until `/maquit` + relaunch. Moving to Lua should let us change settings on
the fly; this design delivers that.

## Scope

- **In:** re-runnable config application on the bot; a `/mareload` bind; embedding the
  MAUI config panel inside the bot process so per-field edits apply live + persist to INI.
- **Out:** cross-character/remote editing over actors IPC (Approach B); file-watcher
  auto-reload. Both explicitly declined.
- **Decision (UI hosting):** Approach A — embed MAUI in the bot (shared Lua state, no
  IPC). The standalone `/lua run muleassist/ui` remains for offline editing.

## Architecture

### 1. Re-runnable config application (bot side)

Split `state.new` so the config-derived half can run again without discarding runtime:

- `state.apply_config(st, cfg)` — **re-runnable.** (Re)assigns every config-derived field
  on the *existing* `st`: `st.flags`, `st.combat` config scalars, `st.heal`/`st.buff`/
  `st.rez`/`st.pet`/`st.med`/`st.move` config fields, `st.camp.radius`/`exceed`,
  `st.pull` config fields, and `st.lists.*`. Does **not** touch runtime fields.
- `state.new(cfg)` — calls `apply_config(st, cfg)`, then initializes runtime-only fields
  once (camp x/y/z, pull/combat state machines, all `timers`, `dragging`,
  `main_assist_id`, `running`, `hooks`).

**Runtime fields preserved across a reapply** (must live outside `apply_config`):
`st.running`, `st.hooks`, `st.camp.x/y/z`, `st.main_assist_id`, `st.med.medding`,
all `*_timers`/`timers`/`read_deadline`/`oog_timers`, and every `st.combat`/`st.pull`
runtime field (`state`, `target_id`, `aggro_target_id`, `combat_start`, `dps_timers`,
`entries`/`debuffs`/`aggro`/`burn` are rebuilt by setups, so they may be cleared,
`dragging`, `chain_*`, `attempts`, etc.).

### 2. `settings` module

New `settings.lua`:

- `settings.reapply(st)` — `config.load(path)` → `apply_config(st, cfg)` → re-run every
  module `setup(st)` (`heal`, `buff`, `petbuff`, `combat`, `pull`; cast scratch-gem
  fields re-read as in `init.lua`). The `cfg` itself is validated first (parse succeeded,
  required sections present); the whole sequence is wrapped in `pcall`. On error logs
  `Write.Error` and **keeps the running `cfg`** — i.e. reapply is a no-op on failure so
  the bot keeps its last-good config. `st` is never replaced (the loop/binds hold its
  reference); only its config-derived subtables are reassigned, and only from a cfg that
  already parsed cleanly. Path resolved the same way `init.lua` does.
- Exposes the INI path + a settable `on_error` hook for tests.

### 3. `/mareload` bind

In `init.lua`: `mq.bind('/mareload', function() st.pending_reapply = true end)`. The main
loop consumes `st.pending_reapply` once per tick and calls `settings.reapply(st)`. (Doing
the work in the loop slot, not the bind callback, keeps casting/yielding out of restricted
contexts.) Covers hand-edits and is the manual safety net.

### 4. MAUI embedding (Approach A)

Refactor the UI so the bot can host it without the standalone loop running at `require`:

- Move the bottom-of-file runner — `mq.imgui.init('MuleAssist', MAUI)`, the
  `while not terminate` loop, and the gem-mem block — into a new `ui/standalone.lua`.
- `ui/init.lua` becomes a module: **no top-level loop**, exports `ui.mount(opts)` and the
  `MAUI` draw function.
- `ui.mount(opts)` registers the ImGui callback once and accepts:
  - `opts.config` — the table to edit (standalone: its LIP config; bot: a table seeded
    from the bot's INI).
  - `opts.on_apply()` — called after a debounced flush (standalone: writes INI only;
    bot: sets `st.pending_reapply = true`).
- `ui/standalone.lua` calls `ui.mount{ config = <LIP>, on_apply = <write INI> }` and runs
  the keep-alive loop — preserving today's `/lua run muleassist/ui` behavior.
- The bot calls `ui.mount{ config = <seed>, on_apply = function() st.pending_reapply = true end }`
  in `init.lua` and adds **`/maui`** to toggle the window's `open` flag.

### Data flow on each edit

1. Widget change → `globals.Config[section][key]` updates that frame (existing behavior).
2. After drawing, the UI diffs `globals.Config` against a `last_applied` snapshot. Any
   difference sets `dirty = true` and resets a **~750 ms debounce timer**.
3. Timer fires with no further edits → flush `globals.Config` → INI (LIP, as Save does
   today), then call `opts.on_apply()`.
4. Bot: `on_apply` sets `st.pending_reapply`; next loop tick runs `settings.reapply(st)`,
   re-reading the just-written INI. Running bot now matches the edit; INI matches too.

Debounce collapses a flurry of edits (and mid-typing keystrokes) into one apply, avoiding
setup thrashing. The diff-snapshot avoids instrumenting all ~15 widget call sites.

## Error handling

- **Bad value mid-edit** (half-typed spell, out-of-range number): `config.load` is
  validated and the `apply_config` + setups sequence is `pcall`-guarded. A clean parse
  that produces a junk *entry* (e.g. unknown spell) is tolerated the same way startup
  tolerates it — the entry simply no-ops at cast time. A parse/apply *error* logs and
  leaves the prior config in place (reapply no-ops). `st` is never replaced, so the
  loop/binds keep working regardless. Bot never crashes from a UI typo.
- **INI write failure** (locked file/disk): LIP flush in `pcall`; on failure log and keep
  `dirty = true` to retry next debounce.
- **Reentrancy:** reapply runs in the main-loop slot, never inside the ImGui draw
  callback. The UI only sets a flag.

## Edge cases

- **Role change live:** re-running setups flips `is_puller`/tank gating; an in-flight pull
  resets via `pull.reset` if the new role isn't a puller.
- **List edits:** add/remove a buff/heal/dps row → `setup` rebuilds `entries`; timers
  keyed by stale indices cleared on reapply.
- **Camp/pull/combat runtime:** survives reapply (lives outside `apply_config`).
- **Standalone UI:** offline editing still just writes INI; applied on next launch or
  `/mareload`.

## Testing (offline, `tests/run`)

- **`test_state`:** `apply_config` idempotent — call twice, assert identical
  config-derived fields. Mutate a cfg value (`AssistAt`) + a list, `apply_config` again,
  assert config updates while a sample runtime field (`st.camp` stub, `st.pull.state`)
  persists.
- **`test_settings`** (new): build cfg, `state.new`, mutate value + list, `settings.reapply`
  with an injected mq-free config-loader stub, assert entries rebuilt and runtime preserved.
- **Diff/debounce** factored into a pure helper (`ui/diff.lua` or in `settings`) so it's
  unit-testable without ImGui: feed two config snapshots → expect changed-key set;
  debounce state machine over a fake clock.
- **In-game:** `/maui` toggle a flag → bot reacts within ~1 s + INI updated; `/mareload`
  after a hand-edit; a typo in a field does not crash the bot.

## Out-of-scope follow-ups

- Actors IPC for remote/cross-character editing (Approach B/C).
- Per-key targeted re-derive (dispatch map) instead of full re-setup, if reapply ever
  proves too heavy (it won't at human edit cadence).
