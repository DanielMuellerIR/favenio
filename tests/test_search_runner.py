"""Echte Unterprozesse prüfen Transport, Abbruch und Reihenfolge ohne GUI-Fokus."""
import json
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent


def build_probe(directory, probe="runner_probe.swift"):
    source = (REPO / 'common/FavenioCore.swift').read_text()
    # Sparkle betrifft ausschließlich den Bundle-Einstieg vor dem Hit-Modell.
    source = ('import AppKit\nimport Darwin\nimport Quartz\n'
              'import UniformTypeIdentifiers\nlet pythonPath = "/usr/bin/python3"\n'
              + source[source.index('struct Hit:'):])
    core = Path(directory) / 'Core.swift'
    core.write_text(source)
    binary = Path(directory) / 'RunnerProbe'
    result = subprocess.run(
        ['swiftc', '-O', str(core), str(REPO / 'tests' / probe),
         '-o', str(binary)], capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError("Runner-Probe kompiliert nicht:\n" + result.stderr)
    return binary


@unittest.skipUnless(shutil.which('swiftc'), 'swiftc fehlt')
class SearchRunnerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.binary = build_probe(cls.tmp.name)

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def run_probe(self, mode):
        result = subprocess.run([str(self.binary), mode], check=True,
                                capture_output=True, text=True, timeout=20)
        report = json.loads(result.stdout)
        self.assertTrue(report['on_main'])
        self.assertFalse(report['running'])
        self.assertLessEqual(report['largest_batch'], 256)
        self.assertLessEqual(report['peak_packets'], 2)
        self.assertLessEqual(report['peak_bytes'], 1024 * 1024)
        return report

    def test_100000_hits_arrive_before_completion(self):
        result = self.run_probe('benchmark')
        self.assertEqual(result['hits'], 100000)
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
        result = subprocess.run([str(self.binary), 'rapid'], check=True,
                                capture_output=True, text=True, timeout=20)
        report = json.loads(result.stdout)
        self.assertEqual(report['completed'], 20)
        self.assertEqual(report['hits'], 1000)
        self.assertEqual(report['stale'], 0)
        self.assertGreater(report['first_queued'], 0)

    def test_quick_stops_with_twenty_hits(self):
        result = self.run_probe('top20')
        self.assertEqual(result['hits'], 20)
        self.assertLess(result['seconds'], 2)
