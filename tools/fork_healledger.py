"""One-off copy of the heal ledger library from sidekick-next origin/feat/heal-ledger into the Lua port
(spec muleassist/docs/superpowers/specs/2026-10-03-luaport-healledger-design.md). The library is copied
byte-for-byte (CRLF -> LF); the test gets the port's package.path and the healledger.* require.
Run from the port root: python tools/fork_healledger.py
"""
import os
import subprocess

REPO = 'F:/lua/sidekick-next'
REF = 'origin/feat/heal-ledger'
PORT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def show(path):
    return subprocess.run(['git', '-C', REPO, 'show', f'{REF}:{path}'], check=True, capture_output=True).stdout


def write(rel, data):
    p = os.path.join(PORT, rel)
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p, 'wb') as f:
        f.write(data.replace(b'\r\n', b'\n'))
    print('wrote', rel)


def main():
    write('healledger/ledger.lua', show('utils/heal_ledger.lua'))
    write('healledger/store.lua', show('utils/heal_ledger_store.lua'))
    test = show('tests/heal_ledger_test.lua').decode('utf-8')
    test = test.replace("package.path = '../?.lua;../?/init.lua;' .. package.path",
                        "-- lua tests/healledger_test.lua   (from lua/muleassist)\npackage.path = './?.lua;./?/init.lua;' .. package.path")
    test = test.replace("require('sidekick-next.utils.heal_ledger')", "require('healledger.ledger')")
    write('tests/healledger_test.lua', test.encode('utf-8'))


if __name__ == '__main__':
    main()
