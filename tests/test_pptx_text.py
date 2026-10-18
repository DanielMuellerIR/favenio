"""PPTX: tatsächliche Folien-/Objekt-/Absatzbelege und begrenzter Paketleser."""
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
from pptx_fixture import pptx_bytes, slide, shape, table, paragraph, PML, DML, OFFICE, REL
from package_text_fixture import package
from swift_test_support import run_probe, suite_binary

REPO = Path(__file__).resolve().parents[1]

class PPTXTextTests(TempTreeTest):
    @classmethod
    def setUpClass(cls): suite_binary()

    def setUp(self):
        super().setUp()
        patch = mock.patch.dict(os.environ, FAVENIO_PDF_HELPER=''); patch.start(); self.addCleanup(patch.stop)
        self.path = Path(self.root, 'report.pptx'); self.path.write_bytes(pptx_bytes())

    def search(self, *options, path=None, pattern='Jahresbericht'):
        code, lines, errors = run(['--json','--search-report','--content-preview','--document-text',*options,pattern,str(path or self.path)])
        self.assertTrue(lines, errors)
        records = [json.loads(line) for line in lines]
        return code, [x for x in records if x['type'] != 'searchReport'], records[-1], errors

    def negative(self):
        return run(['--json','--document-text',*arguments(leaf('n','content',value='absent',negate=True)),str(self.path)])

    def request(self, hit, occurrence=1, context=False):
        return dict(schemaVersion=1,hit=hit,filePath=str(self.path),fileGeneration=favenio.source_generation(str(self.path)),queryIndex=0,occurrence=occurrence,context=context)

    def rewrite(self, name, value=None):
        with zipfile.ZipFile(self.path) as archive:
            items = [(x.filename, archive.read(x)) for x in archive.infolist() if x.filename != name]
        if value is not None: items.append((name,value))
        self.path.write_bytes(package(items))

    def test_runs_table_and_presentation_order(self):
        code,hits,report,errors = self.search(); self.assertEqual((code,errors),(0,'')); self.assertEqual(len(hits),1)
        hit = hits[0]; self.assertEqual(hit['contentEncoding'],'pptx-text-v1')
        self.assertEqual(hit['documentPosition'],dict(kind='pptxParagraph',part='ppt/slides/z.xml',slide=1,objectID='2',objectKind='shape',paragraph=1,line=1))
        self.assertEqual(hit['contentPreview']['snippets'][0]['query']['documentReader'],'pptx-v1')
        self.assertEqual(report['coverage'],'withinRequestedScope')
        positions = [favenio.load_content_preview(self.request(hit,i))['contentPreview']['snippets'][0]['documentPosition'] for i in range(3)]
        self.assertEqual([(x['part'],x['slide'],x['objectID']) for x in positions],[('ppt/slides/z.xml',1,'2'),('ppt/slides/z.xml',1,'3'),('ppt/slides/a.xml',2,'7')])
        self.assertEqual((positions[1]['row'],positions[1]['column']),(1,1))

    def test_unicode_original_encoding_entities_breaks_and_no_cross_paragraph_match(self):
        text = paragraph('\ufeffJahres','bericht 😀 fu\u0308r & < >').replace('</a:p>','<a:br/><a:r><a:t>Zweite Zeile</a:t></a:r></a:p>')
        self.path.write_bytes(pptx_bytes(slides=[('slides/z.xml',slide(shape(2,text,paragraph('A'),paragraph('B'))))]))
        hit = self.search('--encoding=windows-1252')[1][0]
        self.assertTrue(hit['contentPreview']['snippets'][0]['text'].startswith('\ufeffJahresbericht 😀 fu\u0308r & < >'))
        self.assertEqual(hit['contentPreview']['snippets'][0]['query']['encoding'],'windows-1252')
        self.assertEqual(self.search('--exact',pattern='Zweite Zeile')[1][0]['documentPosition']['line'],2)
        self.assertEqual(self.search(pattern='AB')[0],1)
        self.assertEqual(self.search(pattern='für')[0],0)

    def test_table_cells_have_independent_paragraph_numbers_and_rows(self):
        self.path.write_bytes(pptx_bytes(slides=[('slides/z.xml',slide(table(8,[paragraph('A'),paragraph('B')],[paragraph('C')+paragraph('Jahres','bericht'),paragraph('D')])))]))
        pos = self.search()[1][0]['documentPosition']
        self.assertEqual((pos['row'],pos['column'],pos['paragraph'],pos['objectID']),(2,1,2,'8'))
        self.assertEqual(self.search(pattern='AB')[0],1)

    def test_nested_groups_use_object_ids_and_xml_order(self):
        group_xml = '<p:grpSp><p:nvGrpSpPr><p:cNvPr id="6"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/>'+shape(9,paragraph('First Jahresbericht'))+shape(2,paragraph('Second Jahresbericht'))+'</p:grpSp>'
        self.path.write_bytes(pptx_bytes(slides=[('slides/z.xml',slide(group_xml))]))
        hit = self.search()[1][0]
        self.assertEqual(hit['documentPosition']['objectID'],'9')
        self.assertEqual(favenio.load_content_preview(self.request(hit))['contentPreview']['snippets'][0]['documentPosition']['objectID'],'2')

    def test_notes_masters_layouts_comments_fields_charts_foreign_and_attributes_excluded(self):
        body = shape(2,paragraph('Visible').replace('</a:p>','<a:fld id="field" type="slidenum"><a:t>FIELD_ONLY</a:t></a:fld></a:p>'))
        body += '<p:graphicFrame><p:nvGraphicFramePr><p:cNvPr id="3" name="ATTRIBUTE_ONLY"/></p:nvGraphicFramePr><a:graphic><a:graphicData><a:t>CHART_ONLY</a:t></a:graphicData></a:graphic></p:graphicFrame>'
        body += '<p:extLst>'+shape(8,paragraph('EXTENSION_ONLY'))+'</p:extLst>'
        extras = [('ppt/notesSlides/notes.xml',slide(shape(4,paragraph('NOTE_ONLY')))),('ppt/slideMasters/master.xml','MASTER_ONLY'),('ppt/slideLayouts/layout.xml','LAYOUT_ONLY'),('ppt/comments/comment.xml','COMMENT_ONLY'),('ppt/embeddings/foreign.xml','FOREIGN_ONLY')]
        self.path.write_bytes(pptx_bytes(slides=[('slides/z.xml',slide(body,hidden=True))],extra=extras))
        self.assertEqual(self.search(pattern='Visible')[0],0)
        for text in ['FIELD_ONLY','CHART_ONLY','ATTRIBUTE_ONLY','EXTENSION_ONLY','NOTE_ONLY','MASTER_ONLY','LAYOUT_ONLY','COMMENT_ONLY','FOREIGN_ONLY','TECHNICAL_NAME']:
            self.assertEqual(self.search(pattern=text)[0],1,text)
        self.assertEqual(self.negative()[0],0)

    def test_unsigned_object_ids_include_zero_and_reject_numeric_duplicates(self):
        self.path.write_bytes(pptx_bytes(slides=[('slides/z.xml',slide(shape('0000',paragraph('Jahresbericht'))))]))
        hit=self.search()[1][0];self.assertEqual(hit['documentPosition']['objectID'],'0')
        self.assertEqual(json.loads(run_probe('content-preview','parse',input=json.dumps(hit)+'\n').stdout)['status'],'ready')
        self.path.write_bytes(pptx_bytes(slides=[('slides/z.xml',slide(shape('2',paragraph('A'))+shape('+0002',paragraph('B'))))]))
        self.assertEqual(self.negative()[0],1)

    def test_empty_projection_known_and_blank_paragraphs_count(self):
        self.path.write_bytes(pptx_bytes(slides=[('slides/z.xml',slide(shape(2,paragraph(),paragraph('Jahresbericht'))))]))
        self.assertEqual(self.search()[1][0]['documentPosition']['paragraph'],2)
        self.path.write_bytes(pptx_bytes(slides=[]));self.assertEqual(self.negative()[0],0)
        self.path.write_bytes(pptx_bytes(slides=[('slides/z.xml',slide(''))]));self.assertEqual(self.negative()[0],0)

    def test_multiple_terms_criteria_facts_and_cheap_or(self):
        result = self.search('--term=Zweiter'); self.assertEqual(result[0],0,result[3])
        self.assertEqual([x['documentPosition']['slide'] for x in result[1][0]['terms']],[1,2])
        tree = group('all','and',leaf('name','name',value='report'),leaf('path','relativePath',value='report'),leaf('content','content',value='Tabelle'),leaf('size','size',operator='atLeast',value='1'))
        result=self.search(*arguments(tree));self.assertEqual(result[0],0,result[3])
        evidence=next(x for x in result[1][0]['criteriaEvidence'] if x['id']=='content');self.assertEqual(evidence['documentPosition']['objectKind'],'table')
        with mock.patch.object(favenio.PPTXTextReader,'sections',side_effect=AssertionError('ungefragt')):
            result=run(['--json','--document-text',*arguments(group('any','or',leaf('n','name',value='report'),leaf('c','content',value='absent'))),str(self.path)])
        self.assertEqual(result[0],0,result[2])

    def test_missing_external_wrong_relation_and_later_positive(self):
        self.rewrite('ppt/slides/z.xml')
        result=self.search();self.assertEqual(result[0],0);self.assertEqual(result[1][0]['documentPosition']['slide'],2);self.assertEqual(result[2]['coverage'],'incomplete');self.assertEqual(self.negative()[0],1)
        for change in ['Target="https://example.invalid/slide" TargetMode="External"','Target="slides/z.xml" Type="bad"','Target="../../../escape"']:
            self.path.write_bytes(pptx_bytes())
            with zipfile.ZipFile(self.path) as archive: data=archive.read('ppt/_rels/presentation.xml.rels').decode()
            self.rewrite('ppt/_rels/presentation.xml.rels',data.replace('Target="slides/z.xml"',change))
            self.assertEqual(self.negative()[0],1)

    def test_corrupt_xml_relationships_and_identity_prevent_negative_proof(self):
        variants = [b'broken',pptx_bytes(slides=[('slides/z.xml','<broken>')]),pptx_bytes(slides=[('slides/z.xml',slide(shape(2,paragraph('A'))+shape(2,paragraph('B'))))]),pptx_bytes(slides=[('slides/z.xml',slide(shape(-1,paragraph('A'))))]),pptx_bytes(slides=[('slides/z.xml',slide(shape(4294967296,paragraph('A'))))])]
        for data in variants:
            self.path.write_bytes(data);self.assertEqual(self.negative()[0],1)
        for name,data in [('ppt/slides/z.xml','<!DOCTYPE s [<!ENTITY x "boom">]><s/>'),('ppt/presentation.xml','<broken>'),('_rels/.rels',f'<Relationships xmlns="{REL}"><Relationship Id="r" Type="{OFFICE}/officeDocument" Target="ppt/presentation.xml"/><Relationship Id="r"/></Relationships>')]:
            self.path.write_bytes(pptx_bytes());self.rewrite(name,data);self.assertEqual(self.negative()[0],1)

    def test_early_positive_does_not_read_broken_tail_or_missing_later_slide(self):
        self.path.write_bytes(pptx_bytes(slides=[('slides/z.xml',slide(shape(2,paragraph('Jahresbericht')))+'<broken'),('slides/a.xml',None)]))
        self.assertEqual(self.search()[2]['coverage'],'withinRequestedScope');self.assertEqual(self.negative()[0],1)

    def test_strict_namespaces_and_xml_utf16(self):
        with zipfile.ZipFile(self.path) as archive:items=[(x.filename,archive.read(x).decode().replace(PML,'http://purl.oclc.org/ooxml/presentationml/main').replace(DML,'http://purl.oclc.org/ooxml/drawingml/main').replace(OFFICE,'http://purl.oclc.org/ooxml/officeDocument/relationships')) for x in archive.infolist()]
        self.path.write_bytes(package(items));self.assertEqual(self.search()[0],0)
        self.rewrite('ppt/slides/z.xml',('<?xml version="1.0" encoding="UTF-16"?>'+slide(shape(2,paragraph('Jahresbericht')))).encode('utf-16'));self.assertEqual(self.search()[0],0)

    def test_all_shared_and_pptx_limits_and_archive_budgets(self):
        for constant,value in [('DOCUMENT_BYTES',10),('DOCUMENT_ZIP_ENTRIES',1),('DOCUMENT_CATALOG_BYTES',10),('DOCUMENT_METADATA_BYTES',10),('DOCUMENT_XML_BYTES',10),('DOCUMENT_TOTAL_XML_BYTES',10),('DOCUMENT_PARAGRAPH_BYTES',3),('DOCUMENT_TEXT_BYTES',3),('DOCUMENT_XML_DEPTH',2),('PPTX_SLIDES',0),('PPTX_OBJECTS',0),('DOCUMENT_PARAGRAPHS',0),('PPTX_TABLE_CELLS',0),('PPTX_TABLE_ROWS',0)]:
            with self.subTest(constant=constant),mock.patch.object(favenio,constant,value):
                result=self.search(pattern='absent');self.assertEqual(result[0],1);self.assertIn('documentLimit',[x['id'] for x in result[2]['reasons']]);self.assertEqual(self.negative()[0],1)
        self.assertEqual(self.search('--max-archive-total-bytes=10')[0],1)

    def test_actual_slide_object_paragraph_and_table_cell_caps(self):
        cases = [pptx_bytes(slides=[('slides/s'+str(i)+'.xml',slide('')) for i in range(65)]),pptx_bytes(slides=[('slides/z.xml',slide(''.join(shape(i+2) for i in range(32769))))]),pptx_bytes(slides=[('slides/z.xml',slide(shape(2,*([paragraph()]*32769))))]),pptx_bytes(slides=[('slides/z.xml',slide(table(3,['']*131073).replace('<a:txBody><a:bodyPr/><a:lstStyle/></a:txBody>','<a:txBody/>')))])]
        for data in cases:
            self.path.write_bytes(data);result=self.search('--max-archive-ratio=100000',pattern='absent');self.assertIn('documentLimit',[x['id'] for x in result[2]['reasons']])

    def test_empty_table_rows_cannot_produce_locator_beyond_swift_boundary(self):
        self.path.write_bytes(pptx_bytes(slides=[('slides/z.xml',slide(table(3,*([[]]*131072),[paragraph('Jahresbericht')])))]))
        result=self.search();self.assertEqual(result[0],1)
        self.assertIn('documentLimit',[x['id'] for x in result[2]['reasons']])
        self.assertEqual(self.negative()[0],1)

    def test_actual_paragraph_text_and_xml_caps(self):
        cases=[pptx_bytes(slides=[('slides/z.xml',slide(shape(2,paragraph('x'*(262144+1)))))]),pptx_bytes(slides=[('slides/z.xml',('<?xml version="1.0" encoding="UTF-16"?>'+slide(shape(2,*([paragraph('漢'*70000)]*40)))).encode('utf-16'))]),pptx_bytes(slides=[('slides/z.xml',slide('<!--'+'x'*(8*1024*1024)+'-->'))])]
        for data in cases:
            self.path.write_bytes(data);result=self.search('--max-archive-ratio=100000',pattern='absent');self.assertIn('documentLimit',[x['id'] for x in result[2]['reasons']])

    def test_actual_total_xml_limit_and_invalid_table_structure(self):
        self.path.write_bytes(pptx_bytes(slides=[('slides/s'+str(i)+'.xml',slide(('<!--'+'x'*1000+'-->')*7300)) for i in range(5)]))
        result=self.search('--max-archive-ratio=100000',pattern='absent')
        self.assertIn('documentLimit',[x['id'] for x in result[2]['reasons']])
        for body in [table(3,[paragraph('A')]).replace('a:txBody','a:missing'),table(3,[paragraph('A')]).replace(DML+'/table','bad'),shape(2,paragraph('A')).replace('</p:sp>','<p:txBody><a:p/></p:txBody></p:sp>')]:
            self.path.write_bytes(pptx_bytes(slides=[('slides/z.xml',slide(body))]))
            self.assertEqual(self.negative()[0],1)

    def test_navigation_context_end_and_source_generation(self):
        hit=self.search()[1][0]
        value=favenio.load_content_preview(self.request(hit,0,True))['contentPreview']
        self.assertEqual(value['navigation']['contextLines'][0]['documentPosition']['paragraph'],2)
        self.assertEqual(favenio.load_content_preview(self.request(hit,3))['contentPreview']['navigation']['reason'],'end')
        request=self.request(hit);self.path.write_bytes(pptx_bytes(slides=[]));self.assertEqual(favenio.load_content_preview(request)['contentPreview']['status'],'sourceChanged')
        self.path.write_bytes(pptx_bytes());original=favenio.PPTXTextReader.sections
        def changed(instance,*args):
            for section in original(instance,*args):self.path.write_bytes(b'changed');yield section
        with mock.patch.object(favenio.PPTXTextReader,'sections',changed):self.assertEqual(self.search()[0],1)

    def test_archived_identity_raw_name_bytes_materialization_and_raw_mode(self):
        archive_path=Path(self.root,'archive.tar')
        with tarfile.open(archive_path,'w') as archive:
            data=self.path.read_bytes();info=tarfile.TarInfo('folder!/bad-\udcff.pptx');info.size=len(data);archive.addfile(info,io.BytesIO(data))
        result=self.search(path=archive_path);self.assertEqual(result[0],0,result[3]);self.assertIn('archiveMemberBytes',result[1][0]);self.assertIn('folder!/',result[1][0]['archiveMembers'][0])
        self.assertEqual(self.search('--archive-depth=0',path=archive_path)[0],1);self.assertEqual(self.search('--no-archives')[0],0)
        code,rows,errors=run(['--json','--content','TECHNICAL_NAME',str(self.path)]);self.assertEqual(code,0,errors);self.assertTrue(json.loads(rows[0])['archiveMembers'])

    def test_first_hit_parses_only_one_small_prefix(self):
        self.path.write_bytes(pptx_bytes(slides=[('slides/z.xml',slide(shape(2,paragraph('Jahresbericht'),*([paragraph('x'*1000)]*4000))))]))
        original=favenio.PPTXTextReader.chunks;read=[]
        def chunks(instance,archive,name,metadata=False):
            for chunk in original(instance,archive,name,metadata):
                if not metadata:read.append((name,len(chunk)))
                yield chunk
        with mock.patch.object(favenio.PPTXTextReader,'chunks',chunks):self.assertEqual(self.search()[0],0)
        self.assertEqual(sum(size for name,size in read),8192)

    def test_timeout_sigterm_and_materialization_cleanup(self):
        self.path.write_bytes(pptx_bytes(slides=[('slides/z.xml',slide(shape(2,paragraph('a'*20000+'X'))))]))
        with mock.patch.object(favenio,'DOCUMENT_SECONDS',.02):self.assertIn('documentTimeout',[x['id'] for x in self.search('--regex',pattern='(a+)+$')[2]['reasons']])
        archive=Path(self.root,'cancel.zip')
        with zipfile.ZipFile(archive,'w') as output:output.writestr('deck.pptx',self.path.read_bytes())
        scratch=Path(self.root,'scratch');scratch.mkdir()
        p=subprocess.Popen([sys.executable,str(REPO/'favenio.py'),'--document-text','--regex','(a+)+$',str(archive)],stdout=subprocess.PIPE,stderr=subprocess.PIPE,env=dict(os.environ,TMPDIR=str(scratch)))
        try:
            end=time.monotonic()+4
            while not list(scratch.glob('*.pptx')) and p.poll() is None and time.monotonic()<end:time.sleep(.01)
            self.assertTrue(list(scratch.glob('*.pptx')));p.send_signal(signal.SIGTERM);p.communicate(timeout=3);self.assertFalse(list(scratch.glob('*.pptx')))
        finally:
            if p.poll() is None:p.kill();p.communicate()

    def test_sigterm_during_temporary_file_ownership_assignment_cleans_materialization(self):
        archive = Path(self.root, 'cancel-ownership.zip')
        with zipfile.ZipFile(archive, 'w') as output:
            output.writestr('deck.pptx', self.path.read_bytes())
        scratch = Path(self.root, 'ownership-scratch'); scratch.mkdir()
        script = """
import importlib.util, os, signal, sys, tempfile
spec = importlib.util.spec_from_file_location('ownership_probe', sys.argv[1])
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)
original = tempfile._mkstemp_inner
def interrupted(*args, **kwargs):
    result = original(*args, **kwargs)
    if args[2] == '.pptx':
        os.kill(os.getpid(), signal.SIGTERM)
    return result
tempfile._mkstemp_inner = interrupted
raise SystemExit(module.main(['--document-text', 'Jahresbericht', sys.argv[2]]))
"""
        result = subprocess.run([sys.executable, '-c', script, str(REPO / 'favenio.py'), str(archive)],
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                env=dict(os.environ, TMPDIR=str(scratch)), timeout=5)
        self.assertEqual(result.returncode, 128 + signal.SIGTERM, result.stderr.decode(errors='replace'))
        self.assertEqual(list(scratch.iterdir()), [])

    def test_swift_navigation_export_validation_and_byte_identity(self):
        hit=self.search()[1][0];report=json.loads(run_probe('content-preview','pptx',str(REPO/'favenio.py'),input=json.dumps(hit)+'\n').stdout)
        for key in ['partByteIdentity','roundtrip','positionExport','location','csv','configuration','initial','next','previous','context','offCancels']:self.assertTrue(report[key],(key,report))
        for change in [{'slide':0},{'slide':65},{'slide':True},{'objectID':'-1'},{'objectID':'4294967296'},{'objectID':'02'},{'objectID':2},{'objectKind':'chart'},{'paragraph':0},{'row':1},{'sheet':'bad'}]:
            value=json.loads(json.dumps(hit));value['documentPosition'].update(change)
            with self.assertRaises(RuntimeError):run_probe('content-preview','parse',input=json.dumps(value)+'\n')
        table_hit=self.search(pattern='Tabelle')[1][0]
        for change in [{'row':0},{'column':True},{'column':131073}]:
            value=json.loads(json.dumps(table_hit));value['documentPosition'].update(change)
            with self.assertRaises(RuntimeError):run_probe('content-preview','parse',input=json.dumps(value)+'\n')
        value=json.loads(json.dumps(hit));value['contentPreview']['snippets'][0]['query']['documentReader']='xlsx-v1'
        self.assertEqual(json.loads(run_probe('content-preview','parse',input=json.dumps(value)+'\n').stdout)['status'],'invalid')

if __name__=='__main__':unittest.main()
