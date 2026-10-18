"""Gemischte Kriterien: Suchmenge, sichere Negation und tatsächlich gelesene Daten."""
import contextlib
import io
import json
import os
from pathlib import Path
import random
import struct
import unittest
from unittest import mock
import zipfile

from test_favenio import TempTreeTest, favenio, run
from test_criteria import arguments, document, group, leaf


class MixedCriteriaSearchTest(TempTreeTest):
    def records(self, query, *options):
        code, lines, err = run(['--json', '--no-archives'] + arguments(query) + list(options) + [self.root])
        self.assertIn(code, (0, 1), err)
        return [json.loads(line) for line in lines], err

    def test_name_extension_and_content_with_independent_line_evidence(self):
        self.write('Migration.md', 'alpha\nTODO\nbeta\n')
        self.write('Migration.txt', 'TODO\n')
        self.write('Other.md', 'TODO\n')
        query = group('all', 'and', leaf('name', value='Migration'),
                      leaf('type', 'extension', 'equals', 'md'),
                      leaf('todo', 'content', value='TODO'),
                      leaf('beta', 'content', value='beta'))
        records, err = self.records(query)
        self.assertEqual([Path(r['path']).name for r in records], ['Migration.md'])
        self.assertEqual({e['id']: e.get('line') for e in records[0]['criteriaEvidence']},
                         {'name': None, 'type': None, 'todo': 2, 'beta': 3})
        self.assertEqual(err, '')

    def test_negative_content_needs_known_complete_object(self):
        self.write('present.txt', 'alpha\nbeta\n')
        self.write('absent.txt', 'alpha\n')
        self.write('empty.txt', '')
        Path(self.root, 'folder.txt').mkdir()
        records, err = self.records(leaf('without', 'content', value='beta', negate=True))
        self.assertEqual(sorted(Path(r['path']).name for r in records), ['absent.txt', 'empty.txt'])
        self.assertTrue(all(r['criteriaEvidence'][0]['negated'] for r in records))
        self.assertTrue(all('line' not in r['criteriaEvidence'][0] for r in records))
        self.assertEqual(err, '')

    def test_long_unchecked_line_is_unknown_under_negation(self):
        self.write('long.txt', 'a' * 200 + '\n')
        query = leaf('without', 'content', 'regex', '^missing$', negate=True)
        with mock.patch.object(favenio, 'MAX_LINE_CHARS', 40), mock.patch.object(favenio, 'LINE_OVERLAP_CHARS', 10), mock.patch.object(favenio, 'CHUNK_SIZE', 64):
            records, err = self.records(query)
        self.assertEqual(records, [])
        self.assertIn('nicht vollständig geprüft', err)

    def test_size_and_timestamp_resolution_and_unknown_directory_size(self):
        path = self.write('five.txt', '12345')
        os.utime(path, (1704067200.75, 1704067200.75))
        Path(self.root, 'directory').mkdir()
        query = group('all', 'and', leaf('size', 'size', 'equals', '5 B'),
                      leaf('time', 'modified', 'equals', '2024-01-01T00:00:00Z'))
        records, err = self.records(query)
        self.assertEqual([Path(r['path']).name for r in records], ['five.txt'])
        self.assertEqual(records[0]['criteriaEvidence'][1]['value'], '2024-01-01T00:00:00.750000Z')
        records, _ = self.records(leaf('size', 'size', 'equals', '5', negate=True))
        self.assertNotIn('directory', [Path(r['path']).name for r in records])

    def test_dimensions_and_content_share_archive_budget(self):
        image = b'\x89PNG\r\n\x1a\n' + struct.pack('>I', 13) + b'IHDR' + struct.pack('>II', 640, 480) + b'TODO\n'
        archive = Path(self.root, 'images.zip')
        with zipfile.ZipFile(archive, 'w') as z:
            z.writestr('image.png', image)
        query = group('all', 'and', leaf('w', 'width', 'atLeast', '600'),
                      leaf('h', 'height', 'atMost', '500'), leaf('text', 'content', value='TODO'))
        code, lines, err = run(['--json'] + arguments(query) + ['--max-archive-total-bytes', str(len(image)), str(archive)])
        self.assertEqual(code, 0, err)
        records = [json.loads(line) for line in lines]
        self.assertEqual([r['archiveMembers'] for r in records], [['image.png']])
        self.assertEqual((records[0]['width'], records[0]['height']), (640, 480))
        self.assertEqual(err, '')

    def test_metadata_fields_are_allowlisted_and_missing_helper_is_explained(self):
        for field in ('execute', 'Title\n-execute', ''):
            code, lines, err = run(arguments(leaf('meta', 'metadata', value='x', metadataField=field)) + [self.root])
            self.assertEqual((code, lines), (2, []))
            self.assertIn('Bedingung meta', err)
        with mock.patch.object(favenio, 'find_exiftool', return_value=None):
            code, lines, err = run(arguments(leaf('meta', 'metadata', value='x')) + [self.root])
        self.assertEqual((code, lines), (2, []))
        self.assertIn('Metadatenkriterien brauchen exiftool', err)

    def test_open_archives_do_not_produce_raw_content_container_hits(self):
        archive = Path(self.root, 'files.zip')
        with zipfile.ZipFile(archive, 'w', compression=zipfile.ZIP_STORED) as z:
            z.writestr('note.txt', 'TODO\n')
        query = leaf('content', 'content', value='TODO')
        code, lines, err = run(['--json'] + arguments(query) + [str(archive)])
        self.assertEqual(code, 0, err)
        self.assertEqual([json.loads(line)['type'] for line in lines], ['member'])
        code, lines, err = run(['--json', '--no-archives'] + arguments(query) + [str(archive)])
        self.assertEqual(code, 0, err)
        self.assertEqual([json.loads(line)['type'] for line in lines], ['file'])

    def test_fake_nested_archive_falls_back_without_duplicate_container(self):
        archive = Path(self.root, 'outer.zip')
        with zipfile.ZipFile(archive, 'w') as z:
            z.writestr('fake.zip', 'TODO\n')
        for depth in (1, 2):
            code, lines, err = run(['--json', '--archive-depth', str(depth)] +
                                   arguments(leaf('content', 'content', value='TODO')) + [str(archive)])
            self.assertEqual(code, 0, err)
            self.assertEqual([json.loads(line)['archiveMembers'] for line in lines], [['fake.zip']])
            self.assertEqual(err, '')
        query = group('choice', 'or', leaf('name', value='fake.zip'), leaf('content', 'content', value='TODO'))
        code, lines, err = run(['--json', '--archive-depth', '2'] + arguments(query) + [str(archive)])
        self.assertEqual(len(lines), 1, err)


class MixedCriteriaProbeTest(unittest.TestCase):
    def probe(self, query, data=b'alpha\nbeta\ngamma\n', **options):
        search = favenio.Search(None, False, 0, True,
                               criteria_query=favenio.parse_criteria_query(document(query)), **options)
        search.emit = mock.Mock()
        search.warn = mock.Mock()
        events = {'opens': 0, 'closes': 0, 'bytes': 0}
        @contextlib.contextmanager
        def open_stream():
            events['opens'] += 1
            try:
                yield io.BytesIO(data)
            finally:
                events['closes'] += 1
        def chunks(stream, free_bytes=0):
            while True:
                block = stream.read(64)
                if not block:
                    return
                events['bytes'] += len(block)
                yield block
        probe = favenio.FileProbe(search, '/fixture.txt', 'fixture.txt', open_stream,
                                  chunks, '/fixture.txt')
        return search, probe, events

    def evaluate(self, search, probe):
        search.evaluate(probe, '/fixture.txt', 'file')
        return search.emit.called

    def test_nested_mixed_trees_match_independent_three_valued_reference(self):
        generator = random.Random(20261016)
        data = b'alpha\n' + b'x\n' * 80 + b'beta\n'
        def build(depth, counter):
            identifier = 'n' + str(counter[0]); counter[0] += 1
            if depth and generator.random() < 0.6:
                operator = generator.choice(('and', 'or'))
                branches = [build(depth - 1, counter) for _ in range(generator.randint(2, 3))]
                values = [value for _, value in branches]
                expected = (False if False in values else None if None in values else True) if operator == 'and' else (True if True in values else None if None in values else False)
                return group(identifier, operator, *(node for node, _ in branches)), expected
            field, value, expected = generator.choice((
                ('name', 'fixture', True), ('name', 'absent', False),
                ('content', 'alpha', True), ('content', 'beta', True),
                ('content', 'missing', False), ('relativePath', 'missing', None)))
            negate = generator.choice((True, False))
            return leaf(identifier, field, value=value, negate=negate), (None if expected is None else expected != negate)
        for iteration in range(300):
            query, expected = build(4, [0])
            with self.subTest(iteration=iteration, query=query):
                search, probe, events = self.probe(query, data)
                probe.relative_path = None
                self.assertEqual(self.evaluate(search, probe), expected is True)
                self.assertLessEqual(events['opens'], 1)
                self.assertEqual(events['opens'], events['closes'])
                search.warn.assert_not_called()

    def test_multiple_content_leaves_resume_one_stream_and_close_early(self):
        query = group('all', 'and', leaf('alpha', 'content', value='alpha'),
                      leaf('beta', 'content', value='beta'))
        search, probe, events = self.probe(query, b'alpha\nx\nbeta\n' + b'z' * 10000)
        self.assertTrue(self.evaluate(search, probe))
        self.assertEqual((events['opens'], events['closes']), (1, 1))
        self.assertEqual(events['bytes'], 64)
        self.assertEqual([e['line'] for e in probe.criteria_evidence], [1, 3])

    def test_or_also_stops_when_its_second_content_condition_matches_first(self):
        query = group('choice', 'or', leaf('missing', 'content', value='missing'),
                      leaf('alpha', 'content', value='alpha'))
        search, probe, events = self.probe(query, b'alpha\n' + b'z' * 10000)
        self.assertTrue(self.evaluate(search, probe))
        self.assertEqual((events['opens'], events['closes']), (1, 1))
        self.assertEqual(events['bytes'], 64)
        self.assertEqual([e['id'] for e in probe.criteria_evidence], ['alpha'])

    def test_and_stops_when_a_later_negative_content_condition_is_disproved(self):
        query = group('all', 'and', leaf('missing', 'content', value='missing'),
                      leaf('without-alpha', 'content', value='alpha', negate=True))
        search, probe, events = self.probe(query, b'alpha\n' + b'z' * 10000)
        self.assertFalse(self.evaluate(search, probe))
        self.assertEqual((events['opens'], events['closes']), (1, 1))
        self.assertEqual(events['bytes'], 64)

    def test_legacy_content_terms_use_the_same_open_stream(self):
        query = leaf('alpha', 'content', value='alpha')
        search, probe, events = self.probe(query)
        search.matcher = favenio.build_matcher('beta', False, False)
        search.matchers = [search.matcher, favenio.build_matcher('gamma', False, False)]
        search.text_mode = 'content'
        search.criteria.append(favenio.ContentCriterion())
        self.assertTrue(self.evaluate(search, probe))
        self.assertEqual((events['opens'], events['closes']), (1, 1))
        self.assertEqual(probe.content_lines(), [2, 3])

    def test_cheap_legacy_size_filter_rejects_before_tree_content(self):
        query = leaf('content', 'content', value='alpha')
        search, probe, events = self.probe(query, min_size=100)
        search.file_facts = mock.Mock(return_value=(3, None, None))
        self.assertFalse(self.evaluate(search, probe))
        self.assertEqual(events['opens'], 0)
        search.file_facts.assert_called_once()

    def test_cheap_or_avoids_all_expensive_probes(self):
        query = group('choice', 'or', leaf('meta', 'metadata', value='x'),
                      leaf('content', 'content', value='x'), leaf('name', value='fixture'))
        search, probe, events = self.probe(query)
        probe.metadata = mock.Mock(side_effect=AssertionError('unnötige Metadaten'))
        self.assertTrue(self.evaluate(search, probe))
        self.assertEqual(events['opens'], 0)
        self.assertEqual([e['id'] for e in probe.criteria_evidence], ['name'])

    def test_a_proven_cheap_branch_remains_proven_in_later_phases(self):
        query = group('choice', 'or', group('expensive', 'and', leaf('name', value='fixture'),
                      leaf('content', 'content', value='missing')), leaf('size', 'size', 'atLeast', '3'))
        search, probe, events = self.probe(query)
        search.file_facts = mock.Mock(return_value=(3, None, None))
        self.assertTrue(self.evaluate(search, probe))
        self.assertEqual(events['opens'], 0)
        self.assertEqual([e['id'] for e in probe.criteria_evidence], ['size'])

    def test_metadata_reads_once_and_retains_each_field_evidence(self):
        query = group('all', 'and', leaf('title', 'metadata', value='alpha', metadataField='Title'),
                      leaf('description', 'metadata', value='beta', metadataField='Description'))
        search, probe, events = self.probe(query)
        probe.name = 'image.jpg'
        stream = mock.Mock()
        stream.read.return_value = {'Title': 'alpha', 'Description': 'beta'}
        search.exiftool_stream = mock.Mock(return_value=stream)
        self.assertTrue(self.evaluate(search, probe))
        stream.read.assert_called_once()
        self.assertEqual([e['metadataField'] for e in probe.criteria_evidence], ['Title', 'Description'])
        self.assertEqual(events['opens'], 0)

    def test_missing_metadata_is_unknown_even_negated(self):
        search, probe, events = self.probe(leaf('meta', 'metadata', value='alpha', negate=True))
        probe.name = 'image.jpg'
        stream = mock.Mock()
        stream.read.return_value = {}
        search.exiftool_stream = mock.Mock(return_value=stream)
        self.assertFalse(self.evaluate(search, probe))
        self.assertEqual(events['opens'], 0)
        probe.in_archive = True
        probe._metadata = favenio.MISSING
        search.exiftool_stream.reset_mock()
        self.assertFalse(self.evaluate(search, probe))
        search.exiftool_stream.assert_not_called()

    def test_read_error_cannot_prove_negation(self):
        search, probe, events = self.probe(leaf('content', 'content', value='missing', negate=True))
        probe.open_stream = mock.Mock(side_effect=OSError('unlesbar'))
        self.assertFalse(self.evaluate(search, probe))
        self.assertEqual(search.warn.call_count, 1)
        self.assertIn('unlesbar', search.warn.call_args[0][0])

    def test_archive_metadata_stays_unknown_without_running_helper(self):
        search, probe, events = self.probe(leaf('meta', 'metadata', value='alpha', negate=True))
        probe.name = 'image.jpg'
        probe.in_archive = True
        search.exiftool_stream = mock.Mock(side_effect=AssertionError('kein Archivpfad an exiftool'))
        self.assertFalse(self.evaluate(search, probe))
        search.exiftool_stream.assert_not_called()

    def test_first_or_match_avoids_unneeded_long_line_diagnostic(self):
        query = group('choice', 'or', leaf('contains', 'content', value='alpha'),
                      leaf('anchored', 'content', 'regex', '^missing$'))
        search, probe, events = self.probe(query, b'alpha' + b'x' * 1000)
        with mock.patch.object(favenio, 'MAX_LINE_CHARS', 40), mock.patch.object(favenio, 'LINE_OVERLAP_CHARS', 10):
            self.assertTrue(self.evaluate(search, probe))
        self.assertEqual((events['opens'], events['closes']), (1, 1))
        self.assertEqual(events['bytes'], 64)
        search.warn.assert_not_called()


if __name__ == '__main__':
    unittest.main()
