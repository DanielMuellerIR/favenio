"""PDF-Textebenen bevorzugen; Vision-Herkunft und begrenzte Seitenarbeit erhalten."""
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock
import zipfile
from test_favenio import TempTreeTest, favenio, run
from test_criteria import arguments, group, leaf
from pdf_fixture import pdf_bytes
from swift_test_support import run_process

REPO = Path(__file__).resolve().parents[1]


@unittest.skipUnless(sys.platform == 'darwin' and shutil.which('swiftc') and tuple(map(int, __import__('platform').mac_ver()[0].split('.')[:1])) >= (13,), 'PDF-OCR braucht macOS 13/Swift')
class PDFOCRTests(TempTreeTest):
    @classmethod
    def setUpClass(cls):
        cls.tools = tempfile.TemporaryDirectory(prefix='favenio-pdf-ocr-tests-')
        cls.addClassCleanup(cls.tools.cleanup)
        cls.base = Path(cls.tools.name)
        cls.helper = cls.base/'favenio-pdf'
        for sources, output in [(['ocr/VisionText.swift', 'pdf/main.swift'], cls.helper), (['tests/pdf_ocr_fixture.swift'], cls.base/'fixtures'), (['tests/pdf_encrypt_fixture.swift'], cls.base/'encrypt')]:
            result = run_process(['swiftc', '-O', *[str(REPO/p) for p in sources], '-o', str(output)], timeout=40)
            if result.returncode:
                raise RuntimeError(result.stderr)
        (cls.base/'text.pdf').write_bytes(pdf_bytes([[(40, 700, 'original alpha needle')]]))
        (cls.base/'blank.pdf').write_bytes(pdf_bytes([[]]))
        result = run_process([str(cls.base/'fixtures'), str(cls.base)])
        if result.returncode:
            raise RuntimeError(result.stderr)

    def setUp(self):
        super().setUp()
        patch = mock.patch.dict(os.environ, FAVENIO_PDF_HELPER=str(self.helper))
        patch.start(); self.addCleanup(patch.stop)

    def search(self, name='mixed.pdf', *options, pattern='München'):
        path = Path(name) if Path(name).is_absolute() else self.base/name
        code, lines, errors = run(['--json', '--search-report', '--content-preview', '--document-text', '--pdf-ocr', *options, pattern, str(path)])
        records = [json.loads(x) for x in lines]
        return code, [x for x in records if x['type'] not in ('searchReport', 'progress')], records[-1], errors

    def test_scan_and_rotation_have_page_ocr_origin(self):
        for name in ['scan.pdf', 'rotated.pdf']:
            with self.subTest(name=name):
                code, hits, report, errors = self.search(name, '--term', 'Invoice')
                self.assertEqual((code, len(hits), errors), (0, 1, ''))
                self.assertEqual(hits[0]['contentEncoding'], favenio.PDF_OCR_ENCODING)
                self.assertEqual([x['documentPosition']['kind'] for x in hits[0]['terms']], ['pdfOCR', 'pdfOCR'])
                self.assertEqual(hits[0]['documentPosition']['page'], 1)
                self.assertIn('pdfOCRProjection', [r['id'] for r in report['reasons']])

    def test_mixed_terms_keep_origins_and_only_textless_page_runs_vision(self):
        original = favenio.PDFOCRTextReader.exchange
        with mock.patch.object(favenio.PDFOCRTextReader, 'exchange', autospec=True, side_effect=original) as exchange:
            code, hits, report, errors = self.search('mixed.pdf', '--term', 'alpha')
        self.assertEqual((code, len(hits), errors), (0, 1, ''))
        self.assertEqual([(x['documentPosition']['kind'], x['documentPosition']['page']) for x in hits[0]['terms']], [('pdfOCR', 2), ('pdfTextPage', 1)])
        self.assertEqual([c.args[1]['index'] for c in exchange.call_args_list if c.args[1]['operation'] == 'ocrPage'], [1])

    def test_text_hit_stops_before_later_scan_and_default_off_stays_off(self):
        original = favenio.PDFOCRTextReader.exchange
        with mock.patch.object(favenio.PDFOCRTextReader, 'exchange', autospec=True, side_effect=original) as exchange:
            code, hits, _, errors = self.search(pattern='alpha')
        self.assertEqual(code, 0, errors)
        self.assertEqual(hits[0]['documentPosition']['kind'], 'pdfTextPage')
        self.assertFalse(any(c.args[1]['operation'] == 'ocrPage' for c in exchange.call_args_list))
        for options in [[], ['--ocr']]:
            with self.subTest(options=options):
                code, lines, errors = run(['--json', '--document-text', *options, 'München', str(self.base/'scan.pdf')])
                self.assertEqual((code, lines), (1, [])); self.assertIn('keine OCR', errors)

    def test_blank_first_page_does_not_hide_later_scan(self):
        code, hits, report, errors = self.search('blank-first.pdf')
        self.assertEqual((code, hits[0]['documentPosition']['page']), (0, 2), errors)
        self.assertIn('ocrNoText', [r['id'] for r in report['reasons']])

    def test_prefilters_and_cheap_or_do_not_open_pdf(self):
        with mock.patch.object(favenio.PDFOCRTextReader, 'exchange', side_effect=AssertionError('ungefragte PDF-Arbeit')):
            self.assertEqual(self.search('scan.pdf', '--max-size', '1')[0], 1)
            code, _, errors = run(['--json', '--document-text', '--pdf-ocr', *arguments(group('root', 'or', leaf('name', 'name', value='scan'), leaf('text', 'content', value='absent'))), str(self.base/'scan.pdf')])
            self.assertEqual(code, 0, errors)

    def test_ocr_never_proves_original_absence(self):
        code, lines, errors = run(['--json', '--search-report', '--document-text', '--pdf-ocr', *arguments(leaf('missing', 'content', value='absent', negate=True)), str(self.base/'scan.pdf')])
        self.assertEqual(code, 1, errors)
        report = json.loads(lines[-1]); self.assertEqual(report['coverage'], 'incomplete')

    def test_archive_identity_budget_and_preview_reload(self):
        image = (self.base/'mixed.pdf').read_bytes(); archive = Path(self.root)/'own.zip'
        with zipfile.ZipFile(archive, 'w') as out: out.writestr('inner!/mixed.pdf', image)
        code, hits, report, errors = self.search(str(archive), '--max-archive-total-bytes', str(len(image)))
        self.assertEqual((code, len(hits)), (0, 1), errors)
        hit = hits[0]; self.assertEqual(hit['archiveMembers'], ['inner!/mixed.pdf'])
        self.assertEqual(hit['documentPosition']['page'], 2)
        code, _, report, errors = self.search(str(archive), '--max-archive-total-bytes', str(len(image)-1))
        self.assertEqual(code, 1, errors)
        hit = self.search()[1][0]
        request = dict(schemaVersion=1, hit=hit, filePath=str(self.base/'mixed.pdf'), fileGeneration=favenio.source_generation(str(self.base/'mixed.pdf')), queryIndex=0, occurrence=0, context=True)
        loaded = favenio.load_content_preview(request)
        preview = loaded['contentPreview']; self.assertEqual(preview['status'], 'ready')
        self.assertEqual(preview['snippets'][0]['documentPosition']['kind'], 'pdfOCR')
        self.assertEqual(preview['snippets'][0]['query']['documentReader'], 'pdfkit-vision-v1')

    def test_local_policy_precedes_pdf_helper(self):
        with mock.patch.object(favenio, 'local_content_reason', return_value='localContentNotLocal'), mock.patch.object(favenio.PDFOCRTextReader, 'exchange', side_effect=AssertionError('Cloud-OCR')):
            code, hits, report, errors = self.search('scan.pdf', '--local-only')
        self.assertEqual((code, hits), (1, []), errors)
        self.assertIn('localContentNotLocal', [r['id'] for r in report['reasons']])

    def test_huge_page_and_rendered_page_and_total_pixel_budgets(self):
        for name in ['huge.pdf', 'many.pdf', 'large-many.pdf']:
            # Hier werden Pixel-/Seitenbudgets geprüft, unabhängig von der
            # Geschwindigkeit der Vision-Erkennung auf dem Testrechner.
            with self.subTest(name=name), mock.patch.object(favenio, 'PDF_OCR_SECONDS', 60):
                code, hits, report, errors = self.search(name, pattern='absent')
                self.assertEqual((code, hits), (1, []), errors)
                self.assertIn('pdfOCRLimit', [r['id'] for r in report['reasons']])
                self.assertNotIn('documentTimeout', [r['id'] for r in report['reasons']])

    def test_visited_page_budget_and_plain_output(self):
        path = Path(self.root)/'long.pdf'; path.write_bytes(pdf_bytes([[(40,700,'ordinary text')]]*128 + [[(40,700,'needle')]]))
        code, hits, report, errors = self.search(str(path), pattern='needle')
        self.assertEqual((code, hits), (1, []), errors)
        self.assertIn('pdfOCRLimit', [r['id'] for r in report['reasons']])
        code, lines, errors = run(['--document-text', '--pdf-ocr', 'München', str(self.base/'scan.pdf')])
        self.assertEqual(code, 0, errors); self.assertIn('PDF-Seite 1 OCR-Bereich', lines[0])

    def test_encrypted_damaged_and_old_helper_are_explained(self):
        encrypted = Path(self.root)/'encrypted.pdf'
        self.assertEqual(run_process([str(self.base/'encrypt'),str(self.base/'scan.pdf'),str(encrypted)]).returncode, 0)
        damaged = Path(self.root)/'bad.pdf'; damaged.write_bytes(b'%PDF-1.7\nbroken')
        for path, reason in [(encrypted, 'documentEncrypted'), (damaged, 'documentDamaged')]:
            code, hits, report, errors = self.search(str(path))
            self.assertEqual((code, hits), (1, []), errors)
            self.assertIn(reason, [r['id'] for r in report['reasons']])
        def old(reader, request, deadline):
            return dict(schemaVersion=1,ok=True,pageCount=1)
        with mock.patch.object(favenio.PDFOCRTextReader, 'exchange', autospec=True, side_effect=old):
            code, hits, report, errors = self.search('scan.pdf')
        self.assertEqual(code, 1, errors);self.assertIn('ocrHelperUnavailable',[r['id'] for r in report['reasons']])

    def test_page_progress_is_emitted_before_ocr_work(self):
        code, lines, errors = run(['--json','--progress','--document-text','--pdf-ocr','München',str(self.base/'mixed.pdf')])
        records=[json.loads(x) for x in lines];self.assertEqual(code,0,errors)
        progress=next(x for x in records if x['type']=='progress' and x.get('stage')=='pdfOCR')
        self.assertEqual((progress['page'],progress['pages']),(2,2));self.assertLess(records.index(progress),next(i for i,x in enumerate(records) if x['type']=='file'))

    def test_source_change_and_malformed_later_block_discard_hit(self):
        path = Path(self.root)/'changed.pdf'; shutil.copy2(self.base/'scan.pdf', path)
        original = favenio.PDFOCRTextReader.exchange
        def changed(reader, request, deadline):
            value = original(reader, request, deadline)
            if request['operation'] == 'ocrPage':
                with path.open('ab') as stream: stream.write(b'\n%changed')
            return value
        with mock.patch.object(favenio.PDFOCRTextReader, 'exchange', autospec=True, side_effect=changed):
            code, hits, report, errors = self.search(str(path))
        self.assertEqual((code, hits), (1, []), errors)
        self.assertIn('documentSourceChanged', [r['id'] for r in report['reasons']])
        def malformed(reader, request, deadline):
            value = original(reader, request, deadline)
            if request['operation'] == 'ocrPage': value['blocks'][-1]['region'] = [0.9,0.2,0.5,0.1]
            return value
        with mock.patch.object(favenio.PDFOCRTextReader, 'exchange', autospec=True, side_effect=malformed):
            code, hits, report, errors = self.search('scan.pdf')
        self.assertEqual((code, hits), (1, []), errors)
        self.assertIn('ocrReadError', [r['id'] for r in report['reasons']])

    def test_actual_pdf_ocr_sigterm_reaps_helper_and_reports_cancelled(self):
        import select
        from swift_test_support import _terminate_session
        child = subprocess.Popen([sys.executable, '-B', str(REPO/'favenio.py'), '--json', '--progress', '--search-report', '--document-text', '--pdf-ocr', 'absent', str(self.base/'many.pdf')],
            env=dict(os.environ, FAVENIO_PDF_HELPER=str(self.helper)), stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, start_new_session=True)
        rows=[]
        try:
            deadline=time.monotonic()+5
            while time.monotonic()<deadline:
                if select.select([child.stdout],[],[],.1)[0]:
                    line=child.stdout.readline()
                    if not line: break
                    row=json.loads(line);rows.append(row)
                    if row.get('stage')=='pdfOCR':break
            self.assertTrue(rows and rows[-1].get('stage')=='pdfOCR')
            values=subprocess.check_output(['pgrep','-P',str(child.pid)],text=True).split()
            self.assertEqual(len(values),1); helper_pid=int(values[0])
            start=time.monotonic();child.terminate();out,errors=child.communicate(timeout=3)
            self.assertEqual(child.returncode,143,errors);self.assertLess(time.monotonic()-start,2)
            records=rows+[json.loads(line) for line in out.splitlines()]
            self.assertEqual(records[-1]['state'],'cancelled')
            with self.assertRaises(ProcessLookupError):os.kill(helper_pid,0)
        finally:
            _terminate_session(child.pid);child.communicate(timeout=3)

    def test_render_limit_preserves_later_text_layer_hit(self):
        code, hits, report, errors = self.search('huge-first.pdf', pattern='alpha')
        self.assertEqual((code, len(hits)), (0, 1), errors)
        self.assertEqual((hits[0]['documentPosition']['kind'], hits[0]['documentPosition']['page']), ('pdfTextPage', 2))
        self.assertIn('pdfOCRLimit', [r['id'] for r in report['reasons']])

    def test_ocr_phase_replaces_text_phase_without_waiting_for_throttle(self):
        import contextlib, io
        for second, times, count in [('/one.pdf', [0,1,1.001,1.002], 3), ('/two.pdf', [0,.001,.002,.003], 2)]:
            with self.subTest(second=second):
                search = favenio.Search(None, False, 1, True, progress=True)
                output = io.StringIO()
                with contextlib.redirect_stdout(output), mock.patch.object(favenio.time, 'monotonic', side_effect=times):
                    search.report_progress('/one.pdf', stage='pdfOCR', page=1, pages=3)
                    search.report_progress(second, stage='pdfText', page=2, pages=3)
                    search.report_progress(second, stage='pdfOCR', page=2, pages=3)
                    search.report_progress('/ordinary-folder')
                rows = [json.loads(line) for line in output.getvalue().splitlines()]
                self.assertEqual(len(rows), count)
                self.assertEqual((rows[-1]['stage'], rows[-1]['page'], rows[-1]['path']), ('pdfOCR', 2, second))
                search.close()
