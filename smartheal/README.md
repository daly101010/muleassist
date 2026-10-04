# smartheal - SmartHeals engine (fork)

Forked 2026-10-03 from `F:/lua/sidekick-next` (branch fix/review-findings @ 9021f7c plus the uncommitted
2026-09-19 SmartHeals changes in that working tree): `healing/*.lua` (minus `ui/` and `pull_monitor`) and the
helpers in `util/`. Requires were renamed by `tools/fork_smartheal.py`
(`sidekick-next.healing.X` -> `smartheal.X`, `sidekick-next.utils.X` -> `smartheal.util.X`).

Not a copy: `env.lua` (the bot adapter), `util/paths.lua` (files under `config/MuleAssist`, imported once
from `config/SideKick-Next`), and the stubs `util/sk_lib.lua`, `util/core.lua`, `util/actors_coordinator.lua`.
Edited after the copy: `mob_assessor.lua` (ImGui tab removed, data path), `logger.lua` (log directory),
`util/safe_write.lua` (one comment only: "ImGui callbacks" -> "UI draw callbacks"; the rename of the requires is the tool's).

Driven by `modules/smartheal.lua`. Spec: `muleassist/docs/superpowers/specs/2026-10-02-luaport-smartheal-fork-design.md`.
