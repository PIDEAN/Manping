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

ROOT = Path(__file__).resolve().parents[1]


def cpu_sample(pid):
    result = subprocess.run(['ps', '-p', str(pid), '-o', '%cpu=,rss='], capture_output=True, text=True)
    fields = result.stdout.split()
    return (float(fields[0]), int(fields[1])) if len(fields) == 2 else (None, None)


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
    text = log.read_text()
    for line in text.splitlines():
        if line.startswith('PERF '):
            print(line, flush=True)
    if process.returncode != 0 or 'PERF complete' not in text or 'PERF FAIL' in text or 'actual_scroll=FAIL' in text:
        raise RuntimeError(name + ': incomplete diagnostic; see ' + str(log))


def standalone(mpv, media, codec, output):
    # Same public playback settings; standalone uses gpu-next/macvk rather than
    # the application's embedded libmpv/OpenGL renderer.
    ipc = output / ('mpv-' + codec + '.sock')
    ipc.unlink(missing_ok=True)
    log = (output / ('mpv-' + codec + '.log')).open('w')
    process = subprocess.Popen([mpv, '--no-config', '--profile=high-quality', '--hwdec=videotoolbox',
        '--framedrop=vo', '--video-sync=audio', '--volume=0', '--idle=yes', '--keep-open=yes',
        '--geometry=847x651', '--dither-depth=no', '--audio-exclusive=no', '--hr-seek=default',
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
        ipc.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, default=ROOT / 'dist/release/满屏.app')
    parser.add_argument('--media-dir', type=Path, default=ROOT / '.build/perf-media')
    parser.add_argument('--output', type=Path, default=ROOT / '.build/performance')
    parser.add_argument('--only', choices=['all', 'scroll', 'playback', 'stability', 'standalone'], default='all')
    parser.add_argument('--generate-media', action='store_true')
    parser.add_argument('--mpv', default=shutil.which('mpv'))
    args = parser.parse_args()
    media_dir, output = args.media_dir.resolve(), args.output.resolve()
    if any(not path.is_relative_to((ROOT / '.build').resolve()) for path in [media_dir, output]):
        parser.error('Performance media and raw logs must remain under .build')
    binary = args.app.resolve() / 'Contents/MacOS/Manping'
    if not binary.is_file():
        parser.error('Build a Release app before measuring')
    output.mkdir(parents=True, exist_ok=True)
    media_dir.mkdir(parents=True, exist_ok=True)
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
