#!/usr/bin/env python3
"""Regress diagnostic failure propagation and portable/private output."""
from pathlib import Path
import tempfile
import unittest

from diagnostic_privacy import BUILD, portable, scrub
from performance_check import run_app
from diagnostic_terminal import terminal_outcome


class DiagnosticChecks(unittest.TestCase):
    @staticmethod
    def terminal_sample(at, terminal_at=25, **changes):
        sample = dict(elapsed_s=str(at), terminal='1', terminal_elapsed_s=str(terminal_at),
                      terminal_settled_elapsed_s=str(at), error='present', buffering='0',
                      advancing='0', raw_advancing='0', raw_render_advancing='0',
                      engine_idle='1', raw_engine_advancing='0', origin_active_requests='0',
                      origin_requests='4', origin_bytes='65536', observed_elapsed_s=str(at),
                      relay_inflight='0', relay_connections='0')
        sample.update(changes)
        return sample

    def test_transient_error_cannot_satisfy_terminal_deadline(self):
        transient = self.terminal_sample(2, terminal='0', terminal_elapsed_s='-1')
        samples = [transient, self.terminal_sample(50, 50), self.terminal_sample(51, 50)]
        result = terminal_outcome(samples, 0, 30)
        self.assertEqual(result['terminal_settled_s'], 50)
        self.assertFalse(result['bounded_error'])

    def test_true_terminal_holds_within_deadline(self):
        samples = [self.terminal_sample(25), self.terminal_sample(26)]
        self.assertTrue(terminal_outcome(samples, 0, 30)['bounded_error'])

    def test_terminal_resource_convergence_must_meet_deadline(self):
        samples = [self.terminal_sample(25, relay_inflight='1', relay_connections='1'),
                   self.terminal_sample(31), self.terminal_sample(32)]
        result = terminal_outcome(samples, 0, 30)
        self.assertEqual(result['terminal_settled_s'], 31)
        self.assertFalse(result['bounded_error'])

    def test_terminal_must_stay_stopped(self):
        for changes in (dict(terminal='0'), dict(error='none'), dict(buffering='1'),
                        dict(advancing='1'), dict(raw_advancing='1'), dict(raw_render_advancing='1'),
                        dict(engine_idle='0'), dict(raw_engine_advancing='1'), dict(origin_active_requests='1'),
                        dict(origin_requests='5'), dict(origin_bytes='65537'),
                        dict(relay_connections='1'), dict(relay_inflight='1'),
                        dict(terminal_elapsed_s='26')):
            with self.subTest(changes=changes):
                samples = [self.terminal_sample(25), self.terminal_sample(26, **changes),
                           self.terminal_sample(27)]
                self.assertFalse(terminal_outcome(samples, 0, 30)['bounded_error'])

    def test_first_terminal_tail_update_delays_settlement(self):
        samples = [self.terminal_sample(25, raw_advancing='1', raw_render_advancing='1'),
                   self.terminal_sample(26), self.terminal_sample(27)]
        result = terminal_outcome(samples, 0, 30)
        self.assertTrue(result['bounded_error'])
        self.assertEqual(result['terminal_settled_s'], 26)
        self.assertFalse(terminal_outcome(samples, 0, 25)['bounded_error'])

    def test_terminal_requires_explicit_state_and_later_observation(self):
        self.assertFalse(terminal_outcome([self.terminal_sample(25)], 0, 30)['bounded_error'])
        self.assertFalse(terminal_outcome([], 0, 30)['bounded_error'])
        samples = [self.terminal_sample(25, terminal='0'), self.terminal_sample(26, terminal='0')]
        self.assertFalse(terminal_outcome(samples, 0, 30)['bounded_error'])

    def test_frozen_ui_cannot_hide_busy_engine_or_origin_past_deadline(self):
        for busy in (dict(engine_idle='0'), dict(origin_active_requests='1'),
                     dict(engine_idle='0', raw_engine_advancing='1')):
            with self.subTest(busy=busy):
                samples = [self.terminal_sample(25, **busy), self.terminal_sample(26, **busy),
                           self.terminal_sample(50), self.terminal_sample(51)]
                result = terminal_outcome(samples, 0, 30)
                self.assertEqual(result['terminal_settled_s'], 50)
                self.assertFalse(result['bounded_error'])

    def test_engine_and_origin_may_finish_teardown_before_deadline(self):
        samples = [self.terminal_sample(23, terminal_at=23, engine_idle='0', raw_engine_advancing='1'),
                   self.terminal_sample(24, terminal_at=23, origin_active_requests='1'),
                   self.terminal_sample(25, terminal_at=23), self.terminal_sample(26, terminal_at=23)]
        result = terminal_outcome(samples, 0, 30)
        self.assertEqual(result['terminal_settled_s'], 25)
        self.assertTrue(result['bounded_error'])

    def test_delayed_origin_observation_cannot_backdate_settlement(self):
        samples = [self.terminal_sample(25, observed_elapsed_s='50'),
                   self.terminal_sample(26, observed_elapsed_s='51')]
        result = terminal_outcome(samples, 0, 30)
        self.assertEqual(result['terminal_settled_s'], 50)
        self.assertFalse(result['bounded_error'])

    def test_terminal_requires_engine_and_origin_evidence(self):
        for missing in ('engine_idle', 'raw_engine_advancing', 'origin_active_requests',
                        'origin_requests', 'origin_bytes', 'observed_elapsed_s'):
            with self.subTest(missing=missing):
                samples = [self.terminal_sample(25), self.terminal_sample(26)]
                for sample in samples:
                    sample.pop(missing)
                self.assertFalse(terminal_outcome(samples, 0, 30)['bounded_error'])
        samples = [self.terminal_sample(25, engine_idle='unknown'), self.terminal_sample(26, engine_idle='unknown')]
        self.assertFalse(terminal_outcome(samples, 0, 30)['bounded_error'])

    def test_private_output(self):
        value = scrub(str(BUILD / 'test/report.log') + '\nCookie: fixture-value\n'
                      'http://127.0.0.1/r/0123456789abcdef0123456789abcdef/stream.mp4')
        self.assertIn('.build/test/report.log', value)
        self.assertNotIn(str(Path.home()), value)
        self.assertNotIn('fixture-value', value)
        self.assertNotIn('0123456789abcdef', value)
        self.assertEqual(portable(BUILD / 'test/report.log'), '.build/test/report.log')
        for path in ('/usr/bin/vmmap', '/System/Library/Frameworks', '/Applications/Xcode.app', '/opt/homebrew/bin/mpv'):
            self.assertNotIn(path, scrub('Analysis Tool: ' + path))

    def test_playback_failure_does_not_pass_with_complete_marker(self):
        BUILD.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir=BUILD, prefix='diagnostic-check-') as directory:
            output = Path(directory)
            binary = output / 'fixture-player'
            binary.write_text('#!/bin/sh\necho "PERF playback END result=FAIL"\necho "PERF complete"\n')
            binary.chmod(0o700)
            with self.assertRaisesRegex(RuntimeError, 'incomplete diagnostic'):
                run_app(binary, [], 'fixture', output, 5)


if __name__ == '__main__':
    unittest.main()
