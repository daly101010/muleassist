# healledger - raid heal gap ledger (copy)

Copied 2026-10-03 from `F:/lua/sidekick-next` branch origin/feat/heal-ledger @ 6a94070 by
`tools/fork_healledger.py`, byte-for-byte: `ledger.lua` (was `utils/heal_ledger.lua`: the world model and the
gap detectors, pure Lua) and `store.lua` (was `utils/heal_ledger_store.lua`: JSON + JSONL writer).
Driven by `modules/healagent.lua` (every box, `[Heals] HealBrainOn=1`) and `modules/healbrain.lua` (the MA's
box: the "Raid Heal Ledger" window, `/healbrain`). Spec: `muleassist/docs/superpowers/specs/2026-10-03-luaport-healledger-design.md`.
The macro still uses sidekick-next's ma_healagent / ma_healbrain.
