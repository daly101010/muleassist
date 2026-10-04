# muleassist (Lua)

The Lua port of `muleassist.mac`, module by module. Design and porting order:
`muleassist/docs/superpowers/specs/2026-10-02-lua-port-design.md`.

## Status

Step 1: core (INI-compatible config, line parsing, timers, comms, spell facts, cast engine v1, module
framework, DanNet observer sets, the `MuleAssist` TLO) and the **cures** module.
Step 2: **report** (`/healreport`, the fight-end one-liner with `HealReportOnEnd=1`, the 1 s status line in
`${MuleAssist.Status}`), **med** (DoWeMed, SitToMed, GroupWatch, WaitForMedders), **buffs** (self, group, the
heal tank, pet, out-of-group names / XTarget slots / DanNet peers / raid / fellowship / range, the shared
KissAssist_Buffs.ini toons, Mana / Managroup / Endgroup lines, auras, Once, End, Summon, mounts, the power
source, worn-off rebuffs, beg buffs) and **cast engine v2** (memorising into MiscGem and putting the
original back, the already-has-it / stacking / level checks, invis and chase holds, fizzle and resist
retries, the buff interrupt).
Step 3: **combat** (CheckRoles, the kill-target pick with the MA's named / mez-immune / closest-to-camp
ranking, ValidateTarget, StuckKillTarget, MobRadar, HomogenizeMainTarget, CANSTARTCOMBAT, the fight as one
pass per tick, CombatReset, [Aggro], TankAllMobs, the [DPS] |mash and |weave lines, [Bandolier], the rogue
opener and backstab swap, the heal-tank sync, the TANKING / TooFar / CantSee / GotHit / ImDead events),
**movement** (camp, ReturnToCamp with the leash, ChaseAssist with the stuck check and the left-behind
notice, MoveForCast, RunToTank, the campfire) and **pet** (summon with the focus-item swap and the
Companion's Suspension pair, PetAttackSafe and the protect list, CombatPet, BreakMez, the stances).
Step 4: **heals** (CheckHealth with the self / heal-tank / most-hurt / XTarget tiers and HealsOn 1-3,
SingleHeal with every tag: me, ma, !ma, pet, !pet, tap, mob, buff!= / buff==, the group heals, the pet
heals, the fresh-add hold, the SmartHeals engine (`modules/smartheal`), the heal interrupt rules, ManaFeed), **rez** (the battle
rez per member with RezPolicy and the REZCLAIM hold, my own corpse, the out-of-combat rez of guild /
fellowship / XTarget / peer / raid corpses, the rogue corpse drag), **healeraggro** (HEALERAGGRO-> from the
healer, the [HealerAggro] tools on the tank side, FreshAddCheck, HealerDown, the feign hold and stand) and
**ohshit** (the [OhShit] list before every cast and every pass).
Step 5: **dps** (CombatCast with the Me / MA / Feign / util / once / spam / <PC> targets and the if / notif
/ ifme / notifme conditions, the time-to-death estimate and its calibration, the DPS cast interrupt,
CheckForAdds, the AutoFire / StayAwayToCast stance, the [AE] list, the burn with /burn, the |Burn this|
line and NamedWatch, Gift of Mana, the resist-list binds), **debuffs** (the `debuffall` lines with the
strip / slow / tash / malo / crip / snare / always tags on the kill target and the adds), **mez** (MezRadar,
MezNeeded, the AE stun, the AE mez, the single-mez walk, the XTarget-slot mode, Event_MezBroke, the
MEZZING2-> / CCCLAIM-> / CCRELEASE-> protocol, the per-zone immune lists with /mezimmune /charmimmune
/addimmune) and **charm** (the protect list over /charmthis /charmadd /charmdel /charmping /charmsync, the
watchdog, AutoCharmPick, the recharm with stun / short mez / retash, the charm pet heal, /autocharm
/charmhold).
Step 6: **raid** (/changema with the out-of-group XTarHeal seat, the group-window MA tag, the raid aggro
pause for WAR/SHD/PAL, XTarTanks for CLR/SHM/DRU, /raidmode on|off|all, /raidtank), **modes** (kill order,
mark assist, get away, manual mode and manual follow, the MobsToProtect / MobsToIgnore / MobsToPull zone
lists with /addprotect /addignore /addpull, ProtectWatch) and **misc** (the trade accept, the stuck cursor,
zombie mode, /groupcheck, /writespells /memmyspells and [SpellSet], /iniwrite, /customcall with an optional
custom.lua, the OnStart commands, the small events).
Step 7: **pull** (SetPullRange from PullWith: melee, a ranged item with its ammo, a clicky, a spell / AA /
disc, the pet; FindMobToPull with the camp-centred scan, the nav path-length order, PullNamedsFirst,
PullValidate, the MobsToPull / secondary lists, the FailMax skip set and the PullWait respawn wait; Pull with
the nav or moveto walk out, the stuck escape, the aggro and camp checks, the pull by melee / ranged / pet /
cast with UseCalm, the CantHit / CantSee / TooClose / TooFar events; WaitForMob with the walk home and the
puller / pullertank / pullerpettank wait rules; chain pulling with the Combat probe, ChainPullHP and the
ChainPullPause schedule; the pull arc with /setpullarc; GrabTheDead; TogglePullMode; /pull; /masspull;
/maxradius; /maxzrange; the hunter roles). Every box can run on the Lua now.

What changed on purpose in the port (not bugs to report):
- a buff pass advances one cast per tick, so heals and cures keep their turn between buffs;
- per-target buff timers (`buff:<line>:<spawn id>`) replace the `Buff<i>GM<j>` variables and cover OOG
  targets too, so a buffed stranger is not re-targeted every pass;
- a buff the target already has / cannot take returns `CAST_SKIPPED` instead of `CAST_SUCCESS`;
- settings load reads the character INI once per round (the start, `/muleassist reload`): `core/ini.lua` parses
  the file the way GetPrivateProfileString does and answers every Config read from it, instead of one
  `mq.TLO.Ini` read per key; writes still go through `/ini`. A key already in the file is never written back,
  even when it reads as NULL or empty (the macro rewrote such keys at every start); only absent keys get
  their default;
- the class / caster / Melee tags apply to raid, fellowship and range buffing with or without BuffsCOn;
- group-watch and regen thresholds compare percentages (the macro compared raw mana values);
- BuffsCond expressions may use `${Buffee}` / `${BuffeeLevel}`: they are substituted before the parse;
- the fight is one pass per tick instead of the macro's blocking :Attack loop, so heals, cures and buffs keep
  their turn mid-fight; the pet summon, the suspend pair and the chase stuck check are sequenced the same way;
- subsystems not ported yet (DPS casts, AE, debuffs, mez, burns, ohshit, charm, pull, kill order, mark assist,
  manual, get away, healer aggro) are hooks in `combat.hooks` with no-op defaults;
- a chase that stalls (the MA jumped 300+ or RTC leashed out) waits instead of turning ChaseAssist off;
- the live AggroTargetID is the first Auto Hater NPC on XTarget, scanned at most every 100 ms;
- heal timers are per line and per target spawn (`heal:<line>:<id>`) instead of the Spell<i>GM<slot> sets;
  an interrupted heal counts as interrupted, not landed; a failed Tap / Mob cast does not fall through into
  the direct-heal block; RezCheck runs once per heal pass; SmartHeals runs in-process: `smartheal/` is
  the engine forked from sidekick-next (`smartheal/README.md`) and `modules/smartheal.lua` does the old
  bridge's job, handing picks to the heals module directly (`/smarthealson off` pauses the engine: it stays
  loaded with its events, and nothing restarts on re-enable); files live under `config/MuleAssist/` (imported
  once from `config/SideKick-Next/`), so the Lua bot needs nothing from sidekick-next to smart-heal;
- FocusSwap runs in-process: `focusswap/` holds the planner modules copied from `F:/lua/focusswap`
  (`focusswap/README.md`) and `modules/focusswap.lua` plans the map and swaps the focus item in from
  `Cast.hooks.preCast` right before a gem cast (`[FocusSwap] FocusSwapOn`; `/focusswap dump | rebuild | stop`),
  so the Lua bot needs no separate focusswap script;
- The heal ledger runs in-process: `[Heals] HealBrainOn=1` (`/healbrainon`) makes every Lua box ship heal
  snapshots (`modules/healagent.lua`) to the brain on the MA's box (`modules/healbrain.lua`: the "Raid Heal
  Ledger" window, `/healbrain`, rows in `config/MuleAssist/HealingLogs/heal-ledger-<date>.jsonl`); the library is
  copied from sidekick-next (`healledger/README.md`). Lua bots only: macro boxes use sidekick-next's agent/brain.
  The brain idles (no mailbox, no heartbeat, window hidden) while HealBrainOn is off or another box is the MA.
  `/healbrain stop` idles it too and prints the night report; it resumes only on `/healbrain start` (which says
  whether it resumed or why it is still idle) or on HealBrainOn going off and back on (`/healbrainon off`, then
  `on`). Both modules keep ticking while a long wait blocks the main loop: the cast engine runs its tick hooks
  (`Cast.addTickHook`) in the cast bar and its long waits (settle, cooldown, ready, memorising, misc gem), and the
  modules' own waits of 5 s or more (pull, rez, movement, buffs ...) go through `Cast.tickDelay`. Waits of 1-2 s
  or less (targeting, standing up, buff-populate, the skill/AA ready flips, /stopcast) are not sampled.
- an [OhShit] command entry's target is the pipe field after the command, and OhShitCOn gates the
  conditions like every other *COn;
- DPS timers are `dps:<line>:<target id>` and die with the fight; a |weave line lives only in the weave list;
  the "no PvP target" test skips a PC's pet, not a PC (what the macro's NULL master did);
- SmartDPS runs in-process: `[DPS] SmartDPSOn=1` runs necrobrain's picker inside the bot
  (`modules/smartdps.lua` over `necrobrain/`, forked from F:/lua/necrobrain @ 194f9a7). It hands dps.lua its pick
  through `Dps.smartSet` ({ spell, targetId, mode, seq, beat, ranked }) and dps.lua reports each verdict back
  through `smartdps.onResult` (there is no actor mailbox). `/necrobrain` and `/nbmob` work as before. It needs
  MALua (or companion/maui) running for the parse feed, and companion's `EVENT_CONSUMERS` must list `muleassist`
  (branch feat/muleassist-event-consumer in F:/lua/companion) for the landed/resisted feed: until that is merged
  picks still flow, but without live resist and DoT data, and `/necrobrain diag` shows the feed counters at 0.
  Calbuss and Beyonce run the Blade of Vesagran rotation (`/vesclaim`) with Parsaxx's medley; it needs no
  SmartDPSOn. Lua bots only;
- the mez hater table is a Lua list, my mez timers are `mez:<row>`, claims are `mezclaim:<id>`; the zone
  immune names are rebuilt per zone (no leak from the last zone); MezStopHPs drops to 1 only while the MA is
  out of zone; the debuff wait for a cooling line is one delay with a ready condition, not a busy loop;
- the zone lists are read under the short zone name (the long name as a fallback), so /addignore and
  /addpull write where the next start reads; /addignore refreshes the alert list at once; AA and level
  gains are announced over DanNet too; the custom hook is a Lua module (custom.lua beside the script with
  `call(name, param)` and `tick()`), not custom.inc; LocKill (never called by the macro) is not ported;
- the mobs a failed pull put on alert list 1 are a Lua skip set (`pull:skip:<id>` timers, cleared by FailMax,
  on zone and by /addpull); the MQ2AdvPath pull path is not ported (nav or moveto only); a hunter's inline
  fight is left to the combat module; the pull loops are bounded by the pull timer instead of open-ended;
- the 100 ms loop is throttled where the macro's slower pass was not: the XTarget scan (slots, haters) and
  the group id set are cached 100 ms; the mez radar 200 ms; the AE scan 300 ms; the rez check, the idle
  med group scans, the chain-pull scan and the pull rescan once a second; the pull range is recomputed
  only when PullWith / MaxRadius / the role change (or every 30 s); the MA and the heal tank are looked up
  by id; a follower reads the MA's kill target from a `/dobserve` of `MuleAssist.Target` instead of a
  `/dquery` with a delay; the heal ladder re-passes only after a heal landed; a dry pull scan waits a
  second and FailMax (3) dry scans trigger the PullWait announce; expired timers are swept once a minute.

## Install

The script lives in the macros repo. Either add `F:\macros\lua` to MQ's `luaRequirePaths`, or link it:

```
mklink /D F:\lua\muleassist F:\macros\lua\muleassist
```

Run with `/lua run muleassist`. It refuses to start while `muleassist.mac` runs on the same box.

Commands: `/muleassist [pause|resume|reload|stop]`, `/whynot`, `/healreport [reset|bc|all]`, `/cureson [0|1]`,
`/buffson`, `/xtarbuff`, `/dannetbuff`, `/buffwhilechase`, `/rebuffon`, `/buffmode [on|off]`, `/buffgroup`,
`/medstart N`, `/waitformedders [on|off]`, `/waitformeddersmax N`, `/waitformeddersskipma N`, `/pullernoselfmed`,
`/groupwatchresume N`, `/switchnow [id]`, `/maswitch` (peer protocol), `/backoff [temp|off]`, `/aggrotaunt [on|off]`,
`/changema [name]`, `/stickhow [all] <args>|off [save]`, `/assistat N`, `/meleedistance N`, `/meleeon [on|off]`,
`/autofireon`, `/raidtank [all] off|auto|<name>`, `/camphere`, `/returntocamp [on|off]`, `/chase [on|off|name]`,
`/chaseon [name]`, `/chaseoff`, `/chasedistance N`, `/campradius N`, `/goback`, `/campfire`, `/shakeloose`,
`/peton [on|off]`, `/pethold [on|off]`, `/movewhenhit`, `/healson [on|off]`, `/smarthealson [on|off]`, `/manafeed`,
`/autorezon [on|off]`, `/dpson [on|off]`, `/dpsinterval N`, `/dpsskip N`, `/aeon [on|off]`, `/burn`, `/addfire` ..
`/addpoison [zone]`, `/mezon [on|off]`, `/mezimmune`, `/charmimmune [list|add|del|reload|clearsession]`,
`/addimmune [id]`, `/charmthis [id|clear|clearall]`, `/charmadd id`, `/charmdel id|all`, `/charmsync`,
`/autocharm`, `/charmhold [on|off]`, `/killorder add|del|up|down <id|name> | clear|on|off|list`, `/killordermaxdist N`,
`/markassist [on [1-3]|off]`, `/getaway [on|off]`, `/manual [on|off]`, `/addprotect [id]`, `/addignore [id]`, `/addpull id`,
`/raidmode [on [1-3]|off|all on|off]`, `/xtartanks [on|off]`, `/zombiemode [off]`, `/groupcheck`, `/writespells`,
`/memmyspells [name|file]`, `/iniwrite <Section> spell <gem>|aa <name>|item|disc <n>`, `/customcall <name> [param]`,
`/muleedit`, `/pull`, `/masspull <spell> <num> <min level> <max level> <max dist>`, `/setpullarc <width> [dir|n|ne|..]`,
`/maxradius N`, `/maxzrange N`.

`/changevarint <Section> <Name> <Value> [chase name]` and `/togglevariable <Name> [on|off|0|1] [name]` (plus
`/togglevariable conditions all|dps|heals|burn|buffs|gom on|off`) are the macro's generic setting binds, which
MacroQuest.ini [Aliases] route most per-setting commands onto (`/chaseon=/changevarint General ChaseAssist 1`).
A setting with a dedicated bind goes through it (ChaseAssist -> `/chase`, ReturnToCamp -> `/camphere`, BuffsOn ->
`/buffson` ...); any other key a module's Settings declares is set in every module that holds it. `/changevarint`
writes the INI, `/togglevariable` is session-only unless the dedicated bind saves. Unknown names and internal
combat state (MyTargetID, IAmDead ...) are refused.

The TLO: `${MuleAssist.Status}`, `${MuleAssist.HealStats}`, `${MuleAssist.Debuffs}` (observed by peers with
`/dobserve <peer> -q "MuleAssist.Debuffs"`), `${MuleAssist.Role}`, `${MuleAssist.MainAssist}`,
`${MuleAssist.HealTank}`, `${MuleAssist.Target}` (my kill target id, the macro's MyTargetID that
HomogenizeMainTarget queries), `${MuleAssist.Paused}`, and `${MuleAssist.Var[Name]}`: the macro-variable view for MALua
(the names muleassist.mac exposed as macro variables, same value formats: `Role`, `MainAssist`, `MyTargetID`,
`ChaseAssist`, `ReturnToCamp`, `ManualOn`, `AggroPaused`, `GetAwayOn`, `KillOrderOn`, `KillOrderTarget`, `KillOrderList`,
`KillOrderMaxDist`, `MarkAssistOn`, `RaidMarkNum`, `MezImmuneIDs`, `CharmSkipIDs`, `BuffMode`, `ZombieMode`; an
unknown name reads NULL). Peers read it with `/dobserve <peer> -q "MuleAssist.Var[KillOrderList]"`.

Casting stops movement first: stick, nav and `/afollow` pause, a `/moveto` is turned off, and a cast with a cast
time waits until the character has stopped (up to 1.5 s), then `[General] CastSettleMs` more (default 150, 0 = no
settle, at most 2000) so the server has it stopped before the cast starts. Raise it if casts started after a chase
or a move still get interrupted; `/changevarint General CastSettleMs 300` changes it live. Instant spells and bard
songs do not wait.

Launch arguments work as the macro's did: `/lua run muleassist <role> [main assist] [rmark N]` overrides
`[General] Role` and `MainAssist` for the session, and `rmark N` (1-3) turns mark assist on from launch.

## Tests

```
cd F:\macros\lua\muleassist
for t in core cures report buffrules cast buffs med movement combat pet heals dps modes pull smartheal_fork smartheal_regression smartheal_module focusswap_ini focusswap_limits focusswap_plan focusswap_scan focusswap_module healledger healagent healbrain smartdps necrobrain_bridge necrobrain_dpslist necrobrain_feed necrobrain_fork necrobrain_history necrobrain_holds necrobrain_logger necrobrain_procs necrobrain_ranker necrobrain_resist necrobrain_ttd necrobrain_vesclaim; do luajit tests/${t}_test.lua; done
```

The tests use `tests/stub_mq.lua`, a fake `mq` with a table-driven TLO tree, and `tests/world.lua`, a fake
game (me, my spells and buffs, my group, spawns, XTarget haters, the MA's target, the target window, a cast
bar, heals that land when the bar completes, corpses, `/target` `/memspell` `/attack` `/stick` `/nav`
`/pet` side effects), so a buff pass, a med cycle, a cast, a fight from the pick to the reset, a pet summon,
a heal pass, a battle rez, a healer-aggro report, a DPS pass, a debuff, a mez with its claims, a charm, a kill
order, a mark, a manual follow, a get away, an XTarTanks pin and a pull with the walk home run end to end
without the game.
