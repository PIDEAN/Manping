#!/usr/bin/env python3
"""Build an isolated, pinned libmpv; never install into or overwrite Homebrew."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
ARCHIVE_SHA = 'ee21092a5ee427353392360929dc64645c54479aefdb5babc5cfbb5fad626209'
PATCHES = {
    'mpv-coreaudio-device-change.patch': '769b218df220738cc1cf9f81cf696c16518c5dfe56a5ef028e33b22536e0e924',
    'mpv-0.41.0-deduplicate-quad-coordinates.patch': '106dd6766887aead29b8cb5e10cec44702d29cf841d5d371c1b82618be9e16c6',
    'mpv-0.41.0-renderer-compatibility.patch': '15f1c7022e15099c22b228e99b95588d21201a32343f3d0cf641baa538ee7d19',
}

def run(*args, **kwargs):
    subprocess.run(args, check=True, **kwargs)

def fresh_source(archive, work):
    if hashlib.sha256(archive.read_bytes()).hexdigest() != ARCHIVE_SHA:
        raise RuntimeError('Unexpected mpv source archive')
    if {name: hashlib.sha256((ROOT / 'patches' / name).read_bytes()).hexdigest() for name in PATCHES} != PATCHES:
        raise RuntimeError('Unexpected pinned mpv patch')
    work.mkdir(parents=True, exist_ok=True)
    source = work / 'mpv-0.41.0'
    if source.exists(): shutil.rmtree(source)
    with tarfile.open(archive) as bundle:
        bundle.extractall(work, filter='data')
    for name in PATCHES:
        with (ROOT / 'patches' / name).open('rb') as data:
            run('patch', '--batch', '-p1', cwd=source, stdin=data)
    return source

def main():
    os.environ['DEVELOPER_DIR'] = '/Applications/Xcode.app/Contents/Developer'
    work = ROOT / '.build/mpv-source'
    work.mkdir(parents=True, exist_ok=True)
    archive = work / 'mpv-v0.41.0.tar.gz'
    if not archive.exists():
        urllib.request.urlretrieve('https://github.com/mpv-player/mpv/archive/refs/tags/v0.41.0.tar.gz', archive)
    if hashlib.sha256(archive.read_bytes()).hexdigest() != ARCHIVE_SHA:
        raise RuntimeError('Unexpected mpv source archive')
    patch_hashes = {name: hashlib.sha256((ROOT / 'patches' / name).read_bytes()).hexdigest() for name in PATCHES}
    if patch_hashes != PATCHES:
        raise RuntimeError('Unexpected pinned mpv patch')
    # Re-extract the verified archive every time. Reverse-applicability alone does not
    # establish that unrelated files in a reused source tree are clean.
    source = fresh_source(archive, work)
    environment = ROOT / '.build/mpv-tools'
    meson = environment / 'bin/meson'
    if not meson.exists():
        run('python3', '-m', 'venv', str(environment))
        run(str(environment / 'bin/pip'), 'install', 'meson==1.10.1')
    build = ROOT / '.build/mpv-build'
    if build.exists(): shutil.rmtree(build)
    options = ['-Dbuildtype=release', '-Dlibmpv=true', '-Dcplayer=false', '-Dbuild-date=false', '-Dmanpage-build=disabled', '-Dhtml-build=disabled', '-Dvapoursynth=disabled', '-Dmacos-cocoa-cb=disabled', '-Dvulkan=disabled', '-Dswift-flags=']
    setup = ['setup', str(build), str(source), *options]
    run(str(meson), *setup)
    run(str(meson), 'compile', '-C', str(build), '-j', '8')
    library = build / 'libmpv.2.dylib'
    run('lipo', '-verify_arch', 'arm64', str(library))
    metadata = {'version': '0.41.0', 'sourceSHA256': ARCHIVE_SHA, 'deduplicatedTextureCoordinates': True,
                'patches': patch_hashes, 'meson': '1.10.1', 'options': options,
                'librarySHA256': hashlib.sha256(library.read_bytes()).hexdigest()}
    (build / 'MpvBuild.json').write_text(json.dumps(metadata, indent=2) + '\n')
    print(library)

if __name__ == '__main__': main()
