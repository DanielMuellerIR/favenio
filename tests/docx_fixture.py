"""Kleine OOXML-Pakete ohne Office-Abhängigkeit für Leser- und App-Prüfungen."""
import io
import zipfile
from xml.sax.saxutils import escape

WORD = 'http://schemas.openxmlformats.org/wordprocessingml/2006/main'
REL = 'http://schemas.openxmlformats.org/package/2006/relationships'
OFFICE_REL = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships/'


def paragraph(*runs):
    return '<w:p>' + ''.join('<w:r><w:t xml:space="preserve">' + escape(run) + '</w:t></w:r>' for run in runs) + '</w:p>'


def part_xml(body, kind='document', namespace=WORD):
    tag = {'document': 'document', 'header': 'hdr', 'footer': 'ftr', 'footnote': 'footnotes', 'endnote': 'endnotes'}[kind]
    if kind == 'document': body = '<w:body>' + body + '</w:body>'
    return ('<?xml version="1.0" encoding="UTF-8"?><w:' + tag + ' xmlns:w="' + namespace + '">' + body + '</w:' + tag + '>').encode('utf-8')


def docx_bytes(body, parts=(), extra=(), main='word/document.xml'):
    target = io.BytesIO()
    with zipfile.ZipFile(target, 'w', zipfile.ZIP_DEFLATED) as archive:
        archive.writestr('[Content_Types].xml', '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Override PartName="/' + main + '" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>')
        archive.writestr('_rels/.rels', '<Relationships xmlns="' + REL + '"><Relationship Id="main" Type="' + OFFICE_REL + 'officeDocument" Target="' + main + '"/></Relationships>')
        archive.writestr(main, body if isinstance(body, bytes) else part_xml(body))
        if parts:
            directory, _, name = main.rpartition('/')
            relationships = []
            for index, (kind, name_in_zip, text) in enumerate(parts):
                relationships.append('<Relationship Id="part' + str(index) + '" Type="' + OFFICE_REL + kind + '" Target="' + name_in_zip.removeprefix(directory + '/') + '"/>')
                if text is not None: archive.writestr(name_in_zip, text)
            archive.writestr(directory + '/_rels/' + name + '.rels', '<Relationships xmlns="' + REL + '">' + ''.join(relationships) + '</Relationships>')
        for name, value in extra: archive.writestr(name, value)
    return target.getvalue()
