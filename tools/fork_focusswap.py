"""Copy of F:/lua/focusswap's planner into the Lua port (spec
muleassist/docs/superpowers/specs/2026-10-03-luaport-focusswap-design.md).

Source: F:/lua/focusswap @ 7c91d84 (branch perf/scan-cost), read via `git show` so the copy does not
depend on what that shared checkout has switched to. Modules are copied byte-for-byte apart from
CRLF -> LF; the tests get the port's package.path and the tests.focusswap.* helper paths.
Run from the port root: python tools/fork_focusswap.py [--check]
"""
import os
import subprocess
import sys

SRC_REPO = 'F:/lua/focusswap'
SRC_COMMIT = '7c91d84'
PORT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MODULES = ['limits', 'plan', 'ini', 'scan']


def show(path):
    raw = subprocess.run(['git', '-C', SRC_REPO, 'show', f'{SRC_COMMIT}:{path}'], check=True,
                         capture_output=True).stdout
    return raw.replace(b'\r\n', b'\n')


def write(p, data):
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p, 'wb') as f:
        f.write(data)
    print('wrote', os.path.relpath(p, PORT))


def check():
    bad = 0
    for name in MODULES:
        dst = os.path.join(PORT, 'focusswap', f'{name}.lua')
        try:
            with open(dst, 'rb') as f:
                have = f.read()
        except OSError:
            have = None
        if have != show(f'{name}.lua'):
            print('DIFFERS', f'focusswap/{name}.lua')
            bad += 1
    return 1 if bad else 0


def main():
    if '--check' in sys.argv:
        sys.exit(check())
    for name in MODULES:
        write(os.path.join(PORT, 'focusswap', f'{name}.lua'), show(f'{name}.lua'))
    for name in ['fakes', 'fixtures']:
        write(os.path.join(PORT, 'tests', 'focusswap', f'{name}.lua'), show(f'tests/{name}.lua'))
    for name in ['ini', 'limits', 'plan', 'scan']:
        text = show(f'tests/test_{name}.lua').decode('utf-8')
        text = text.replace("package.path = './?.lua;../?.lua;' .. package.path",
                            "package.path = './?.lua;./?/init.lua;' .. package.path")
        text = text.replace("require('tests.fakes')", "require('tests.focusswap.fakes')")
        text = text.replace("require('tests.fixtures')", "require('tests.focusswap.fixtures')")
        text = text.replace('(from F:\\lua\\focusswap)', '(from lua/muleassist)')
        write(os.path.join(PORT, 'tests', f'focusswap_{name}_test.lua'), text.encode('utf-8'))


if __name__ == '__main__':
    main()
