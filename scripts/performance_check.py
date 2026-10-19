#!/usr/bin/env python3
"""Run serialized, offline Release diagnostics; keep media and plain logs under .build."""
import argparse
import csv
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import time

from diagnostic_privacy import portable, scrub, scrub_file

ROOT = Path(__file__).resolve().parents[1]


def cpu_sample(pid):
    result = subprocess.run(['ps', '-p', str(pid), '-o', '%cpu=,rss='], capture_output=True, text=True)
    fields = result.stdout.split()
    return (float(fields[0]), int(fields[1])) if len(fields) == 2 else (None, None)


def cpu_seconds(pid):
    """Accumulated CPU time of a process (user + system), from `ps -o time=`; no privileges needed."""
    text = subprocess.run(['ps', '-p', str(pid), '-o', 'time='], capture_output=True, text=True).stdout.strip()
    if not text:
        return None
    days, _, clock = text.rpartition('-')
    total = 0.0
    for part in clock.split(':'):
        total = total * 60 + float(part)
    return total + (float(days) * 86400 if days else 0)


POWER_MEDIA = 'testsrc2-h264-1080p30.mp4'


def generate_power_media(binary, media_dir, output):
    """A 65-second 1080p30 H.264 SDR (BT.709-tagged) sample, the common Bilibili shape."""
    path = media_dir / POWER_MEDIA
    if path.is_file() and path.stat().st_size > 0:
        return path
    command = [str(binary.parent / 'ffmpeg'), '-hide_banner', '-nostdin', '-y', '-f', 'lavfi', '-i',
        'testsrc2=size=1920x1080:rate=30', '-f', 'lavfi', '-i', 'sine=frequency=1000:sample_rate=48000',
        '-t', '65', '-c:v', 'h264_videotoolbox', '-b:v', '8M', '-pix_fmt', 'yuv420p',
        '-color_primaries', 'bt709', '-color_trc', 'bt709', '-colorspace', 'bt709',
        '-c:a', 'aac', '-b:a', '128k', '-movflags', '+faststart', str(path)]
    with (output / 'power-media-generation.log').open('w') as handle:
        subprocess.run(command, stdout=handle, stderr=handle, check=True)
    scrub_file(output / 'power-media-generation.log')
    return path


def run_power(binary, media, pattern, label, output, timeout=150):
    """One 1080p30 playback with the danmaku layer on (`empty` or `bursty` timeline).

    Measures, between the WARM marker (5 s in) and the end of playback: the app's and
    WindowServer's CPU time deltas (ps), `top`'s CPU and POWER (Activity Monitor's energy impact)
    every 2 s, and the app's own danmaku present rate and display/render evidence.
    powermetrics needs sudo and is not used.
    """
    import re
    import threading
    window_server = int(subprocess.run(['pgrep', '-x', 'WindowServer'], capture_output=True, text=True).stdout.split()[0])
    # WindowServer also composites everything else on screen: take its rate over 10 s without
    # the app right before the run, and report the run's increase over it.
    idle_start = (time.monotonic(), cpu_seconds(window_server))
    time.sleep(10)
    idle_ws = (cpu_seconds(window_server) - idle_start[1]) / (time.monotonic() - idle_start[0]) * 100
    name = f'power-{label}-{pattern}'
    log_path = output / (name + '.log')
    process = subprocess.Popen([str(binary), '--perf-fixture', '--perf-play-local', str(media), '--perf-source-fps', '30',
        '--perf-danmaku', pattern], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1)
    watchdog = threading.Timer(timeout, process.kill)
    watchdog.start()
    warm = end = top = None
    lines = []
    try:
        with log_path.open('w') as handle:
            for line in process.stdout:
                line = scrub(line)
                handle.write(line)
                lines.append(line.rstrip('\n'))
                if line.startswith('PERF playback WARM') and warm is None:
                    warm = (time.monotonic(), cpu_seconds(process.pid), cpu_seconds(window_server))
                    top = subprocess.Popen(['top', '-l', '0', '-s', '2', '-stats', 'pid,cpu,power', '-pid', str(process.pid),
                        '-pid', str(window_server)], stdout=(output / (name + '-top.txt')).open('w'), stderr=subprocess.DEVNULL)
                elif line.startswith('PERF playback DANMAKU') and end is None:
                    end = (time.monotonic(), cpu_seconds(process.pid), cpu_seconds(window_server))
                    if top:
                        top.terminate(); top.wait()
            process.wait()
    finally:
        watchdog.cancel()
        if top and top.poll() is None:
            top.terminate(); top.wait()
        if process.poll() is None:
            process.kill(); process.wait()
    text = '\n'.join(lines)
    if process.returncode != 0 or 'PERF complete' not in text or 'PERF FAIL' in text or 'result=FAIL' in text or not warm or not end:
        raise RuntimeError(name + ': incomplete diagnostic; see ' + str(log_path))
    samples = {process.pid: [], window_server: []}
    seen = {process.pid: 0, window_server: 0}
    for row in (output / (name + '-top.txt')).read_text().splitlines():
        match = re.match(r'^\s*(\d+)\s+([\d.]+)\s+([\d.]+)\s*$', row)
        if match and int(match.group(1)) in samples:
            pid = int(match.group(1))
            seen[pid] += 1
            if seen[pid] > 1:  # top's first logging sample has no interval
                samples[pid].append((float(match.group(2)), float(match.group(3))))

    def mean(values):
        return round(sum(values) / len(values), 2) if values else None

    def field(prefix, key):
        for row in lines:
            if row.startswith(prefix):
                match = re.search(r'(?:^|\s)' + re.escape(key) + r'=(\S+)', row)
                if match:
                    return match.group(1)
        return None

    wall = end[0] - warm[0]
    result = {
        'pattern': pattern, 'window_s': round(wall, 3),
        'app_cpu_pct': round((end[1] - warm[1]) / wall * 100, 2),
        'windowserver_cpu_pct': round((end[2] - warm[2]) / wall * 100, 2),
        'windowserver_idle_cpu_pct': round(idle_ws, 2),
        'windowserver_cpu_delta_pct': round((end[2] - warm[2]) / wall * 100 - idle_ws, 2),
        'app_top_cpu_mean': mean([x[0] for x in samples[process.pid]]),
        'app_energy_impact_mean': mean([x[1] for x in samples[process.pid]]),
        'windowserver_top_cpu_mean': mean([x[0] for x in samples[window_server]]),
        'windowserver_energy_impact_mean': mean([x[1] for x in samples[window_server]]),
        'top_samples': len(samples[process.pid]),
        'danmaku_presents_per_s': float(field('PERF playback DANMAKU', 'presents_per_s') or 'nan'),
        'danmaku_lines': int(field('PERF playback DANMAKU', 'lines') or 0),
        'total_drop_pct': float(field('PERF playback END', 'total_drop_pct') or 'nan'),
        'hwdec_current': field('PERF playback END', 'hwdec_current'),
        'profile': field('PERF playback WARM', 'engine_profile') or field('PERF playback START', 'profile'),
        'power_saving': field('PERF playback WARM', 'power'),
        'display': next((row[len('PERF playback DISPLAY '):] for row in lines if row.startswith('PERF playback DISPLAY ')), None),
        'render': next((row.split('render_evidence=', 1)[1] for row in lines if 'render_evidence=' in row), None),
        'danmaku_evidence': field('PERF playback DANMAKU', 'evidence'),
        'log': portable(log_path),
    }
    print('PERF power ' + json.dumps(result, ensure_ascii=False), flush=True)
    return result


def power(binary, media_dir, output, label, rounds):
    media = generate_power_media(binary, media_dir, output)
    runs = []
    for index in range(rounds):
        for pattern in ['empty', 'bursty']:
            run = run_power(binary, media, pattern, f'{label}-r{index + 1}', output)
            run['round'] = index + 1
            runs.append(run)
    keys = ['app_cpu_pct', 'windowserver_cpu_pct', 'windowserver_cpu_delta_pct', 'app_energy_impact_mean',
        'windowserver_energy_impact_mean', 'danmaku_presents_per_s']
    summary = {}
    for pattern in ['empty', 'bursty']:
        selected = [run for run in runs if run['pattern'] == pattern]
        summary[pattern] = {key: round(sum(run[key] for run in selected) / len(selected), 2) for key in keys
            if all(isinstance(run[key], (int, float)) for run in selected)}
    report = {
        'label': label, 'app': portable(binary.parents[2]), 'media': portable(media),
        'power_source': subprocess.run(['pmset', '-g', 'batt'], capture_output=True, text=True).stdout.splitlines()[:1],
        'method': 'ps CPU-time deltas and top -stats cpu,power (energy impact) between WARM (5 s) and end of a 65 s '
            '1080p30 H.264 SDR file; danmaku layer on; WindowServer delta = its rate during the run minus its rate '
            'over 10 s without the app just before; powermetrics not used (needs sudo).',
        'summary': summary, 'runs': runs,
    }
    path = output / f'power-{label}.json'
    path.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    print(f'PERF power summary {label} ' + json.dumps(summary, ensure_ascii=False), flush=True)
    print('PERF power report ' + str(path), flush=True)


def run_app(binary, arguments, name, output, timeout):
    log = output / (name + '.log')
    with log.open('w') as handle, (output / (name + '-cpu.csv')).open('w') as samples:
        process = subprocess.Popen([str(binary), '--perf-fixture', *arguments], stdout=handle, stderr=handle)
        writer = csv.writer(samples)
        writer.writerow(['elapsed_s', 'cpu_percent', 'rss_kib'])
        start = time.monotonic()
        try:
            while process.poll() is None:
                elapsed = time.monotonic() - start
                if elapsed > timeout:
                    raise RuntimeError(name + ': diagnostic timed out')
                cpu, rss = cpu_sample(process.pid)
                if cpu is not None:
                    writer.writerow([round(elapsed, 3), cpu, rss])
                time.sleep(.5)
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill(); process.wait()
            scrub_file(log)
    text = log.read_text()
    for line in text.splitlines():
        if line.startswith('PERF '):
            print(line, flush=True)
    if process.returncode != 0 or 'PERF complete' not in text or 'PERF FAIL' in text or 'result=FAIL' in text or 'actual_scroll=FAIL' in text:
        raise RuntimeError(name + ': incomplete diagnostic; see ' + str(log))


def standalone(mpv, media, codec, output):
    # Same public playback settings; standalone uses gpu-next/macvk rather than
    # the application's embedded libmpv/OpenGL renderer.
    ipc = output / ('mpv-' + codec + '.sock')
    ipc.unlink(missing_ok=True)
    log = (output / ('mpv-' + codec + '.log')).open('w')
    process = subprocess.Popen([mpv, '--no-config', '--profile=high-quality', '--hwdec=videotoolbox',
        '--framedrop=vo', '--video-sync=audio', '--volume=0', '--idle=yes', '--keep-open=yes',
        '--geometry=847x651', '--focus-on=never', '--macos-app-activation-policy=accessory', '--dither-depth=no', '--audio-exclusive=no', '--hr-seek=default',
        '--cache-on-disk=no', '--audio-channels=auto', '--demuxer-max-bytes=314572800',
        '--demuxer-max-back-bytes=0', '--demuxer-readahead-secs=300',
        '--input-default-bindings=no', '--input-ipc-server=' + str(ipc), str(media)], stdout=log, stderr=log)
    connection = socket.socket(socket.AF_UNIX)
    connection.settimeout(5)
    reader = None
    try:
        deadline = time.monotonic() + 30
        while not ipc.exists():
            if process.poll() is not None or time.monotonic() >= deadline:
                raise RuntimeError('standalone mpv startup failed')
            time.sleep(.1)
        connection.connect(str(ipc))
        reader = connection.makefile('rb')
        request = 0

        def prop(name):
            nonlocal request
            request += 1
            connection.sendall((json.dumps({'command': ['get_property', name], 'request_id': request}) + '\n').encode())
            while True:
                line = reader.readline()
                if not line:
                    raise RuntimeError('standalone mpv IPC disconnected')
                reply = json.loads(line)
                if reply.get('request_id') == request:
                    return reply.get('data') if reply.get('error') == 'success' else None

        properties = ['time-pos', 'duration', 'frame-drop-count', 'decoder-frame-drop-count',
            'hwdec-current', 'estimated-vf-fps', 'eof-reached', 'current-vo', 'osd-dimensions']
        baseline = final = None
        samples = []
        deadline = time.monotonic() + 100
        while time.monotonic() < deadline:
            values = {name: prop(name) for name in properties}
            values['cpu_percent'], values['rss_kib'] = cpu_sample(process.pid)
            samples.append(values)
            position = values['time-pos']
            if position is not None and position >= 5 and baseline is None:
                baseline = values.copy()
            if baseline and position is not None:
                final = values.copy()
            if values['eof-reached']:
                break
            time.sleep(.5)
        with (output / ('mpv-' + codec + '.csv')).open('w') as handle:
            writer = csv.DictWriter(handle, fieldnames=list(samples[0]))
            writer.writeheader(); writer.writerows(samples)
        if not baseline or not final or not final['eof-reached']:
            raise RuntimeError('standalone mpv incomplete playback')
        counters = ['frame-drop-count', 'decoder-frame-drop-count']
        if any(baseline[x] is None or final[x] is None for x in counters):
            raise RuntimeError('standalone mpv counters unavailable')
        frames = (final['time-pos'] - baseline['time-pos']) * 60
        vo = final[counters[0]] - baseline[counters[0]]
        decoder = final[counters[1]] - baseline[counters[1]]
        cpu = [x['cpu_percent'] for x in samples if x['time-pos'] is not None and x['time-pos'] >= baseline['time-pos'] and x['cpu_percent'] is not None]
        dimensions = final['osd-dimensions'] or {}
        summary = (f"PERF standalone codec={codec} start_s={baseline['time-pos']:.3f} end_s={final['time-pos']:.3f} "
            f"expected_cfr_frames={frames:.1f} vo_drop_delta={vo} decoder_drop_delta={decoder} "
            f"total_drop_pct={(vo + decoder) / frames * 100:.6f} hwdec_current={final['hwdec-current']} "
            f"estimated_vf_fps={final['estimated-vf-fps']} vo={final['current-vo']} osd_pixels={dimensions.get('w', 'unknown')}x{dimensions.get('h', 'unknown')} "
            f"cpu_mean_pct={sum(cpu) / len(cpu):.2f} cpu_peak_pct={max(cpu):.2f}")
        print(summary, flush=True)
        (output / ('mpv-' + codec + '-summary.txt')).write_text(summary + '\n')
        if (vo + decoder) / frames * 100 >= 0.1 or not str(final['hwdec-current']).startswith('videotoolbox'):
            raise RuntimeError('standalone mpv playback threshold failed')
    finally:
        try:
            connection.sendall(b'{"command":["quit"]}\n')
        except OSError:
            pass
        if reader:
            reader.close()
        connection.close()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill(); process.wait()
        log.close()
        scrub_file(output / ('mpv-' + codec + '.log'))
        ipc.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, default=ROOT / 'dist/release/满屏.app')
    parser.add_argument('--media-dir', type=Path, default=ROOT / '.build/perf-media')
    parser.add_argument('--output', type=Path, default=ROOT / '.build/performance')
    # `power` is separate from `all`: 1080p30 playback with the danmaku layer on, CPU and energy proxies.
    parser.add_argument('--only', choices=['all', 'scroll', 'playback', 'stability', 'standalone', 'power'], default='all')
    parser.add_argument('--power-label', default='current')
    parser.add_argument('--power-rounds', type=int, default=2)
    parser.add_argument('--power-compare', nargs=2, type=Path, metavar=('BEFORE_JSON', 'AFTER_JSON'),
        help='Print and save a before/after table from two power reports; runs nothing.')
    parser.add_argument('--generate-media', action='store_true')
    parser.add_argument('--mpv', default=shutil.which('mpv'))
    args = parser.parse_args()
    media_dir, output = args.media_dir.resolve(), args.output.resolve()
    if any(not path.is_relative_to((ROOT / '.build').resolve()) for path in [media_dir, output]):
        parser.error('Performance media and raw logs must remain under .build')
    if args.power_compare:
        before, after = (json.loads(path.read_text()) for path in args.power_compare)
        rows = []
        for pattern in ['empty', 'bursty']:
            for key, value in before['summary'][pattern].items():
                new = after['summary'][pattern].get(key)
                rows.append({'pattern': pattern, 'metric': key, 'before': value, 'after': new,
                    'change_pct': round((new - value) / value * 100, 1) if new is not None and value else None})
        output.mkdir(parents=True, exist_ok=True)
        path = output / 'power-compare.json'
        path.write_text(json.dumps({'before': before['label'], 'after': after['label'], 'rows': rows}, ensure_ascii=False, indent=2) + '\n')
        print('| 场景 | 指标 | 改动前 | 改动后 | 变化 |\n| --- | --- | ---: | ---: | ---: |')
        for row in rows:
            print(f"| {row['pattern']} | {row['metric']} | {row['before']} | {row['after']} | {row['change_pct']}% |")
        print('PERF power compare ' + str(path), flush=True)
        return
    binary = args.app.resolve() / 'Contents/MacOS/Manping'
    if not binary.is_file():
        parser.error('Build a Release app before measuring')
    output.mkdir(parents=True, exist_ok=True)
    media_dir.mkdir(parents=True, exist_ok=True)
    if args.only == 'power':
        power(binary, media_dir, output, args.power_label, max(1, args.power_rounds))
        return
    media = {codec: media_dir / ('testsrc2-' + codec + '-4k60.mp4') for codec in ['h264', 'hevc']}
    if args.generate_media:
        for codec, path in media.items():
            if path.exists():
                continue
            command = [str(binary.parent / 'ffmpeg'), '-hide_banner', '-nostdin', '-y', '-f', 'lavfi', '-i',
                'testsrc2=size=3840x2160:rate=60', '-f', 'lavfi', '-i', 'sine=frequency=1000:sample_rate=48000',
                '-t', '60', '-c:v', codec + '_videotoolbox', '-b:v', '35M' if codec == 'h264' else '25M',
                '-pix_fmt', 'yuv420p', '-c:a', 'aac', '-b:a', '128k', '-movflags', '+faststart']
            if codec == 'hevc':
                command += ['-tag:v', 'hvc1']
            with (output / (codec + '-generation.log')).open('w') as handle:
                subprocess.run([*command, str(path)], stdout=handle, stderr=handle, check=True)
            scrub_file(output / (codec + '-generation.log'))
    if args.only in ['all', 'scroll']:
        for page in ['recommended', 'popular', 'search']:
            run_app(binary, ['--perf-scroll', page], 'scroll-' + page, output, 60)
    if args.only in ['all', 'playback', 'stability', 'standalone']:
        if any(not path.is_file() or path.stat().st_size == 0 for path in media.values()):
            parser.error('Generate both 60-second local files with --generate-media first')
    if args.only in ['all', 'playback']:
        for codec, path in media.items():
            run_app(binary, ['--perf-play-local', str(path)], 'playback-' + codec, output, 110)
    if args.only in ['all', 'stability']:
        run_app(binary, ['--perf-stability', '--perf-media', str(media['h264'])], 'stability', output, 240)
    if args.only in ['all', 'standalone']:
        if args.mpv:
            for codec, path in media.items():
                standalone(args.mpv, path, codec, output)
        else:
            print('PERF standalone unavailable: no separate mpv installed', flush=True)
    print('PERF GPU and energy: unmeasured; no sudo/powermetrics', flush=True)


if __name__ == '__main__':
    main()
