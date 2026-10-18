#!/usr/bin/env python3
"""Collect closed-player vmmap/leaks and optional allocation graphs; no sudo."""
import argparse
import os
from pathlib import Path
import re
import selectors
import subprocess
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, default=ROOT / 'dist/release/满屏.app')
    parser.add_argument('--media', type=Path, default=ROOT / '.build/perf-media/testsrc2-h264-4k60.mp4')
    parser.add_argument('--output', type=Path, default=ROOT / '.build/memory-300')
    parser.add_argument('--iterations', type=int, default=300)
    parser.add_argument('--stack-graphs', action='store_true', help='Save live allocation graphs and sorted heaps at cycles 25 and 150')
    args = parser.parse_args()
    if not 25 <= args.iterations <= 300 or args.iterations % 25:
        parser.error('--iterations must be a multiple of 25 between 25 and 300')
    output = args.output.resolve()
    build_root = (ROOT / '.build').resolve()
    if output == build_root or not output.is_relative_to(build_root):
        parser.error('Raw memory logs must remain in a subdirectory of .build')
    binary = args.app.resolve() / 'Contents/MacOS/Manping'
    media = args.media.resolve()
    if not binary.is_file() or not media.is_file():
        parser.error('Build the app and generate the local media first')
    output.mkdir(parents=True, exist_ok=True)
    # A unique directory and names avoid accepting a previous run's ACK.
    acknowledgements = output / ('ack-' + uuid.uuid4().hex)
    acknowledgements.mkdir()
    graph_cycles = {25, 150}.intersection(range(25, args.iterations + 1, 25)) if args.stack_graphs else set()
    for cycle in graph_cycles:
        (output / f'c{cycle}.memgraph').unlink(missing_ok=True)
    environment = os.environ.copy()
    if args.stack_graphs:
        environment['MallocStackLogging'] = '1'
    process = subprocess.Popen([
        str(binary), '--perf-fixture', '--perf-memory-stress', '--perf-media', str(media),
        '--perf-memory-iterations', str(args.iterations), '--perf-memory-ack-dir', str(acknowledgements),
    ], cwd=ROOT, env=environment, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, bufsize=0)
    start = time.monotonic()
    deadline = start + 930
    markers = []
    acknowledgements_seen = []
    tools = []
    failed_tools = []
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)

    def inspect(command, name, timeout, leaks=False):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise RuntimeError('Memory diagnostic exceeded its external deadline')
        path = output / name
        with path.open('w') as file:
            try:
                result = subprocess.run(command, stdout=file, stderr=subprocess.STDOUT,
                                        timeout=min(timeout, remaining), cwd=ROOT)
                status = result.returncode
            except subprocess.TimeoutExpired:
                status = 'timeout'
            except OSError as error:
                file.write(f'{type(error).__name__}: {error}\n')
                status = 'launch_failed'
        # leaks uses exit 1 when it successfully reports leaked allocations.
        reported_leaks = leaks and status == 1 and re.search(r'\d+ leaks for', path.read_text(errors='replace'))
        success = status == 0 or bool(reported_leaks)
        tools.append((name, f'{status}' + (' (leaks reported)' if reported_leaks else '')))
        if not success:
            failed_tools.append(name)
        print(f'MEMORY tool={name} status={status}' + (' leaks_reported=true' if reported_leaks else ''), flush=True)
        return success

    def acknowledge(name):
        # The app only accepts these fixed filenames under its validated .build directory.
        if name != 'idle.resume' and not re.fullmatch(r'checkpoint-\d+\.resume', name):
            raise RuntimeError('Unexpected checkpoint ACK filename')
        temporary = acknowledgements / (name + '.tmp')
        temporary.write_text('collector complete\n')
        temporary.replace(acknowledgements / name)
        print(f'MEMORY resume={name}', flush=True)

    def consume(line):
        if line.startswith('PERF '):
            print(line.rstrip(), flush=True)
        marker = re.search(r'PERF memory_stress MARK iteration=(\d+) wait_ack=(\S+) timeout_s=(\d+) engine=closed', line)
        if marker:
            iteration = int(marker.group(1))
            markers.append(iteration)
            try:
                inspect(['/usr/bin/vmmap', '-summary', str(process.pid)], f'vmmap-{iteration:03d}.txt', 8)
                if iteration in graph_cycles:
                    graph = output / f'c{iteration}.memgraph'
                    inspect(['/usr/bin/leaks', '--readonlyContent', f'--outputGraph={graph}', str(process.pid)],
                            f'leaks-{iteration:03d}.txt', 55, leaks=True)
                    if graph.is_file() and graph.stat().st_size > 0:
                        # Two complete sorted heaps support net class-size deltas;
                        # heap --diffFrom reports surviving new objects, not net deltas.
                        inspect(['/usr/bin/heap', '-s', str(graph)], f'heap-{iteration:03d}.txt', 18)
                    else:
                        failed_tools.append(f'c{iteration}.memgraph missing or empty')
                        print(f'MEMORY graph=c{iteration}.memgraph status=missing_or_empty', flush=True)
            finally:
                acknowledge(marker.group(2))
        else:
            idle = re.search(r'PERF memory_stress IDLE iteration=(\d+) wait_ack=(\S+) timeout_s=(\d+) engine=closed', line)
            if idle:
                try:
                    inspect(['/usr/bin/vmmap', '-summary', str(process.pid)], 'vmmap-idle.txt', 8)
                    inspect(['/usr/bin/leaks', '--readonlyContent', str(process.pid)], 'leaks-final.txt', 55, leaks=True)
                finally:
                    acknowledge(idle.group(2))
            acknowledged = re.search(r'PERF memory_stress ACK iteration=(\d+) phase=(\w+) engine=closed', line)
            if acknowledged:
                acknowledgements_seen.append((int(acknowledged.group(1)), acknowledged.group(2)))

    try:
        with (output / 'app.log').open('w') as log:
            pending = b''
            while selector.get_map():
                if time.monotonic() >= deadline:
                    raise RuntimeError('Memory diagnostic exceeded its external deadline, including silent stdout')
                for key, _ in selector.select(timeout=min(1, max(0, deadline - time.monotonic()))):
                    chunk = os.read(key.fd, 65536)
                    if not chunk:
                        selector.unregister(key.fileobj)
                        if pending:
                            line = pending.decode('utf-8', errors='replace')
                            log.write(line); log.flush(); consume(line)
                            pending = b''
                        break
                    pending += chunk
                    while b'\n' in pending:
                        raw, pending = pending.split(b'\n', 1)
                        line = raw.decode('utf-8', errors='replace') + '\n'
                        log.write(line); log.flush(); consume(line)
            process.wait(timeout=min(5, max(0.1, deadline - time.monotonic())))
        contents = (output / 'app.log').read_text()
        expected = list(range(0, args.iterations + 1, 25))
        expected_ack = [(cycle, 'checkpoint') for cycle in expected] + [(args.iterations, 'idle')]
        if (process.returncode != 0 or markers != expected or acknowledgements_seen != expected_ack
                or f'actual_engines={args.iterations}\n' not in contents or 'PERF FAIL' in contents):
            raise RuntimeError(f'Incomplete {args.iterations}-cycle closed-state diagnostic; preserve raw logs')
        if failed_tools:
            raise RuntimeError('Memory tools failed: ' + ', '.join(failed_tools))
        print(f'MEMORY complete cycles={args.iterations} vmmap_samples={len(markers)} '
              f'stack_graphs={len(graph_cycles)} elapsed_s={time.monotonic()-start:.1f}', flush=True)
    finally:
        selector.close()
        (output / 'tools.txt').write_text('\n'.join(f'{name}: {status}' for name, status in tools)
                                           + '\n' + '\n'.join(f'FAIL: {name}' for name in failed_tools) + '\n')
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill(); process.wait(timeout=5)
        process.stdout.close()
        for sentinel in acknowledgements.iterdir():
            sentinel.unlink()
        acknowledgements.rmdir()


if __name__ == '__main__':
    main()
