#!/usr/bin/env python3
"""Run one quiet anonymous playback diagnostic. Real public requests occur only when run.

The child uses fixture settings, denies all stored credential access and permits only public
GET API routes. stderr is discarded; only scalar PERF lines are saved inside .build.
"""
import argparse
import csv
import json
import os
from pathlib import Path
import re
import statistics
import subprocess
import threading
import time

from diagnostic_audio import audio_summary, cpu_summary, number, media_isolation_summary
from diagnostic_privacy import scrub
from network_stability_check import BUILD, ROOT, build_path, fields

ALLOWED = re.compile(r'^PERF (?:media_isolation |anonymous (?:SETUP|START|SAMPLE|END|AUDIT|MEDIA|FAIL)|memory |browse_lifetime |lifetime |complete$)')


def safe_line(raw):
    line = raw.strip()
    if line.startswith('PERF FAIL'):
        return 'PERF anonymous FAIL category=diagnostic_failure'
    if not ALLOWED.match(line):
        return None
    # The fixed cookies=no option proof contains no header or account cookie value.
    checked = re.sub(r'\bcookies=no\b', '', line) if line.startswith('PERF media_isolation ') else line
    if re.search(r'(?:https?://|/Users/|/private/|Cookie|Token)', checked, re.I):
        return 'PERF anonymous FAIL category=unsafe_output_omitted'
    # Known App output is already scalar-only. This extra gate rejects unexpected free text.
    if not re.fullmatch(r'[A-Za-z0-9_=.\- ]+', line):
        return 'PERF anonymous FAIL category=invalid_scalar_output'
    return scrub(line)


def summarize(lines, rows, returncode, timed_out, seconds, app_offset):
    samples = [fields(line) for line in lines if line.startswith('PERF anonymous SAMPLE')]
    audits = [fields(line) for line in lines if line.startswith('PERF anonymous AUDIT')]
    end = next((fields(line) for line in lines if line.startswith('PERF anonymous END')), {})
    audio = audio_summary(samples)
    media_isolation = media_isolation_summary(lines)
    media = [fields(line) for line in lines if line.startswith('PERF anonymous MEDIA ')]
    media_ok = media_isolation['verified'] and bool(media) and all(item.get('isolation') == 'pass' for item in media)
    first_frame = number(end, 'first_frame_s')
    if first_frame is None:
        first_frame = next((value for sample in samples if (value := number(sample, 'first_frame_s')) is not None and value >= 0), None)
    boundary = len(audits) == 2 and {item.get('phase') for item in audits} == {'start', 'end'} and all(
        item.get('auth_check') == 'pass' and item.get('credential_calls') == '0'
        and item.get('non_get') == '0' and item.get('rejected') == '0' for item in audits)
    completed = returncode == 0 and not timed_out and 'PERF complete' in lines and not any(
        line.startswith('PERF anonymous FAIL') for line in lines)
    duration_ok = float(end.get('elapsed_s', 0)) >= seconds and end.get('result') == 'PASS'
    return {'result': 'PASS' if completed and boundary and media_ok and duration_ok and audio['valid_for_audio_cpu_comparison'] else 'FAIL',
            'exit_code': returncode, 'timed_out': timed_out, 'requested_seconds': seconds,
            'first_frame_load_loop_s': first_frame,
            'first_frame_from_launch_s': app_offset + first_frame if app_offset is not None and first_frame is not None else None,
            'first_frame_method': 'upper bound at next 1Hz App sample; launch offset includes setup APIs; load-loop origin differs between video and live',
            'diagnostic_complete': completed, 'boundary_pass': boundary, 'full_duration_pass': duration_ok,
            'audit': audits, 'audio': audio, 'playback': end,
            'media_isolation': media_isolation, 'session_media': media, 'media_isolation_pass': media_ok,
            'setup': [fields(line) for line in lines if line.startswith('PERF anonymous SETUP')],
            'failures': [fields(line) for line in lines if line.startswith('PERF anonymous FAIL')],
            'memory': [fields(line) for line in lines if line.startswith('PERF memory')],
            'lifetimes': [fields(line) for line in lines if line.startswith('PERF lifetime')],
            'cpu_phases': cpu_summary(rows, app_offset, samples),
            'cpu_mean_pct': round(statistics.mean(row[1] for row in rows), 3) if rows else None,
            'rss_max_bytes': max((row[2] for row in rows), default=None),
            'method': 'quiet child; ps once per second; no stored credentials/chat/heartbeat/history; stderr discarded',
            'limits': 'only the selected public media; no device switch/exclusive/hotplug testing; ps whole mean includes setup and teardown'}


def run(binary, output, target_kind, target, seconds, audio_driver='default', audio_buffer=None, pause_wait=None):
    args = [str(binary), '--perf-fixture', '--skip-auth', '--perf-anonymous-' + target_kind, target,
            '--perf-anonymous-seconds', str(seconds), '--perf-audio-driver', audio_driver]
    if audio_buffer is not None:
        args += ['--perf-audio-buffer', str(audio_buffer)]
    if pause_wait is not None:
        args += ['--perf-cache-pause-wait', str(pause_wait)]
    lines, rows, timing = [], [], {}
    started = time.monotonic()
    process = None
    timed_out = False
    try:
        process = subprocess.Popen(args, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                   text=True, errors='replace', env={key: value for key, value in os.environ.items()
                                                                   if not key.startswith('MANPING_')})
        def read_lines():
            with (output / 'app.log').open('w') as log:
                for raw in process.stdout:
                    line = safe_line(raw)
                    if line is None:
                        continue
                    if line.startswith('PERF anonymous START'):
                        timing['app_offset'] = time.monotonic() - started
                    lines.append(line)
                    log.write(line + '\n'); log.flush()
        reader = threading.Thread(target=read_lines, daemon=True)
        reader.start()
        while process.poll() is None:
            elapsed = time.monotonic() - started
            if elapsed > seconds + 100:
                timed_out = True
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill(); process.wait()
                break
            try:
                result = subprocess.run(['ps', '-p', str(process.pid), '-o', '%cpu=,rss='],
                                        capture_output=True, text=True, timeout=3)
                values = result.stdout.split()
                if len(values) == 2:
                    rows.append((round(elapsed, 3), float(values[0]), int(values[1]) * 1024))
            except (ValueError, subprocess.TimeoutExpired):
                pass
            time.sleep(1)
        process.wait(); reader.join(timeout=5)
        with (output / 'cpu.csv').open('w', newline='') as handle:
            writer = csv.writer(handle); writer.writerow(['launch_elapsed_s', 'cpu_pct', 'rss_bytes']); writer.writerows(rows)
        samples = [fields(line) for line in lines if line.startswith('PERF anonymous SAMPLE')]
        if samples:
            with (output / 'playback.csv').open('w', newline='') as handle:
                writer = csv.DictWriter(handle, fieldnames=sorted({key for sample in samples for key in sample}))
                writer.writeheader(); writer.writerows(samples)
        report = summarize(lines, rows, process.returncode, timed_out, seconds, timing.get('app_offset'))
        # Only validated public content IDs are retained in SETUP; full argv is omitted.
        report.update({'mode': target_kind, 'audio_driver_requested': audio_driver,
                       'audio_buffer_requested': audio_buffer, 'pause_wait_requested': pause_wait})
        (output / 'summary.json').write_text(scrub(json.dumps(report, indent=2)) + '\n')
        print(json.dumps({'result': report['result'], 'mode': target_kind,
                          'summary': str(Path('.build') / output.relative_to(BUILD) / 'summary.json')}), flush=True)
        return report
    finally:
        if process is not None and process.poll() is None:
            process.kill(); process.wait()


def self_test():
    assert safe_line('secret stderr') is None
    assert safe_line('PERF anonymous SAMPLE elapsed_s=1 media_s=2 actual_ao=coreaudio') is not None
    assert 'unsafe_output' in safe_line('PERF anonymous FAIL category=https://example.invalid/')
    assert 'invalid_scalar' in safe_line('PERF anonymous SAMPLE data=[unsafe]')
    assert summarize(['PERF complete'], [], 0, False, 300, 0)['result'] == 'FAIL'
    assert summarize(['PERF anonymous END elapsed_s=299 result=PASS', 'PERF complete'], [], 0, False, 300, 0)['result'] == 'FAIL'
    lines = ['PERF anonymous AUDIT phase=start auth_check=pass credential_calls=0 allowed_gets=0 rejected=0 non_get=0',
             'PERF anonymous AUDIT phase=end auth_check=pass credential_calls=0 allowed_gets=9 rejected=0 non_get=0']
    lines += ['PERF media_isolation requested=1 verified=1 ytdl=no load_scripts=no cookies=no',
              'PERF anonymous MEDIA isolation=pass']
    for stamp in range(3):
        lines.append(f'PERF anonymous SAMPLE elapsed_s={stamp} advancing=1 buffering=0 error=none audio_present=1 actual_ao=coreaudio audio_rate_hz=48000 audio_channels=2 avsync_s=unavailable')
    lines += ['PERF anonymous END elapsed_s=300 first_frame_s=2 result=PASS', 'PERF complete']
    report = summarize(lines, [], 0, False, 300, 5)
    assert report['result'] == 'PASS' and report['first_frame_from_launch_s'] == 7
    assert report['audio']['abs_avsync_s']['p95'] is None
    assert safe_line(lines[2]) == lines[2]
    assert summarize([line for line in lines if not line.startswith('PERF anonymous MEDIA')], [], 0, False, 300, 5)['result'] == 'FAIL'
    assert summarize([line.replace('cookies=no', 'cookies=yes') for line in lines], [], 0, False, 300, 5)['result'] == 'FAIL'
    failed = summarize(lines + ['PERF anonymous FAIL category=api code=-412'], [], 0, False, 300, 5)
    assert failed['result'] == 'FAIL' and failed['failures'] == [{'category': 'api', 'code': '-412'}]
    print('anonymous_playback_check self-test: PASS')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--self-test', action='store_true')
    parser.add_argument('--app', type=Path)
    target = parser.add_mutually_exclusive_group()
    target.add_argument('--bvid'); target.add_argument('--live')
    parser.add_argument('--seconds', type=int, default=300)
    parser.add_argument('--output', type=Path)
    parser.add_argument('--audio-driver', choices=['default', 'coreaudio', 'avfoundation'], default='default')
    parser.add_argument('--audio-buffer', type=float)
    parser.add_argument('--cache-pause-wait', type=float)
    args = parser.parse_args()
    if args.self_test:
        self_test(); return
    if args.app is None or args.output is None or (args.bvid is None and args.live is None):
        parser.error('--app, --output and one of --bvid/--live are required')
    if args.bvid is not None and not re.fullmatch(r'BV[A-Za-z0-9]{10}', args.bvid):
        parser.error('invalid public video identifier')
    if args.live is not None and args.live != 'auto' and not (re.fullmatch(r'[0-9]+', args.live) and 0 < int(args.live) <= 9223372036854775807):
        parser.error('live target must be auto or a positive room identifier')
    if not 300 <= args.seconds <= 600:
        parser.error('--seconds must be between 300 and 600')
    if args.audio_buffer is not None and not .1 <= args.audio_buffer <= 2:
        parser.error('--audio-buffer must be between 0.1 and 2')
    if args.cache_pause_wait is not None and not .1 <= args.cache_pause_wait <= 5:
        parser.error('--cache-pause-wait must be between 0.1 and 5')
    binary = args.app / 'Contents/MacOS/Manping' if args.app.is_dir() else args.app
    if not binary.is_file() or not os.access(binary, os.X_OK):
        parser.error('App executable must exist and be executable')
    try:
        output = build_path(args.output)
        output.mkdir(parents=True, exist_ok=False)
    except (ValueError, FileExistsError):
        parser.error('output must be a new directory inside .build')
    result = run(binary.resolve(), output, 'bvid' if args.bvid else 'live', args.bvid or args.live,
                 args.seconds, args.audio_driver, args.audio_buffer, args.cache_pause_wait)
    raise SystemExit(0 if result['result'] == 'PASS' else 1)


if __name__ == '__main__':
    main()
