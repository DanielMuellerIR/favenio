"""Kleine synthetische ODT-/EPUB-Pakete, unabhängig von Office-Programmen."""
import io
import zipfile

OFFICE = 'urn:oasis:names:tc:opendocument:xmlns:office:1.0'
TEXT = 'urn:oasis:names:tc:opendocument:xmlns:text:1.0'
TABLE = 'urn:oasis:names:tc:opendocument:xmlns:table:1.0'
MANIFEST = 'urn:oasis:names:tc:opendocument:xmlns:manifest:1.0'
OPF = 'http://www.idpf.org/2007/opf'
CONTAINER = 'urn:oasis:names:tc:opendocument:xmlns:container'

def package(entries):
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
        for name, data in entries:
            archive.writestr(name, data)
    return buffer.getvalue()

def odt_xml(body):
    return f'<office:document-content xmlns:office="{OFFICE}" xmlns:text="{TEXT}" xmlns:table="{TABLE}"><office:body><office:text>{body}</office:text></office:body></office:document-content>'

def odt_bytes(body='<text:p>Jahres<text:span>bericht</text:span></text:p>', extra=(), raw=False):
    manifest=f'<manifest:manifest xmlns:manifest="{MANIFEST}"><manifest:file-entry manifest:full-path="/" manifest:media-type="application/vnd.oasis.opendocument.text"/></manifest:manifest>'
    return package([('mimetype','application/vnd.oasis.opendocument.text'),('META-INF/manifest.xml',manifest),('content.xml',body if raw else odt_xml(body)),*extra])

def html(body):
    return f'<!DOCTYPE html><html xmlns="http://www.w3.org/1999/xhtml"><head><title>TITLE_ONLY</title></head><body>{body}</body></html>'

def epub_bytes(first=None, second=None, spine=None, manifest=None, extra=()):
    first = html('<p>Jahres<em>bericht</em> 😀 fu&#x308;r &amp; Text</p><p>Kontextmitte</p>') if first is None else first
    second = html('<p>Zweites Jahres<b>bericht</b></p>') if second is None else second
    manifest = '<item id="a" href="a.xhtml" media-type="application/xhtml+xml"/><item id="z" href="z.xhtml" media-type="application/xhtml+xml"/>' if manifest is None else manifest
    spine = '<itemref idref="z"/><itemref idref="a"/>' if spine is None else spine
    container=f'<container xmlns="{CONTAINER}"><rootfiles><rootfile full-path="OPS/book.opf" media-type="application/oebps-package+xml"/></rootfiles></container>'
    opf=f'<package xmlns="{OPF}" version="3.0"><manifest>{manifest}</manifest><spine>{spine}</spine></package>'
    # Katalog und Namen stehen absichtlich entgegen der Spine-Reihenfolge.
    return package([('mimetype','application/epub+zip'),('META-INF/container.xml',container),('OPS/book.opf',opf),('OPS/a.xhtml',second),('OPS/z.xhtml',first),*extra])
