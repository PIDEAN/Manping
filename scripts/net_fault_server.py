#!/usr/bin/env python3
"""Loopback-only HTTP Range media origin with bounded, time-based faults.

No proxy settings, TLS interception, credentials, access logs or system network changes.
The runner imports FaultOrigins; this module can also serve a file independently.
"""
import argparse
from collections import Counter
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import re
import select
import socket
import threading
import time

SCENARIOS = ('healthy', 'latency', 'throttle', 'disconnect', 'stall', '403', '404', '410', 'slow-start')


class _IPv6Server(ThreadingHTTPServer):
    address_family = socket.AF_INET6


class FaultOrigins:
    """Primary on 127.0.0.1, optional independently bound backup on ::1.

    All requests share one rate clock, so parallel relay fetches cannot multiply
    bandwidth or prefetch the whole file before the fault. Faults affect only
    primary; backup is healthy. Default fault window: [5, 25) seconds from arm().
    """
    def __init__(self, media, scenario='healthy', backup=False, bitrate=8_000_000,
                 fault_start=5, fault_end=25):
        if scenario not in SCENARIOS or not 0 <= fault_start < fault_end <= 90:
            raise ValueError('invalid fault configuration')
        self.media = Path(media)
        if not self.media.is_file() or not 100_000 <= bitrate <= 200_000_000:
            raise ValueError('invalid local media or bitrate')
        self.size = self.media.stat().st_size
        self.scenario = scenario
        self.bitrate = bitrate
        self.fault_start, self.fault_end = fault_start, fault_end
        self.lock = threading.Lock()
        self.stop = threading.Event()
        self.started = None
        self.next_send = time.monotonic()
        self.counts = Counter()
        self.servers = []
        self.threads = []
        owner = self

        class Handler(BaseHTTPRequestHandler):
            protocol_version = 'HTTP/1.1'

            def log_message(self, *_args):
                pass

            def do_HEAD(self):
                self.serve(head=True)

            def do_GET(self):
                self.serve(head=False)

            def reply(self, status, length=0, content_range=None):
                self.send_response(status)
                self.send_header('Content-Length', str(length))
                self.send_header('Content-Type', 'video/mp4')
                self.send_header('Accept-Ranges', 'bytes')
                self.send_header('Connection', 'close')
                if content_range:
                    self.send_header('Content-Range', content_range)
                self.end_headers()
                self.close_connection = True

            def serve(self, head):
                endpoint = self.server.endpoint
                if self.path != '/' + endpoint + '/media.mp4':
                    self.reply(404)
                    return
                with owner.lock:
                    owner.counts[endpoint + '_requests'] += 1
                    owner.counts['active_requests'] += 1
                    owner.counts['peak_active_requests'] = max(owner.counts['peak_active_requests'], owner.counts['active_requests'])
                    if self.headers.get('Cookie') or self.headers.get('Authorization'):
                        owner.counts['credential_header_requests'] += 1
                    if owner.started is None:
                        owner.started = owner.next_send = time.monotonic()
                try:
                    self.connection.settimeout(3)
                    fault = owner.fault(endpoint)
                    if fault in ('403', '404', '410', 'latency'):
                        owner.note_fault()
                    if fault in ('403', '404', '410'):
                        with owner.lock:
                            owner.counts['fault_responses'] += 1
                        self.reply(int(fault))
                        return
                    if fault == 'latency':
                        with owner.lock:
                            owner.counts['latency_delays'] += 1
                        owner.stop.wait(3)
                    raw_range = self.headers.get('Range')
                    start, end = 0, owner.size - 1
                    if raw_range:
                        match = re.fullmatch(r'bytes=(\d*)-(\d*)', raw_range.strip())
                        if not match or not any(match.groups()):
                            self.reply(416, content_range=f'bytes */{owner.size}')
                            return
                        left, right = match.groups()
                        if left:
                            start = int(left)
                            end = min(int(right), end) if right else end
                        else:
                            start = max(0, owner.size - int(right))
                        if start > end or start >= owner.size:
                            self.reply(416, content_range=f'bytes */{owner.size}')
                            return
                    self.reply(206 if raw_range else 200, end - start + 1,
                               f'bytes {start}-{end}/{owner.size}' if raw_range else None)
                    if head:
                        return
                    sent = 0
                    with owner.media.open('rb') as source:
                        source.seek(start)
                        while sent < end - start + 1 and not owner.stop.is_set():
                            fault = owner.fault(endpoint)
                            if fault in ('stall', 'throttle', 'slow-start') or (fault == 'disconnect' and sent >= 32_768):
                                owner.note_fault()
                            if fault == 'stall':
                                # A deliberate body stall must still notice cancellation by the
                                # client; otherwise harness threads masquerade as leaked requests.
                                if select.select([self.connection], [], [], 0)[0] and not self.connection.recv(1, socket.MSG_PEEK):
                                    with owner.lock:
                                        owner.counts[endpoint + '_closed_connections'] += 1
                                    return
                                with owner.lock:
                                    owner.counts['stall_waits'] += 1
                                owner.stop.wait(min(0.25, max(0, owner.fault_end - owner.elapsed())))
                                continue
                            if fault == 'disconnect' and sent >= 32_768:
                                with owner.lock:
                                    owner.counts['disconnects'] += 1
                                self.connection.shutdown(socket.SHUT_RDWR)
                                return
                            # Healthy is deliberately near realtime, including the backup.
                            rate = owner.bitrate / 8 * 1.15
                            if fault == 'throttle':
                                rate *= 0.15
                            elif fault == 'slow-start':
                                rate *= min(1, 0.05 + (owner.elapsed() - owner.fault_start) / 20)
                            chunk = source.read(min(16_384, end - start + 1 - sent))
                            if not chunk:
                                return
                            with owner.lock:
                                now = time.monotonic()
                                reservation = max(now, owner.next_send)
                                owner.next_send = reservation + len(chunk) / max(1, rate)
                            if owner.stop.wait(max(0, reservation - time.monotonic())):
                                return
                            self.wfile.write(chunk)
                            self.wfile.flush()
                            sent += len(chunk)
                            with owner.lock:
                                owner.counts.setdefault(endpoint + '_first_byte_s', owner.elapsed())
                                owner.counts[endpoint + '_bytes'] += len(chunk)
                                if fault in ('throttle', 'slow-start'):
                                    owner.counts['fault_chunks'] += 1
                except (OSError, ConnectionError):
                    with owner.lock:
                        owner.counts[endpoint + '_closed_connections'] += 1
                finally:
                    with owner.lock:
                        owner.counts['active_requests'] -= 1

        try:
            for endpoint, host, server_type in [('primary', '127.0.0.1', ThreadingHTTPServer)] + (
                    [('backup', '::1', _IPv6Server)] if backup else []):
                server = server_type((host, 0), Handler)
                server.daemon_threads = True
                server.endpoint = endpoint
                self.servers.append(server)
                thread = threading.Thread(target=server.serve_forever, daemon=True)
                self.threads.append(thread)
                thread.start()
        except Exception:
            self.close()
            raise

    def arm(self):
        with self.lock:
            self.started = self.next_send = time.monotonic()

    def elapsed(self):
        return time.monotonic() - self.started if self.started is not None else 0

    def fault(self, endpoint):
        return self.scenario if endpoint == 'primary' and self.fault_start <= self.elapsed() < self.fault_end else 'healthy'

    @property
    def primary_url(self):
        return f'http://127.0.0.1:{self.servers[0].server_port}/primary/media.mp4'

    @property
    def backup_url(self):
        return f'http://[::1]:{self.servers[1].server_port}/backup/media.mp4' if len(self.servers) > 1 else None

    def note_fault(self):
        with self.lock:
            elapsed = round(self.elapsed(), 3)
            self.counts.setdefault('first_fault_s', elapsed)
            self.counts['last_fault_s'] = elapsed

    def snapshot(self):
        with self.lock:
            return dict(self.counts)

    def close(self):
        self.stop.set()
        for server in self.servers:
            server.shutdown()
            server.server_close()
        for thread in self.threads:
            thread.join(timeout=2)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--media', required=True, type=Path)
    parser.add_argument('--scenario', choices=SCENARIOS, default='healthy')
    parser.add_argument('--backup', action='store_true')
    parser.add_argument('--bitrate', type=int, default=8_000_000)
    parser.add_argument('--seconds', type=int, default=75)
    args = parser.parse_args()
    if not 30 <= args.seconds <= 180:
        parser.error('--seconds must be between 30 and 180')
    origin = FaultOrigins(args.media, args.scenario, args.backup, args.bitrate)
    try:
        print(json.dumps({'primary': origin.primary_url, 'backup': origin.backup_url}), flush=True)
        origin.stop.wait(args.seconds)
        print(json.dumps(origin.snapshot(), sort_keys=True), flush=True)
    finally:
        origin.close()


if __name__ == '__main__':
    main()
