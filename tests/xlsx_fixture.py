"""Synthetische SpreadsheetML-Pakete mit absichtlich vertauschten Teilnamen."""
from xml.sax.saxutils import escape
import re
from package_text_fixture import package

SML = 'http://schemas.openxmlformats.org/spreadsheetml/2006/main'
REL = 'http://schemas.openxmlformats.org/package/2006/relationships'
OFFICE = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships'
TYPES = 'http://schemas.openxmlformats.org/package/2006/content-types'

def rich(*parts):
    return ''.join('<r><t xml:space="preserve">'+escape(text)+'</t></r>' for text in parts)

def cell(address, value=None, kind='s', formula=None):
    text=f'<c r="{address}" t="{kind}">'
    if formula is not None:text+='<f>'+escape(formula)+'</f>'
    if value is not None:text+=('<is>'+value+'</is>') if kind=='inlineStr' else '<v>'+escape(str(value))+'</v>'
    return text+'</c>'

def worksheet(cells, namespace=SML):
    rows = []
    for item in re.findall(r'<c\b.*?</c>', cells, re.S):
        match = re.search(r' r="[A-Z]+([0-9]+)"', item)
        number = match[1] if match else '1'
        if rows and rows[-1][0] == number: rows[-1][1].append(item)
        else: rows.append((number,[item]))
    content = ''.join(f'<row r="{number}">'+''.join(items)+'</row>' for number,items in rows)
    return f'<worksheet xmlns="{namespace}"><sheetData>{content}</sheetData></worksheet>'

def xlsx_bytes(first=None, second=None, strings=None, sheets=None, extra=(), namespace=SML):
    strings = '<si>'+rich('Jahres','bericht')+'</si><si><t>UNUSED_ONLY</t></si>' if strings is None else strings
    first = cell('A1','0')+cell('A2',rich('Kontextmitte'),kind='inlineStr')+cell('A3','0') if first is None else first
    second = cell('B2',rich('Zweiter Jahres','bericht'),kind='inlineStr') if second is None else second
    sheets = [('Übersicht','worksheets/z.xml',first),('Archiv','worksheets/a.xml',second)] if sheets is None else sheets
    rootrels=f'<Relationships xmlns="{REL}"><Relationship Id="root" Type="{OFFICE}/officeDocument" Target="xl/workbook.xml"/></Relationships>'
    workbook=f'<workbook xmlns="{namespace}" xmlns:r="{OFFICE}"><sheets>'+''.join(f'<sheet name="{escape(name, {chr(34): "&quot;"})}" sheetId="{i}" r:id="s{i}"/>' for i,(name,part,body) in enumerate(sheets,1))+'</sheets></workbook>'
    rels=f'<Relationships xmlns="{REL}">'+''.join(f'<Relationship Id="s{i}" Type="{OFFICE}/worksheet" Target="{part}"/>' for i,(name,part,body) in enumerate(sheets,1))
    if strings is not False:rels+=f'<Relationship Id="strings" Type="{OFFICE}/sharedStrings" Target="sharedStrings.xml"/>'
    rels+='</Relationships>'
    types=f'<Types xmlns="{TYPES}"><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/></Types>'
    entries=[('_rels/.rels',rootrels),('[Content_Types].xml',types),('xl/workbook.xml',workbook),('xl/_rels/workbook.xml.rels',rels)]
    for name,part,body in reversed(sheets):
        if body is not None:entries.append(('xl/'+part,body if isinstance(body,bytes) or body.startswith('<worksheet') or body.startswith('<?xml') else worksheet(body,namespace)))
    if strings is not False:entries.append(('xl/sharedStrings.xml',f'<sst xmlns="{namespace}">{strings}</sst>'))
    return package([*entries,*extra])
