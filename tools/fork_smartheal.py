"""One-off fork of sidekick-next's SmartHeals engine into the Lua port (spec
muleassist/docs/superpowers/specs/2026-10-02-luaport-smartheal-fork-design.md).

Copies the files ON DISK in F:/lua/sidekick-next (9021f7c + the uncommitted 2026-09-19 SmartHeals
changes) and renames module paths. Run from the port root: python tools/fork_smartheal.py
"""
import os

SRC = 'F:/lua/sidekick-next'
PORT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DST = os.path.join(PORT, 'smartheal')

ENGINE = ['init', 'config', 'heal_selector', 'hot_analyzer', 'proactive', 'heal_tracker', 'persistence',
          'target_monitor', 'incoming_heals', 'combat_assessor', 'analytics', 'spell_events',
          'damage_parser', 'damage_attribution', 'mob_assessor', 'logger']
UTIL = ['lazy_require', 'safe_write', 'logger', 'debug_log', 'named_detector', 'healer_classes',
        'ma_bridge_state']

# Order matters: the bare engine module before the generic sidekick-next prefix.
RULES = [
    ('sidekick-next.healing.', 'smartheal.'),
    ("'sidekick-next.healing'", "'smartheal'"),
    ('sidekick-next.utils.', 'smartheal.util.'),
    ('sidekick-next.', 'smartheal.util.'),
]


def rename(text):
    for old, new in RULES:
        text = text.replace(old, new)
    return text


def copy(src, dst):
    with open(src, 'rb') as f:
        data = f.read().decode('utf-8')
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    with open(dst, 'wb') as f:
        f.write(rename(data).encode('utf-8'))
    print('copied', os.path.relpath(src, SRC), '->', os.path.relpath(dst, PORT))


def main():
    for name in ENGINE:
        copy(f'{SRC}/healing/{name}.lua', os.path.join(DST, f'{name}.lua'))
    for name in UTIL:
        copy(f'{SRC}/utils/{name}.lua', os.path.join(DST, 'util', f'{name}.lua'))
    copy(f'{SRC}/tests/smartheal_regression_test.lua', os.path.join(PORT, 'tests', 'smartheal_regression_test.lua'))


if __name__ == '__main__':
    main()
