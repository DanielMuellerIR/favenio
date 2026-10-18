"""Kleine synthetische PDFs, ohne Python-Zusatzpaket und mit Flate-Textebene."""
import zlib


def pdf_bytes(pages):
    objects = [b'', b'', b'<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>']
    kids = []
    for entries in pages:
        page_id = len(objects) + 1
        kids.append(b'%d 0 R' % page_id)
        objects.append(b'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 600 800] /Resources << /Font << /F1 3 0 R >> >> /Contents %d 0 R >>' % (page_id + 1))
        lines = []
        for x, y, text in entries:
            escaped = text.encode('latin-1').replace(b'\\', b'\\\\').replace(b'(', b'\\(').replace(b')', b'\\)')
            lines.append(b'BT /F1 14 Tf %d %d Td (' % (x, y) + escaped + b') Tj ET')
        data = zlib.compress(b'\n'.join(lines))
        objects.append(b'<< /Length %d /Filter /FlateDecode >>\nstream\n' % len(data) + data + b'\nendstream')
    objects[0] = b'<< /Type /Catalog /Pages 2 0 R >>'
    objects[1] = b'<< /Type /Pages /Count %d /Kids [' % len(kids) + b' '.join(kids) + b'] >>'
    result = bytearray(b'%PDF-1.7\n%\xe2\xe3\xcf\xd3\n')
    offsets = [0]
    for index, data in enumerate(objects, 1):
        offsets.append(len(result))
        result.extend(b'%d 0 obj\n' % index + data + b'\nendobj\n')
    start = len(result)
    result.extend(b'xref\n0 %d\n0000000000 65535 f \n' % len(offsets))
    for offset in offsets[1:]:
        result.extend(b'%010d 00000 n \n' % offset)
    result.extend(b'trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n' % (len(offsets), start))
    return bytes(result)
