#!/usr/bin/env python3
"""Regression checks for source freshness and quiet native capture failure handling."""
from pathlib import Path
import struct
import tempfile
import unittest
import zlib
from unittest.mock import patch

from debug_build_fingerprint import source_manifest, validate_build_record
from live_check import capture_in_app, png_dimensions


class LiveCheckTests(unittest.TestCase):
    @staticmethod
    def png(width, height):
        def chunk(kind, payload):
            return struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", zlib.crc32(kind + payload))
        header = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
        pixels = zlib.compress((b"\0" + b"\0" * (width * 3)) * height)
        return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", pixels) + chunk(b"IEND", b"")

    def test_fingerprint_rejects_changed_added_and_removed_build_inputs(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "Sources/App.swift"
            source.parent.mkdir(); source.write_text("first")
            original = source_manifest(root)
            record = {"schema": 1, "verified": True, **original}
            validate_build_record(record, source_manifest(root))
            source.write_text("changed")
            with self.assertRaisesRegex(RuntimeError, "stale.*Sources/App.swift"):
                validate_build_record(record, source_manifest(root))
            source.write_text("first")
            added = root / "Sources/Added.swift"; added.write_text("new")
            with self.assertRaisesRegex(RuntimeError, "stale.*Added.swift"):
                validate_build_record(record, source_manifest(root))
            added.unlink(); source.unlink()
            with self.assertRaisesRegex(RuntimeError, "stale.*App.swift"):
                validate_build_record(record, source_manifest(root))

    def test_no_build_and_missing_or_malformed_records_are_unverified(self):
        current = {"fingerprint": "x", "files": {}}
        for record in ({}, None, [], {"schema": 1, "verified": False, **current},
                       {"schema": 1, "verified": True, "files": []}):
            with self.subTest(record=record), self.assertRaisesRegex(RuntimeError, "unverified"):
                validate_build_record(record, current)

    def test_fingerprint_ignores_commits_and_documentation(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "Package.swift").write_text("package")
            original = source_manifest(root)
            (root / ".git").mkdir(); (root / ".git/HEAD").write_text("new commit")
            (root / "docs").mkdir(); (root / "docs/Report.md").write_text("documentation")
            self.assertEqual(original, source_manifest(root))

    def test_native_capture_uses_quiet_argv_and_only_its_png(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); snapshot = root / "native.png"; destination = root / "result.png"
            with patch("live_check.subprocess.Popen") as popen:
                process = popen.return_value; process.pid = 123; process.poll.return_value = None
                def launched(*args, **kwargs):
                    snapshot.write_bytes(self.png(2560, 1700))
                    (root / "capture-123.state").write_text("ready")
                    return process
                popen.side_effect = launched
                dimensions = capture_in_app(["Manping", "--ui-space-tab", "主页"], root / "Debug.app",
                                            snapshot, destination, 2)
                self.assertEqual(dimensions, (2560, 1700))
                self.assertEqual(destination.read_bytes(), snapshot.read_bytes())
                argv = popen.call_args.args[0]
                self.assertIn("--ui-quiet", argv); self.assertIn("主页", argv)
                self.assertEqual(argv[-3:], ["--ui-snapshot", str(snapshot), "2"])
                process.terminate.assert_called_once(); process.wait.assert_called_once()

    def test_early_success_exit_without_snapshot_is_a_failure(self):
        with tempfile.TemporaryDirectory() as directory, patch("live_check.subprocess.Popen") as popen:
            root = Path(directory)
            process = popen.return_value; process.pid = 123; process.poll.return_value = 0
            destination = root / "result.png"; destination.write_bytes(b"old capture")
            with self.assertRaisesRegex(RuntimeError, "exited before snapshot.*exit=0"):
                capture_in_app(["Manping"], root / "Debug.app", root / "missing.png", destination, 2)
            self.assertFalse(destination.exists())

    def test_native_capture_timeout_reports_missing_state(self):
        with tempfile.TemporaryDirectory() as directory, patch("live_check.subprocess.Popen") as popen:
            root = Path(directory)
            process = popen.return_value; process.pid = 123; process.poll.return_value = None
            with self.assertRaisesRegex(RuntimeError, "timed out.*state=missing"):
                capture_in_app(["Manping"], root / "Debug.app", root / "missing.png", root / "result.png", 2, timeout=0)
            process.terminate.assert_called_once()

    def test_truncated_or_corrupted_png_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            png = Path(directory) / "capture.png"
            complete = self.png(800, 600)
            for invalid in (complete[:24], complete[:-12], complete[:-1], complete[:40] + b"X" + complete[41:]):
                with self.subTest(size=len(invalid)), self.assertRaises(RuntimeError):
                    png.write_bytes(invalid)
                    png_dimensions(png)


if __name__ == "__main__":
    unittest.main()
