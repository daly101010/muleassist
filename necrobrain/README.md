# necrobrain (forked modules)

Source: `F:/lua/necrobrain` @ `194f9a7` (branch `perf/boot-fold`, on `feat/gom-chaos` @ afdb330: the snapshot resist fold runs once).

Modules here (`bridge ranker ttd holds resist dpslist procs feed history logger vesagran vesclaim`) are
byte-identical to 194f9a7 apart from CRLF -> LF. `tests/necrobrain_fork_test.lua` checks that (via
`python tools/fork_necrobrain.py --check`) and that none contains CR. Do not edit them here; change the
source repo and re-fork.

`init.lua` is not copied: `modules/smartdps.lua` replaces it.

## Re-forking

    cd lua/muleassist
    python tools/fork_necrobrain.py          # copy modules + tests from 194f9a7 (edit SRC_COMMIT to move)
    python tools/fork_necrobrain.py --check  # exit 1 if a module differs from 194f9a7

## Tests

Ported as `tests/necrobrain_<name>_test.lua` plus `tests/necrobrain_fakes.lua` (copy of the fork's
`tests/fakes.lua`, LF only). Header rewrites applied by the script, and nothing else:

- every `package.path = ...` line becomes `package.path = './necrobrain/?.lua;./?.lua;' .. package.path`
- `require('tests.fakes')` becomes `require('tests.necrobrain_fakes')`

Test-only fixes: none needed. All eleven ported tests pass under Lua 5.4 and LuaJIT unchanged. No test
writes under the real `F:/Config` (the fakes' `configDir` is only used to build keys for an in-memory store;
dpslist and logger tests use temp files).
