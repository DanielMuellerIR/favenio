"""XLSX: reale Zellbelege, begrenzte Strings und ausdrücklich gespeicherte Werte."""
import io
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tarfile
import time
import unittest
from unittest import mock
import zipfile

from test_favenio import TempTreeTest, favenio, run
from test_criteria import arguments, group, leaf
from xlsx_fixture import xlsx_bytes, cell, rich, worksheet, SML, OFFICE, REL
from package_text_fixture import package
from swift_test_support import run_probe, suite_binary

REPO = Path(__file__).resolve().parents[1]

class XLSXTextTests(TempTreeTest):
    @classmethod
    def setUpClass(cls):suite_binary()

    def setUp(self):
        super().setUp()
        patch=mock.patch.dict(os.environ,FAVENIO_PDF_HELPER='');patch.start();self.addCleanup(patch.stop)
        self.path=Path(self.root,'report.xlsx');self.path.write_bytes(xlsx_bytes())

    def search(self,*options,path=None,pattern='Jahresbericht'):
        code,lines,errors=run(['--json','--search-report','--content-preview','--document-text',*options,pattern,str(path or self.path)])
        records=[json.loads(line) for line in lines]
        return code,[x for x in records if x['type']!='searchReport'],records[-1],errors

    def negative(self,path=None):
        return run(['--json','--document-text',*arguments(leaf('n','content',value='absent',negate=True)),str(path or self.path)])

    def request(self,hit,occurrence=1,context=False):
        return dict(schemaVersion=1,hit=hit,filePath=str(self.path),fileGeneration=favenio.source_generation(str(self.path)),queryIndex=0,occurrence=occurrence,context=context)

    def rewrite(self,name,value=None):
        with zipfile.ZipFile(self.path) as archive:items=[(x.filename,archive.read(x)) for x in archive.infolist() if x.filename!=name]
        if value is not None:items.append((name,value))
        self.path.write_bytes(package(items))

    def test_shared_inline_and_workbook_order(self):
        code,hits,report,errors=self.search();self.assertEqual((code,errors),(0,''));self.assertEqual(len(hits),1)
        hit=hits[0];self.assertEqual(hit['contentEncoding'],'xlsx-text-v1')
        self.assertEqual(hit['documentPosition'],dict(kind='xlsxCell',part='xl/worksheets/z.xml',sheet='Übersicht',sheetIndex=1,cell='A1',valueKind='text',line=1))
        self.assertEqual(hit['contentPreview']['snippets'][0]['query']['documentReader'],'xlsx-v1')
        self.assertEqual(report['coverage'],'withinRequestedScope')
        values=[]
        for occurrence in range(3):values.append(favenio.load_content_preview(self.request(hit,occurrence))['contentPreview']['snippets'][0]['documentPosition'])
        self.assertEqual([(x['sheet'],x['cell']) for x in values],[('Übersicht','A1'),('Übersicht','A3'),('Archiv','B2')])

    def test_unused_shared_strings_never_match_or_open_when_unneeded(self):
        self.assertEqual(self.search(pattern='UNUSED_ONLY')[0],1)
        original=favenio.XLSXTextReader.strings_in;seen=[]
        def strings(instance,*args):
            for text in original(instance,*args):seen.append(text);yield text
        with mock.patch.object(favenio.XLSXTextReader,'strings_in',strings):self.assertEqual(self.search()[0],0)
        self.assertEqual(seen,['Jahresbericht'])
        self.path.write_bytes(xlsx_bytes(first=cell('A1',rich('Inline Jahresbericht'),kind='inlineStr'),strings=False))
        with mock.patch.object(favenio.XLSXTextReader,'strings_in',side_effect=AssertionError('ungefragt')):self.assertEqual(self.search()[0],0)

    def test_out_of_order_references_share_one_progressive_string_reader(self):
        self.path.write_bytes(xlsx_bytes(first=cell('A1',2)+cell('A2',0)+cell('A3',2),strings='<si><t>alpha</t></si><si><t>unused</t></si><si><t>omega</t></si>'))
        original=favenio.XLSXTextReader.strings_in
        with mock.patch.object(favenio.XLSXTextReader,'strings_in',autospec=True,side_effect=original) as reader:
            code,hits,_,errors=self.search('--term=alpha',pattern='omega')
        self.assertEqual(code,0,errors);self.assertEqual(reader.call_count,1)
        self.assertEqual([x['documentPosition']['cell'] for x in hits[0]['terms']],['A1','A2'])

    def test_inline_runs_unicode_entities_ooxml_escapes_and_phonetics(self):
        value=rich('\ufeffJahres','bericht 😀 fu\u0308r & < >')+'<rPh><t>PHONETIC_ONLY</t></rPh>'
        self.path.write_bytes(xlsx_bytes(first=cell('A1',value,kind='inlineStr')+cell('A2',rich('_x0041__x000D_Second _x005F_x0041_ _xD83D__xDE00_'),kind='inlineStr')))
        hit=self.search('--encoding=windows-1252')[1][0]
        self.assertTrue(hit['contentPreview']['snippets'][0]['text'].startswith('\ufeffJahresbericht 😀 fu\u0308r & < >'))
        self.assertEqual(self.search(pattern='PHONETIC_ONLY')[0],1)
        self.assertEqual(self.search('--exact',pattern='A')[0],0)
        h=self.search(pattern='Second _x0041_ 😀')[1][0];self.assertEqual(h['documentPosition']['line'],2)

    def test_formula_text_excluded_and_cached_values_explicit(self):
        self.path.write_bytes(xlsx_bytes(first=cell('A1','Jahresbericht',kind='str',formula='FORMULA_ONLY()')+cell('B1','123.40',kind='n',formula='SUM(A2:A3)')+cell('C1','1',kind='b',formula='TRUE()')+cell('D1','2026-10-18',kind='d',formula='DATE(2026,10,18)')))
        for text,kind in [('Jahresbericht','cachedString'),('123.40','cachedNumber'),('TRUE','cachedBoolean'),('2026-10-18','cachedDate')]:
            self.assertEqual(self.search(pattern=text)[1][0]['documentPosition']['valueKind'],kind)
        self.assertEqual(self.search(pattern='FORMULA_ONLY')[0],1)
        self.assertEqual(self.search(pattern='SUM(A2:A3)')[0],1)

    def test_plain_scalars_remain_unformatted_and_style_text_is_not_content(self):
        self.path.write_bytes(xlsx_bytes(first=cell('A1','45300',kind='n')+cell('B1','0',kind='b')+cell('C1','2026-10-18T12:34:56Z',kind='d'),extra=[('xl/styles.xml','<styles>FORMAT_ONLY</styles>')]))
        for text,kind in [('45300','number'),('FALSE','boolean'),('2026-10-18T12:34:56Z','date')]:self.assertEqual(self.search(pattern=text)[1][0]['documentPosition']['valueKind'],kind)
        self.assertEqual(self.search(pattern='FORMAT_ONLY')[0],1)
        self.assertEqual(self.search(pattern='2024')[0],1)

    def test_missing_formula_cache_errors_bad_types_and_references_are_unknown(self):
        variants=[cell('A1',formula='1+1'),cell('A1','#DIV/0!',kind='e'),cell('A1','NaN',kind='n'),cell('A1','2',kind='b'),cell('A1','not-date',kind='d'),cell('A1','0',kind='future'),cell('A1',kind='future'),cell('A1','999'),cell('A1','-1')]
        for body in variants:
            with self.subTest(body=body):
                self.path.write_bytes(xlsx_bytes(first=body,second=cell('A1','0')))
                self.assertEqual(self.search()[0],0)
                self.assertEqual(self.search()[2]['coverage'],'incomplete')
                self.assertEqual(self.negative()[0],1)

    def test_blank_and_empty_string_cells_are_known(self):
        self.path.write_bytes(xlsx_bytes(first=cell('A1',kind='n')+cell('A2','',kind='str',formula='""')+cell('A3','',kind='inlineStr'),second='',strings=False))
        self.assertEqual(self.search()[0],1);self.assertEqual(self.negative()[0],0)

    def test_comments_drawings_hidden_cells_and_sheets_policy(self):
        self.path.write_bytes(xlsx_bytes(first=cell('A1',rich('HIDDEN_TEXT'),kind='inlineStr'),extra=[('xl/comments1.xml','COMMENT_ONLY'),('xl/drawings/drawing1.xml','DRAWING_ONLY')]))
        with zipfile.ZipFile(self.path) as archive:workbook=archive.read('xl/workbook.xml').decode();sheet=archive.read('xl/worksheets/z.xml').decode()
        self.rewrite('xl/workbook.xml',workbook.replace('sheetId="1"','sheetId="1" state="veryHidden"'))
        self.rewrite('xl/worksheets/z.xml',sheet.replace('<row r="1">','<row r="1" hidden="1">').replace('<c r="A1"','<c s="1" r="A1"'))
        self.assertEqual(self.search(pattern='HIDDEN_TEXT')[0],0)
        for text in ['COMMENT_ONLY','DRAWING_ONLY','veryHidden']:self.assertEqual(self.search(pattern=text)[0],1)

    def test_multiple_terms_mixed_criteria_and_cheap_or(self):
        result=self.search('--term=Kontextmitte');self.assertEqual(result[0],0);self.assertEqual(result[1][0]['terms'][1]['documentPosition']['cell'],'A2')
        tree=group('r','and',leaf('name','name',value='report'),leaf('path','relativePath',value='report.xlsx'),leaf('content','content',value='Zweiter'))
        code,rows,errors=run(['--json','--document-text',*arguments(tree),str(self.path)]);self.assertEqual(code,0,errors)
        self.assertEqual(json.loads(rows[0])['criteriaEvidence'][-1]['documentPosition']['sheetIndex'],2)
        tree=group('r','or',leaf('name','name',value='report'),leaf('body','content',value='absent'))
        with mock.patch.object(favenio.XLSXTextReader,'sections',side_effect=AssertionError('ungefragt')):self.assertEqual(run(['--document-text',*arguments(tree),str(self.path)])[0],0)

    def test_cells_are_separate_search_lines(self):
        self.path.write_bytes(xlsx_bytes(first=cell('A1',rich('Jahres'),kind='inlineStr')+cell('A2',rich('bericht'),kind='inlineStr'),second='',strings=False))
        self.assertEqual(self.search()[0],1)

    def test_missing_sheets_and_shared_parts_prevent_negative_but_not_earlier_hit(self):
        self.path.write_bytes(xlsx_bytes(sheets=[('Erstes','worksheets/z.xml',cell('A1',0)),('Fehlt','worksheets/a.xml',None)]))
        self.assertEqual(self.search()[2]['coverage'],'withinRequestedScope');self.assertEqual(self.negative()[0],1)
        self.rewrite('xl/sharedStrings.xml');self.assertEqual(self.search()[0],1);self.assertEqual(self.negative()[0],1)

    def test_broken_later_shared_tail_is_not_scanned_for_report(self):
        self.rewrite('xl/sharedStrings.xml',f'<sst xmlns="{SML}"><si><t>Jahresbericht</t></si><broken')
        self.assertEqual(self.search()[2]['coverage'],'withinRequestedScope')
        # Alle Zellen referenzieren nur den bereits bekannten ersten String.
        self.assertEqual(self.negative()[0],0)

    def test_corrupt_package_metadata_xml_dtd_and_duplicate_cells(self):
        variants=[b'broken',xlsx_bytes(first='<c r="A1" t="str"><v>value</v><is><t>conflict</t></is></c>',second=''),xlsx_bytes(first=cell('A1',0)+cell('A1',0)),xlsx_bytes(first=cell('XFE1',0)),xlsx_bytes(first=cell('A1048577',0)),xlsx_bytes(first=cell('A1',rich('_xD800_'),kind='inlineStr'),second='')]
        for data in variants:
            self.path.write_bytes(data);self.assertEqual(self.negative()[0],1)
        for name,data in [('xl/workbook.xml','<broken>'),('xl/sharedStrings.xml','<!DOCTYPE s [<!ENTITY x "boom">]><s/>'),('xl/_rels/workbook.xml.rels',f'<Relationships xmlns="{REL}"><Relationship Id="s1" Type="{OFFICE}/worksheet" Target="../../../escape"/></Relationships>')]:
            self.path.write_bytes(xlsx_bytes());self.rewrite(name,data);self.assertEqual(self.negative()[0],1)

    def test_original_xml_encoding_and_strict_namespace(self):
        self.path.write_bytes(xlsx_bytes(namespace='http://purl.oclc.org/ooxml/spreadsheetml/main'))
        self.assertEqual(self.search()[0],0)
        self.rewrite('xl/worksheets/z.xml',('<?xml version="1.0" encoding="UTF-16"?>'+worksheet(cell('A1',rich('Jahresbericht'),kind='inlineStr'))).encode('utf-16'))
        self.assertEqual(self.search()[0],0)

    def test_limits_and_archive_budgets(self):
        for constant,value in [('DOCUMENT_BYTES',10),('DOCUMENT_ZIP_ENTRIES',1),('DOCUMENT_CATALOG_BYTES',10),('DOCUMENT_METADATA_BYTES',10),('DOCUMENT_XML_BYTES',10),('DOCUMENT_TOTAL_XML_BYTES',10),('DOCUMENT_PARAGRAPH_BYTES',3),('DOCUMENT_TEXT_BYTES',3),('DOCUMENT_XML_DEPTH',2),('DOCUMENT_PARTS',0),('XLSX_CELLS',0),('XLSX_SHARED_STRINGS',0),('XLSX_SHARED_TEXT_BYTES',3)]:
            with self.subTest(constant=constant),mock.patch.object(favenio,constant,value):
                result=self.search();self.assertEqual(result[0],1);self.assertIn('documentLimit',[x['id'] for x in result[2]['reasons']]);self.assertEqual(self.negative()[0],1)
        self.assertEqual(self.search('--max-archive-total-bytes=10')[0],1)

    def test_navigation_context_and_source_generation(self):
        hit=self.search()[1][0]
        value=favenio.load_content_preview(self.request(hit,0,True))['contentPreview']
        self.assertEqual(value['navigation']['contextLines'][0]['documentPosition']['cell'],'A2')
        request=self.request(hit);self.path.write_bytes(xlsx_bytes(first=cell('A1',0)))
        self.assertEqual(favenio.load_content_preview(request)['contentPreview']['status'],'sourceChanged')
        original=favenio.XLSXTextReader.sections
        def changed(instance,*args):
            for section in original(instance,*args):self.path.write_bytes(b'changed');yield section
        with mock.patch.object(favenio.XLSXTextReader,'sections',changed):self.assertEqual(self.search()[0],1)

    def test_archived_xlsx_identity_raw_name_bytes_and_archive_depth(self):
        archive_path=Path(self.root,'archive.tar')
        with tarfile.open(archive_path,'w') as archive:
            data=self.path.read_bytes();info=tarfile.TarInfo('folder!/bad-\udcff.xlsx');info.size=len(data);archive.addfile(info,io.BytesIO(data))
        result=self.search(path=archive_path);self.assertEqual(result[0],0,result[3]);self.assertIn('archiveMemberBytes',result[1][0]);self.assertIn('folder!/',result[1][0]['archiveMembers'][0])
        self.assertEqual(self.search('--archive-depth=0',path=archive_path)[0],1)
        self.assertEqual(self.search('--no-archives')[0],0)
        code,rows,errors=run(['--json','--content','UNUSED_ONLY',str(self.path)]);self.assertEqual(code,0,errors);self.assertTrue(json.loads(rows[0])['archiveMembers'])

    def test_first_hit_reads_only_small_sheet_and_shared_prefixes(self):
        self.path.write_bytes(xlsx_bytes(first=cell('A1',0)+''.join(cell('A'+str(i),rich('x'*1000),kind='inlineStr') for i in range(2,4002)),strings='<si><t>Jahresbericht</t></si>'+('<si><t>'+'x'*1000+'</t></si>')*4000))
        original=favenio.XLSXTextReader.chunks;read=[]
        def chunks(instance,archive,name,metadata=False):
            for chunk in original(instance,archive,name,metadata):
                if not metadata:read.append((name,len(chunk)))
                yield chunk
        with mock.patch.object(favenio.XLSXTextReader,'chunks',chunks):self.assertEqual(self.search()[0],0)
        self.assertLess(sum(size for name,size in read),20000)

    def test_actual_cell_and_sheet_caps(self):
        self.path.write_bytes(xlsx_bytes(first=''.join(cell(chr(65+(i%26))+str(i//26+1),kind='n') for i in range(131073)),second='',strings=False))
        result=self.search('--max-archive-ratio=100000',pattern='absent');self.assertEqual(result[0],1);self.assertIn('documentLimit',[x['id'] for x in result[2]['reasons']])
        self.path.write_bytes(xlsx_bytes(sheets=[('Blatt'+str(i),'worksheets/s'+str(i)+'.xml','') for i in range(65)],strings=False))
        self.assertIn('documentLimit',[x['id'] for x in self.search()[2]['reasons']])

    def test_actual_string_index_cache_cell_and_document_text_caps(self):
        cases = [
            xlsx_bytes(first=cell('A1',65536),strings='<si><t/></si>'*65537,second=''),
            xlsx_bytes(first=cell('A1',rich('x'*(256*1024+1)),kind='inlineStr'),second='',strings=False),
            xlsx_bytes(first=''.join(cell('A'+str(i),0) for i in range(1,9001)),strings='<si><t>'+'x'*1024+'</t></si>',second=''),
        ]
        for data in cases:
            self.path.write_bytes(data);result=self.search('--max-archive-ratio=100000',pattern='absent')
            self.assertEqual(result[0],1);self.assertIn('documentLimit',[x['id'] for x in result[2]['reasons']])
        self.path.write_bytes(xlsx_bytes(first=cell('A1',39),second=''))
        xml='<?xml version="1.0" encoding="UTF-16"?>'+f'<sst xmlns="{SML}">'+('<si><t>'+'漢'*70000+'</t></si>')*40+'</sst>'
        self.rewrite('xl/sharedStrings.xml',xml.encode('utf-16'))
        result=self.search('--max-archive-ratio=100000',pattern='absent')
        self.assertEqual(result[0],1);self.assertIn('documentLimit',[x['id'] for x in result[2]['reasons']])

    def test_inconsistent_row_address_duplicate_relationship_and_external_sheet(self):
        self.rewrite('xl/worksheets/z.xml',f'<worksheet xmlns="{SML}"><sheetData><row r="2">'+cell('A1',0)+'</row></sheetData></worksheet>')
        self.assertEqual(self.negative()[0],1)
        self.path.write_bytes(xlsx_bytes())
        with zipfile.ZipFile(self.path) as archive:rels=archive.read('xl/_rels/workbook.xml.rels').decode()
        self.rewrite('xl/_rels/workbook.xml.rels',rels.replace('</Relationships>',f'<Relationship Id="s1" Type="{OFFICE}/worksheet" Target="worksheets/a.xml"/></Relationships>'))
        self.assertEqual(self.negative()[0],1)
        self.path.write_bytes(xlsx_bytes())
        self.rewrite('xl/_rels/workbook.xml.rels',rels.replace('Target="worksheets/z.xml"','Target="https://example.invalid/sheet" TargetMode="External"'))
        result=self.search();self.assertEqual(result[0],0);self.assertEqual(result[2]['coverage'],'incomplete');self.assertEqual(self.negative()[0],1)

    def test_timeout_and_sigterm_clear_materialization(self):
        self.path.write_bytes(xlsx_bytes(first=cell('A1',rich('a'*20000+'X'),kind='inlineStr')))
        with mock.patch.object(favenio,'DOCUMENT_SECONDS',.02):self.assertIn('documentTimeout',[x['id'] for x in self.search('--regex',pattern='(a+)+$')[2]['reasons']])
        archive=Path(self.root,'cancel.zip')
        with zipfile.ZipFile(archive,'w') as output:output.writestr('book.xlsx',self.path.read_bytes())
        scratch=Path(self.root,'scratch');scratch.mkdir()
        p=subprocess.Popen([sys.executable,str(REPO/'favenio.py'),'--document-text','--regex','(a+)+$',str(archive)],stdout=subprocess.PIPE,stderr=subprocess.PIPE,env=dict(os.environ,TMPDIR=str(scratch)))
        try:
            end=time.monotonic()+4
            while not list(scratch.glob('*.xlsx')) and p.poll() is None and time.monotonic()<end:time.sleep(.01)
            self.assertTrue(list(scratch.glob('*.xlsx')));p.send_signal(signal.SIGTERM);p.communicate(timeout=3);self.assertFalse(list(scratch.glob('*.xlsx')))
        finally:
            if p.poll() is None:p.kill();p.communicate()

    def test_swift_cell_navigation_export_and_byte_identity(self):
        hit=self.search()[1][0];r=run_probe('content-preview','xlsx',str(REPO/'favenio.py'),input=json.dumps(hit)+'\n');report=json.loads(r.stdout)
        for key in ['sheetByteIdentity','partByteIdentity','roundtrip','positionExport','location','csv','configuration','initial','next','previous','context','offCancels']:self.assertTrue(report[key],(key,report))
        self.path.write_bytes(xlsx_bytes(first=cell('A1',0)+cell('A2',formula='1+1'),second=''))
        unavailable=self.search()[1][0]
        result=run_probe('content-preview','xlsx-unavailable',str(REPO/'favenio.py'),input=json.dumps(unavailable)+'\n')
        self.assertTrue(json.loads(result.stdout)['unavailable'])
        for change in [{'cell':'XFE1'},{'cell':'A0'},{'cell':'A1048577'},{'cell':'a1'},{'sheetIndex':0},{'sheetIndex':65},{'sheetIndex':True},{'sheet':''},{'valueKind':'formula'},{'paragraph':1}]:
            value=json.loads(json.dumps(hit));value['documentPosition'].update(change)
            with self.assertRaises(RuntimeError):run_probe('content-preview','parse',input=json.dumps(value)+'\n')
        value=json.loads(json.dumps(hit));value['contentPreview']['snippets'][0]['query']['documentReader']='epub-v1'
        self.assertEqual(json.loads(run_probe('content-preview','parse',input=json.dumps(value)+'\n').stdout)['status'],'invalid')

if __name__=='__main__':unittest.main()
