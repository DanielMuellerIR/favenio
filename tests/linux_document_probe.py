"""Reale Poppler-/Tesseract-Suche mit demselben Kern und gebundenen Fundstellen."""
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
from pdf_fixture import pdf_bytes


def main():
    engine, image = map(Path, sys.argv[1:])
    spec = importlib.util.spec_from_file_location('favenio', engine)
    core = importlib.util.module_from_spec(spec)
    sys.modules['favenio'] = core
    spec.loader.exec_module(core)
    def search(path, pattern, *options):
        process = subprocess.run([sys.executable, '-B', str(engine), '--json', '--document-text', '--content-preview', '--search-report', *options, pattern, str(path)], capture_output=True, timeout=25)
        records = [json.loads(line) for line in process.stdout.splitlines()]
        hits = [row for row in records if row['type'] not in ('searchReport', 'progress')]
        assert process.returncode == 0 and len(hits) == 1, (process.returncode, records, process.stderr)
        return hits[0]
    with tempfile.TemporaryDirectory(prefix='favenio-document-probe-') as directory:
        root = Path(directory)
        pdf = root/'text.pdf'
        pdf.write_bytes(pdf_bytes([[(40, 700, 'alpha needle')], [(40, 700, 'second needle')]]))
        hit = search(pdf, 'needle')
        assert hit['documentPosition']['reader'] == 'poppler-v1', hit
        assert len(hit['documentPosition']['readerFingerprint']) == 64
        request = dict(schemaVersion=1, hit=hit, filePath=str(pdf), fileGeneration=core.source_generation(str(pdf)), queryIndex=0, occurrence=1, context=True)
        preview = core.load_content_preview(request)['contentPreview']
        assert preview['status'] == 'ready' and preview['snippets'][0]['documentPosition']['page'] == 2, preview
        changed = json.loads(json.dumps(request))
        for snippet in changed['hit']['contentPreview']['snippets']:
            snippet['documentPosition']['readerFingerprint'] = '0'*64
        changed['hit']['documentPosition']['readerFingerprint'] = '0'*64
        preview = core.load_content_preview(changed)['contentPreview']
        assert preview['status'] != 'ready', preview
        ocr = search(image, 'München', '--ocr')
        assert ocr['documentPosition']['reader'] == 'tesseract-image-v1', ocr
        large = root/'large-ocr.png'
        subprocess.run(['convert', str(image), '-resize', '3000x1500!', str(large)], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, timeout=10)
        ocr = search(large, 'München', '--ocr')
        assert ocr['documentPosition']['reader'] == 'tesseract-image-v1', ocr
        # Der Scan enthält ausschließlich ein Bild, keine unsichtbare Textebene.
        ppm = subprocess.check_output(['convert', str(image), '-depth', '8', 'ppm:-'], timeout=10)
        # ImageMagick schreibt üblicherweise eine dreizeilige PPM-Kopfzeile.
        import re, zlib
        match = re.match(rb'P6\s+(?:#[^\n]*\n\s*)?(\d+)\s+(\d+)\s+255\s', ppm)
        assert match, ppm[:100]
        width, height = map(int, match.groups())
        pixels = ppm[match.end():]
        assert len(pixels) == width*height*3
        encoded = zlib.compress(pixels)
        content = b'q 720 0 0 360 0 0 cm /Im0 Do Q'
        objects = [b'<< /Type /Catalog /Pages 2 0 R >>', b'<< /Type /Pages /Kids [3 0 R] /Count 1 >>', b'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 720 360] /Resources << /XObject << /Im0 4 0 R >> >> /Contents 5 0 R >>', ('<< /Type /XObject /Subtype /Image /Width %d /Height %d /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /FlateDecode /Length %d >>\nstream\n' % (width,height,len(encoded))).encode()+encoded+b'\nendstream', b'<< /Length '+str(len(content)).encode()+b' >>\nstream\n'+content+b'\nendstream']
        data = bytearray(b'%PDF-1.4\n'); offsets = [0]
        for index, obj in enumerate(objects, 1):
            offsets.append(len(data)); data.extend(str(index).encode()+b' 0 obj\n'+obj+b'\nendobj\n')
        start = len(data); data.extend(b'xref\n0 6\n0000000000 65535 f \n')
        for offset in offsets[1:]: data.extend(('%010d 00000 n \n' % offset).encode())
        data.extend(b'trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n'+str(start).encode()+b'\n%%EOF\n')
        scan = root/'scan.pdf'; scan.write_bytes(data)
        hit = search(scan, 'München', '--pdf-ocr')
        assert hit['documentPosition']['reader'] == 'poppler-tesseract-v1', hit
        assert hit['documentPosition']['kind'] == 'pdfOCR', hit
    print('LINUX DOCUMENT OK: real PDF text, next page, changed reader rejected, German image OCR, scanned PDF OCR')


if __name__ == '__main__': main()
