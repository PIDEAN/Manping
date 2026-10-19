#!/usr/bin/env python3
"""Measure grid scroll frame pacing (default 120 Hz) in an isolated --perf-fixture run; JSON under .build.

The app scrolls its own NSClipView from a CADisplayLink at a fixed speed (no synthetic input,
no pointer movement) and reports callback-arrival and vsync-timestamp frame intervals plus
main run-loop busy time. Covers default to the production ImageCache/CachedImage path.

  python3 scripts/scroll_fps_check.py --build --label before
  python3 scripts/scroll_fps_check.py --app '.build/perf/满屏 Perf.app' --label after --runs 3 --sample-seconds 8
"""
import argparse
import json
import os
from pathlib import Path
import plistlib
import shutil
import statistics
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(Path(__file__).resolve().parent))

from resource_bundles import copy_resource_bundles  # noqa: E402

PERF_APP = ROOT / '.build/perf/满屏 Perf.app'


def build_perf_app(template, app=PERF_APP):
    """Release-optimized binary in a copy of the Release runtime, under its own bundle id."""
    env = dict(os.environ, DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer')
    subprocess.check_call(['swift', 'build', '-c', 'release'], cwd=ROOT, env=env)
    bin_dir = Path(subprocess.check_output(['swift', 'build', '-c', 'release', '--show-bin-path'],
        cwd=ROOT, env=env, text=True).strip())
    template = template.resolve()
    if not (template / 'Contents/Frameworks/libmpv.2.dylib').is_file():
        raise RuntimeError('A bundled runtime template with libmpv.2.dylib is required')
    if app.exists():
        shutil.rmtree(app)
    app.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(template, app)
    shutil.copy2(bin_dir / 'Manping', app / 'Contents/MacOS/Manping')
    resources = app / 'Contents/Resources'
    copy_resource_bundles(bin_dir, resources)
    (resources / 'BundleManifest.json').unlink(missing_ok=True)
    with (app / 'Contents/Info.plist').open('rb') as handle:
        info = plistlib.load(handle)
    # Never the Release identifier: window frames and other AppKit state must not reach its defaults.
    info['CFBundleDisplayName'] = '满屏 Perf'
    info['CFBundleIdentifier'] = 'io.github.pidean.manping.perf'
    info.pop('CFBundleURLTypes', None)
    with (app / 'Contents/Info.plist').open('wb') as handle:
        plistlib.dump(info, handle)
    subprocess.check_call(['codesign', '--force', '--sign', '-', str(app)])
    return app


def run_once(binary, args, output, label, index):
    name = f'{label}-{args.page}-{index}'
    log_path = output / (name + '.log')
    command = [str(binary), '--perf-fixture', '--perf-scroll', args.page, '--perf-scroll-hz', str(args.hz),
        '--perf-scroll-seconds', str(args.seconds), '--perf-scroll-speed', str(args.speed),
        '--perf-covers', args.covers, '--perf-pointer', args.pointer]
    with log_path.open('w') as handle:
        process = subprocess.Popen(command, stdout=handle, stderr=handle)
        sampler = None
        start = time.monotonic()
        load_before = os.getloadavg()[0]
        try:
            while process.poll() is None:
                elapsed = time.monotonic() - start
                if elapsed > args.seconds + 40:
                    raise RuntimeError(name + ': diagnostic timed out')
                # Profile the main thread mid-scroll (after the 2 s warm-up and the first sweep).
                if args.sample_seconds and sampler is None and 'PERF scroll driver' in log_path.read_text():
                    time.sleep(3)
                    sampler = subprocess.Popen(['/usr/bin/sample', str(process.pid), str(args.sample_seconds),
                        '-mayDie', '-file', str(output / (name + '-sample.txt'))],
                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                time.sleep(.2)
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill(); process.wait()
            if sampler:
                sampler.wait(timeout=args.sample_seconds + 30)
    text = log_path.read_text()
    report = None
    for line in text.splitlines():
        if line.startswith('PERF scroll JSON '):
            report = json.loads(line[len('PERF scroll JSON '):])
        elif line.startswith('PERF ') and not line.startswith('PERF scroll JSON'):
            print(line, flush=True)
    if process.returncode != 0 or report is None or 'PERF FAIL' in text or not report['scroll']['verified']:
        raise RuntimeError(name + ': incomplete diagnostic; see ' + str(log_path))
    report['log'] = str(log_path)
    # Other work on the machine (builds, sync) shifts frame pacing; keep it next to the numbers.
    report['loadavg_1m'] = [round(load_before, 2), round(os.getloadavg()[0], 2)]
    return report


def summarize(runs):
    keys = {
        'pointer_inside_pct': lambda r: r.get('pointer_inside_pct', 0),
        'effective_fps': lambda r: r['effective_fps'],
        'arrival_p50_ms': lambda r: r['arrival_interval_ms']['p50'],
        'arrival_p95_ms': lambda r: r['arrival_interval_ms']['p95'],
        'arrival_p99_ms': lambda r: r['arrival_interval_ms']['p99'],
        'arrival_max_ms': lambda r: r['arrival_interval_ms']['max'],
        'arrival_over_8.33_pct': lambda r: r['arrival_over_pct']['8.33'],
        'arrival_over_12.5_pct': lambda r: r['arrival_over_pct']['12.5'],
        'arrival_over_16.7_pct': lambda r: r['arrival_over_pct']['16.7'],
        'missed_vsyncs': lambda r: r['missed_vsyncs'],
        'missed_vsync_pct': lambda r: r['missed_vsync_pct'],
        'hitch_ms_per_s': lambda r: r['hitch_ms_per_s'],
        'main_busy_pct': lambda r: r['main_busy_pct'],
        'main_busy_p50_ms': lambda r: r['main_busy_ms']['p50'],
        'main_busy_p95_ms': lambda r: r['main_busy_ms']['p95'],
        'main_busy_p99_ms': lambda r: r['main_busy_ms']['p99'],
        'main_busy_over_8.33_pct': lambda r: r['main_busy_over_pct']['8.33'],
        'nominal_period_over_10ms_pct': lambda r: r.get('nominal_period_over_10ms_pct', 0),
        'card_hover_events_per_s': lambda r: r.get('card_hover_events_per_s', 0),
        'card_hover_lifts_per_s': lambda r: r.get('card_hover_lifts_per_s', 0),
    }
    return {key: round(statistics.median(get(r) for r in runs), 4) for key, get in keys.items()}


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--app', type=Path, default=PERF_APP)
    parser.add_argument('--build', action='store_true', help='swift build -c release and assemble ' + str(PERF_APP.relative_to(ROOT)))
    parser.add_argument('--build-to', type=Path, default=PERF_APP, help='where --build assembles the app (under .build)')
    parser.add_argument('--template', type=Path, default=ROOT / 'dist/release/满屏.app')
    parser.add_argument('--page', choices=['recommended', 'popular', 'search'], default='recommended')
    parser.add_argument('--hz', type=int, choices=[60, 120], default=120)
    parser.add_argument('--seconds', type=int, default=30)
    parser.add_argument('--speed', type=int, default=2400, help='points per second')
    parser.add_argument('--covers', choices=['pipeline', 'bitmap'], default='pipeline')
    parser.add_argument('--pointer', choices=['any', 'over', 'hover', 'away'], default='any',
        help='over: place the click-through window under the resting pointer, as during a scroll gesture '
             '(card hover paused); hover: same placement without the gesture (card hover runs); '
             'away: place the window so the pointer is outside it when the screen allows')
    parser.add_argument('--runs', type=int, default=1)
    parser.add_argument('--sample-seconds', type=int, default=0, help='also run /usr/bin/sample on the app mid-scroll')
    parser.add_argument('--label', default='run')
    parser.add_argument('--output', type=Path, default=ROOT / '.build/scroll-fps')
    args = parser.parse_args()
    output = args.output.resolve()
    if not output.is_relative_to((ROOT / '.build').resolve()):
        parser.error('Raw logs and reports must remain under .build')
    if args.build and not args.build_to.resolve().is_relative_to((ROOT / '.build').resolve()):
        parser.error('--build-to must be under .build')
    app = build_perf_app(args.template, args.build_to.resolve()) if args.build else args.app.resolve()
    if app.resolve() == (ROOT / 'dist/release/满屏.app').resolve() or app.resolve() == args.template.resolve():
        parser.error('Measure a separate app bundle, never the Release app the user is running')
    binary = app / 'Contents/MacOS/Manping'
    if not binary.is_file():
        parser.error('Build the perf app first (--build)')
    output.mkdir(parents=True, exist_ok=True)
    runs = [run_once(binary, args, output, args.label, index + 1) for index in range(args.runs)]
    result = {'label': args.label, 'app': str(app), 'page': args.page, 'requested_hz': args.hz,
        'duration_s': args.seconds, 'speed_pt_s': args.speed, 'cover_mode': args.covers, 'pointer': args.pointer,
        'median': summarize(runs), 'runs': runs}
    if any('hover_settle' in r for r in runs):
        # --pointer hover: lifts while the content moved, and whether the card under the pointer lifted after.
        result['hover_settle'] = [r.get('hover_settle') for r in runs]
    path = output / f'{args.label}-{args.page}.json'
    path.write_text(json.dumps(result, indent=2, ensure_ascii=False) + '\n')
    print('SCROLL median ' + json.dumps(result['median'], ensure_ascii=False), flush=True)
    if 'hover_settle' in result:
        print('SCROLL hover_settle ' + json.dumps(result['hover_settle']), flush=True)
    print('SCROLL report ' + str(path), flush=True)


if __name__ == '__main__':
    main()
