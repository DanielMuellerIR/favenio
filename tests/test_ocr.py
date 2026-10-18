"""OCR bleibt opt-in, budgetiert und ein unvollständiger Beleg des Bildtextes."""
import contextlib
import copy
import io
import json
import os
from pathlib import Path
import shutil
import signal
import struct
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock
import zipfile
import zlib

import favenio as f

REPO = Path(__file__).resolve().parent.parent


def png_bytes(width=64, height=32):
    def chunk(kind, data):
        return struct.pack('!I', len(data)) + kind + data + struct.pack('!I', zlib.crc32(kind + data))
    compressor = zlib.compressobj()
    row = b'\0' + b'\xff\xff\xff' * width
    compressed = b''.join(compressor.compress(row) for _ in range(height)) + compressor.flush()
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('!2I5B', width, height, 8, 2, 0, 0, 0)) + chunk(b'IDAT', compressed) + chunk(b'IEND', b'')


def recognized(*texts):
    return dict(schemaVersion=1, ok=True, reader='vision-image-v1', blocks=[
        dict(block=index, text=text, confidence=0.9, region=[0.1, 0.1, 0.8, 0.1])
        for index, text in enumerate(texts, 1)])


class OCRCoreTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix='favenio-ocr-test-')
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.source = self.root / 'screen.png'
        self.source.write_bytes(png_bytes())

    def run_core(self, args, response=None):
        output, errors = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(output), contextlib.redirect_stderr(errors), \
             mock.patch.object(f.OCRTextReader, 'exchange', return_value=response or recognized('alpha', 'beta')) as exchange:
            status = f.main(['--json', '--search-report', '--document-text', '--ocr'] + args)
        rows = [json.loads(line) for line in output.getvalue().splitlines()]
        return status, [r for r in rows if r['type'] != 'searchReport'], rows[-1], errors.getvalue(), exchange.call_count

    def test_recognized_terms_share_one_image_scan_and_have_separate_regions(self):
        status, hits, report, _, calls = self.run_core(['--content-preview', '--term', 'beta', 'alpha', str(self.source)])
        self.assertEqual((status, len(hits), calls), (0, 1, 1))
        self.assertEqual(hits[0]['contentEncoding'], f.OCR_ENCODING)
        self.assertEqual([term['documentPosition']['block'] for term in hits[0]['terms']], [1, 2])
        self.assertEqual(hits[0]['contentPreview']['snippets'][0]['query']['documentReader'], 'vision-image-v1')
        self.assertEqual(report['coverage'], 'incomplete')
        self.assertIn('ocrProjection', [r['id'] for r in report['reasons']])

    def test_default_off_and_raw_content_never_run_ocr(self):
        with mock.patch.object(f.OCRTextReader, 'exchange', side_effect=AssertionError('OCR trotz ausgeschalteter Option')), \
             contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(f.main(['--document-text', 'alpha', str(self.source)]), 1)
            self.assertEqual(f.main(['--content', '--ocr', 'alpha', str(self.source)]), 1)

    def test_size_and_dimension_rejection_happen_before_ocr(self):
        for options in [['--min-size', '1GiB'], ['--min-width', '1000']]:
            status, hits, _, _, calls = self.run_core(options + ['alpha', str(self.source)])
            self.assertEqual((status, hits, calls), (1, [], 0))

    def test_cheap_criteria_or_does_not_open_image(self):
        query = dict(schemaVersion=1, root=dict(id='root', op='or', children=[
            dict(id='name', field='name', operator='contains', value='screen'),
            dict(id='text', field='content', operator='contains', value='alpha')]))
        _, hits, _, _, calls = self.run_core(['--criteria-json', json.dumps(query), str(self.source)])
        self.assertEqual((len(hits), calls), (1, 0))

    def test_ocr_cannot_prove_absence_even_after_all_regions(self):
        query = dict(schemaVersion=1, root=dict(id='text', field='content', operator='contains', value='missing', negate=True))
        status, hits, report, _, calls = self.run_core(['--criteria-json', json.dumps(query), str(self.source)])
        self.assertEqual((status, hits, calls), (1, [], 1))
        self.assertEqual(report['coverage'], 'incomplete')

    def test_no_text_and_unavailable_helper_are_explained(self):
        _, hits, report, _, _ = self.run_core(['alpha', str(self.source)], recognized())
        self.assertFalse(hits)
        self.assertIn('ocrNoText', [r['id'] for r in report['reasons']])
        reader = f.OCRTextReader(None)
        with self.assertRaises(f.DocumentReadError) as caught:
            list(reader.sections(str(self.source), time.monotonic() + 1))
        self.assertEqual(caught.exception.reason, 'ocrHelperUnavailable')

    def test_archive_identity_and_budget_survive_ocr_materialization(self):
        archive = self.root / 'outer.zip'
        data = self.source.read_bytes()
        with zipfile.ZipFile(archive, 'w') as out:
            out.writestr('folder!/screen.png', data)
        for limits in [[], ['--min-width', '64']]:
            status, hits, _, _, calls = self.run_core(limits + ['--max-archive-total-bytes', str(len(data)), 'alpha', str(archive)])
            self.assertEqual((status, len(hits), calls), (0, 1, 1))
            self.assertEqual(hits[0]['archiveMembers'], ['folder!/screen.png'])
            self.assertEqual(hits[0]['documentPosition']['kind'], 'imageOCR')

    def test_archive_limit_rejects_image_before_ocr(self):
        archive = self.root / 'limited.zip'
        with zipfile.ZipFile(archive, 'w') as out:out.writestr('screen.png', self.source.read_bytes())
        status, hits, report, _, calls = self.run_core(['--max-archive-member-bytes', '10', 'alpha', str(archive)])
        self.assertEqual((status, hits, calls), (1, [], 0))
        self.assertEqual(report['coverage'], 'incomplete')

    def test_existing_pdf_text_does_not_start_image_ocr(self):
        source = self.root / 'text.pdf';source.write_bytes(b'%PDF-own-test')
        with mock.patch.object(f.PDFTextReader, 'pages', return_value=iter([(1, 'alpha')])):
            status, hits, _, _, calls = self.run_core(['alpha', str(source)])
        self.assertEqual((status, len(hits), calls), (0, 1, 0))
        self.assertEqual(hits[0]['contentEncoding'], f.DOCUMENT_ENCODING)

    def test_plain_text_output_labels_ocr_without_file_byte_offsets(self):
        with mock.patch.object(f.OCRTextReader, 'exchange', return_value=recognized('alpha')), \
             contextlib.redirect_stdout(io.StringIO()) as out, contextlib.redirect_stderr(io.StringIO()):
            status = f.main(['--document-text', '--ocr', 'alpha', str(self.source)])
        self.assertEqual(status, 0)
        self.assertIn('OCR-Bereich 1 Zeile 1 (erkannt, ungefähre Bildposition)', out.getvalue())

    def test_source_change_discards_recognized_hit(self):
        def changed(*args):
            self.source.write_bytes(self.source.read_bytes() + b'changed')
            return recognized('alpha')
        with mock.patch.object(f.OCRTextReader, 'exchange', side_effect=changed), \
             contextlib.redirect_stdout(io.StringIO()) as out, contextlib.redirect_stderr(io.StringIO()):
            status = f.main(['--json', '--search-report', '--document-text', '--ocr', 'alpha', str(self.source)])
        rows = [json.loads(line) for line in out.getvalue().splitlines()]
        self.assertEqual(status, 1)
        self.assertFalse([r for r in rows if r['type'] != 'searchReport'])
        self.assertIn('documentSourceChanged', [r['id'] for r in rows[-1]['reasons']])

    def test_local_policy_guards_ocr_before_helper(self):
        with mock.patch.object(f, 'local_content_policy', side_effect=lambda _: contextlib.nullcontext()), \
             mock.patch.object(f, 'local_content_reason', return_value='localContentUnknown'):
            _, hits, report, _, calls = self.run_core(['--local-only', 'alpha', str(self.source)])
        self.assertEqual((hits, calls), ([], 0))
        self.assertIn('localContentUnknown', [r['id'] for r in report['reasons']])

    def test_malformed_later_region_rejects_whole_received_response(self):
        response = recognized('alpha', 'beta')
        mutations = [lambda b: b.update(confidence=True), lambda b: b.update(confidence=float('nan')),
                     lambda b: b.update(region=[.8, .1, .8, .1]), lambda b: b.update(region=[0, 0, 0, .1]),
                     lambda b: b.update(block=1), lambda b: b.update(text='\ud800')]
        for mutate in mutations:
            value = copy.deepcopy(response); mutate(value['blocks'][1])
            _, hits, report, _, _ = self.run_core(['alpha', str(self.source)], value)
            self.assertFalse(hits)
            self.assertIn('ocrReadError', [r['id'] for r in report['reasons']])

    def test_preview_reload_uses_same_reader_and_original_text_ranges(self):
        _, hits, _, _, _ = self.run_core(['--content-preview', 'alpha', str(self.source)], recognized('alpha alpha'))
        request = dict(schemaVersion=1, hit=hits[0], queryIndex=0, occurrence=1,
                       filePath=str(self.source), fileGeneration=f.source_generation(str(self.source)), context=False)
        with mock.patch.object(f.OCRTextReader, 'exchange', return_value=recognized('alpha alpha')):
            result = f.load_content_preview(request)
        preview = result['contentPreview']
        self.assertEqual(preview['snippets'][0]['documentPosition']['kind'], 'imageOCR')
        self.assertEqual(preview['snippets'][0]['location'], 6)
        self.assertEqual(preview['navigation']['occurrence'], 1)

    def test_oversized_helper_output_is_bounded(self):
        helper = self.root / 'huge-helper'
        helper.write_text('#!' + sys.executable + '\nimport sys\nsys.stdin.readline()\nsys.stdout.write("x" * (3 * 1024 * 1024));sys.stdout.flush()\n')
        helper.chmod(0o755)
        reader = f.OCRTextReader(str(helper))
        try:
            with self.assertRaises(f.DocumentReadError) as caught:
                list(reader.sections(str(self.source), time.monotonic() + 2))
            self.assertEqual(caught.exception.reason, 'ocrLimit')
        finally:
            reader.close()
        self.assertIsNone(reader.process)

    def test_core_sigterm_reaps_slow_ocr_helper(self):
        from swift_test_support import _terminate_session
        pid_file = self.root / 'helper.pid'
        helper = self.root / 'cancel-helper'
        helper.write_text('#!' + sys.executable + '\nimport os,sys,time\nfrom pathlib import Path\nsys.stdin.readline()\nPath(' + repr(str(pid_file)) + ').write_text(str(os.getpid()))\ntime.sleep(30)\n')
        helper.chmod(0o755)
        child = subprocess.Popen([sys.executable, '-B', str(REPO/'favenio.py'), '--json', '--search-report', '--document-text', '--ocr', 'alpha', str(self.source)],
            env=dict(os.environ, FAVENIO_OCR_HELPER=str(helper)), stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, start_new_session=True)
        try:
            deadline = time.monotonic() + 3
            while not pid_file.exists() and time.monotonic() < deadline and child.poll() is None:time.sleep(.02)
            self.assertTrue(pid_file.exists())
            helper_pid = int(pid_file.read_text())
            self.assertIsNone(child.poll())
            child.terminate()
            out, errors = child.communicate(timeout=3)
            self.assertEqual(child.returncode, 143, errors)
            rows = [json.loads(line) for line in out.splitlines()]
            self.assertEqual(rows[-1]['state'], 'cancelled')
            with self.assertRaises(ProcessLookupError):os.kill(helper_pid, 0)
        finally:
            _terminate_session(child.pid)
            child.communicate(timeout=3)

    def test_helper_timeout_reaps_own_process(self):
        helper = self.root / 'slow-helper'
        helper.write_text('#!' + sys.executable + '\nimport sys,time\nsys.stdin.readline()\ntime.sleep(30)\n')
        helper.chmod(0o755)
        reader = f.OCRTextReader(str(helper))
        with self.assertRaises(f.DocumentReadError) as caught:
            list(reader.sections(str(self.source), time.monotonic() + .1))
        self.assertEqual(caught.exception.reason, 'ocrTimeout')
        self.assertIsNone(reader.process)


@unittest.skipUnless(sys.platform == 'darwin' and int(os.uname().release.split('.')[0]) >= 22 and shutil.which('swiftc'), 'macOS/Swift erforderlich')
class NativeOCRTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory(prefix='favenio-native-ocr-')
        cls.addClassCleanup(cls.directory.cleanup)
        cls.root = Path(cls.directory.name)
        cls.helper, cls.fixture = cls.root / 'ocr', cls.root / 'fixture'
        for sources, target in [(['ocr/VisionText.swift', 'ocr/main.swift'], cls.helper), (['tests/ocr_fixture.swift'], cls.fixture)]:
            result = subprocess.run(['swiftc', '-O', *[str(REPO / p) for p in sources], '-o', str(target)], capture_output=True, text=True, timeout=30)
            if result.returncode:raise RuntimeError(result.stderr)
        cls.image = cls.root / 'own-screen.png'
        subprocess.run([str(cls.fixture), str(cls.image)], check=True, timeout=5)

    def test_actual_vision_finds_german_and_english_and_marks_approximate_evidence(self):
        env = dict(os.environ, FAVENIO_OCR_HELPER=str(self.helper))
        result = subprocess.run([sys.executable, '-B', str(REPO/'favenio.py'), '--json', '--document-text', '--ocr', '--content-preview', '--term', 'Invoice', 'München', str(self.image)], env=env, capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stderr)
        hits = [json.loads(line) for line in result.stdout.splitlines()]
        self.assertEqual(len(hits), 1)
        self.assertEqual(hits[0]['contentEncoding'], f.OCR_ENCODING)
        self.assertEqual(hits[0]['documentPosition']['kind'], 'imageOCR')
        self.assertEqual(len(hits[0]['terms']), 2)

    def test_pixel_limit_precedes_native_image_decode(self):
        image = self.root / 'too-many-pixels.png';image.write_bytes(png_bytes(4000, 4000))
        reader = f.OCRTextReader(str(self.helper))
        try:
            with self.assertRaises(f.DocumentReadError) as caught:list(reader.sections(str(image), time.monotonic()+5))
            self.assertEqual(caught.exception.reason, 'ocrLimit')
        finally:reader.close()

    def test_named_pipe_is_rejected_without_waiting_for_writer(self):
        source = self.root / 'pipe.png';os.mkfifo(source)
        reader = f.OCRTextReader(str(self.helper));started=time.monotonic()
        try:
            with self.assertRaises(f.DocumentReadError) as caught:list(reader.sections(str(source), time.monotonic()+2))
            self.assertEqual(caught.exception.reason, 'ocrReadError')
            self.assertLess(time.monotonic()-started, 1)
        finally:reader.close()
