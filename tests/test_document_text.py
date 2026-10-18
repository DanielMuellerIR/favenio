"""PDFKit extrahiert, Python sucht: Seitenbelege, frühes Ende und Grenzen."""
import contextlib
import io
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import tarfile
import time
import unittest
from unittest import mock
import zipfile

from test_favenio import TempTreeTest, favenio, run
from test_criteria import arguments, group, leaf
from pdf_fixture import pdf_bytes
from swift_test_support import run_process, run_probe, suite_binary

REPO = Path(__file__).resolve().parents[1]


@unittest.skipUnless(sys.platform == 'darwin' and shutil.which('swiftc'), 'PDFKit braucht macOS/Swift')
class DocumentTextTests(TempTreeTest):
    @classmethod
    def setUpClass(cls):
        cls.tools = tempfile.TemporaryDirectory(prefix='favenio-pdf-tests-')
        cls.addClassCleanup(cls.tools.cleanup)
        cls.helper = Path(cls.tools.name, 'favenio-pdf')
        cls.encrypt = Path(cls.tools.name, 'encrypt')
        for source, output in [('pdf/main.swift', cls.helper), ('tests/pdf_encrypt_fixture.swift', cls.encrypt)]:
            result = run_process(['swiftc', '-O', *([str(REPO / 'ocr/VisionText.swift')] if source == 'pdf/main.swift' else []), str(REPO / source), '-o', str(output)], timeout=30)
            if result.returncode:
                raise RuntimeError(result.stderr)
        suite_binary()

    def setUp(self):
        super().setUp()
        patch = mock.patch.dict(os.environ, FAVENIO_PDF_HELPER=str(self.helper))
        patch.start(); self.addCleanup(patch.stop)
        self.path = Path(self.root, 'report.pdf')
        self.path.write_bytes(pdf_bytes([
            [(40, 700, 'first needle alpha')],
            [(40, 700, 'left column'), (330, 700, 'right beta'), (40, 650, 'left bottom'), (330, 650, 'right bottom')],
            [(40, 700, 'last needle omega')]]))

    def search(self, path=None, *options, pattern='needle'):
        code, lines, errors = run(['--json', '--search-report', '--content-preview', '--document-text', *options,
                                  pattern, str(path or self.path)])
        records = [json.loads(line) for line in lines]
        return code, [item for item in records if item['type'] != 'searchReport'], records[-1], errors

    def request(self, hit, occurrence=0, context=False, path=None):
        path = str(path or self.path)
        return dict(schemaVersion=1, hit=hit, filePath=path, fileGeneration=favenio.source_generation(path),
                    queryIndex=0, occurrence=occurrence, context=context)

    def test_compressed_text_first_page_and_source_bound_even_without_preview(self):
        self.assertIn(b'/FlateDecode', self.path.read_bytes())
        self.assertNotIn(b'needle', self.path.read_bytes())
        code, hits, report, errors = self.search()
        self.assertEqual((code, errors), (0, ''))
        self.assertEqual(hits[0]['documentPosition'], dict(kind='pdfPage', page=1, line=1))
        self.assertEqual(hits[0]['documentSourceGeneration'], favenio.source_generation(str(self.path)))
        self.assertEqual(hits[0]['contentEncoding'], 'pdfkit-text-v1')
        self.assertEqual(report['coverage'], 'withinRequestedScope')
        code, lines, errors = run(['--json', '--document-text', 'needle', str(self.path)])
        plain = json.loads(lines[0]); self.assertNotIn('contentPreview', plain)
        self.assertEqual(plain['documentPosition'], hits[0]['documentPosition'])
        raw = run(['--json', '--content', 'needle', str(self.path)])
        self.assertEqual(raw[0], 1)

    def test_terms_across_pages_and_columns_have_their_own_positions(self):
        code, hits, report, errors = self.search(None, '--term', 'beta', '--term', 'omega')
        self.assertEqual(code, 0, errors)
        self.assertEqual([item['documentPosition']['page'] for item in hits[0]['terms']], [1, 2, 3])
        self.assertEqual([item['documentPosition']['page'] for item in hits[0]['contentPreview']['snippets']], [1, 2, 3])
        self.assertIn('left column right beta', hits[0]['contentPreview']['snippets'][1]['text'])

    def test_name_path_facts_and_document_criteria_share_one_reader(self):
        criteria = group('root', 'and', leaf('name', 'name', value='report'),
                         leaf('path', 'relativePath', value='report.pdf'),
                         leaf('text', 'content', value='beta'))
        with mock.patch.object(favenio.PDFTextReader, 'exchange', autospec=True, side_effect=favenio.PDFTextReader.exchange) as exchange:
            code, lines, errors = run(['--json', '--document-text', '--content-preview', '--min-size', '1', *arguments(criteria), str(self.path)])
        self.assertEqual(code, 0, errors)
        hit = json.loads(lines[0]); evidence = next(item for item in hit['criteriaEvidence'] if item['id'] == 'text')
        self.assertEqual(evidence['documentPosition']['page'], 2)
        self.assertEqual(hit['documentPosition']['page'], 2)
        self.assertEqual([call.args[1]['operation'] for call in exchange.call_args_list].count('open'), 1)
        self.assertEqual([call.args[1]['index'] for call in exchange.call_args_list if call.args[1]['operation'] == 'page'], [0, 1])

    def test_cheap_or_decision_does_not_open_document(self):
        criteria = group('root', 'or', leaf('cheap', value='report'), leaf('pdf', 'content', value='absent'))
        with mock.patch.object(favenio.PDFTextReader, 'exchange', side_effect=AssertionError('ungefragtes Lesen')):
            code, lines, errors = run(['--json', '--document-text', *arguments(criteria), str(self.path)])
        self.assertEqual(code, 0, errors)
        self.assertNotIn('contentEncoding', json.loads(lines[0]))

    def test_absence_needs_all_pages_but_positive_hit_stops_early(self):
        original = favenio.PDFTextReader.exchange
        for pattern, expected in [('needle', [0]), ('absent', [0, 1, 2])]:
            with mock.patch.object(favenio.PDFTextReader, 'exchange', autospec=True, side_effect=original) as exchange:
                code, hits, report, errors = self.search(pattern=pattern)
            self.assertEqual([call.args[1]['index'] for call in exchange.call_args_list if call.args[1]['operation'] == 'page'], expected)
            self.assertEqual(code, 0 if pattern == 'needle' else 1, errors)

    def test_reader_process_reused_and_recycled(self):
        reader = favenio.PDFTextReader(str(self.helper))
        self.addCleanup(reader.close)
        pages = reader.pages(str(self.path), time.monotonic()+5); next(pages); first = reader.process.pid; pages.close()
        pages = reader.pages(str(self.path), time.monotonic()+5); next(pages); self.assertEqual(reader.process.pid, first); pages.close()
        reader.documents = 32
        pages = reader.pages(str(self.path), time.monotonic()+5); next(pages); self.assertNotEqual(reader.process.pid, first); pages.close()

    def test_encrypted_damaged_and_textless_are_incomplete_unknowns(self):
        encrypted = Path(self.root, 'encrypted.pdf')
        result = run_process([str(self.encrypt), str(self.path), str(encrypted)])
        self.assertEqual(result.returncode, 0, result.stderr)
        blank = Path(self.root, 'blank.pdf'); blank.write_bytes(pdf_bytes([[]]))
        damaged = Path(self.root, 'damaged.pdf'); damaged.write_bytes(b'%PDF-1.7\nbroken')
        for path, reason in [(encrypted, 'documentEncrypted'), (blank, 'documentNoText'), (damaged, 'documentDamaged')]:
            with self.subTest(reason=reason):
                code, hits, report, errors = self.search(path)
                self.assertEqual((code, hits, report['coverage']), (1, [], 'incomplete'))
                self.assertIn(reason, [item['id'] for item in report['reasons']])
                self.assertEqual(next(item['count'] for item in report['reasons'] if item['id'] == reason), 1)
                code, lines, errors = run(['--json', '--document-text', *arguments(leaf('negative', 'content', value='absent', negate=True)), str(path)])
                self.assertEqual(code, 1, errors); self.assertFalse(lines)

    def test_mixed_textless_page_does_not_prove_negative(self):
        self.path.write_bytes(pdf_bytes([[(40, 700, 'alpha')], []]))
        code, lines, errors = run(['--json', '--document-text', '--search-report', *arguments(leaf('negative', 'content', value='absent', negate=True)), str(self.path)])
        self.assertEqual(code, 1, errors)
        self.assertEqual(json.loads(lines[-1])['coverage'], 'incomplete')

    def test_missing_optional_helper_preserves_raw_and_name_modes(self):
        with mock.patch.dict(os.environ, FAVENIO_PDF_HELPER=''):
            code, hits, report, errors = self.search()
            self.assertEqual((code, hits, report['coverage']), (1, [], 'incomplete'))
            self.assertIn('documentHelperUnavailable', [item['id'] for item in report['reasons']])
            self.assertIn('PDF-Texthelfer', errors)
            self.assertEqual(run(['report', str(self.path)])[0], 0)
            self.assertEqual(run(['--content', '%PDF', str(self.path)])[0], 0)

    def test_nested_archive_identity_and_budgets(self):
        inner = io.BytesIO()
        with zipfile.ZipFile(inner, 'w') as archive: archive.writestr('name!/report.pdf', self.path.read_bytes())
        path = Path(self.root, 'outer.zip')
        with zipfile.ZipFile(path, 'w') as archive: archive.writestr('inner.zip', inner.getvalue())
        code, hits, report, errors = self.search(path, '--archive-depth', '2')
        self.assertEqual(code, 0, errors)
        self.assertEqual(hits[0]['archiveMembers'], ['inner.zip', 'name!/report.pdf'])
        self.assertEqual(len(hits[0]['archiveMemberBytes']), 2)
        self.assertEqual(hits[0]['documentPosition']['page'], 1)
        code, hits, report, errors = self.search(path, '--archive-depth', '2', '--max-archive-member-bytes', '100')
        self.assertEqual((code, hits), (1, [])); self.assertIn('archiveMemberBytes', [item['id'] for item in report['reasons']])

    def test_materialization_page_and_text_limits(self):
        for constant, limit, pattern in [('DOCUMENT_BYTES', 10, 'needle'), ('DOCUMENT_PAGES', 1, 'omega'), ('DOCUMENT_TEXT_BYTES', 3, 'needle'), ('DOCUMENT_PAGE_BYTES', 3, 'needle')]:
            with self.subTest(constant=constant), mock.patch.object(favenio, constant, limit):
                code, hits, report, errors = self.search(pattern=pattern)
                self.assertEqual((code, hits, report['coverage']), (1, [], 'incomplete'))
                self.assertIn('documentLimit', [item['id'] for item in report['reasons']])

    def test_non_utf8_archive_names_keep_distinct_raw_identity(self):
        path = Path(self.root, 'bytes.tar')
        data = self.path.read_bytes()
        with tarfile.open(path, 'w', format=tarfile.GNU_FORMAT, encoding='utf-8', errors='surrogateescape') as archive:
            for name in ('bad-\udcff.pdf', 'bad-\udcfe.pdf'):
                member = tarfile.TarInfo(name); member.size = len(data)
                archive.addfile(member, io.BytesIO(data))
        code, hits, report, errors = self.search(path)
        self.assertEqual(code, 0, errors); self.assertEqual(len(hits), 2)
        self.assertEqual(hits[0]['archiveMembers'], hits[1]['archiveMembers'])
        self.assertNotEqual(hits[0]['archiveMemberBytes'], hits[1]['archiveMemberBytes'])
        self.assertTrue(all(hit['documentPosition']['page'] == 1 for hit in hits))

    def test_source_change_discards_positions(self):
        original = favenio.PDFTextReader.exchange
        def changed(reader, request, deadline):
            response = original(reader, request, deadline)
            if request['operation'] == 'page': self.path.write_bytes(pdf_bytes([[(40,700,'changed')]]))
            return response
        with mock.patch.object(favenio.PDFTextReader, 'exchange', changed):
            code, hits, report, errors = self.search()
        self.assertEqual((code, hits), (1, []))
        self.assertIn('documentSourceChanged', [item['id'] for item in report['reasons']])

    def test_on_demand_navigation_and_context_page_contract(self):
        code, hits, report, errors = self.search()
        second = favenio.load_content_preview(self.request(hits[0], 1, True))['contentPreview']
        self.assertEqual(second['snippets'][0]['documentPosition']['page'], 3)
        self.assertEqual(second['navigation']['reason'], 'ready')
        self.assertTrue(all('documentPosition' in item for item in second['navigation']['contextLines']))
        end = favenio.load_content_preview(self.request(hits[0], 2))['contentPreview']
        self.assertEqual(end['navigation']['reason'], 'end')
        self.path.write_bytes(pdf_bytes([[(40,700,'changed')]]))
        changed = favenio.load_content_preview(self.request(hits[0]))['contentPreview']
        self.assertEqual(changed['status'], 'sourceChanged'); self.assertFalse(changed['snippets'])

    def test_swift_roundtrip_view_navigation_and_exports(self):
        code, hits, report, errors = self.search()
        result = run_probe('content-preview', 'pdf', str(REPO/'favenio.py'), input=json.dumps(hits[0])+'\n')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(all(json.loads(result.stdout).values()), result.stdout)

    def test_timeout_and_cancel_reap_helper_and_remove_materialization(self):
        helper = Path(self.root, 'blocked-helper')
        helper.write_text('#!/bin/sh\necho "$$" > "$PDF_PID"\nexec /bin/sleep 60\n'); helper.chmod(0o700)
        pidfile = Path(self.root, 'pid')
        children = []
        spawn = subprocess.Popen
        def start_child(*args, **kwargs):
            child = spawn(*args, **kwargs); children.append(child.pid); return child
        with mock.patch.dict(os.environ, FAVENIO_PDF_HELPER=str(helper), PDF_PID=str(pidfile)), mock.patch.object(favenio, 'DOCUMENT_SECONDS', 0.5), mock.patch.object(favenio.subprocess, 'Popen', start_child):
            started = time.monotonic(); code, hits, report, errors = self.search()
        self.assertLess(time.monotonic()-started, 2)
        self.assertIn('documentTimeout', [item['id'] for item in report['reasons']])
        self.assertEqual(len(children), 1)
        with self.assertRaises(ProcessLookupError): os.kill(children[0], 0)
        env = dict(os.environ, FAVENIO_PDF_HELPER=str(helper), PDF_PID=str(pidfile), TMPDIR=self.scratch.name)
        if pidfile.exists(): pidfile.unlink()
        archive = Path(self.root, 'cancel.zip')
        with zipfile.ZipFile(archive, 'w') as output: output.writestr('report.pdf', self.path.read_bytes())
        with subprocess.Popen([sys.executable, str(REPO/'favenio.py'), '--json', '--search-report', '--document-text', 'needle', str(archive)], stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env) as process:
            deadline = time.monotonic()+4
            while not pidfile.exists() and time.monotonic()<deadline: time.sleep(0.01)
            self.assertTrue(pidfile.exists())
            self.assertTrue(list(Path(self.scratch.name).glob('*.pdf')))
            process.terminate(); stdout, stderr = process.communicate(timeout=3)
        self.assertEqual(json.loads(stdout.splitlines()[-1])['state'], 'cancelled')
        with self.assertRaises(ProcessLookupError): os.kill(int(pidfile.read_text()), 0)
        self.assertFalse(list(Path(self.scratch.name).glob('*.pdf')))

    def test_modes_and_unsupported_type_are_explicit(self):
        self.assertEqual(run(['--content', '--document-text', 'needle', str(self.path)])[0], 2)
        path = Path(self.root, 'note.txt'); path.write_text('needle')
        code, hits, report, errors = self.search(path)
        self.assertEqual((code, hits, report['coverage']), (1, [], 'incomplete'))
        self.assertIn('documentUnsupported', [item['id'] for item in report['reasons']])

    def test_original_projection_bom_unicode_and_requested_encoding_survive(self):
        def pages(reader, path, deadline):
            yield 1, '\ufefffu\u0308r 😀 needle'
        with mock.patch.object(favenio.PDFTextReader, 'pages', pages):
            code, hits, report, errors = self.search(None, '--encoding', 'auto', pattern='FÜR')
        self.assertEqual(code, 0, errors)
        snippet = hits[0]['contentPreview']['snippets'][0]
        self.assertTrue(snippet['text'].startswith('\ufefffu\u0308r'))
        self.assertEqual(snippet['query']['encoding'], 'auto')
        result = run_probe('content-preview', 'parse', input=json.dumps(hits[0])+'\n')
        parsed = json.loads(result.stdout)
        self.assertTrue(parsed['roundtrip']); self.assertEqual(parsed['marks'], ['fu\u0308r'])
        self.assertIn('\ufefffu\u0308r', parsed['rendered'])


if __name__ == '__main__': unittest.main()
