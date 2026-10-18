#!/usr/bin/env python3
"""Copy the license texts of every bundled dylib into ThirdPartyNotices/Libraries.

The libraries come from Dependencies.lock.json (Homebrew kegs plus the project-built libmpv);
each keg's COPYING / LICENSE / COPYRIGHT files are copied unchanged, and Libraries/README.md
lists library, formula, version and SPDX license. Fails if a bundled library has no text.
"""
import json
import pathlib
import re
import shutil
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
NOTICES = ROOT / 'ThirdPartyNotices'
OUTPUT = NOTICES / 'Libraries'
LICENSE_FILE = re.compile(r'^(COPYING|LICEN[CS]E|COPYRIGHT)([.-][A-Za-z0-9.-]+)?$', re.I)
# A file that only says where the license is ("see the file LICENCE", "found in docs/FTL.TXT").
POINTER = re.compile(r'see the file|found in the file|found in\s+`?docs/|Read the file', re.I)
NOT_LICENSE = {'.cfg', '.py', '.sh'}  # tool configuration that happens to start with "license"
# Kegs that ship no license file: point at the identical text already kept in ThirdPartyNotices.
FALLBACK = {'glib': ('LGPL-2.1', NOTICES / 'mpv-LICENSE.LGPL')}
# Dual-licensed kegs whose own file only describes the choice: the option taken and its full text.
CHOSEN = {'freetype': ('GPL-3.0', ROOT / 'LICENSE',
                       'FreeType is dual-licensed (FTL or GPL-2.0-or-later, see LICENSE.TXT). Manping, a\n'
                       'GPL-3.0 program, uses it under the GPL option, version 3; the full text is in\n'
                       'COPYING.GPL-3.0. Portions of this software are copyright (C) The FreeType\n'
                       'Project (https://freetype.org). All rights reserved.\n')}


def main():
    lock = json.loads((ROOT / 'Dependencies.lock.json').read_text())
    formulae = {item['name']: item for item in json.loads((NOTICES / 'HomebrewFormulae.json').read_text())}
    kegs = {}
    for item in lock['libraries'] + [lock['ffmpegExecutable'] | {'library': 'ffmpeg (executable)'}]:
        match = re.match(r'/opt/homebrew/Cellar/([^/]+)/([^/]+)/', item['source'])
        if match:
            kegs.setdefault((match.group(1), match.group(2)), []).append(item['library'])
        elif item['library'] != 'libmpv.2.dylib':
            sys.exit(f'unknown library source: {item["source"]}')
    if OUTPUT.exists():
        shutil.rmtree(OUTPUT)
    OUTPUT.mkdir()
    rows, missing = [], []
    for (name, version), libraries in sorted(kegs.items()):
        keg = pathlib.Path('/opt/homebrew/Cellar') / name / version
        target = OUTPUT / f'{name}-{version}'
        target.mkdir()
        copied = [path for path in sorted(keg.iterdir()) if path.is_file() and LICENSE_FILE.match(path.name)
                  and path.suffix.lower() not in NOT_LICENSE]
        for path in copied:
            shutil.copy2(path, target / path.name)
        if name in CHOSEN:
            label, text, note = CHOSEN[name]
            shutil.copy2(text, target / f'COPYING.{label}')
            (target / 'CHOICE.txt').write_text(note)
            copied += [target / f'COPYING.{label}', target / 'CHOICE.txt']
        if not copied and name in FALLBACK:
            label, text = FALLBACK[name]
            shutil.copy2(text, target / f'COPYING.{label}')
            copied = [target / f'COPYING.{label}']
        if not any(not POINTER.search(path.read_text(errors='ignore')) for path in copied):
            missing.append(f'{name} {version}')  # nothing copied, or only pointers to texts not shipped
        license = CHOSEN[name][0] + '（双许可之一）' if name in CHOSEN else formulae.get(name, {}).get('license', '?')
        files = ', '.join(f'`{name}-{version}/{path.name}`' for path in copied)
        rows.append(f'| {", ".join(sorted(libraries))} | {name} {version} | {license} | {files} |')
    rows.append('| libmpv.2.dylib | mpv 0.41.0（本项目构建） | GPL-2.0-or-later | `../mpv-LICENSE.GPL`, `../mpv-LICENSE.LGPL`, `../mpv-Copyright` |')
    (OUTPUT / 'README.md').write_text(
        '# 随附动态库的许可\n\n由 `scripts/collect_licenses.py` 从 `Dependencies.lock.json` 对应的 Homebrew keg 原样复制。'
        '源码地址与校验和见上级目录 `HomebrewFormulae.json`。\n\n'
        '| 库 | 来源 | 许可（SPDX） | 许可全文 |\n|---|---|---|---|\n' + '\n'.join(rows) + '\n')
    if missing:
        sys.exit('no license text for: ' + ', '.join(missing))
    print(f'{len(kegs)} formulae, license texts in {OUTPUT.relative_to(ROOT)}')


if __name__ == '__main__':
    main()
