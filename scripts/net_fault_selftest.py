#!/usr/bin/env python3
"""Small standard-library origin regressions; writes synthetic bytes only under .build."""
import http.client
from pathlib import Path
import time
import unittest
from urllib.parse import urlsplit

from net_fault_server import FaultOrigins

ROOT = Path(__file__).resolve().parents[1]


class FaultOriginTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = ROOT / '.build/network-server-selftest'
        cls.directory.mkdir(parents=True, exist_ok=True)
        cls.media = cls.directory / 'synthetic.bin'
        cls.payload = bytes(range(256)) * 512
        cls.media.write_bytes(cls.payload)

    def origin(self, scenario='healthy', backup=False, end=25):
        origin = FaultOrigins(self.media, scenario, backup, fault_start=0, fault_end=end)
        self.addCleanup(origin.close)
        return origin

    def get(self, url, byte_range='bytes=1024-2047', head=False):
        parts = urlsplit(url)
        connection = http.client.HTTPConnection(parts.hostname, parts.port, timeout=5)
        self.addCleanup(connection.close)
        connection.request('HEAD' if head else 'GET', parts.path, headers={'Range': byte_range})
        response = connection.getresponse()
        return response, response.read()

    def test_range_exact(self):
        origin = self.origin()
        response, body = self.get(origin.primary_url)
        self.assertEqual(response.status, 206)
        self.assertEqual(response.getheader('Content-Range'), 'bytes 1024-2047/131072')
        self.assertEqual(body, self.payload[1024:2048])

    def test_suffix_and_head(self):
        origin = self.origin()
        self.assertEqual(self.get(origin.primary_url, 'bytes=-512')[1], self.payload[-512:])
        response, body = self.get(origin.primary_url, head=True)
        self.assertEqual((response.status, body), (206, b''))

    def test_invalid_range(self):
        origin = self.origin()
        for value in ('bytes=999999-', 'bytes=0-1,3-4', 'bytes=-', 'bytes=12-1'):
            self.assertEqual(self.get(origin.primary_url, value)[0].status, 416)

    def test_http_error_then_recovery(self):
        for code in ('403', '404'):
            origin = self.origin(code)
            self.assertEqual(self.get(origin.primary_url)[0].status, int(code))
            origin.started = time.monotonic() - 26
            self.assertEqual(self.get(origin.primary_url)[1], self.payload[1024:2048])
            self.assertEqual(origin.snapshot()['fault_responses'], 1)

    def test_independent_ipv6_backup(self):
        origin = self.origin('403', backup=True)
        self.assertEqual(self.get(origin.primary_url)[0].status, 403)
        self.assertEqual(self.get(origin.backup_url)[1], self.payload[1024:2048])
        self.assertGreater(origin.snapshot()['backup_bytes'], 0)

    def test_disconnect_incomplete_body(self):
        origin = self.origin('disconnect')
        with self.assertRaises(http.client.IncompleteRead):
            self.get(origin.primary_url, 'bytes=0-65535')
        self.assertEqual(origin.snapshot()['disconnects'], 1)

    def test_stall_then_recovers(self):
        origin = self.origin('stall', end=0.2)
        start = time.monotonic()
        self.assertEqual(self.get(origin.primary_url)[1], self.payload[1024:2048])
        self.assertGreaterEqual(time.monotonic() - start, 0.18)
        self.assertGreater(origin.snapshot()['stall_waits'], 0)

    def test_expired_410_response(self):
        origin = self.origin('410')
        response, body = self.get(origin.primary_url)
        self.assertEqual(response.status, 410)
        self.assertEqual(body, b'')
        self.assertEqual(origin.snapshot()['fault_responses'], 1)

    def test_reject_invalid_configuration(self):
        with self.assertRaises(ValueError):
            FaultOrigins(self.media, 'unknown')

    def test_stalled_request_notices_client_close(self):
        origin = self.origin('stall')
        parts = urlsplit(origin.primary_url)
        connection = http.client.HTTPConnection(parts.hostname, parts.port, timeout=3)
        connection.request('GET', parts.path, headers={'Range': 'bytes=0-65535'})
        response = connection.getresponse()
        response.close()
        connection.close()
        deadline = time.monotonic() + 2
        while origin.snapshot().get('active_requests', 0) and time.monotonic() < deadline:
            time.sleep(.02)
        self.assertEqual(origin.snapshot()['active_requests'], 0)


if __name__ == '__main__':
    unittest.main()
