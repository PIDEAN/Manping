#!/usr/bin/env python3
"""Build the 满屏 / Manping icons with native macOS tools (no pip dependencies).

Source of truth is the Icon Composer document Resources/AppIcon/AppIcon.icon, generated here:
four layered, glass-material streaks on a dark gradient, no inner frame (docs/DesignSystem.md).
Pipeline: .icon -> ictool 1024 px AppIcon.png -> AppIcon.icns; render_app_icon.swift then adds the
DEBUG badge (AppIconDebug.png), the sidebar mark StoreLogo.png and the MenuBarIcon.png template.
Release bundles compile the .icon with actool (scripts/bundle.py), so they carry Assets.car too.
"""
import json
import os
import pathlib
import shutil
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
ASSETS = ROOT / 'Resources/AppIcon'
APP_RESOURCES = ROOT / 'Sources/ManpingApp/Resources'
ICON_DOCUMENT = ASSETS / 'AppIcon.icon'
DEVELOPER_DIR = '/Applications/Xcode.app/Contents/Developer'
# `xcrun ictool` resolves to a different tool; the Icon Composer executable must be addressed directly.
ICTOOL = '/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool'

# name, tail x, head x, centre y, head radius, colour, tail opacity (1024 px canvas)
STREAKS = [
    ('mist', 300, 812, 300, 60, '#F6F3EE', 0.25),
    ('cyan', 132, 776, 466, 98, '#2EC0F7', 0.30),
    ('pink', 360, 872, 630, 80, '#FF4F95', 0.30),
    ('amber', 196, 612, 782, 62, '#FFB13B', 0.30),
]
TAPER = 0.36
TRANSLUCENCY = 0.5
BACKGROUND = {'linear-gradient': ['display-p3:0.15,0.18,0.28,1.0', 'display-p3:0.04,0.05,0.09,1.0']}


def streak_svg(tail, head, y, radius, color, tail_opacity):
    """A tapered capsule: round head on the right, thin tail on the left, fading toward the tail."""
    rt = radius * TAPER
    path = (f'M{tail:.1f},{y - rt:.1f} C{(tail + head) / 2:.1f},{y - rt:.1f} {head - radius * 1.2:.1f},{y - radius:.1f} '
            f'{head:.1f},{y - radius:.1f} A{radius:.1f},{radius:.1f} 0 0 1 {head:.1f},{y + radius:.1f} '
            f'C{head - radius * 1.2:.1f},{y + radius:.1f} {(tail + head) / 2:.1f},{y + rt:.1f} {tail:.1f},{y + rt:.1f} '
            f'A{rt:.1f},{rt:.1f} 0 0 1 {tail:.1f},{y - rt:.1f} Z')
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">\n'
            f'<defs><linearGradient id="g" x1="{tail - rt}" y1="0" x2="{head + radius}" y2="0" gradientUnits="userSpaceOnUse">\n'
            f'<stop offset="0" stop-color="{color}" stop-opacity="{tail_opacity}"/>'
            f'<stop offset="0.6" stop-color="{color}" stop-opacity="0.9"/><stop offset="1" stop-color="{color}"/>'
            f'</linearGradient></defs>\n<path d="{path}" fill="url(#g)"/></svg>\n')


def write_icon_document():
    if ICON_DOCUMENT.exists():
        shutil.rmtree(ICON_DOCUMENT)
    layer_dir = ICON_DOCUMENT / 'Assets'
    layer_dir.mkdir(parents=True)
    groups = []
    for name, tail, head, y, radius, color, tail_opacity in STREAKS:
        (layer_dir / f'{name}.svg').write_text(streak_svg(tail, head, y, radius, color, tail_opacity))
        # icon.json lists groups front to back, so each streak is inserted ahead of the earlier ones.
        groups.insert(0, {
            'layers': [{'image-name': f'{name}.svg', 'name': name, 'glass': True}],
            'shadow': {'kind': 'layer-color', 'opacity': 0.5},
            'translucency': {'enabled': True, 'value': TRANSLUCENCY},
            'specular': True,
        })
    document = {'fill': BACKGROUND, 'groups': groups, 'supported-platforms': {'squares': ['macOS']}}
    (ICON_DOCUMENT / 'icon.json').write_text(json.dumps(document, indent=2) + '\n')


def export_png(target):
    env = dict(os.environ, DEVELOPER_DIR=DEVELOPER_DIR)
    subprocess.check_call([ICTOOL, str(ICON_DOCUMENT), '--export-image', '--output-file', str(target),
                           '--platform', 'macOS', '--rendition', 'Default',
                           '--width', '512', '--height', '512', '--scale', '2'], env=env)


def make_icns(png, icns):
    with tempfile.TemporaryDirectory() as scratch:
        iconset = pathlib.Path(scratch) / 'icon.iconset'
        iconset.mkdir()
        for size in (16, 32, 128, 256, 512):
            for scale in (1, 2):
                suffix = '@2x' if scale == 2 else ''
                subprocess.check_call(['sips', '-z', str(size * scale), str(size * scale), str(png),
                                       '--out', str(iconset / f'icon_{size}x{size}{suffix}.png')],
                                      stdout=subprocess.DEVNULL)
        subprocess.check_call(['iconutil', '-c', 'icns', str(iconset), '-o', str(icns)])


def main():
    ASSETS.mkdir(parents=True, exist_ok=True)
    write_icon_document()
    export_png(ASSETS / 'AppIcon.png')
    # Badge, StoreLogo and MenuBarIcon come from the Swift renderer, which reads AppIcon.png.
    subprocess.check_call(['swift', '-module-cache-path', str(ROOT / '.build/icon-module-cache'),
                           str(ROOT / 'scripts/render_app_icon.swift'), str(ASSETS), str(APP_RESOURCES)])
    for name in ('AppIcon', 'AppIconDebug'):
        make_icns(ASSETS / (name + '.png'), ASSETS / (name + '.icns'))
    preview = ROOT / 'docs/screenshots/app-icon.png'
    preview.parent.mkdir(parents=True, exist_ok=True)
    subprocess.check_call(['sips', '-z', '512', '512', str(ASSETS / 'AppIcon.png'), '--out', str(preview)],
                          stdout=subprocess.DEVNULL)


if __name__ == '__main__':
    main()
