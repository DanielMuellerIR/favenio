"""Synthetische Folienpakete mit vertauschter ZIP- und Präsentationsreihenfolge."""
from xml.sax.saxutils import escape
from package_text_fixture import package
from xlsx_fixture import REL, OFFICE, TYPES

PML = 'http://schemas.openxmlformats.org/presentationml/2006/main'
DML = 'http://schemas.openxmlformats.org/drawingml/2006/main'

def paragraph(*runs):
    return '<a:p>'+''.join('<a:r><a:t xml:space="preserve">'+escape(text)+'</a:t></a:r>' for text in runs)+'</a:p>'

def shape(identifier, *paragraphs):
    return f'<p:sp><p:nvSpPr><p:cNvPr id="{identifier}" name="TECHNICAL_NAME"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr><p:spPr/><p:txBody><a:bodyPr/><a:lstStyle/>'+''.join(paragraphs)+'</p:txBody></p:sp>'

def table(identifier, *rows):
    return f'<p:graphicFrame><p:nvGraphicFramePr><p:cNvPr id="{identifier}" name="TABLE_NAME"/><p:cNvGraphicFramePr/><p:nvPr/></p:nvGraphicFramePr><p:xfrm/><a:graphic><a:graphicData uri="{DML}/table"><a:tbl><a:tblPr/><a:tblGrid/>'+''.join('<a:tr>'+''.join('<a:tc><a:txBody><a:bodyPr/><a:lstStyle/>'+value+'</a:txBody><a:tcPr/></a:tc>' for value in row)+'</a:tr>' for row in rows)+'</a:tbl></a:graphicData></a:graphic></p:graphicFrame>'

def slide(body, hidden=False):
    return f'<p:sld xmlns:p="{PML}" xmlns:a="{DML}"'+(' show="0"' if hidden else '')+'><p:cSld><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/>'+body+'</p:spTree></p:cSld></p:sld>'

def pptx_bytes(slides=None, extra=()):
    slides = [('slides/z.xml',slide(shape(2,paragraph('Jahres','bericht'),paragraph('Kontextmitte'))+table(3,[paragraph('Jahresbericht Tabelle')]))),('slides/a.xml',slide(shape(7,paragraph('Zweiter Jahresbericht')),hidden=True))] if slides is None else slides
    roots=f'<Relationships xmlns="{REL}"><Relationship Id="root" Type="{OFFICE}/officeDocument" Target="ppt/presentation.xml"/></Relationships>'
    presentation=f'<p:presentation xmlns:p="{PML}" xmlns:r="{OFFICE}"><p:sldIdLst>'+''.join(f'<p:sldId id="{255+i}" r:id="s{i}"/>' for i,_ in enumerate(slides,1))+'</p:sldIdLst></p:presentation>'
    rels=f'<Relationships xmlns="{REL}">'+''.join(f'<Relationship Id="s{i}" Type="{OFFICE}/slide" Target="{part}"/>' for i,(part,body) in enumerate(slides,1))+'</Relationships>'
    types=f'<Types xmlns="{TYPES}"><Override PartName="/ppt/presentation.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"/></Types>'
    entries=[('_rels/.rels',roots),('[Content_Types].xml',types),('ppt/presentation.xml',presentation),('ppt/_rels/presentation.xml.rels',rels)]
    entries += [('ppt/'+part,body) for part,body in reversed(slides) if body is not None]
    return package([*entries,*extra])
