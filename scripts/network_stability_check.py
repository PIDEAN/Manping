#!/usr/bin/env python3
"""Serialize quiet fixture App runs against a local HTTP fault origin.

Only the launched child is terminated on timeout. Artifacts are restricted to
.build; App output is allowlisted so stderr, arbitrary paths and URLs never land
in reports. This tests production Player/CDN/MediaRelay, not system proxy/TLS.
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

from net_fault_server import FaultOrigins, SCENARIOS
from diagnostic_privacy import scrub_file
from diagnostic_audio import phased_audio, cpu_summary, media_isolation_summary
from diagnostic_terminal import terminal_outcome

ROOT = Path(__file__).resolve().parents[1]
BUILD = (ROOT / '.build').resolve()
ALLOWED = re.compile(r'^PERF (?:media_isolation |network (?:SETUP|START|SAMPLE|PRESENTATION|END)|memory |browse_lifetime |lifetime |complete)')


def build_path(path):
    path = path.resolve()
    if path == BUILD or BUILD not in path.parents:
        raise ValueError('artifact directory must be inside .build')
    return path


def fields(line):
    return dict(re.findall(r'([a-z_]+)=([^\s]+)', line))


def run(binary, media, output, scenario, backup, seconds, bitrate, fault_start=5, fault_end=25, sample_at=None, expect_error=False, refresh=None, error_budget=30, direct=False, third_candidate=False, audio_driver="default", audio_buffer=None, pause_wait=None, hide_seconds=0, hidden_reload_at=None, node_policy='auto'):
    label = scenario + ('-backup' if backup else '-single') + ('-refresh-' + refresh if refresh else '') + ('-direct' if direct else '') + ('-third' if third_candidate else '')
    if hide_seconds:
        label += '-hidden' + str(hide_seconds) + ('-reload' if hidden_reload_at is not None else '')
    if node_policy != 'auto':
        label += '-' + node_policy
    origin = FaultOrigins(media, scenario, backup or refresh in ('healthy', 'same-with-backup'), bitrate, fault_start, fault_end)
    middle = FaultOrigins(media, scenario, False, bitrate, fault_start, fault_end) if third_candidate else None
    args = [str(binary), '--perf-fixture', '--skip-auth', '--perf-network', origin.primary_url,
            '--perf-network-seconds', str(seconds)]
    args += ['--perf-audio-driver', audio_driver]
    if node_policy != 'auto':
        args += ['--perf-network-node-policy', node_policy]
    if hide_seconds:
        args += ['--perf-network-hide-seconds', str(hide_seconds)]
    if hidden_reload_at is not None:
        args += ['--perf-network-hidden-reload-at', str(hidden_reload_at)]
    if audio_buffer is not None:
        args += ['--perf-audio-buffer', str(audio_buffer)]
    if pause_wait is not None:
        args += ['--perf-cache-pause-wait', str(pause_wait)]
    if direct:
        args += ['--perf-network-direct']
    if backup:
        args += ['--perf-network-backup', middle.primary_url if middle else origin.backup_url]
    if middle:
        args += ['--perf-network-third', origin.backup_url]
    if refresh:
        args += ['--perf-network-refresh', origin.backup_url if refresh == 'healthy' else origin.primary_url]
    if refresh == 'same-with-backup':
        args += ['--perf-network-refresh-backup', origin.backup_url]
    if refresh == 'cancel':
        args += ['--perf-network-cancel-refresh']
    process = None
    rows, lines = [], []
    timing = {}
    start = time.monotonic()
    timed_out = False
    sample_status = None
    try:
        process = subprocess.Popen(args, cwd=ROOT, stdout=subprocess.PIPE,
                                   stderr=subprocess.DEVNULL, text=True, errors='replace',
                                   env={key: value for key, value in os.environ.items() if not key.startswith("MANPING_")})

        def read_lines():
            with (output / (label + '.log')).open('w') as log:
                for raw in process.stdout:
                    line = raw.strip()
                    if line.startswith('PERF network START'):
                        timing['app_start'] = time.monotonic()
                    # Diagnostic lines must have only fixed categories and scalar values.
                    if line.startswith('PERF FAIL'):
                        line = 'PERF FAIL reason=diagnostic_failure'
                    elif not ALLOWED.match(line):
                        continue
                    # cookies=no is a fixed option proof, never a Cookie header/value.
                    checked = re.sub(r'\bcookies=no\b', '', line) if line.startswith('PERF media_isolation ') else line
                    if re.search(r'(?:https?://|/Users/|/private/|Cookie|Token)', checked, re.I):
                        line = 'PERF FAIL reason=unsafe_output_omitted'
                    if line.startswith('PERF network SAMPLE'):
                        origins = [origin.snapshot()] + ([middle.snapshot()] if middle else [])
                        active = sum(item.get('active_requests', 0) for item in origins)
                        requests = sum(item.get('primary_requests', 0) + item.get('backup_requests', 0) for item in origins)
                        byte_count = sum(item.get('primary_bytes', 0) + item.get('backup_bytes', 0) for item in origins)
                        observed = time.monotonic() - timing.get('app_start', start)
                        line += (f' origin_active_requests={active} origin_requests={requests}'
                                 f' origin_bytes={byte_count} observed_elapsed_s={observed:.3f}')
                    log.write(line + '\n')
                    log.flush()
                    lines.append(line)

        reader = threading.Thread(target=read_lines, daemon=True)
        reader.start()
        while process.poll() is None:
            elapsed = time.monotonic() - start
            if elapsed > seconds + 35:
                timed_out = True
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
                break
            result = subprocess.run(['ps', '-p', str(process.pid), '-o', '%cpu=,rss='],
                                    capture_output=True, text=True, timeout=3)
            values = result.stdout.split()
            if len(values) == 2:
                rows.append((round(elapsed, 3), float(values[0]), int(values[1]) * 1024))
            if sample_at is not None and elapsed >= sample_at and sample_status is None:
                sample_path = output / (label + '-sample.txt')
                try:
                    sample_status = subprocess.run(['/usr/bin/sample', str(process.pid), '3', '1',
                        '-file', str(sample_path)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                        timeout=10).returncode
                except subprocess.TimeoutExpired:
                    sample_status = 'timeout'
                finally:
                    scrub_file(sample_path)
            time.sleep(1)
        process.wait()
        reader.join(timeout=5)
        with (output / (label + '-cpu.csv')).open('w', newline='') as handle:
            writer = csv.writer(handle)
            writer.writerow(['elapsed_s', 'cpu_pct', 'rss_bytes'])
            writer.writerows(rows)
        samples = [fields(line) for line in lines if line.startswith('PERF network SAMPLE')]
        presentation = [fields(line) for line in lines if line.startswith('PERF network PRESENTATION')]
        summary = next((fields(line) for line in lines if line.startswith('PERF network END')), {})
        metrics = [fields(line) for line in lines if line.startswith('PERF memory')]
        settle_deadline = time.monotonic() + 5
        while origin.snapshot().get('active_requests', 0) and time.monotonic() < settle_deadline:
            time.sleep(.1)
        counters = origin.snapshot()
        # Match the origin fault window to the App timeline using first HTTP request.
        app_start_offset = origin.started - start if origin.started is not None else None
        recovery_after = origin.fault_end + (origin.started - timing.get('app_start', start) if origin.started else 0)
        fresh_path = refresh in ('healthy', 'same-with-backup') or (direct and backup)
        fresh_start = counters.get('backup_first_byte_s')
        if fresh_path and fresh_start is not None:
            recovery_after = fresh_start + (origin.started - timing.get('app_start', start) if origin.started else 0)
        recovery_after = max(recovery_after, hide_seconds)
        recovering = [sample for sample in samples
                      if float(sample['elapsed_s']) >= recovery_after and sample['advancing'] == '1'
                      and sample['buffering'] == '0' and sample['error'] == 'none']
        recovered = next((float(recovering[i]['elapsed_s']) for i in range(2, len(recovering))
                          if float(recovering[i]['elapsed_s']) - float(recovering[i - 2]['elapsed_s']) < 3), None)
        complete = process.returncode == 0 and 'PERF complete' in lines and not any(
            line.startswith('PERF FAIL') for line in lines)
        injection_seen = scenario == 'healthy' or any(counters.get(key, 0) > 0
            for key in ('fault_responses', 'fault_chunks', 'stall_waits', 'disconnects', 'latency_delays'))
        final = samples[-5:]
        progressing_end = sum(sample['advancing'] == '1' for sample in final) >= 3
        first_error = next((float(sample['elapsed_s']) for sample in samples if sample['error'] != 'none'), None)
        recovered_ok = (progressing_end and recovered is not None and final
            and final[-1]['error'] == 'none' and final[-1]['buffering'] == '0'
            and float(summary.get('first_frame_s', '-1')) >= 0
            and (not fresh_path or counters.get('backup_bytes', 0) > 0))
        fault_start_from_app = fault_start + (origin.started - timing.get('app_start', start) if origin.started else 0)
        error_from_fault = first_error - fault_start_from_app if first_error is not None else None
        terminal = terminal_outcome(samples, fault_start_from_app, error_budget)
        bounded_error = terminal['bounded_error']
        refresh_count = max((int(sample.get('refresh_attempts', 0)) for sample in samples), default=0)
        reload_count = max((int(sample.get('automatic_reloads', 0)) for sample in samples), default=0)
        refresh_ok = (refresh is None or refresh_count == 1) and (refresh != 'cancel' or reload_count == 0)
        middle_counters = middle.snapshot() if middle else None
        candidates_ok = middle is None or middle_counters.get('primary_requests', 0) > 0
        node_restricted = node_policy == 'manual' or (direct and node_policy == 'no-switch')
        node_policy_ok = (not node_restricted or (counters.get('backup_requests', 0) == 0
            and (middle_counters is None or middle_counters.get('primary_requests', 0) == 0)))
        app_offset = timing.get('app_start', start) - start if 'app_start' in timing else None
        fault_end_from_app = fault_end + (origin.started - timing.get('app_start', start) if origin.started else 0)
        audio = phased_audio(samples, fault_start_from_app, fault_end_from_app)
        audio_ok = audio['valid_for_audio_cpu_comparison']
        media_isolation = media_isolation_summary(lines)
        hidden = [sample for sample in presentation if sample['hidden'] == '1']
        restored = [sample for sample in presentation if sample['hidden'] == '0' and float(sample['elapsed_s']) >= hide_seconds]
        presentation_ok = (not hide_seconds or bool(hidden and restored
            and all(sample['expected'] == '0' for sample in hidden)
            and all(sample.get('terminal') == '0' for sample in samples if float(sample['elapsed_s']) < hide_seconds)
            and max(int(sample['frames']) for sample in restored) > int(hidden[-1]['frames'])
            and float(summary.get('first_frame_s', '-1')) >= hide_seconds
            and (hidden_reload_at is None or max(int(sample['session']) for sample in hidden) == 2)))
        recovery_gate = complete and injection_seen and refresh_ok and candidates_ok and presentation_ok and node_policy_ok and (bounded_error if expect_error else recovered_ok)
        result = {
            'scenario': scenario, 'origins': 'backup' if backup else 'single', 'route': 'direct' if direct else 'relay',
            'middle_origin': middle_counters,
            'exit_code': process.returncode, 'timed_out': timed_out, 'diagnostic_complete': complete,
            'duration_s': seconds, 'fault_start_s': origin.fault_start, 'fault_end_s': origin.fault_end,
            'profiling_sample_at_s': sample_at, 'profiling_status': sample_status,
            'expectation': 'bounded_error' if expect_error else 'automatic_recovery',
            'error_budget_s': error_budget, **terminal,
            'presentation_hidden_s': hide_seconds, 'hidden_reload_at_s': hidden_reload_at,
            'presentation_gate_pass': presentation_ok, 'presentation_samples': presentation,
            'node_policy': node_policy, 'node_policy_gate_pass': node_policy_ok,
            'first_origin_request_from_launch_s': round(app_start_offset, 3) if app_start_offset is not None else None,
            'bitrate_bps': bitrate, 'origin': counters, 'injection_seen': injection_seen,
            'backup_used': counters.get('backup_bytes', 0) > 0,
            'progress_reference': 'fresh_first_byte' if fresh_path else 'fault_end',
            'post_fault_sustained_progress_s': round(recovered - recovery_after, 3) if recovered else None,
            'first_error_s': first_error, 'error_from_fault_s': error_from_fault,
            'refresh_fixture': refresh, 'refresh_attempts': refresh_count, 'automatic_reloads': reload_count,
            'first_buffering_s': next((float(sample['elapsed_s']) for sample in samples if sample['buffering'] == '1'), None),
            'relay_retries_max': max((int(sample['relay_retries']) for sample in samples), default=0),
            'relay_hedges_max': max((int(sample['relay_hedges']) for sample in samples), default=0),
            'progressing_at_end': progressing_end,
            'cpu_mean_pct': round(statistics.mean(row[1] for row in rows), 2) if rows else None,
            'cpu_max_pct': max((row[1] for row in rows), default=None),
            'rss_max_bytes': max((row[2] for row in rows), default=None),
            'playback': summary, 'playback_samples': samples, 'memory': metrics,
            'audio': audio, 'audio_driver_requested': audio_driver, 'media_isolation': media_isolation,
            'audio_buffer_requested': audio_buffer, 'pause_wait_requested': pause_wait,
            'cpu_phases': cpu_summary(rows, app_offset, samples, fault_start_from_app, fault_end_from_app),
            'recovery_gate_pass': bool(recovery_gate),
            'cpu_comparison_eligible': audio_ok and sample_at is None and media_isolation['verified'],
            'lifetimes': [fields(line) for line in lines if line.startswith('PERF lifetime')],
            'result': 'PASS' if recovery_gate and media_isolation['verified'] and (expect_error or audio_ok) else 'FAIL',
            'log': str(Path('.build') / (output / (label + '.log')).relative_to(BUILD)),
        }
        (output / (label + '.json')).write_text(json.dumps(result, indent=2) + '\n')
        print(json.dumps(result, ensure_ascii=False), flush=True)
        return result
    finally:
        if process and process.poll() is None:
            process.kill()
            process.wait()
        origin.close()
        if middle:
            middle.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--media', type=Path, required=True)
    parser.add_argument('--output', type=Path, default=ROOT / '.build/network-stability')
    parser.add_argument('--scenarios', nargs='+', choices=SCENARIOS, default=list(SCENARIOS))
    parser.add_argument('--origins', choices=['single', 'backup', 'both'], default='both')
    parser.add_argument('--seconds', type=int, default=60)
    parser.add_argument('--fault-start', type=float, default=5)
    parser.add_argument('--fault-end', type=float, default=25)
    parser.add_argument('--bitrate', type=int, default=8_000_000,
                        help='actual media bitrate; controls global near-realtime send rate')
    parser.add_argument('--sample-at', type=float,
                        help='capture 3s of sample stacks at this elapsed time; exclude this run from CPU comparisons')
    parser.add_argument('--error-budget', type=float, default=30, help='terminal error deadline in seconds from fault start (default 30; midstream may include cached playback)')
    parser.add_argument('--direct', action='store_true', help='test production single-node mode instead of MediaRelay')
    parser.add_argument('--third-candidate', action='store_true', help='insert a second faulty origin before the healthy backup (requires --direct --origins backup)')
    parser.add_argument('--refresh', choices=['healthy', 'same', 'same-with-backup', 'cancel'], help='provide one diagnostic playurl replacement, healthy or still failing')
    parser.add_argument('--audio-driver', choices=['default', 'coreaudio', 'avfoundation'], default='default')
    parser.add_argument('--audio-buffer', type=float)
    parser.add_argument('--cache-pause-wait', type=float)
    parser.add_argument('--hide-seconds', type=float, default=0, help='hide only the fixture surface before attach, then restore it')
    parser.add_argument('--hidden-reload-at', type=float, help='prepare and attach a new session while the fixture surface is hidden')
    parser.add_argument('--node-policy', choices=['auto', 'manual', 'no-switch'], default='auto',
                        help='exercise the production manual node or disabled stall-switch setting')
    parser.add_argument('--expect-error', action='store_true',
                        help='persistent fault: require a terminal Player error within 30s of fault start instead of recovery')
    args = parser.parse_args()
    if args.audio_buffer is not None and not .1 <= args.audio_buffer <= 2:
        parser.error('--audio-buffer must be between 0.1 and 2')
    if args.cache_pause_wait is not None and not .1 <= args.cache_pause_wait <= 5:
        parser.error('--cache-pause-wait must be between 0.1 and 5')
    if not 1 <= args.error_budget <= 60:
        parser.error('--error-budget must be between 1 and 60')
    if not 30 <= args.seconds <= 120:
        parser.error('--seconds must be between 30 and 120')
    if not 0 <= args.hide_seconds <= args.seconds - 10:
        parser.error('--hide-seconds must leave 10 seconds after restoring presentation')
    if args.hidden_reload_at is not None and not 0 < args.hidden_reload_at < args.hide_seconds:
        parser.error('--hidden-reload-at must fall inside the hidden interval')
    if not 0 <= args.fault_start < args.fault_end <= 90:
        parser.error('fault window must satisfy 0 <= start < end <= 90')
    if args.third_candidate and (not args.direct or args.origins != 'backup'):
        parser.error('--third-candidate requires --direct --origins backup')
    if args.third_candidate and args.node_policy != 'auto':
        parser.error('--third-candidate requires --node-policy auto')
    if not args.expect_error and args.refresh not in ('healthy', 'same-with-backup') and not (args.direct and args.origins == 'backup') and args.fault_end + 10 > args.seconds:
        parser.error('leave at least 10 seconds after the fault for recovery observation')
    if args.sample_at is not None and not 0 <= args.sample_at <= args.seconds - 5:
        parser.error('--sample-at must leave at least 5 seconds before the run ends')
    binary = args.app / 'Contents/MacOS/Manping' if args.app.is_dir() else args.app
    if not binary.is_file() or not args.media.is_file():
        parser.error('App executable and media must exist')
    output = build_path(args.output)
    output.mkdir(parents=True, exist_ok=True)
    reports = []
    for scenario in args.scenarios:
        for backup in ([False, True] if args.origins == 'both' else [args.origins == 'backup']):
            reports.append(run(binary, args.media, output, scenario, backup, args.seconds, args.bitrate, args.fault_start, args.fault_end, args.sample_at, args.expect_error, args.refresh, args.error_budget, args.direct, args.third_candidate, args.audio_driver, args.audio_buffer, args.cache_pause_wait, args.hide_seconds, args.hidden_reload_at, args.node_policy))
    report = {'method': 'quiet fixture Player via CDNController and MediaRelay; transient origin fault '
              'during configured window after first HTTP request; globally paced 16KiB chunks; '
              'recovery requires three progressing samples after fault end; no synthetic retry or seek',
              'pass_criteria': (f'clean completion, injected fault observed, explicit policy/Player terminal failure with resources settled within {args.error_budget:g}s of fault start; '
              'engine idle, all loopback origins idle, at least one later sample; no terminal/error clearing, buffering, '
              'engine/render progress, reopened connections or cumulative origin requests/bytes afterwards' if args.expect_error else 'clean completion, injected fault observed, rendered first frame, three '
              'consecutive progressing samples after fault end, >=3 progressing samples in last 5, '
              'and final sample without error or buffering; backup use reported separately'),
              'coverage_limits': 'HTTP loopback origins only; no HTTPS CONNECT, proxy, live, DNS or '
              'production adaptive quality; 2s readahead/4MiB cache diagnostic budget; '
              'ps CPU includes warmup and teardown; EOF near test end may require longer media',
              'runs': reports}
    (output / 'summary.json').write_text(json.dumps(report, indent=2) + '\n')
    raise SystemExit(0 if all(item['result'] == 'PASS' for item in reports) else 1)


if __name__ == '__main__':
    main()
