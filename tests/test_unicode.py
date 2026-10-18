"""Kanonische Suche mit rohen Quellen, begrenzten Lesern und eindeutigen Treffern."""
import base64
import hashlib
import json
from pathlib import Path
import random
import unicodedata
import unittest
from unittest import mock
import zipfile

from test_favenio import TempTreeTest, favenio, run
from test_criteria import arguments, leaf
import test_criteria_fields


class UnicodeMatcherTest(unittest.TestCase):
    def test_canonical_literal_exact_glob_and_raw_regex(self):
        pairs = [('Büro', 'Bu\u0308ro'), ('가', '\u1100\u1161'),
                 ('a\u0323\u0301', 'a\u0301\u0323')]
        for first, second in pairs:
            self.assertEqual(unicodedata.normalize('NFC', first), unicodedata.normalize('NFC', second))
            for pattern, target in ((first, second), (second, first)):
                with self.subTest(pattern=pattern, target=target):
                    self.assertTrue(favenio.build_matcher(pattern, False, True, exact=True)(target))
                    self.assertTrue(favenio.build_matcher('*' + pattern + '*', False, True)(target))
        self.assertFalse(favenio.build_matcher('Büro', True, True)('Bu\u0308ro'))
        self.assertTrue(favenio.build_matcher('Bu\u0308ro', True, True)('Bu\u0308ro'))
        for pattern, target in [('cafe', 'café'), ('1', '①'), ('ffi', 'ﬃ')]:
            self.assertFalse(favenio.build_matcher(pattern, False, True, exact=True)(target))

    def test_content_probe_at_every_byte_boundary(self):
        text = '😀\nBu\u0308ro und cafe\u0301\n\u1100\u1161\n'
        data = text.encode()
        for pattern in ('Büro', 'café', '가'):
            for boundary in range(len(data) + 1):
                with self.subTest(pattern=pattern, boundary=boundary):
                    self.assertTrue(favenio.ContentProbe(pattern, True).hits(iter([data[:boundary], data[boundary:]])))
            self.assertTrue(favenio.ContentProbe(pattern, False).hits(bytes([b]) for b in data))

    def test_probe_limit_is_conservative(self):
        with mock.patch.object(favenio, 'MAX_NORMALIZATION_CHARS', 8):
            self.assertTrue(favenio.ContentProbe('missing', True).hits(iter([('x' + '\u0301' * 30).encode()])))

    def test_fragmented_stream_matches_whole_canonical_reference(self):
        generator = random.Random(20261016)
        alphabet = ['x', 'e', '\u0301', '\u0323', '😀', '\u1100', '\u1161', '\u11a8']
        with mock.patch.object(favenio, 'MAX_LINE_CHARS', 40), mock.patch.object(favenio, 'LINE_OVERLAP_CHARS', 10):
            for iteration in range(200):
                text = ''.join(generator.choice(alphabet) for _ in range(140))
                canonical = unicodedata.normalize('NFC', text)
                start = generator.randrange(len(canonical) - 3)
                pattern = canonical[start:start + 3] if iteration % 2 else 'missing'
                expected = pattern in canonical
                data = (text + '\n').encode()
                chunks = [data[i:i + 7] for i in range(0, len(data), 7)]
                matcher = favenio.build_matcher(pattern, False, True)
                search = favenio.Search(matcher, True, 0, False)
                with self.subTest(iteration=iteration, pattern=pattern):
                    self.assertEqual(search.match_content(iter(chunks)) == 1, expected)
                    if expected:
                        self.assertTrue(favenio.ContentProbe(pattern, True).hits(iter(chunks)))

    def test_fragment_match_waits_for_composition_and_keeps_line_number(self):
        data = ('first\n' + 'x' * 60 + 'cafe\u0301\n').encode()
        with mock.patch.object(favenio, 'MAX_LINE_CHARS', 40), mock.patch.object(favenio, 'LINE_OVERLAP_CHARS', 10), mock.patch.object(favenio, 'CHUNK_SIZE', 64):
            for pattern, expected in [('cafe', None), ('café', 2)]:
                matcher = favenio.build_matcher(pattern, False, True)
                search = favenio.Search(matcher, True, 0, False)
                self.assertEqual(search.match_content(iter([data])), expected)


class UnicodeSourceTest(TempTreeTest):
    def test_name_path_extension_and_exclusions_preserve_source(self):
        original = 'Bu\u0308ro.e\u0301'
        self.write(original, 'Bu\u0308ro\n')
        for query in (leaf('name', value='Büro'), leaf('path', 'relativePath', value='Büro'),
                      leaf('extension', 'extension', 'equals', 'é')):
            code, lines, err = run(['--json', '--no-archives'] + arguments(query) + [self.root])
            self.assertEqual(code, 0, err)
            self.assertEqual(Path(json.loads(lines[0])['filesystemPath']).name.encode(), original.encode())
        code, lines, err = run(['--json', '--exclude', 'Büro.é', 'Büro', self.root])
        self.assertEqual((code, lines, err), (1, [], ''))

    def test_canonical_exact_terms_do_not_conflict(self):
        self.write('Bu\u0308ro', '')
        code, lines, err = run(['--json', '--exact', '--term', 'Bu\u0308ro', 'Büro', self.root])
        self.assertEqual((code, len(lines), err), (0, 1, ''))

    def test_two_archive_spellings_keep_identity_and_extract_own_content(self):
        archive = Path(self.root, 'source.zip')
        names = ['Büro.txt', 'Bu\u0308ro.txt']
        with zipfile.ZipFile(archive, 'w') as stream:
            for index, name in enumerate(names):
                stream.writestr(name, str(index))
        code, lines, err = run(['--json', 'Büro', str(archive)])
        self.assertEqual((code, len(lines), err), (0, 2, ''))
        records = [json.loads(line) for line in lines]
        self.assertEqual([r['archiveMembers'][0].encode() for r in records], [n.encode() for n in names])
        self.assertEqual([base64.b64decode(r['archiveMemberBytes'][0]) for r in records], [n.encode() for n in names])
        paths = []
        root = Path(self.root, 'materialized'); root.mkdir()
        for index, record in enumerate(records):
            code, extracted, err = run(['--extract-json', json.dumps(record), '--extract-root', str(root)])
            self.assertEqual(code, 0, err)
            paths.append(extracted[0])
            self.assertEqual(Path(extracted[0]).read_text(), str(index))
        self.assertNotEqual(paths[0], paths[1])

    def test_original_utf16_line_position_and_hash(self):
        text = '\ufeff😀\nBu\u0308ro\n'
        path = self.write('source.txt', text)
        position = favenio.snapshot_position(dict(path=path, mode='content', pattern='Büro', terms=[],
            regex=False, caseSensitive=True, exact=False, literalWildcards=False))
        self.assertEqual((position['line'], position['location'], position['length']), (2, 3, 5))
        self.assertEqual(position['sha256'], hashlib.sha256(text.encode()).hexdigest())

    def test_regex_overflow_is_validation_error_before_search(self):
        query = leaf('overflow', 'name', 'regex', 'a{999999999999999999999}')
        for options in (['--validate-criteria'], []):
            with mock.patch.object(favenio.Search, 'search_path', side_effect=AssertionError('kein Suchstart')):
                code, lines, err = run(options + arguments(query) + [self.root])
            self.assertEqual((code, lines), (2, []))
            self.assertIn('favenio: fehler:', err)
            self.assertIn('Bedingung overflow', err)
            self.assertNotIn('Traceback', err)
        code, lines, err = run(['--regex', 'a{999999999999999999999}', self.root])
        self.assertEqual((code, lines), (2, []))
        self.assertIn('favenio: fehler:', err)
        path = self.write('overflow.txt', 'a\n')
        position = dict(path=path, mode='content', pattern=query['value'], terms=[],
                        regex=True, caseSensitive=True, exact=False, literalWildcards=False)
        code, lines, err = run(['--snapshot-position-json', json.dumps(position)])
        self.assertEqual((code, lines), (2, []))
        self.assertIn('Positionsprüfung fehlgeschlagen', err)
        self.assertNotIn('Traceback', err)


class UnicodeCriteriaProbeTest(unittest.TestCase):
    probe = test_criteria_fields.MixedCriteriaProbeTest.probe
    evaluate = test_criteria_fields.MixedCriteriaProbeTest.evaluate

    def test_metadata_evidence_retains_original_value(self):
        search, probe, events = self.probe(leaf('title', 'metadata', value='Büro', metadataField='Title'))
        probe.name = 'image.jpg'
        stream = mock.Mock(); stream.read.return_value = {'Title': 'Bu\u0308ro'}
        search.exiftool_stream = mock.Mock(return_value=stream)
        self.assertTrue(self.evaluate(search, probe))
        self.assertEqual(probe.criteria_evidence[0]['value'].encode(), 'Bu\u0308ro'.encode())
        self.assertEqual(events['opens'], 0)

    def test_normalization_overflow_cannot_prove_negative_content(self):
        data = ('x' * 60 + 'a' + '\u0301' * 100 + '\n').encode()
        with mock.patch.object(favenio, 'MAX_NORMALIZATION_CHARS', 8), mock.patch.object(favenio, 'MAX_LINE_CHARS', 40), mock.patch.object(favenio, 'LINE_OVERLAP_CHARS', 10):
            search, probe, events = self.probe(leaf('negative', 'content', value='missing', negate=True), data)
            self.assertFalse(self.evaluate(search, probe))
            self.assertIn('nicht vollständig geprüft', search.warn.call_args[0][0])
            search, probe, events = self.probe(leaf('positive', 'content', value='xxx'), data)
            self.assertTrue(self.evaluate(search, probe))
            self.assertEqual((events['opens'], events['closes']), (1, 1))
