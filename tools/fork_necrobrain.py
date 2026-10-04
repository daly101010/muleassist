"""Fork of the necrobrain SmartDPS modules into the Lua port.

Source: F:/lua/necrobrain @ 194f9a7 (branch perf/boot-fold), read via `git show`. Modules are copied
unchanged except CRLF -> LF. Tests get two header rewrites (package.path, tests.fakes). Run from the
port root: python tools/fork_necrobrain.py [--check]
"""
import os
import re
import subprocess
import sys

SRC_REPO = 'F:/lua/necrobrain'
SRC_COMMIT = '194f9a7'
PORT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MODULES = ['bridge', 'ranker', 'ttd', 'holds', 'resist', 'dpslist', 'procs', 'feed', 'history', 'logger',
           'vesagran', 'vesclaim']
TESTS = ['bridge', 'dpslist', 'feed', 'history', 'holds', 'logger', 'procs', 'ranker', 'resist', 'ttd',
         'vesclaim']
PATH_LINE = "package.path = './necrobrain/?.lua;./?.lua;' .. package.path"


def show(path):
    raw = subprocess.run(['git', '-C', SRC_REPO, 'show', f'{SRC_COMMIT}:{path}'], check=True,
                         capture_output=True).stdout
    return raw.replace(b'\r\n', b'\n')


def rewrite_test(data):
    data = re.sub(rb'^package\.path = .*$', PATH_LINE.encode(), data, flags=re.M)
    return data.replace(b"require('tests.fakes')", b"require('tests.necrobrain_fakes')")


def write(rel, data):
    dst = os.path.join(PORT, rel)
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    with open(dst, 'wb') as f:
        f.write(data)
    print('copied', rel)


def check():
    bad = 0
    for name in MODULES:
        dst = os.path.join(PORT, 'necrobrain', f'{name}.lua')
        try:
            with open(dst, 'rb') as f:
                have = f.read()
        except OSError:
            have = None
        if have != show(f'{name}.lua'):
            print('DIFFERS', f'necrobrain/{name}.lua')
            bad += 1
    return 1 if bad else 0


def main():
    if '--check' in sys.argv:
        sys.exit(check())
    for name in MODULES:
        write(f'necrobrain/{name}.lua', show(f'{name}.lua'))
    for name in TESTS:
        write(f'tests/necrobrain_{name}_test.lua', rewrite_test(show(f'tests/test_{name}.lua')))
    write('tests/necrobrain_fakes.lua', show('tests/fakes.lua'))


if __name__ == '__main__':
    main()
