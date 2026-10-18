"""Suchwurzeln bleiben geordnet; Pfadbedingungen gelten vor UI-Deduplikation."""
import json
import os
from pathlib import Path
from unittest import mock
import zipfile

import favenio
from test_favenio import TempTreeTest, run
from swift_test_support import run_probe
import unittest


class NativeSearchRootsTests(unittest.TestCase):
    def test_model(self): self.check('model')
    def test_arguments(self): self.check('arguments')
    def test_templates(self): self.check('templates')
    def test_provenance(self): self.check('provenance')
    def test_handoff(self): self.check('handoff')
    def test_editor(self): self.check('editor')
    def check(self, mode):
        report = json.loads(run_probe('search-roots', mode).stdout)
        self.assertTrue(report and all(report.values()), report)


class SearchRootsTests(TempTreeTest):
    def fixture(self):
        folder = Path(self.root) / 'project'
        folder.mkdir()
        file = folder / 'needle.txt'
        file.write_text('needle\n', encoding='utf8')
        return folder, file

    def records(self, arguments):
        code, rows, error = run(['--json'] + arguments)
        return code, [json.loads(row) for row in rows], error

    def test_overlaps_keep_cli_duplicates_and_ordered_provenance(self):
        folder, file = self.fixture()
        code, rows, _ = self.records(['--', 'needle', self.root, str(folder), str(file)])
        self.assertEqual(code, 0)
        self.assertEqual([r['searchRoot'] for r in rows], [self.root, str(folder), str(file)])
        self.assertEqual({r['filesystemPath'] for r in rows}, {str(file)})

    def test_relative_condition_can_match_only_later_root(self):
        folder, file = self.fixture()
        query = dict(schemaVersion=1, root=dict(id='relative', field='relativePath', operator='equals', value='needle.txt'))
        code, rows, _ = self.records(['--criteria-json=' + json.dumps(query), '--', '', self.root, str(folder)])
        self.assertEqual(code, 0)
        self.assertEqual([r['searchRoot'] for r in rows], [str(folder)])
        self.assertEqual(rows[0]['filesystemPath'], str(file))

    def test_exclusion_is_relative_to_each_root(self):
        folder, _ = self.fixture()
        code, rows, _ = self.records(['--exclude=project/needle.txt', '--', 'needle', self.root, str(folder)])
        self.assertEqual(code, 0)
        self.assertEqual([r['searchRoot'] for r in rows], [str(folder)])

    def test_depth_is_relative_to_each_root(self):
        folder, _ = self.fixture()
        code, rows, _ = self.records(['--max-depth=1', '--', 'needle', self.root, str(folder)])
        self.assertEqual(code, 0)
        self.assertEqual([r['searchRoot'] for r in rows], [str(folder)])

    def test_missing_root_rejects_entire_empty_pattern_search(self):
        folder, _ = self.fixture()
        missing = str(folder / 'missing')
        for roots in ([missing, self.root], [self.root, missing]):
            code, rows, error = self.records(['--min-size=0', '--', ''] + roots)
            self.assertEqual((code, rows), (2, []))
            self.assertIn(missing, error)

    def test_declared_absolute_spelling_is_preserved(self):
        folder, _ = self.fixture()
        for root in (str(folder) + '/', str(folder) + '/.'):
            code, rows, _ = self.records(['--', 'needle', root])
            self.assertEqual(code, 0)
            self.assertEqual(rows[0]['searchRoot'].encode(), root.encode())

    def test_relative_cli_root_gets_absolute_provenance_only(self):
        self.fixture()
        code, rows, _ = run(['--json', '--', 'needle', 'project'], cwd=self.root)
        self.assertEqual(code, 0)
        record = json.loads(rows[0])
        self.assertEqual(record['searchRoot'], os.path.join(os.path.realpath(self.root), 'project'))
        self.assertEqual(record['filesystemPath'], 'project/needle.txt')

    def test_archive_relative_path_is_independent_of_search_root(self):
        archive = Path(self.root) / 'needle.zip'
        with zipfile.ZipFile(archive, 'w') as stream:
            stream.writestr('folder/needle.txt', 'x')
        code, rows, _ = self.records(['--', 'needle', self.root, str(archive)])
        members = [row for row in rows if row['type'] == 'member']
        self.assertEqual(code, 0)
        self.assertEqual([r['searchRoot'] for r in members], [self.root, str(archive)])
        self.assertEqual([favenio.KnownResultProbe(row, '/wrong').relative_path for row in members], ['folder/needle.txt'] * 2)

    def test_known_filter_uses_per_hit_root_without_source_access(self):
        row = dict(path='/missing/project/needle.txt', type='file', isDirectory=False,
                   filesystemPath='/missing/project/needle.txt', archiveMembers=[], searchRoot='/missing/project')
        with mock.patch('os.stat', side_effect=AssertionError('source access')), mock.patch('builtins.open', side_effect=AssertionError('source access')):
            self.assertEqual(favenio.KnownResultProbe(row, '/wrong').relative_path, 'needle.txt')
            row['searchRoot'] = row['filesystemPath']
            self.assertEqual(favenio.KnownResultProbe(row).relative_path, 'needle.txt')

    def test_invalid_hit_root_is_an_error(self):
        row = dict(path='/missing/a', type='file', isDirectory=False, filesystemPath='/missing/a', archiveMembers=[])
        for value in (None, [], True, 'relative', '/nul\0x'):
            with self.subTest(value=value), self.assertRaises(ValueError):
                favenio.KnownResultProbe(dict(row, searchRoot=value))

    def test_search_context_is_restored_after_failure(self):
        search = favenio.Search(None, False, 0, True)
        with mock.patch.object(search, '_search_path', side_effect=RuntimeError('stop')):
            with self.assertRaises(RuntimeError):
                search.search_path('/missing/.')
        self.assertIsNone(search.search_root)
