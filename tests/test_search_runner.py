"""Echte Unterprozesse prüfen Transport, Abbruch und Reihenfolge ohne GUI-Fokus."""
import json
import shutil
import unittest
from swift_test_support import run_probe


@unittest.skipUnless(shutil.which('swiftc'), 'swiftc fehlt')
class SearchRunnerTests(unittest.TestCase):
    def run_probe(self, mode):
        result = run_probe('runner', mode)
        report = json.loads(result.stdout)
        self.assertEqual(report['completions'], 1)
        self.assertFalse(report['running'])
        self.assertLessEqual(report['largest_batch'], 256)
        self.assertLessEqual(report['peak_packets'], 2)
        self.assertLessEqual(report['peak_bytes'], 1024 * 1024)
        return report

    def test_multiple_packets_and_partial_tail_arrive_in_order_before_completion(self):
        result = self.run_probe('ordered')
        self.assertEqual(result['hits'], 4097)
        self.assertTrue(result['ordered'])
        self.assertEqual(result['status'], 0)

    def test_progress_without_hits_reaches_consumer(self):
        result = self.run_probe('progress')
        self.assertEqual(result['hits'], 0)
        self.assertEqual(result['progress'], '/only-progress')

    def test_tail_and_eof_exit_order(self):
        for mode in ('tail', 'eof-first', 'exit-first'):
            with self.subTest(mode=mode):
                result = self.run_probe(mode)
                self.assertEqual(result['hits'], 1)
                self.assertEqual(result['status'], 0)

    def test_stderr_flood_and_start_error(self):
        result = self.run_probe('stderr')
        self.assertEqual(result['warnings'], 10000)
        self.assertEqual(result['hits'], 1)
        result = self.run_probe('start-error')
        self.assertEqual(result['status'], 2)
        self.assertTrue(result['error'])

    def test_foreign_stderr_line_names_the_failure(self):
        # /usr/bin/python3 ohne akzeptierte Xcode-Lizenz schreibt eine Zeile
        # ohne Favenio-Präfix und endet mit 69; die Zeile muss ankommen.
        result = self.run_probe('foreign-stderr')
        self.assertEqual(result['status'], 69)
        self.assertIn('Xcode license', result['error'])

    def test_foreign_stderr_line_with_crlf_is_trimmed(self):
        # Eine Leerzeile aus „\r\n" vor dem eigentlichen Text: gespeichert
        # wurde sonst „\r" als Grund, und die echte Zeile ging verloren.
        result = self.run_probe('foreign-crlf')
        self.assertEqual(result['status'], 69)
        self.assertEqual(result['error'], 'xcrun: error: invalid active developer path')

    def test_cancel_including_full_queue_and_before_start(self):
        for mode in ('cancel', 'backpressure', 'cancel-before'):
            with self.subTest(mode=mode):
                result = self.run_probe(mode)
                self.assertLess(result['seconds'], 2)
                self.assertNotEqual(result['status'], 0)
                if mode != 'cancel':
                    self.assertEqual(result['hits'], 0)
                if mode == 'backpressure':
                    self.assertEqual(result['peak_packets'], 2)

    def test_oversize_record_is_an_explicit_error(self):
        result = self.run_probe('oversize')
        self.assertEqual(result['status'], 2)
        self.assertIn('1 MiB', result['error'])
        self.assertLess(result['seconds'], 2)

    def test_sigterm_ignoring_child_is_killed_after_ready(self):
        result = self.run_probe('ignore-term')
        self.assertEqual(result['progress'], 'ready')
        self.assertEqual(result['status'], 9)
        self.assertGreaterEqual(result['seconds'], 0.5)
        self.assertLess(result['seconds'], 2)

    def test_long_records_respect_packet_byte_limit(self):
        result = self.run_probe('large-records')
        self.assertEqual(result['hits'], 5)
        self.assertGreater(result['peak_bytes'], 500000)

    def test_rapid_changes_reject_already_queued_old_hits(self):
        result = run_probe('runner', 'rapid')
        report = json.loads(result.stdout)
        self.assertEqual(report['completed'], 20)
        self.assertEqual(report['hits'], 1000)
        self.assertEqual(report['stale'], 0)
        self.assertGreater(report['first_queued'], 0)
