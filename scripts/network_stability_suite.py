#!/usr/bin/env python3
"""Reproduce the 20-case loopback stability matrix, optionally its eight recovery extensions.

--plan-only writes the exact scalar case plan without starting an App or HTTP origin.
Profiling cases are explicitly excluded from CPU comparisons. Every case gets a new folder.
"""
import argparse
import json
import os
from pathlib import Path

from diagnostic_privacy import scrub
from network_stability_check import ROOT, BUILD, build_path, run


def plan(extended=False):
    cases = []
    def add(name, scenario, seconds, start=5, end=25, **options):
        cases.append(dict(name=name, scenario=scenario, backup=False, seconds=seconds,
                          fault_start=start, fault_end=end, sample_at=None, expect_error=False,
                          refresh=None, error_budget=30, direct=False, third_candidate=False))
        cases[-1].update(options)
        cases[-1]['cpu_comparison_eligible'] = cases[-1]['sample_at'] is None
    for scenario in ['healthy', 'latency', 'throttle', 'disconnect', 'stall', '403', '404', 'slow-start']:
        add('single-60-' + scenario, scenario, 60)
    for scenario in ['stall', '403', 'disconnect']:
        add('single-45-' + scenario, scenario, 45)
    for scenario in ['stall', '403', '404', 'disconnect']:
        add('backup-45-' + scenario, scenario, 45, start=0, backup=True)
    add('profile-throttle', 'throttle', 45, sample_at=15)
    add('profile-healthy', 'healthy', 30, end=15, sample_at=15)
    add('persistent-stall-before-reference', 'stall', 45, start=0, end=90, sample_at=15, expect_error=True)
    add('persistent-stall-after-reference', 'stall', 45, start=0, end=90, expect_error=True)
    add('persistent-403', '403', 35, start=0, end=90, expect_error=True)
    if extended:
        add('persistent-410', '410', 35, start=0, end=90, expect_error=True)
        add('midstream-persistent-stall', 'stall', 60, end=90, expect_error=True, error_budget=50)
        add('relay-403-refresh-healthy', '403', 35, start=0, end=90, refresh='healthy')
        add('relay-403-refresh-same', '403', 35, start=0, end=90, refresh='same', expect_error=True)
        add('relay-403-refresh-cancel', '403', 35, start=0, end=90, refresh='cancel', expect_error=True)
        add('direct-403-third', '403', 35, start=0, end=90, direct=True, backup=True, third_candidate=True)
        add('direct-403-refresh-same-with-backup', '403', 35, start=0, end=90, direct=True, refresh='same-with-backup')
        add('direct-403-backup', '403', 35, start=0, end=90, direct=True, backup=True)
    return cases


def command(case, folder, bitrate, driver, audio_buffer, pause_wait):
    # Inputs are placeholders so manifests never persist local App/media absolute paths.
    args = ['python3', 'scripts/network_stability_check.py', '--app', '<APP>', '--media', '<MEDIA>',
            '--output', str(Path('.build') / folder.relative_to(BUILD)), '--scenarios', case['scenario'],
            '--origins', 'backup' if case['backup'] else 'single', '--seconds', str(case['seconds']),
            '--fault-start', str(case['fault_start']), '--fault-end', str(case['fault_end']),
            '--bitrate', str(bitrate), '--error-budget', str(case['error_budget']), '--audio-driver', driver]
    for key, flag in [('expect_error', '--expect-error'), ('direct', '--direct'), ('third_candidate', '--third-candidate')]:
        if case[key]: args.append(flag)
    for value, flag in [(case['sample_at'], '--sample-at'), (case['refresh'], '--refresh'),
                        (audio_buffer, '--audio-buffer'), (pause_wait, '--cache-pause-wait')]:
        if value is not None: args.extend([flag, str(value)])
    return args


def self_test():
    assert len(plan()) == 20 and len(plan(True)) == 28
    assert len({case['name'] for case in plan(True)}) == 28
    assert sum(case['sample_at'] is not None for case in plan()) == 3
    assert all(not case['cpu_comparison_eligible'] for case in plan() if case['sample_at'] is not None)
    assert all(case['expect_error'] for case in plan() if case['fault_end'] > case['seconds'])
    assert plan(True)[-3]['third_candidate'] and plan(True)[-3]['backup']
    print('network_stability_suite self-test: PASS (20 base, 28 extended; no child runs)')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path); parser.add_argument('--media', type=Path)
    parser.add_argument('--output', type=Path)
    parser.add_argument('--extended', action='store_true'); parser.add_argument('--plan-only', action='store_true')
    parser.add_argument('--self-test', action='store_true')
    parser.add_argument('--bitrate', type=int, default=8_000_000)
    parser.add_argument('--audio-driver', choices=['default', 'coreaudio', 'avfoundation'], default='default')
    parser.add_argument('--audio-buffer', type=float); parser.add_argument('--cache-pause-wait', type=float)
    args = parser.parse_args()
    if args.self_test: self_test(); return
    if args.output is None: parser.error('--output is required')
    if args.bitrate <= 0: parser.error('--bitrate must be positive')
    if args.audio_buffer is not None and not .1 <= args.audio_buffer <= 2: parser.error('invalid --audio-buffer')
    if args.cache_pause_wait is not None and not .1 <= args.cache_pause_wait <= 5: parser.error('invalid --cache-pause-wait')
    binary = None
    if not args.plan_only:
        if args.app is None or args.media is None: parser.error('--app and --media are required')
        binary = args.app / 'Contents/MacOS/Manping' if args.app.is_dir() else args.app
        if not binary.is_file() or not os.access(binary, os.X_OK) or not args.media.is_file(): parser.error('App executable and media must exist')
        binary = binary.resolve()
    try:
        output = build_path(args.output)
        output.mkdir(parents=True, exist_ok=False)
    except (ValueError, FileExistsError):
        parser.error('output must be a new directory inside .build')
    manifest = {'method': 'serial quiet loopback production recovery; ps phases and audio scalars',
                'plan_only': args.plan_only, 'extended': args.extended,
                'profile_policy': 'sample stack captures affect CPU; exclude all sample_at cases from CPU comparisons',
                'reference_labels': 'before/after-reference are historical labels; both execute the current supplied binary',
                'audio_driver_requested': args.audio_driver, 'runs': []}
    for index, case in enumerate(plan(args.extended), 1):
        folder = output / f"{index:02d}-{case['name']}"
        entry = {'case': case, 'command': command(case, folder, args.bitrate, args.audio_driver, args.audio_buffer, args.cache_pause_wait)}
        if not args.plan_only:
            folder.mkdir()
            config = {key: value for key, value in case.items() if key not in ('name', 'cpu_comparison_eligible')}
            try:
                result = run(binary, args.media.resolve(), folder, bitrate=args.bitrate,
                             audio_driver=args.audio_driver, audio_buffer=args.audio_buffer,
                             pause_wait=args.cache_pause_wait, **config)
                entry['result'] = result
            except Exception:
                # Keep processing every independent case; arbitrary Error text may carry paths.
                entry['result'] = {'result': 'FAIL', 'category': 'runner_failure'}
            entry['cpu_comparison_eligible'] = case['cpu_comparison_eligible'] and entry['result'].get('cpu_comparison_eligible', False)
        manifest['runs'].append(entry)
        (output / 'summary.json').write_text(scrub(json.dumps(manifest, indent=2)) + '\n')
    failed = [entry for entry in manifest['runs'] if entry.get('result', {}).get('result') == 'FAIL']
    print(json.dumps({'cases': len(manifest['runs']), 'failed': len(failed), 'plan_only': args.plan_only,
                      'summary': str(Path('.build') / output.relative_to(BUILD) / 'summary.json')}))
    raise SystemExit(1 if failed else 0)


if __name__ == '__main__':
    main()
