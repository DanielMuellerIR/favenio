"""Bekannte Trefferwerte filtern: keine Quellenöffnung und unveränderte Belege."""
import base64
import io
import json
from pathlib import Path
import signal
import sys
import subprocess
import unittest
from unittest import mock

from test_favenio import TempTreeTest, favenio, run
from test_criteria import leaf, group


def record(name='fu\u0308r.txt', **extra):
    path = '/missing/' + name
    return dict(path=path, type='file', filesystemPath=path,
                archiveMembers=[], isDirectory=False, **extra)


class ResultFilterTests(TempTreeTest):
    def apply(self, rows, node, *options):
        source = Path(self.root, 'results.jsonl')
        source.write_text(''.join(json.dumps(row, ensure_ascii=True) + '\n' for row in rows))
        return run(['--filter-results=' + str(source), '--criteria-json=' + json.dumps(
            dict(schemaVersion=1, root=node)), *options])

    def test_existing_normalization_regex_case_and_glob_rules(self):
        rows = [record()]
        self.assertEqual(self.apply(rows, leaf('n', 'name', value='für'))[0], 0)
        self.assertEqual(self.apply(rows, leaf('n', 'name', operator='regex', value='für'))[0], 1)
        self.assertEqual(self.apply(rows, leaf('n', 'name', operator='glob', value='*.txt'))[0], 0)
        self.assertEqual(self.apply(rows, leaf('n', 'name', value='FÜR', caseSensitive=True))[0], 1)
        self.assertEqual(self.apply(rows, leaf('n', 'extension', operator='equals', value='TXT'))[0], 0)

    def test_known_facts_and_three_valued_negation(self):
        rows = [record(size=2048, modified=1720000000, width=1200, height=800), record('unknown.txt')]
        for field, value in [('size', '1 KiB'), ('width', '1000'), ('modified', '2024-01-01T00:00:00Z')]:
            code, matches, errors = self.apply(rows, leaf('f', field, operator='atLeast', value=value))
            self.assertEqual((code, len(matches), errors), (0, 1, ''))
            self.assertEqual(self.apply([rows[1]], leaf('f', field, operator='atLeast', value=value, negate=True))[0], 1)
        self.assertEqual(self.apply(rows, group('any', 'or', leaf('n', 'name', value='unknown'), leaf('f', 'size', operator='atLeast', value='1 KiB')))[0], 0)

    def test_directories_do_not_invent_size_extension_or_dimensions(self):
        row = record('folder.txt', size=100, width=1200)
        row['isDirectory'] = True
        row['type'] = 'dir'
        for field, value, op in [('extension', 'txt', 'equals'), ('size', '1', 'atLeast'), ('width', '1', 'atLeast')]:
            self.assertEqual(self.apply([row], leaf('f', field, operator=op, value=value, negate=True))[0], 1)

    def test_sources_are_never_opened_and_original_records_remain(self):
        row = record(size=42, line=7, contentEncoding='pptx-text-v1',
                     contentPreview={'schemaVersion': 1, 'snippets': []}, arbitrary='unchanged')
        with mock.patch.object(favenio, 'FileProbe', side_effect=AssertionError('source probe')), \
             mock.patch.object(favenio.Search, 'search_path', side_effect=AssertionError('scan')):
            code, matches, errors = self.apply([row], leaf('n', 'name', value='für'))
        self.assertEqual((code, errors), (0, ''))
        self.assertEqual(matches, [json.dumps(row, ensure_ascii=True)])

    def test_relative_paths_and_archive_bytes_not_display_separator(self):
        row = record('archive.zip')
        row.update(type='member', archiveMembers=['folder!/bad-\ufffd.txt'],
                   archiveMemberBytes=[base64.b64encode(b'folder!/bad-\xff.txt').decode()])
        self.assertEqual(self.apply([row], leaf('p', 'relativePath', value='folder!/'))[0], 0)
        self.assertEqual(self.apply([row], leaf('n', 'name', value='bad-'))[0], 0)
        self.assertEqual(self.apply([row], leaf('n', 'name', value='\ufffd'))[0], 1)
        self.assertEqual(self.apply([record()], leaf('p', 'relativePath', operator='equals', value='missing/für.txt'), '--results-root=/')[0], 0)

    def test_file_start_root_uses_name_but_directory_root_uses_dot(self):
        row = record('test.txt')
        self.assertEqual(self.apply([row], leaf('p', 'relativePath', operator='equals', value='test.txt'), '--results-root=/missing/test.txt')[0], 0)
        row['isDirectory'] = True
        self.assertEqual(self.apply([row], leaf('p', 'relativePath', operator='equals', value='.'), '--results-root=/missing/test.txt')[0], 0)

    def test_content_and_metadata_rejected_before_input_open(self):
        for field in ['content', 'metadata']:
            with mock.patch.object(favenio, 'open_regular_file', side_effect=AssertionError('opened')):
                code, _, errors = run(['--filter-results=/does-not-exist', '--criteria-json=' + json.dumps(dict(schemaVersion=1, root=leaf('f', field, value='text')))])
            self.assertEqual(code, 2)
            self.assertIn('bekannte Fakten', errors)

    def test_validation_without_scan_and_incompatible_modes(self):
        criteria = '--criteria-json=' + json.dumps(dict(schemaVersion=1, root=leaf('n', 'name', value='text')))
        with mock.patch.object(favenio, 'open_regular_file', side_effect=AssertionError('opened')):
            self.assertEqual(run(['--validate-result-filter', criteria])[0], 0)
        for options in [['--content'], ['--term=x'], ['--search-report', '--json'], ['--preview-request={}'], ['--validate-result-filter'], ['some-pattern']]:
            code, _, errors = run(['--filter-results=/missing', criteria, *options])
            self.assertEqual(code, 2, errors)
        self.assertEqual(run(['--filter-results=-', '--criteria-file=-'])[0], 2)
        self.assertEqual(run(['--results-root=/'])[0], 2)
        self.assertEqual(run(['--validate-result-filter', criteria, '--results-root=relative'])[0], 2)

    def test_malformed_facts_identities_records_and_limits(self):
        for changes in [dict(size=True), dict(size=-1), dict(modified=float('nan')), dict(width='100'), dict(isDirectory=1), dict(archiveMemberBytes=['bad']), dict(filesystemPath='relative')]:
            row = record(); row.update(changes)
            self.assertEqual(self.apply([row], leaf('n', 'name', value='für'))[0], 2, changes)
        with mock.patch.object(favenio, 'RESULT_FILTER_RECORD_BYTES', 16):
            self.assertEqual(self.apply([record()], leaf('n', 'name', value='für'))[0], 2)
        query = favenio.parse_criteria_query(dict(schemaVersion=1, root=leaf('n', 'name', value='für')))
        for data in [b'{}\n', b'\xff\n', b'{"type":"file","type":"dir"}\n']:
            with self.assertRaises((ValueError, UnicodeError)):
                list(favenio.iter_filtered_results(io.BytesIO(data), query))
        for constant in ['NaN', 'Infinity', '-Infinity']:
            text = json.dumps(record())[:-1] + ',"unknown":' + constant + '}\n'
            with self.assertRaises(ValueError):
                list(favenio.iter_filtered_results(io.BytesIO(text.encode()), query))

    def test_fifo_rejected_without_waiting_and_stdin_supported(self):
        import os
        source = Path(self.root, 'fifo'); os.mkfifo(source)
        query = json.dumps(dict(schemaVersion=1, root=leaf('n', 'name', value='für')))
        self.assertEqual(run(['--filter-results=' + str(source), '--criteria-json=' + query])[0], 2)
        with mock.patch.object(sys, 'stdin', io.BytesIO((json.dumps(record())+'\n').encode())):
            self.assertEqual(run(['--filter-results=-', '--criteria-json=' + query])[0], 0)

    def test_timeout_interrupts_regex_and_restores_alarm(self):
        old = signal.getsignal(signal.SIGALRM)
        with mock.patch.object(favenio, 'RESULT_FILTER_SECONDS', .02):
            code, _, errors = self.apply([record('a'*30000+'X')], leaf('n', 'name', operator='regex', value='(a+)+$'))
        self.assertEqual(code, 2)
        self.assertIn('Zeitbudget', errors)
        self.assertEqual(signal.getsignal(signal.SIGALRM), old)
        self.assertEqual(signal.getitimer(signal.ITIMER_REAL), (0., 0.))

    def test_streaming_large_list_preserves_order(self):
        rows = [record('keep-' + str(n)+'.txt' if n % 2 else 'other-'+str(n)+'.txt', size=n) for n in range(10000)]
        code, matches, errors = self.apply(rows, leaf('n', 'name', value='keep-'))
        self.assertEqual((code, len(matches), errors), (0, 5000, ''))
        self.assertEqual([json.loads(line)['size'] for line in matches], list(range(1,10000,2)))


class NativeResultFilterTests(TempTreeTest):
    @classmethod
    def setUpClass(cls):
        from swift_test_support import suite_binary
        suite_binary()

    def test_quick_stream_keeps_loaded_occurrence_for_same_identity(self):
        self.quick_occurrence('quick-selection')

    def test_quick_grouped_stream_keeps_loaded_occurrence_for_same_identity(self):
        self.quick_occurrence('quick-selection-grouped')

    def quick_occurrence(self, mode):
        from swift_test_support import run_probe
        source = Path(self.root, 'content.txt')
        source.write_text('needle\nKontext\nneedle\n')
        code, lines, errors = run(['--json', '--content', '--content-preview', 'needle', str(source)])
        self.assertEqual((code, errors), (0, ''))
        result = run_probe('result-filter', mode, Path(favenio.__file__), input=lines[0]+'\n', timeout=20)
        self.assertTrue(all(json.loads(result.stdout).values()), result.stdout)

    def test_shared_controller_selection_streaming_generation_and_cleanup(self):
        from swift_test_support import run_probe
        rows = [record('keep-a.txt', line=7), record('other-b.txt'), record('keep-c.txt'), record('other-d.txt')]
        rows[2].update(type='member', filesystemPath='/missing/source.zip',
                       archiveMembers=['\ufeffkeep-c.txt'], contentEncoding='pptx-text-v1')
        result = run_probe('result-filter', input=''.join(json.dumps(row)+'\n' for row in rows), timeout=20)
        report = json.loads(result.stdout)
        self.assertTrue(all(report.values()), report)


if __name__ == '__main__':
    unittest.main()
