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

    def position_fixture(self, position, encoding, query=None):
        # Frühe Vorschauobjekte mit Schema 1 besitzen noch keinen Query-Deskriptor.
        generation = dict(device='1', inode='2', size='6', modifiedNS='3', changedNS='4')
        path = str(Path(self.root, 'historical.document'))
        snippet = dict(line=position['line'], termIndex=1, text='needle', label='needle',
                       positionBinding='excerptUTF16', location=0, length=6,
                       excerptSHA256=hashlib.sha256(b'needle').hexdigest(),
                       prefixTruncated=False, suffixTruncated=False, documentPosition=position)
        if query is not None:
            snippet['query'] = query
        return dict(type='file', isDirectory=False, path=path, filesystemPath=path,
                    archiveMembers=[], line=1, contentEncoding=encoding,
                    documentSourceGeneration=generation, documentPosition=position,
                    contentPreview=dict(schemaVersion=1, status='ready', omitted=0, snippets=[snippet],
                                        contentEncoding=encoding, sourceGeneration=generation))

    def position_fixtures(self, hits):
        payload = ''.join(json.dumps(hit) + '\n' for hit in hits)
        return json.loads(run_probe('content-preview', 'positions', input=payload).stdout)

    def test_historical_document_position_variants_keep_their_wire_fields(self):
        ocr = dict(block=2, confidence=0.75, region=[0.1, 0.2, 0.3, 0.4])
        slide = dict(part='ppt/slides/z.xml', slide=3, objectID='10')
        fingerprint = 'a' * 64
        cases = [
            ('pdfkit-text-v1', 'pdfkit-v1', 'Seite 2', dict(kind='pdfPage', page=2)),
            ('pdfkit-vision-text-v1', 'pdfkit-vision-v1', 'Textebene', dict(kind='pdfTextPage', page=2)),
            ('pdfkit-vision-text-v1', 'pdfkit-vision-v1', 'Seite 2 · OCR', dict(kind='pdfOCR', page=2, **ocr)),
            ('vision-ocr-text-v1', 'vision-image-v1', 'OCR · Bereich 2', dict(kind='imageOCR', **ocr)),
            ('docx-text-v1', 'docx-v1', 'Kopfzeile', dict(kind='docxParagraph', part='word/header.xml', partKind='header', paragraph=1)),
            ('odt-text-v1', 'odt-v1', 'ODT-Haupttext', dict(kind='odtParagraph', part='content.xml', paragraph=2)),
            ('epub-text-v1', 'epub-v1', 'Kapitel 4', dict(kind='epubParagraph', part='OPS/z.xhtml', chapter=4, paragraph=3)),
            ('xlsx-text-v1', 'xlsx-v1', 'Zelle XFD1048576', dict(kind='xlsxCell', part='xl/sheet.xml', sheet='Übersicht', sheetIndex=4, cell='XFD1048576', valueKind='cachedDate')),
            ('pptx-text-v1', 'pptx-v1', 'Objekt 10', dict(kind='pptxParagraph', objectKind='shape', paragraph=4, **slide)),
            ('pptx-text-v1', 'pptx-v1', 'Zelle 2,3', dict(kind='pptxParagraph', objectKind='table', paragraph=4, row=2, column=3, **slide)),
            ('pptx-vision-text-v1', 'pptx-vision-v1', 'Bild 10 · OCR', dict(kind='pptxOCR', objectKind='picture', reader='pptx-vision-v1', **slide, **ocr)),
            ('pptx-vision-text-v1', 'pptx-vision-v1', 'Objekt 10', dict(kind='pptxParagraph', objectKind='shape', paragraph=4, reader='pptx-vision-v1', **slide)),
            ('pptx-tesseract-text-v1', 'pptx-tesseract-v1', 'Bild 10 · OCR', dict(kind='pptxOCR', objectKind='picture', reader='pptx-tesseract-v1', readerFingerprint=fingerprint, **slide, **ocr)),
            ('pptx-tesseract-text-v1', 'pptx-tesseract-v1', 'Objekt 10', dict(kind='pptxParagraph', objectKind='shape', paragraph=4, reader='pptx-tesseract-v1', **slide)),
            ('poppler-text-v1', 'poppler-v1', 'Seite 2', dict(kind='pdfPage', page=2, reader='poppler-v1', readerFingerprint=fingerprint)),
            ('poppler-tesseract-text-v1', 'poppler-tesseract-v1', 'Textebene', dict(kind='pdfTextPage', page=2, reader='poppler-tesseract-v1', readerFingerprint=fingerprint)),
            ('poppler-tesseract-text-v1', 'poppler-tesseract-v1', 'Seite 2 · OCR', dict(kind='pdfOCR', page=2, reader='poppler-tesseract-v1', readerFingerprint=fingerprint, **ocr)),
            ('tesseract-ocr-text-v1', 'tesseract-image-v1', 'OCR · Bereich 2', dict(kind='imageOCR', reader='tesseract-image-v1', readerFingerprint=fingerprint, **ocr)),
        ]
        hits = [self.position_fixture(dict(position, line=1), encoding) for encoding, _, _, position in cases]
        report = self.position_fixtures(hits)
        self.assertEqual(report['distinctPositions'], len(cases))
        for (_, reader, title, _), hit, row in zip(cases, hits, report['rows']):
            with self.subTest(position=hit['documentPosition']):
                self.assertTrue(row['accepted'], row)
                self.assertTrue(row['roundtrip'], row)
                self.assertEqual(row['reader'], reader)
                self.assertIn(title, row['title'])
                self.assertEqual(row['written']['documentPosition'], hit['documentPosition'])
                self.assertEqual(row['written']['contentPreview'], hit['contentPreview'])

    def test_positions_keep_original_package_and_query_bytes(self):
        query = dict(pattern='\ufeffBu\u0308ro', regex=True, caseSensitive=False, exact=True,
                     literalWildcards=False, documentReader='xlsx-v1')
        forms = ('Büro', 'Bu\u0308ro', '\ufeffBüro')
        hits = []
        for text in forms:
            epub = dict(kind='epubParagraph', part=text + '.xhtml', chapter=1, paragraph=2, line=1)
            xlsx = dict(kind='xlsxCell', part='xl/sheet.xml', sheet=text,
                        sheetIndex=1, cell='A1', valueKind='text', line=1)
            hits.extend([self.position_fixture(epub, 'epub-text-v1'), self.position_fixture(xlsx, 'xlsx-text-v1', query)])
        report = self.position_fixtures(hits + [hits[0]])
        self.assertEqual(report['distinctPositions'], len(hits))
        for hit, row in zip(hits, report['rows']):
            self.assertTrue(row['roundtrip'], row)
            self.assertEqual(row['written']['documentPosition'], hit['documentPosition'])
            self.assertEqual(row['written']['contentPreview'], hit['contentPreview'])

    def test_position_and_query_reject_invalid_typed_fields(self):
        pdf = dict(kind='pdfTextPage', page=1, line=1)
        image = dict(kind='imageOCR', block=1, confidence=0.8, region=[0.1, 0.2, 0.3, 0.4], line=1)
        docx = dict(kind='docxParagraph', part='word/document.xml', partKind='document', paragraph=1, line=1)
        odt = dict(kind='odtParagraph', part='content.xml', paragraph=1, line=1)
        epub = dict(kind='epubParagraph', part='OPS/z.xhtml', chapter=1, paragraph=1, line=1)
        xlsx = dict(kind='xlsxCell', part='xl/sheet.xml', sheet='Übersicht', sheetIndex=1, cell='A1', valueKind='text', line=1)
        table = dict(kind='pptxParagraph', part='ppt/slides/z.xml', slide=1,
                     objectKind='table', objectID='2', paragraph=1, line=1, row=1, column=2)
        picture_ocr = dict(image, kind='pptxOCR', part=table['part'], slide=1, objectKind='picture', objectID='3',
                           reader='pptx-tesseract-v1', readerFingerprint='a' * 64)
        invalid = [
            (dict(pdf, page=True), 'pdfkit-vision-text-v1'),
            (dict(pdf, line=1.5), 'pdfkit-vision-text-v1'),
            (dict(pdf, region=image['region']), 'pdfkit-vision-text-v1'),
            (dict(pdf, kind='pdfPage', page=513), 'pdfkit-text-v1'),
            (dict(pdf, kind='pdfOCR', block=1), 'pdfkit-vision-text-v1'),
            (dict(pdf, kind='pdfPage', reader='poppler-v1'), 'poppler-text-v1'),
            (dict(image, confidence=True), 'vision-ocr-text-v1'),
            (dict(image, region=[False, 0.2, 0.3, 0.4]), 'vision-ocr-text-v1'),
            (dict(image, region=[0.8, 0.2, 0.3, 0.4]), 'vision-ocr-text-v1'),
            (dict(docx, partKind='unknown'), 'docx-text-v1'),
            (dict(odt, part='other.xml'), 'odt-text-v1'),
            (dict(epub, chapter=4097), 'epub-text-v1'),
            (dict(epub, part='../escape'), 'epub-text-v1'),
            (dict(xlsx, sheetIndex=True), 'xlsx-text-v1'),
            (dict(xlsx, cell='XFE1'), 'xlsx-text-v1'),
            (dict(table, objectKind='shape'), 'pptx-text-v1'),
            (dict(table, row=0), 'pptx-text-v1'),
            ({key: val for key, val in table.items() if key != 'column'}, 'pptx-text-v1'),
            (dict(picture_ocr, objectKind='table'), 'pptx-tesseract-text-v1'),
            (dict(picture_ocr, readerFingerprint='A' * 64), 'pptx-tesseract-text-v1'),
        ]
        hits = [self.position_fixture(position, encoding) for position, encoding in invalid]
        self.assertEqual(self.position_fixtures(hits)['rows'], [{'accepted': False}] * len(hits))

        query = dict(pattern='needle', regex=False, caseSensitive=True, exact=False, literalWildcards=True,
                     documentReader='pdfkit-vision-v1', encoding='utf-8')
        bad_queries = [dict(query, **{key: int(query[key])}) for key in ('regex', 'caseSensitive', 'exact', 'literalWildcards')]
        bad_queries.extend([dict(query, encoding=None), dict(query, documentReader='pdfkit-v1')])
        hits = [self.position_fixture(pdf, 'pdfkit-vision-text-v1', descriptor) for descriptor in [query] + bad_queries]
        rows = self.position_fixtures(hits)['rows']
        self.assertEqual([row['previewStatus'] for row in rows], ['ready'] + ['invalid'] * len(bad_queries))
        self.assertEqual(rows[0]['written']['contentPreview']['snippets'][0]['query'], query)

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
