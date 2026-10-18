"""Originalbelege, frühes Leseende und begrenzte optionale Vorschau."""
import codecs
import hashlib
import io
import json
import os
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest import mock
import zipfile
import shutil

from test_favenio import TempTreeTest, favenio, run
from test_criteria import arguments, group, leaf
from swift_test_support import run_probe, suite_binary


def selected(snippet):
    text = snippet['text'].encode('utf-16-le')
    return text[snippet['location'] * 2:(snippet['location'] + snippet['length']) * 2].decode('utf-16-le')


class PreviewSpanTests(unittest.TestCase):
    def test_original_unicode_spelling_and_ranges(self):
        cases = [('vor fu\u0308r Ko\u0308ln danach', 'FÜR KÖLN', 'fu\u0308r Ko\u0308ln'),
                 ('😀 Jahresbericht Köln', 'KÖLN', 'Köln'),
                 ('x\u1100\u1161\u11a8 y', '각', '\u1100\u1161\u11a8'),
                 ('xA\u0315\u0300z', 'À\u0315', 'A\u0315\u0300'),
                 ('xİY', 'i\u0307y', 'İY'), ('xΟΣ y', 'ος', 'ΟΣ'),
                 ('\u0301\u0323a', '\u0323\u0301', '\u0301\u0323')]
        for raw, pattern, expected in cases:
            with self.subTest(raw=raw):
                matcher = favenio.build_matcher(pattern, False, False, text_wildcards=True)
                self.assertTrue(matcher(raw))
                start, end = favenio.preview_match_span(matcher, raw)
                self.assertEqual(raw[start:end], expected)

    def test_regex_uses_raw_codepoints_and_zero_width_stays_zero(self):
        raw = '😀 fu\u0308r Köln'
        for pattern, expected in [('fu\u0308r', 'fu\u0308r'), ('(?=Köln)', '')]:
            matcher = favenio.build_matcher(pattern, True, True, text_wildcards=True)
            start, end = favenio.preview_match_span(matcher, raw)
            self.assertEqual(raw[start:end], expected)
        self.assertIsNone(favenio.preview_match_span(favenio.build_matcher('für', True, True), raw))

    def test_wildcard_exact_and_literal_matcher_rules(self):
        for raw, pattern, options, expected in [
                ('vor alpha --- beta nach', 'alpha*beta', {}, 'alpha --- beta'),
                ('alpha --- beta', 'alpha*beta', {'exact': True}, 'alpha --- beta'),
                ('alpha*beta', 'alpha*beta', {'literal_wildcards': True}, 'alpha*beta'),
                ('abc', '*', {}, 'a'), ('abc', '*', {'exact': True}, 'abc'),
                ('ÄPFEL', 'äpfel', {'exact': True}, 'ÄPFEL')]:
            matcher = favenio.build_matcher(pattern, False, False, text_wildcards=True, **options)
            self.assertTrue(matcher(raw))
            start, end = favenio.preview_match_span(matcher, raw)
            self.assertEqual(raw[start:end], expected)

    def test_mapping_limit_has_no_invented_position(self):
        matcher = favenio.build_matcher('needle', False, False)
        self.assertIsNone(favenio.preview_match_span(matcher, 'x' * favenio.MAX_PREVIEW_MAPPING_CHARS + 'needle'))


class ContentPreviewTests(TempTreeTest):
    def preview(self, path, *options, pattern='needle'):
        code, rows, errors = run(['--json', '--content-preview', '--content', *options, pattern, str(path)])
        self.assertEqual(code, 0, errors)
        return json.loads(rows[0])

    def test_default_output_and_reading_path_remain_without_preview(self):
        path = self.write('simple.txt', 'needle\nrest')
        with mock.patch.object(favenio.ContentPreviewCapture, 'record', side_effect=AssertionError('unerwartete Vorschau')):
            code, rows, errors = run(['--json', '--content', 'needle', path])
        self.assertEqual(code, 0, errors)
        self.assertNotIn('contentPreview', json.loads(rows[0]))

    def test_preview_requires_json(self):
        path = self.write('simple.txt', 'needle')
        code, rows, errors = run(['--content-preview', '--content', 'needle', path])
        self.assertEqual(code, 2)
        self.assertEqual(rows, [])
        self.assertIn('favenio: fehler: --content-preview braucht --json', errors)

    def test_first_evidence_per_term_preserves_original_and_decoder(self):
        path = Path(self.root, 'source.txt')
        path.write_bytes('vorher\r\n😀 fu\u0308r Ko\u0308ln danach\r\nzweiter Begriff\r\nfür Köln'.encode())
        hit = self.preview(path, '--term', 'zweiter', pattern='FÜR KÖLN')
        preview = hit['contentPreview']
        self.assertEqual(preview['status'], 'ready')
        self.assertEqual(preview['contentEncoding'], 'utf-8')
        self.assertEqual(preview['sourceGeneration'], favenio.source_generation(path))
        snippets = preview['snippets']
        self.assertEqual([item['line'] for item in snippets], [2, 3])
        self.assertEqual([selected(item) for item in snippets], ['fu\u0308r Ko\u0308ln', 'zweiter'])
        for item in snippets:
            self.assertEqual(item['excerptSHA256'], hashlib.sha256(item['text'].encode()).hexdigest())

    def test_utf16_and_legacy_use_final_decoder(self):
        path = Path(self.root, 'source.txt')
        for data, choice, decoder in [(codecs.BOM_UTF16_LE + '😀 für Köln'.encode('utf-16-le'), 'auto', 'utf-16-le'),
                                      (codecs.BOM_UTF16_BE + '😀 für Köln'.encode('utf-16-be'), 'auto', 'utf-16-be'),
                                      (b'vor f\x9fr K\x9aln', 'mac-roman', 'mac-roman')]:
            path.write_bytes(data)
            preview = self.preview(path, '--encoding', choice, pattern='für Köln')['contentPreview']
            self.assertEqual(preview['contentEncoding'], decoder)
            self.assertEqual(selected(preview['snippets'][0]), 'für Köln')

    def test_invalid_decoding_has_text_but_no_exact_range(self):
        path = Path(self.root, 'source.txt'); path.write_bytes(b'bad\xff needle\n')
        snippet = self.preview(path)['contentPreview']['snippets'][0]
        self.assertEqual(snippet['positionBinding'], 'invalidDecoding')
        self.assertNotIn('location', snippet)
        self.assertNotIn('length', snippet)
        self.assertIn('\ufffd', snippet['text'])

    def test_nested_archive_retains_exact_identity_and_outer_generation(self):
        inner = io.BytesIO()
        with zipfile.ZipFile(inner, 'w') as archive:
            archive.writestr('Büro!/original.txt', 'vor needle nach')
        path = Path(self.root, 'outer.zip')
        with zipfile.ZipFile(path, 'w') as archive:
            archive.writestr('inner.zip', inner.getvalue())
        hit = self.preview(path, '--archive-depth', '2')
        self.assertEqual(hit['archiveMembers'], ['inner.zip', 'Büro!/original.txt'])
        self.assertEqual(len(hit['archiveMemberBytes']), 2)
        self.assertEqual(hit['contentPreview']['sourceGeneration'], favenio.source_generation(path))
        self.assertEqual(selected(hit['contentPreview']['snippets'][0]), 'needle')

    def test_only_decisive_positive_content_branch_contributes(self):
        path = self.write('source.txt', 'alpha beta\ngamma')
        query = group('root', 'or', leaf('chosen', 'content', value='alpha'), leaf('other', 'content', value='gamma'))
        code, rows, errors = run(['--json', '--content-preview', *arguments(query), path])
        self.assertEqual(code, 0, errors)
        snippets = json.loads(rows[0])['contentPreview']['snippets']
        self.assertEqual([item['criterionID'] for item in snippets], ['chosen'])
        self.assertEqual(selected(snippets[0]), 'alpha')

    def test_negative_content_and_cheap_name_branch_do_not_invent_excerpt(self):
        path = self.write('source.txt', 'alpha')
        for query in [leaf('negative', 'content', value='absent', negate=True),
                      group('root', 'or', leaf('name', value='source'), leaf('unread', 'content', value='alpha'))]:
            code, rows, errors = run(['--json', '--content-preview', *arguments(query), path])
            self.assertEqual(code, 0, errors)
            preview = json.loads(rows[0])['contentPreview']
            self.assertEqual(preview['status'], 'noContentEvidence')
            self.assertEqual(preview['snippets'], [])

    def test_context_and_number_of_stored_characters_are_bounded(self):
        path = self.write('source.txt', 'x' * 1000 + 'needle' + 'y' * 1000)
        snippet = self.preview(path)['contentPreview']['snippets'][0]
        self.assertTrue(snippet['prefixTruncated'])
        self.assertTrue(snippet['suffixTruncated'])
        self.assertLessEqual(len(snippet['text']), favenio.MAX_PREVIEW_SNIPPET_CHARS)
        self.assertEqual(selected(snippet), 'needle')

    def test_long_match_is_clipped_and_explicit(self):
        path = self.write('source.txt', 'alpha ' + 'x' * 1000 + ' beta')
        snippet = self.preview(path, pattern='alpha*beta')['contentPreview']['snippets'][0]
        self.assertTrue(snippet['matchTruncated'])
        self.assertEqual(len(snippet['text']), favenio.MAX_PREVIEW_SNIPPET_CHARS)
        self.assertEqual(selected(snippet), snippet['text'])

    def test_whole_run_budget_is_enforced(self):
        path = self.write('source.txt', 'needle')
        with mock.patch.object(favenio, 'MAX_PREVIEW_TOTAL_BYTES', 1):
            preview = self.preview(path)['contentPreview']
        self.assertEqual(preview['status'], 'budgetExceeded')
        self.assertEqual(preview['snippets'], [])
        self.assertNotIn('omitted', preview)

    def test_surrogate_pattern_has_utf8_safe_preview_label(self):
        path = self.write('source.txt', 'needle after')
        hit = self.preview(path, '--regex', pattern='\udcff|needle')
        self.assertEqual(hit['contentPreview']['snippets'][0]['label'], '\ufffd|needle')
        json.dumps(hit, ensure_ascii=False).encode('utf-8')

    def test_surrogate_term_evidence_remains_utf8_jsonl_with_and_without_preview(self):
        path = self.write('source.txt', 'needle after')
        for preview in (False, True):
            code, rows, errors = run(['--json', '--regex', '--content', '--term', 'after',
                                     *(['--content-preview'] if preview else []), '\udcff|needle', path])
            self.assertEqual(code, 0, errors)
            rows[0].encode('utf-8')
            self.assertEqual(json.loads(rows[0])['terms'][0]['term'], '\ufffd|needle')

    def test_source_change_after_read_discards_all_snippets(self):
        path = self.write('source.txt', 'needle')
        finish = favenio.ContentPreviewCapture.finish
        def changed(capture):
            Path(path).write_bytes(b'changed source')
            return finish(capture)
        with mock.patch.object(favenio.ContentPreviewCapture, 'finish', changed):
            preview = self.preview(path)['contentPreview']
        self.assertEqual(preview['status'], 'sourceChanged')
        self.assertEqual(preview['snippets'], [])

    def test_capture_does_not_read_after_first_hit(self):
        matcher = favenio.build_matcher('needle', False, False, text_wildcards=True)
        search = favenio.Search(matcher, True, 0, True)
        def chunks():
            yield b'needle\n'
            raise AssertionError('nach erstem Treffer gelesen')
        capture = favenio.ContentPreviewCapture(SimpleNamespace())
        self.assertEqual(search.match_content(chunks(), preview=capture), 1)
        self.assertEqual(selected(capture.snippets[matcher]), 'needle')

    def test_many_terms_have_bounded_storage_and_explicit_omissions(self):
        terms = ['term-%03d' % index for index in range(64)]
        path = self.write('many.txt', '\n'.join(terms))
        options = [value for term in terms[1:] for value in ('--term', term)]
        preview = self.preview(path, *options, pattern=terms[0])['contentPreview']
        self.assertLessEqual(len(preview['snippets']), 32)
        self.assertLessEqual(sum(len(item['text']) for item in preview['snippets']), 2048)
        self.assertEqual(preview['omitted'], 64 - len(preview['snippets']))
        self.assertEqual([item['termIndex'] for item in preview['snippets']], list(range(1, len(preview['snippets']) + 1)))

    def test_actual_file_reader_has_same_read_calls_with_preview(self):
        path = self.write('large.txt', 'needle\n' + 'rest\n' * 100000)
        original = favenio.open_regular_file
        runs = []
        class Reader:
            def __init__(self, handle, counts): self.handle, self.counts = handle, counts
            def __enter__(self): return self
            def __exit__(self, *args): self.handle.close()
            def fileno(self): return self.handle.fileno()
            def read(self, size):
                data = self.handle.read(size); self.counts.append(len(data)); return data
        for preview in (False, True):
            counts = []
            with mock.patch.object(favenio, 'open_regular_file', lambda name: Reader(original(name), counts)):
                code, rows, errors = run(['--json', '--content', *(['--content-preview'] if preview else []), 'needle', path])
            self.assertEqual(code, 0, errors)
            runs.append(counts)
        self.assertEqual(runs[0], runs[1])
        self.assertEqual(runs[0], [favenio.CHUNK_SIZE, favenio.CHUNK_SIZE])

    def test_archive_budget_and_hit_semantics_are_unchanged(self):
        path = Path(self.root, 'small.zip')
        with zipfile.ZipFile(path, 'w') as archive:
            archive.writestr('source.txt', 'before needle after')
        outputs = []
        for preview in (False, True):
            code, rows, errors = run(['--json', '--content', '--max-archive-total-bytes', '19',
                                     *(['--content-preview'] if preview else []), 'needle', str(path)])
            self.assertEqual(code, 0, errors)
            hit = json.loads(rows[0]); hit.pop('contentPreview', None); outputs.append(hit)
        self.assertEqual(outputs[0], outputs[1])

    def test_oversized_line_keeps_hit_without_a_fabricated_range(self):
        path = self.write('long.txt', 'x' * (favenio.MAX_PREVIEW_MAPPING_CHARS + 10) + 'needle')
        snippet = self.preview(path)['contentPreview']['snippets'][0]
        self.assertEqual(snippet['positionBinding'], 'unavailable')
        self.assertNotIn('location', snippet)
        self.assertLessEqual(len(snippet['text']), 256)


@unittest.skipUnless(shutil.which('swiftc'), 'swiftc fehlt')
class SwiftContentPreviewTests(TempTreeTest):
    @classmethod
    def setUpClass(cls):
        suite_binary()

    def product_hit(self, name='source.txt', text='😀 fu\u0308r Ko\u0308ln danach', pattern='FÜR KÖLN'):
        path = self.write(name, text)
        return ContentPreviewTests.preview(self, path, pattern=pattern)

    def swift(self, hit):
        return json.loads(run_probe('content-preview', 'parse', input=json.dumps(hit) + '\n').stdout)

    def test_real_kernel_json_roundtrip_hash_generation_and_highlight(self):
        report = self.swift(self.product_hit())
        self.assertEqual(report['status'], 'ready')
        self.assertTrue(report['roundtrip'])
        self.assertTrue(report['same_generation'])
        self.assertEqual(report['marks'], ['fu\u0308r Ko\u0308ln'])
        self.assertIn('😀 fu\u0308r Ko\u0308ln danach', report['rendered'])

    def test_long_archive_source_keeps_compact_preview_width(self):
        report = json.loads(run_probe('content-preview', 'layout',
                                     input=json.dumps(self.product_hit()) + '\n').stdout)
        self.assertTrue(report['compactWidth'], report)
        self.assertTrue(report['sourceRetained'], report)
        self.assertLessEqual(report['fittingWidth'], 520, report)

    def test_corrupted_hash_range_schema_and_limits_are_rejected(self):
        hit = self.product_hit()
        for corruption in ('hash', 'range', 'schema', 'count', 'surrogate', 'boolean', 'encoding'):
            altered = json.loads(json.dumps(hit))
            preview = altered['contentPreview']; snippet = preview['snippets'][0]
            if corruption == 'hash': snippet['excerptSHA256'] = '0' * 64
            if corruption == 'range': snippet['location'] = 999999
            if corruption == 'schema': preview['schemaVersion'] = 2
            if corruption == 'count': preview['snippets'] *= 33
            if corruption == 'surrogate': snippet['location'] = 1
            if corruption == 'boolean': snippet['length'] = True
            if corruption == 'encoding': preview['contentEncoding'] = 'mac-roman'
            with self.subTest(corruption=corruption):
                self.assertEqual(self.swift(altered)['status'], 'invalid')

    def test_rapid_selection_changes_source_mutation_and_hidden_results(self):
        hits = [self.product_hit('first.txt', 'first needle', 'needle'),
                self.product_hit('second.txt', 'second needle', 'needle')]
        report = json.loads(run_probe('content-preview', 'controller',
                                     input='\n'.join(map(json.dumps, hits)) + '\n').stdout)
        self.assertTrue(all(report.values()), report)

    def test_source_generation_keeps_negative_and_extreme_nanoseconds_exact(self):
        path = Path(self.root, 'clock.txt'); path.write_text('needle')
        for timestamp in (-315619200123456789, 9223372036854775807):
            os.utime(path, ns=(timestamp, timestamp))
            hit = ContentPreviewTests.preview(self, path)
            self.assertEqual(hit['contentPreview']['sourceGeneration']['modifiedNS'], str(os.stat(path).st_mtime_ns))
            self.assertTrue(self.swift(hit)['same_generation'])

    def test_criterion_label_explains_content_without_showing_transport_identifier(self):
        path = self.write('criteria.txt', 'before needle after')
        code, rows, errors = run(['--json', '--content-preview',
                                 *arguments(leaf('opaque_condition_7', 'content', value='needle')), path])
        self.assertEqual(code, 0, errors)
        report = self.swift(json.loads(rows[0]))
        self.assertIn('Inhaltsbedingung', report['rendered'])
        self.assertNotIn('opaque_condition_7', report['rendered'])
        self.assertEqual(report['marks'], ['needle'])
