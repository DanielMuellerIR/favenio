"""Abbrechbare Materialisierung von Archivtreffern: echte Unterprozesse,
keine App, kein Fenster (Probe: tests/materialization_probe.swift)."""
import json
import shutil
import sys
import tempfile
import textwrap
import unittest
import zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from swift_test_support import run_probe  # noqa: E402

REPO = Path(__file__).resolve().parent.parent

# Ein Kern-Ersatz, der die Argumente von --extract-json/--extract-root
# versteht und sich sonst verhält, wie der jeweilige Fall es braucht.
FAKE_CLI_HEAD = textwrap.dedent('''\
    import json, os, sys, tempfile, time
    args = sys.argv[1:]
    root = args[args.index("--extract-root") + 1]
    record = json.loads(args[args.index("--extract-json") + 1])
    def emit():
        out_dir = tempfile.mkdtemp(prefix="hit-", dir=root)
        path = os.path.join(out_dir, os.path.basename(record["archiveMembers"][-1]))
        with open(path, "w") as handle:
            handle.write("FAKE")
        print(path)
    ''')


@unittest.skipUnless(shutil.which('swiftc'), 'swiftc fehlt')
class MaterializationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory(prefix='favenio-mat-test-')
        cls.root = Path(cls.tmp.name)
        cls.archive = cls.root / 'probe.zip'
        with zipfile.ZipFile(cls.archive, 'w') as archive:
            archive.writestr('inner/geheim.txt', 'FAVENIO_PROBE im Zip')
            for index in range(20):
                archive.writestr('member-%d.txt' % index, 'nr %d' % index)
        cls.broken = cls.root / 'kaputt.zip'
        cls.broken.write_bytes(b'PK\x03\x04 abgeschnitten')

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def fake_cli(self, name, body):
        path = self.root / (name + '.py')
        path.write_text(FAKE_CLI_HEAD + textwrap.dedent(body))
        return str(path)

    def run_probe(self, *arguments, timeout=30):
        result = run_probe('materialization', *arguments, timeout=timeout)
        report = json.loads(result.stdout)
        self.assertTrue(report['on_main'])
        root = Path(report['temporary_root'])
        self.assertTrue(root.name.startswith('favenio-probe-'), report)
        for outcome in (report, report.get('first', {}), report.get('second', {})):
            if outcome.get('state') == 'ready':
                self.assertIn(root, Path(outcome['path']).parents)
        return report

    def test_a_member_is_extracted_off_the_main_thread(self):
        report = self.run_probe('benchmark', self.archive, 'inner/geheim.txt')
        self.assertTrue(report['ok'], report)
        self.assertEqual(report['bytes'], len('FAVENIO_PROBE im Zip'))
        # Der Aufruf selbst kehrt sofort zurück; Main bleibt frei.
        self.assertLess(report['blocked_seconds'], 0.01)
        self.assertLess(report['max_delay'], 0.05)

    def test_synchronous_preview_replacement_clears_the_loading_state(self):
        report = self.run_probe('preview-sync', self.archive, 'inner/geheim.txt')
        self.assertEqual(report['states'], [True, False])
        self.assertFalse(report['materializing'])
        self.assertEqual(report['latest_urls'], [str(self.archive)])
        self.assertEqual(report['stale'], 0)
        self.assertEqual(report['callbacks'], 1)

    def test_open_and_preview_share_one_extracted_file(self):
        report = self.run_probe('same-file', self.archive, 'inner/geheim.txt')
        self.assertEqual(report['state'], 'ready')
        self.assertTrue(report['deferred'])
        # Die zweite Anforderung kommt aus dem Cache: sofort, synchron,
        # dieselbe Datei — die auch knownURL() (Drag-and-drop) nennt.
        self.assertEqual(report['second']['state'], 'ready')
        self.assertEqual(report['second']['path'], report['path'])
        self.assertFalse(report['second_deferred'])
        self.assertEqual(report['known'], report['path'])

    def test_trailing_filename_whitespace_survives_extraction_and_cache(self):
        for suffix in (' ', '\t', '\n', '\r', '\r\n', ' \t\n'):
            with self.subTest(suffix=repr(suffix)):
                member = 'inner/note.txt' + suffix
                archive_path = self.root / 'whitespace.zip'
                with zipfile.ZipFile(archive_path, 'w') as archive:
                    archive.writestr(member, b'unchanged bytes')
                report = self.run_probe('same-file', archive_path, member)
                self.assertEqual(report['state'], 'ready', report)
                self.assertEqual(Path(report['path']).name, 'note.txt' + suffix)
                self.assertEqual(report['bytes'], len(b'unchanged bytes'))
                self.assertEqual(report['second']['path'], report['path'])
                self.assertFalse(report['second_deferred'])
                self.assertEqual(report['known'], report['path'])

    def test_successful_core_cannot_publish_a_missing_path(self):
        cli = self.fake_cli('missing-path', '''
            print(os.path.join(root, "missing.txt"))
            ''')
        report = self.run_probe('stderr-flood', cli, self.archive, 'x.txt')
        self.assertEqual(report['state'], 'failed', report)

    def test_start_error_names_the_interpreter(self):
        report = self.run_probe('start-error', self.archive, 'inner/geheim.txt')
        self.assertEqual(report['state'], 'failed')
        self.assertIn('nicht startbar', report['reason'])

    def test_a_broken_archive_reports_the_core_reason(self):
        report = self.run_probe('broken', self.broken, 'inner/geheim.txt')
        self.assertEqual(report['state'], 'failed')
        # Die Fehlerzeile des Kerns, nicht ein pauschales „fehlgeschlagen".
        self.assertIn('kaputt.zip', report['reason'])
        self.assertNotIn('Status', report['reason'])

    def test_a_budget_overrun_reports_the_limit(self):
        report = self.run_probe('budget', self.archive, 'inner/geheim.txt')
        self.assertEqual(report['state'], 'failed')
        self.assertIn('Einzelgrenze 10', report['reason'])

    def test_a_stderr_flood_does_not_stall_the_extraction(self):
        # Eine volle stderr-Pipe hält den Kern an, während wir auf stdout
        # warten. 200 000 Zeilen sind weit mehr als ein Pipe-Puffer.
        cli = self.fake_cli('flood', '''
            for i in range(200000):
                print("favenio: warnung: %d" % i, file=sys.stderr)
            emit()
            ''')
        report = self.run_probe('stderr-flood', cli, self.archive, 'x.txt')
        self.assertEqual(report['state'], 'ready', report)

    def test_cancel_terminates_the_core(self):
        pid_file = self.root / 'cancel.pid'
        cli = self.fake_cli('slow', '''
            open(%r, "w").write(str(os.getpid()))
            time.sleep(20)
            emit()
            ''' % str(pid_file))
        report = self.run_probe('cancel', cli, self.archive, 'x.txt', pid_file)
        self.assertEqual(report['state'], 'cancelled')
        self.assertLess(report['cancel_seconds'], 2)
        self.assertTrue(report['process_gone'])

    def test_rapid_selection_changes_deliver_only_the_last(self):
        report = self.run_probe('rapid', self.archive, timeout=60)
        self.assertEqual(report['completed'], 20)
        self.assertFalse(report['last_cancelled'])
        self.assertEqual(len(report['last_urls']), 1)
        self.assertTrue(report['last_urls'][0].endswith('member-19.txt'))
        # Alle anderen wurden abgebrochen — kein alter Auftrag legt sich
        # über die letzte Auswahl.
        self.assertEqual(report['cancelled'], 19)

    def test_concurrent_requests_share_one_extraction(self):
        counter = self.root / 'shared.count'
        cli = self.fake_cli('counted', '''
            with open(%r, "a") as handle:
                handle.write("x")
            time.sleep(0.3)
            emit()
            ''' % str(counter))
        report = self.run_probe('shared', cli, self.archive, 'x.txt')
        self.assertEqual(report['first']['state'], 'ready')
        self.assertEqual(report['second']['state'], 'ready')
        self.assertEqual(report['first']['path'], report['second']['path'])
        self.assertEqual(counter.read_text(), 'x')

    def test_cleanup_stops_running_jobs_and_creates_nothing_afterwards(self):
        cli = self.fake_cli('late', '''
            time.sleep(0.5)
            emit()
            ''')
        report = self.run_probe('cleanup', cli, self.archive, 'x.txt')
        self.assertEqual(report['state'], 'cancelled')
        # Der Root ist nach cleanup() weg und kommt durch den späten
        # Auftrag nicht wieder.
        self.assertEqual(report['dirs_after_cleanup'], report['dirs_before'])
        self.assertEqual(report['dirs_end'], report['dirs_before'])

    def test_cancel_and_cleanup_still_apply_before_queued_callbacks_arrive(self):
        for mode in ('late-selection', 'late-cancel', 'late-cleanup',
                     'reentrant-cancel', 'reentrant-cleanup'):
            with self.subTest(mode=mode):
                release = self.root / (mode + '.release')
                cli = self.fake_cli(mode, '''
                    deadline = time.monotonic() + 15
                    while not os.path.exists(%r):
                        if time.monotonic() >= deadline:
                            raise RuntimeError("Freigabe der Probe fehlt")
                        time.sleep(0.001)
                    emit()
                    ''' % str(release))
                report = self.run_probe(mode, cli, self.archive, 'x.txt', release)
                if mode == 'late-selection':
                    self.assertTrue(report['selection_cancelled'], report)
                    self.assertEqual(report['callbacks'], 1)
                    continue
                first = 'cancelled' if mode.startswith('late-') else 'ready'
                second = 'ready' if mode == 'late-cancel' else 'cancelled'
                self.assertEqual(report['first']['state'], first, report)
                self.assertEqual(report['second']['state'], second, report)
                cleanup = mode.endswith('cleanup')
                self.assertEqual(report['cached'], not cleanup, report)
                self.assertEqual(report['file_exists'], not cleanup, report)
                self.assertEqual(report['callbacks'], 3 if mode == 'late-cancel' else 2)
                if mode == 'late-cancel':
                    self.assertTrue(report['cache_synchronous'], report)


if __name__ == '__main__':
    unittest.main()
