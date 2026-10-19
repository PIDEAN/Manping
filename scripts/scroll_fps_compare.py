#!/usr/bin/env python3
"""Interleave scroll_fps_check runs of two perf apps (A B A B ...) so machine load hits both alike.

  python3 scripts/scroll_fps_compare.py --before .build/perf/before.app --after .build/perf/after.app --pairs 4
"""
import argparse
import json
from pathlib import Path
import statistics
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
CHECK = Path(__file__).resolve().parent / 'scroll_fps_check.py'


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--before', type=Path, required=True)
    parser.add_argument('--after', type=Path, required=True)
    parser.add_argument('--pairs', type=int, default=4)
    parser.add_argument('--label', default='compare')
    parser.add_argument('--output', type=Path, default=ROOT / '.build/scroll-fps')
    parser.add_argument('extra', nargs=argparse.REMAINDER, help='passed to scroll_fps_check.py after --')
    args = parser.parse_args()
    extra = [x for x in args.extra if x != '--']
    output = args.output.resolve()
    reports = {'before': [], 'after': []}
    for index in range(args.pairs):
        for side in ['before', 'after']:
            label = f'{args.label}-{side}-{index + 1}'
            app = getattr(args, side)
            subprocess.check_call([sys.executable, str(CHECK), '--app', str(app), '--label', label,
                '--output', str(output), *extra], stdout=subprocess.DEVNULL)
            report = next(output.glob(label + '-*.json'))
            reports[side].append(json.loads(report.read_text()))
    result = {'label': args.label, 'pairs': args.pairs, 'before_app': str(args.before), 'after_app': str(args.after)}
    for side in ['before', 'after']:
        medians = [r['median'] for r in reports[side]]
        result[side] = {key: round(statistics.median(m[key] for m in medians), 4) for key in medians[0]}
        result[side + '_runs'] = [{'effective_fps': m['effective_fps'], 'missed_vsync_pct': m['missed_vsync_pct'],
            'main_busy_pct': m['main_busy_pct'], 'loadavg_1m': r['runs'][0].get('loadavg_1m')}
            for m, r in zip(medians, reports[side])]
    path = output / f'{args.label}.json'
    path.write_text(json.dumps(result, indent=2, ensure_ascii=False) + '\n')
    for side in ['before', 'after']:
        print(side.upper(), json.dumps(result[side], ensure_ascii=False), flush=True)
    print('COMPARE report ' + str(path), flush=True)


if __name__ == '__main__':
    main()
