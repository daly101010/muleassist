# focusswap - FocusSwap planner (copy)

Copied from `F:/lua/focusswap` @ 7c91d84 (branch `perf/scan-cost`, on `feat/focusswap` @ 530f365: a
cheaper scan and fingerprint) by `tools/fork_focusswap.py`, byte-for-byte apart from CRLF -> LF:
`limits.lua`, `plan.lua`, `ini.lua` (pure) and `scan.lua` (the TLO reader). The script reads the source
with `git show` (edit `SRC_COMMIT` to move); `python tools/fork_focusswap.py --check` exits 1 if a module
differs, and `tests/focusswap_fork_test.lua` runs it. Do not edit the copies here; change the source repo
and re-fork.

focusswap's standalone `init.lua` is replaced by `modules/focusswap.lua`, which plans in-process and does
the swap from the cast engine's `preCast` hook. Tests: `tests/focusswap_*_test.lua` (ported) and
`tests/focusswap_module_test.lua`. Spec: `muleassist/docs/superpowers/specs/2026-10-03-luaport-focusswap-design.md`.
The macro still uses `F:/lua/focusswap`.
