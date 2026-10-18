"""Begrenzte Suchberichte: echte Auslassungen, Kompatibilität und Transport."""
import contextlib
import io
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import tracemalloc
import unittest
from unittest import mock
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import favenio
from swift_test_support import run_probe, suite_binary

REPO = Path(__file__).resolve().parent.parent


class SearchReportTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='favenio-report-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def search(self, *options):
        output, errors = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(output), contextlib.redirect_stderr(errors):
            code = favenio.main(['--json', '--search-report', *options, '--', 'needle', str(self.root)])
        return code, [json.loads(line) for line in output.getvalue().splitlines()], errors.getvalue()

    def test_opt_in_keeps_plain_jsonl_and_stderr_unchanged(self):
        (self.root / 'needle.txt').write_text('needle')
        (self.root / 'broken.zip').write_bytes(b'PK\x03\x04damaged')
        argv = ['--json', '--content', '--', 'needle', str(self.root)]
        def run(options):
            out, err = io.StringIO(), io.StringIO()
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                code = favenio.main(options)
            return code, [json.loads(x) for x in out.getvalue().splitlines()], err.getvalue()
        plain = run(argv)
        report = run(['--search-report'] + argv)
        self.assertEqual(plain, (report[0], [x for x in report[1] if x['type'] != 'searchReport'], report[2]))
        final = report[1][-1]
        self.assertEqual(final['state'], 'finished')
        self.assertEqual(final['coverage'], 'incomplete')
        self.assertEqual(final['reasons'][0]['id'], 'damagedArchive')

    def test_permission_archive_and_budget_are_distinct(self):
        protected = self.root / 'protected.txt'
        protected.write_text('needle')
        protected.chmod(0)
        self.addCleanup(protected.chmod, 0o600)
        (self.root / 'broken.zip').write_bytes(b'PK\x03\x04bad')
        with zipfile.ZipFile(self.root / 'large.zip', 'w') as archive:
            archive.writestr('large.txt', 'needle' * 30)
        code, records, errors = self.search('--content', '--max-archive-member-bytes', '20')
        self.assertEqual(code, 1)
        reasons = {r['id']: r for r in records[-1]['reasons']}
        self.assertEqual(set(reasons), {'permissionDenied', 'damagedArchive', 'archiveMemberBytes'})
        self.assertEqual({r['category'] for r in reasons.values()}, {'readError', 'budget'})
        self.assertEqual(errors.count('favenio: warnung: '), 3)
        self.assertEqual(reasons['permissionDenied']['examples'][0]['path'], str(protected))

    def test_pruned_subtree_is_one_event_not_unknown_descendant_count(self):
        (self.root / 'skip').mkdir()
        (self.root / 'skip' / 'child').mkdir()
        (self.root / 'skip' / 'child' / 'needle').write_text('needle')
        (self.root / '.hidden').write_text('needle')
        (self.root / 'limited').mkdir()
        code, records, _ = self.search('--exclude', 'skip', '--max-depth', '1')
        reasons = {r['id']: r['count'] for r in records[-1]['reasons']}
        self.assertEqual(reasons, {'excludedPattern': 1, 'hidden': 1, 'folderDepth': 1})
        self.assertEqual(records[-1]['counting'], 'events')
        self.assertEqual(records[-1]['coverage'], 'incomplete')

    def test_config_retains_file_criteria_requested_encoding_and_limits(self):
        criteria = {'schemaVersion': 1, 'root': {'id': 'n', 'field': 'name', 'operator': 'contains', 'value': '\ufeffneedle'}}
        source = self.root / 'criteria.json'
        source.write_text(json.dumps(criteria))
        _, records, _ = self.search('--encoding', 'auto', '--criteria-file', str(source))
        config = records[-1]['configuration']
        self.assertEqual(config['criteria'], criteria)
        self.assertEqual(config['encoding'], 'auto')
        self.assertIn('tarMembers', config['fixedLimits'])
        self.assertEqual(records[0]['runID'], records[-1]['runID'])

    def test_report_does_not_change_early_read_end(self):
        matcher = favenio.build_matcher('needle', False, False)
        def chunks():
            yield b'needle\n'
            raise AssertionError('frühes Leseende verloren')
        search = favenio.Search(matcher, True, 1, True, search_report=favenio.SearchReport({}))
        self.assertEqual(search.match_content(chunks()), 1)

    def test_bounded_examples_broken_names_counter_saturation_and_config(self):
        report = favenio.SearchReport({'pattern': '"' * 200000})
        for i in range(20000):
            report.record('readError', str(i) + '\udcff\n' + 'x' * 500)
        item = report.reasons['readError']
        self.assertEqual(item['count'], 20000)
        self.assertEqual(len(item['examples']), 3)
        self.assertTrue(all(x['truncated'] and len(x['path']) <= 256 and '\udcff' not in x['path'] for x in item['examples']))
        item['count'] = favenio.MAX_REPORT_COUNT
        report.record('readError', '/same')
        self.assertTrue(item['countCapped'])
        self.assertEqual(item['count'], favenio.MAX_REPORT_COUNT)
        for reason in favenio.REPORT_REASONS:
            for i in range(3): report.record(reason, str(i) + '界' * 300)
        raw = json.dumps(report.snapshot('finished'), ensure_ascii=True).encode()
        self.assertLess(len(raw), favenio.MAX_REPORT_BYTES)
        self.assertTrue(report.configuration['truncated'])
        with self.assertRaises(ValueError): report.record('undefined')
        long_path = 'x\udcff' * (5 * 1024 * 1024 // 2)
        bounded = favenio.SearchReport({})
        tracemalloc.start()
        try:
            bounded.record('readError', long_path)
            peak = tracemalloc.get_traced_memory()[1]
        finally:
            tracemalloc.stop()
        self.assertLess(peak, 128 * 1024)
        self.assertEqual(len(bounded.reasons['readError']['examples'][0]['path']), 256)


    def test_missing_archive_tool_and_no_archives_keep_raw_search(self):
        (self.root / 'needle.7z').write_text('needle')
        with mock.patch.object(favenio, 'external_archive_tools', return_value=(None, None, {})):
            code, records, _ = self.search('--content')
        self.assertEqual(code, 0)
        self.assertEqual(records[-1]['reasons'][0]['id'], 'toolUnavailable')
        with zipfile.ZipFile(self.root / 'a.zip', 'w') as archive: archive.writestr('a.txt', 'needle')
        _, records, _ = self.search('--no-archives')
        self.assertIn('archiveDepth', {r['id'] for r in records[-1]['reasons']})

    def test_full_registry_astral_and_control_examples_fit_record_byte_limit(self):
        for sample in ('😀', '\x01'):
            report = favenio.SearchReport({'pattern': '"' * 70000})
            for reason in favenio.REPORT_REASONS:
                for index in range(3): report.record(reason, str(index) + sample * 255)
            output = io.StringIO()
            with contextlib.redirect_stdout(output): report.emit('finished', force=True)
            self.assertLessEqual(len(output.getvalue().encode('utf-8')), favenio.MAX_REPORT_BYTES + 1)
            parsed = json.loads(output.getvalue())
            self.assertEqual(len(parsed['reasons']), len(favenio.REPORT_REASONS))
            self.assertTrue(all(item['count'] == 3 for item in parsed['reasons']))
            self.assertTrue(all(len(example['path']) == 256 for item in report.reasons.values() for example in item['examples']))
            self.assertLessEqual(len(json.dumps(parsed['configuration'], ensure_ascii=True)), 65536)

    def test_disabled_archive_and_large_numeric_filter_remain_truthful(self):
        (self.root / 'needle.7z').write_text('needle')
        with mock.patch.object(favenio, 'external_archive_tools', return_value=(None, None, {})):
            _, records, _ = self.search('--no-archives')
        self.assertEqual({r['id'] for r in records[-1]['reasons']}, {'archiveDepth'})
        limit = 9007199254740993
        _, records, _ = self.search('--min-size', str(limit))
        self.assertEqual(records[-1]['configuration']['min_size'], str(limit))

    def test_long_anchored_line_and_fifo_have_stable_reasons(self):
        (self.root / 'long.txt').write_text('x' * (favenio.MAX_LINE_CHARS + 10))
        os.mkfifo(self.root / 'pipe')
        _, records, _ = self.search('--content', '--regex')
        self.assertEqual({r['id'] for r in records[-1]['reasons']}, {'lineTooLong', 'notRegularFile'})

    def test_budget_types_and_failed_stat_keep_their_reason(self):
        report = favenio.SearchReport({})
        search = favenio.Search(None, False, 1, True, search_report=report)
        cases = [
            (favenio.ArchiveBudget(1, 100, 100), lambda budget: budget.validate('/member', 2, 2), 'archiveMemberBytes'),
            (favenio.ArchiveBudget(100, 1, 100), lambda budget: list(budget.iter_chunks(io.BytesIO(b'xx'), '/member')), 'archiveTotalBytes'),
            (favenio.ArchiveBudget(100, 100, 1), lambda budget: budget.validate('/member', 10, 1), 'archiveRatio'),
        ]
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            for budget, invoke, reason in cases:
                with self.assertRaises(favenio.ArchiveLimitError) as caught: invoke(budget)
                search.report_warning(str(caught.exception), path='/member', error=caught.exception)
                self.assertEqual(caught.exception.reason, reason)
            with mock.patch.object(favenio, 'MAX_TAR_MEMBERS', 1):
                with self.assertRaises(favenio.ArchiveLimitError) as caught: favenio.bounded_tar_members([object(), object()])
            self.assertEqual(caught.exception.reason, 'archiveMemberCount')
            facts = search.file_facts(str(self.root / 'missing'), onerror=lambda err: search.omission(favenio.report_error_reason(err), str(self.root / 'missing')))
            self.assertEqual(facts, (None, None, None))
        self.assertEqual({reason for reason in report.reasons}, {'archiveMemberBytes', 'archiveTotalBytes', 'archiveRatio', 'readError'})

    def test_unknown_criteria_and_archive_creation_date_are_not_complete(self):
        (self.root / 'needle-note.txt').write_text('needle')
        criteria = {'schemaVersion': 1, 'root': {'id': 'n', 'field': 'metadata', 'operator': 'contains', 'value': 'absent', 'negate': True}}
        with mock.patch.object(favenio, 'external_archive_tools', return_value=(None, None, '/fixture/exiftool')):
            _, records, _ = self.search('--criteria-json', json.dumps(criteria))
        self.assertEqual({r['id'] for r in records[-1]['reasons']}, {'metadataUnsupported', 'criterionUnknown'})
        self.assertEqual(records[-1]['coverage'], 'incomplete')
        with zipfile.ZipFile(self.root / 'a.zip', 'w') as archive: archive.writestr('needle.txt', 'needle')
        _, records, _ = self.search('--created-from', '2000-01-01T00:00:00Z')
        self.assertIn('factUnavailable', {r['id'] for r in records[-1]['reasons']})
        self.assertEqual(records[-1]['coverage'], 'incomplete')

    def test_failure_and_signal_are_incomplete(self):
        (self.root / 'needle').write_text('needle')
        out = io.StringIO()
        with mock.patch.object(favenio.Search, 'search_path', side_effect=RuntimeError('test-failure')), contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(favenio.main(['--json', '--search-report', 'needle', str(self.root)]), 2)
        final = json.loads(out.getvalue().splitlines()[-1])
        self.assertEqual((final['state'], final['coverage']), ('failed', 'incomplete'))
        script = '''import favenio,time
favenio.Search.search_path=lambda *args: time.sleep(60)
favenio.main(['--json','--search-report','needle','.'])'''
        with subprocess.Popen([sys.executable, '-u', '-c', script], cwd=REPO, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True) as child:
            first = json.loads(child.stdout.readline())
            child.terminate()
            output, error = child.communicate(timeout=3)
            self.assertEqual(child.returncode, 128 + signal.SIGTERM)
            final = json.loads(output.splitlines()[-1])
            self.assertEqual(final['runID'], first['runID'])
            self.assertEqual((final['state'], final['coverage']), ('cancelled', 'incomplete'))


class SearchReportSwiftTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        suite_binary()

    def probe(self, mode):
        result = run_probe('search-report', mode, timeout=30)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return json.loads(result.stdout)

    def test_warning_flood_drains_both_pipes_and_keeps_counts(self):
        report = self.probe('flood')
        self.assertEqual(report['warnings'], 12000)
        self.assertEqual(report['events'], 12000)
        self.assertEqual(report['examples'], 3)
        self.assertLessEqual(report['peakPackets'], 2)
        self.assertEqual(report['state'], 'finished')
        self.assertEqual(report['coverage'], 'incomplete')

    def test_export_captures_running_state_and_original_bom_then_cancels(self):
        report = self.probe('live-export')
        self.assertEqual(report['exportedState'], 'running')
        self.assertFalse(report['cancelWarningKnown'])
        self.assertEqual(report['state'], 'cancelled')
        self.assertEqual(report['coverage'], 'incomplete')
        self.assertTrue(report['bomPreserved'])
        self.assertTrue(report['writerFinished'])
        self.assertTrue(report['invalidRejected'])
        self.assertEqual(report['restoredState'], 'recorded')
        self.assertEqual(report['limitState'], 'limitReached')

    def test_invalid_report_is_a_visible_protocol_failure(self):
        report = self.probe('invalid')
        self.assertEqual(report['status'], 2)
        self.assertEqual(report['state'], 'failed')
        self.assertEqual(report['coverage'], 'incomplete')
        self.assertIn('Suchbericht', report['error'])
